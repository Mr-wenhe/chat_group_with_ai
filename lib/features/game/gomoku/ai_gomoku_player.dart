/// AI 角色玩家：让 App 里现成的 [AICharacter] 以五子棋选手身份落子。
///
/// 把「棋盘状态 → 人设化 prompt → 模型决策 → 坐标解析」封装成一次调用。
/// 依赖全部可注入（ChatApiService / ApiCredentialResolver），便于用假实现单测
/// prompt 构造与容错，不依赖真实网络或 Keychain。
library;

import 'dart:async';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart' show CancelToken;

import 'ai_move_decision.dart';
import 'ai_move_parser.dart';
import 'gomoku_board.dart';
import 'gomoku_budget_resolver.dart';
import 'gomoku_player.dart';

export 'ai_move_decision.dart';

/// 让一个 AI 角色在五子棋对局中落子。
class AiGomokuPlayer implements GomokuPlayer {
  final AICharacter character;

  /// 角色绑定的模型配置；为空表示该角色没接入模型（此时会快速失败，
  /// 由上层的内置棋力辅助接手）。
  final ApiConfig? config;
  final ChatApiService _api;
  final ApiCredentialResolver _credentials;

  /// 按模型能力计算输出预算；未注入时用保守兜底值。
  final GomokuBudgetResolver _budgetResolver;

  /// 读取该角色的历史五子棋经历；记忆读取失败不能中断对局。
  final String Function()? _gameExperienceLoader;

  /// 单次请求的接收超时。对弈有节奏要求，一步棋不该吊住整局。
  ///
  /// 实测正常落子 6~7s；偶发上游卡顿会撞超时线。这里给 18s，配合游戏层
  /// 1 次重试，单步硬上限约 36s——不会出现「名义超时 45s、实际底层重试
  /// 叠加成 65s」的失控耗时。
  final Duration requestTimeout;

  AiGomokuPlayer({
    required this.character,
    this.config,
    ChatApiService? api,
    ApiCredentialResolver? credentials,
    GomokuBudgetResolver? budgetResolver,
    String Function()? gameExperienceLoader,
    this.requestTimeout = const Duration(seconds: 18),
  })  : _api = api ?? ChatApiService(),
        _credentials = credentials ?? SecureApiCredentialResolver(),
        _budgetResolver =
            budgetResolver ?? ((_, __) => kGomokuFallbackMaxTokens),
        _gameExperienceLoader = gameExperienceLoader;

  /// 该角色是否具备落子条件（已绑定配置且有凭据）。
  bool get isPlayable => config?.hasCredential ?? false;

  /// 游戏层的重试次数（不含首次）。
  ///
  /// 底层 `ChatApiService.sendChatMessage` 的 5 次重试已被显式关闭
  /// （见下方 maxRetries: 0），重试统一收口到这一层。1 次重试 + 18s 单次
  /// 超时 ⇒ 单步硬上限约 36s，不会像之前那样被底层放大到 65s。
  static const int _maxRetries = 1;

  /// 退避上限：服务端给了 retryAfter 时也封顶，避免一步卡太久。
  static const int _maxRetryDelayMs = 1500;

  /// 五子棋专用战术规则：让模型按胜负威胁检查落点，而不只生成合法坐标。
  static const String _gomokuTacticalPrompt = '''
【五子棋战术判断】
落子前先根据棋盘和落子清单核对双方棋子位置，再按以下优先级判断：
1. 如果自己有一步成五的点，立即获胜。
2. 检查对手所有一步成五的点；存在时必须优先封堵。若对手有多个必胜点而无法全堵，选择能立即获胜或最大限度制造反击威胁的点。
3. 检查对手的冲四、活四和双重威胁，优先阻止下一回合将无法防守的局面。
4. 检查双方活三。若对手活三下一步能形成活四、双活三或其他强制威胁，应及时封堵或抢先制造更强威胁；不要只数棋子、不看两端和后续变化。自己的活三若能形成连续攻势，优先考虑。
5. 逐个比较候选点：假设对手作出最强回应，排除会让对手立即成五或建立必胜威胁的走法；同时考虑自己的下一步。
6. 只有没有更高优先级的攻防威胁时，才按连线形状和位置选择普通布局点。
只输出一句简短战术理由和最终坐标，不要输出详细推理过程。不得把已占位置当作候选点。''';

  /// 请模型落一子。
  ///
  /// 刻意走非流式而非 [ChatApiService.streamChatMessage]：推理模型（DeepSeek /
  /// 各类国内中转）普遍把答案写进 `reasoning_content`，正文 `content` 留空；
  /// 流式通道会把 reasoning 当私有思考过滤掉，导致解析器永远拿不到坐标。
  /// 非流式的 `allowReasoningContentFallback: true` 会把 reasoning 作为正文
  /// 返回，是这类模型能做结构化决策的关键。
  ///
  /// 防「思考吃光预算」：首次就用 JSON-first 的紧凑 prompt（见 _buildMessages），
  /// 从源头抑制推理模型长篇思考；重试时进一步收紧。
  ///
  /// [onThinking] 保留作接口兼容（当前非流式无增量，不触发）。
  @override
  Future<AiMoveDecision> decideMove({
    required GomokuBoard board,
    required GomokuStone myStone,
    CancelToken? cancelToken,
    void Function(String delta)? onThinking,
  }) async {
    final stopwatch = Stopwatch()..start();
    int elapsed() => stopwatch.elapsedMilliseconds;

    final cfg = config;
    if (cfg == null) {
      return AiMoveDecision.failure(
        '${character.name} 未绑定模型配置',
        elapsedMs: elapsed(),
      );
    }
    final apiKey = await _credentials.resolve(cfg);
    if (apiKey == null || apiKey.isEmpty) {
      return AiMoveDecision.failure(
        '${character.name} 未配置可用密钥',
        elapsedMs: elapsed(),
      );
    }

    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == cfg.provider,
      orElse: () => ApiProvider.custom,
    );

    String gameExperience = '';
    try {
      gameExperience = _gameExperienceLoader?.call().trim() ?? '';
    } on Object {
      // Memory is an enhancement; a read failure must not block a move.
    }

    String lastReasoning = '';
    String lastError = '未能从回复中解析出落子坐标';
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      // 紧凑度逐轮升级：首次就要求 JSON-first，重试再进一步只给坐标。
      final messages = _buildMessages(
        board: board,
        myStone: myStone,
        compact: attempt >= 1,
        gameExperience: gameExperience,
      );

      final Map<String, dynamic> result;
      try {
        result = await _api.sendChatMessage(
          apiKey: apiKey,
          provider: provider,
          apiProtocol: cfg.protocol,
          customBaseUrl: cfg.customBaseUrl,
          userAgent: cfg.userAgentOverride,
          model: cfg.modelName,
          messages: messages,
          temperature: 0.0, // 落子是确定性决策，低温减少发散与废话。
          maxTokens: _budgetResolver(provider, cfg.modelName),
          receiveTimeout: requestTimeout,
          // 关键：关掉底层默认的 5 次重试。否则每次超时都要等满
          // 45s×多轮，并叠加退避（现场：名义 45s 实际 65s）。
          // 重试统一交给游戏层这一层管理，单步耗时才有确定上限。
          maxRetries: 0,
          cancelToken: cancelToken,
          // 关键：推理模型只回 reasoning_content 时把它当正文，否则解析不到坐标。
          allowReasoningContentFallback: true,
        );
      } on Object catch (e) {
        lastError = '落子请求异常：$e';
        if (cancelToken?.isCancelled == true) break;
        await _backoff(attempt, null);
        continue;
      }

      if (result['success'] != true) {
        lastError = result['message']?.toString() ?? '模型请求失败';
        // 空响应把上游信号带进错误文本，观战区可见 finishReason / tokens。
        final detail = result['emptyCompletionDetail'];
        if (detail is Map && detail.isNotEmpty) {
          final signal =
              detail.entries.map((e) => '${e.key}=${e.value}').join(',');
          lastError = '$lastError（$signal）';
        }
        // 预算耗尽型空内容是确定性失败，原样重发只会再撞一次上限；
        // 靠下一轮的紧凑 prompt 换「要求」才有意义，这里不额外退避空转。
        if (cancelToken?.isCancelled == true) break;
        if (!_isBudgetExhausted(result)) {
          await _backoff(attempt, result['retryAfterMs']);
        }
        continue;
      }

      final reasoning = result['message']?.toString() ?? '';
      lastReasoning = reasoning;
      final position = GomokuMoveParser.parse(reasoning);
      if (position == null) {
        lastError = '未能从回复中解析出落子坐标';
        continue;
      }
      if (board.stoneAt(position.row, position.col) != null) {
        lastError = '模型给出的坐标已被占用';
        continue;
      }

      return AiMoveDecision.success(
        position,
        reasoning,
        elapsedMs: elapsed(),
      );
    }

    return AiMoveDecision.failure(
      lastError,
      reasoning: lastReasoning,
      elapsedMs: elapsed(),
    );
  }

  /// 是否因「输出长度上限」结束且没产出正文——推理模型思考吃光预算的典型信号。
  bool _isBudgetExhausted(Map<String, dynamic> result) {
    if (result['failureCode'] != 'emptyResponse') return false;
    final detail = result['emptyCompletionDetail'];
    if (detail is! Map) return false;
    final stop = detail['finishReason']?.toString().toLowerCase() ?? '';
    return stop == 'length' || stop == 'max_output_tokens';
  }

  /// 瞬时故障的退避等待：优先用服务端 retryAfter，否则指数退避，均封顶。
  Future<void> _backoff(int attempt, Object? retryAfterMs) async {
    final serverMs = retryAfterMs is int ? retryAfterMs : 0;
    final fallbackMs = 300 * (1 << attempt); // 300, 600, 1200, 2400, ...
    final ms = serverMs > 0 ? serverMs : fallbackMs;
    await Future<void>.delayed(
      Duration(milliseconds: ms.clamp(0, _maxRetryDelayMs)),
    );
  }

  /// 构造人设化 prompt：系统消息保留角色人格，用户消息给棋盘与输出契约。
  ///
  /// 首次就用 [compact] 之外的紧凑契约：直接给坐标 JSON、不展开推理。
  /// [compact]（重试轮）进一步收紧成「只输出 JSON」，且**第一个字符必须是 {**，
  /// 抑制推理模型把 token 预算全花在思考段。
  List<Map<String, dynamic>> _buildMessages({
    required GomokuBoard board,
    required GomokuStone myStone,
    bool compact = false,
    String gameExperience = '',
  }) {
    final formatRule = compact
        ? '只输出一个 JSON 对象，不要任何思考过程、解释或 markdown 代码块。'
            '你的第一个字符必须是 {，最后一个字符必须是 }，中间只有 row 和 col 两个数字。'
            '例如：{"row":7,"col":7}'
        : '直接给出落子，不要展开推理过程。可以先用角色口吻写一句短想法，'
            '但结尾必须单独一行输出 JSON：{"row":行号,"col":列号}。'
            '第一个输出字符不要是思考标记，尽早写出坐标。';
    return [
      {
        'role': 'system',
        'content': [
          character.rolePlaySystemPrompt,
          '现在你正在和对手下五子棋（15×15），你执${myStone.label}子（${myStone.symbol}）。',
          '棋盘坐标是 (行,列)，都从 0 开始，左上角是 (0,0)，右下角是 (14,14)。',
          _gomokuTacticalPrompt,
          if (gameExperience.isNotEmpty)
            '【过往五子棋对局记忆】\n$gameExperience\n结合当前局面重新判断，不要机械复刻历史棋步。',
          formatRule,
        ].join('\n'),
      },
      {
        'role': 'user',
        'content': [
          '当前棋盘（X=黑，O=白，.=空）：',
          board.renderAsText(),
          '轮到你落子。直接给坐标 JSON。',
        ].join('\n'),
      },
    ];
  }
}
