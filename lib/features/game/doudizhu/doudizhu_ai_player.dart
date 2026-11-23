import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart' show CancelToken;

import 'doudizhu_budget_resolver.dart';
import 'doudizhu_engine.dart';
import 'doudizhu_game_state.dart';
import 'doudizhu_move_generator.dart';
import 'doudizhu_rules.dart';

const Duration doudizhuModelRequestTimeout = Duration(seconds: 18);
const Duration doudizhuModelTurnTimeout = Duration(seconds: 37);
const int _doudizhuRetryDelayMilliseconds = 300;

const String doudizhuTacticalPrompt = '''
你正在以指定席位玩经典三人斗地主。目标是让自己的阵营先出完牌。只能使用自己的手牌和已公开的信息，未公开的牌只能按可能性推断。

叫分时，综合大王、小王、2、炸弹、顺子结构和预计拆成几手，评估拿到未知底牌后的领牌能力。在给出的合法选项中选择。

出牌时，先找能直接走完或能阻止对手立即走完的合法动作。否则比较候选出牌后的手数、保留下来的完整组合、拆牌成本、控制权和各家剩余张数；至少比较“少拆牌”“减少手数”“保留顶牌控制”几种方案。不能把剩余手数更少当作充分理由：除非能走完、必须救场，或拆牌确实减少手数且保住关键控制，否则不要拆对子、三张、顺子和连对。

2 和大小王是控制资源，不是普通高点牌。地主手牌仍多时，不要只因对子 2 点数最大就把它当普通开局牌打掉；如果对子 2 不能让整手牌更快成型，也没有阻止农民走完或夺回领出权的明确收益，应优先保留。根据公开出牌计数判断外面是否仍可能有更大的同点数对子、炸弹或王炸；不能把未见到的牌当成已经打出。农民优先阻止地主接手；队友领先且有机会走完时，考虑让牌。炸弹和火箭留给关键控制、阻止对手走完或自己的收尾计划。领出时必须出牌，跟牌时按局势决定是否过牌。

只返回一个 JSON 对象，字段为 actionId 和 say。actionId 必须来自本回合列表；say 是不超过 32 字的角色口吻公开台词，只回应本次动作，不透露手牌、底牌、牌点、私下计划或详细推理。没有合适台词时 say 返回空字符串，不附加其他字段或文本。
''';

class DoudizhuActionOption {
  const DoudizhuActionOption({
    required this.actionId,
    required this.action,
    required this.typeLabel,
    required this.cardIds,
    this.bidScore,
  });

  final String actionId;
  final DoudizhuAction action;
  final String typeLabel;
  final List<int> cardIds;
  final int? bidScore;

  String get compactLabel {
    if (action is DoudizhuBidAction) {
      final score = bidScore ?? 0;
      return score == 0 ? '不叫' : '$score 分';
    }
    if (action is DoudizhuPassAction) return '过牌';
    final face = cardIds.map(DoudizhuRules.compactCard).join(',');
    return '$typeLabel[$face]';
  }
}

/// Model-visible data is a seat projection; it has no reference to full state.
class DoudizhuAiTurnInput {
  DoudizhuAiTurnInput({
    required this.seat,
    required this.seatName,
    required this.teamLabel,
    required this.phase,
    required List<int> ownHand,
    required List<int?> bids,
    required List<int> handSizes,
    required List<DoudizhuGameLogEntry> publicLog,
    required List<DoudizhuActionOption> options,
    required this.highestBid,
    required this.landlord,
    required this.passCount,
    required this.multiplier,
    this.lastPlay,
    List<int>? publicBottom,
  })  : ownHand = List.unmodifiable(ownHand),
        bids = List.unmodifiable(bids),
        handSizes = List.unmodifiable(handSizes),
        publicLog = List.unmodifiable(publicLog),
        options = List.unmodifiable(options),
        publicBottom =
            publicBottom == null ? null : List.unmodifiable(publicBottom);

  final int seat;
  final String seatName;
  final String teamLabel;
  final DoudizhuPhase phase;
  final List<int> ownHand;
  final List<int?> bids;
  final List<int> handSizes;
  final List<DoudizhuGameLogEntry> publicLog;
  final List<DoudizhuActionOption> options;
  final int highestBid;
  final int landlord;
  final int passCount;
  final int multiplier;
  final DoudizhuTrick? lastPlay;
  final List<int>? publicBottom;

  DoudizhuEngineContext get engineContext => DoudizhuEngineContext(
        seat: seat,
        landlord: landlord,
        handSizes: handSizes,
        playedCounts: _playedCountsFromPublicLog(publicLog),
        passCount: passCount,
        lastPlaySeat: lastPlay?.seat ?? -1,
      );
}

enum DoudizhuModelFailure {
  unavailable,
  request,
  empty,
  format,
  illegalAction,
  promptTooLarge,
  cancelled,
}

class DoudizhuModelOutcome {
  const DoudizhuModelOutcome._({
    required this.action,
    required this.failure,
    required this.attempts,
    required this.publicLine,
    this.detail,
  });

  const DoudizhuModelOutcome.success(
    DoudizhuAction action,
    int attempts, {
    String publicLine = '',
  }) : this._(
          action: action,
          failure: null,
          attempts: attempts,
          publicLine: publicLine,
        );

  const DoudizhuModelOutcome.failed(
    DoudizhuModelFailure failure, {
    required int attempts,
    String? detail,
  }) : this._(
          action: null,
          failure: failure,
          attempts: attempts,
          publicLine: '',
          detail: detail,
        );

  final DoudizhuAction? action;
  final DoudizhuModelFailure? failure;
  final int attempts;
  final String publicLine;

  /// 底层 API 返回的结构化真实错误（如「连接超时」「HTTP 429 限流」），
  /// 仅用于日志诊断；测试里的异常路径不带此值，保证分类标签不变。
  final String? detail;

  bool get isSuccess => action != null && failure == null;
  bool get wasCancelled => failure == DoudizhuModelFailure.cancelled;
}

enum DoudizhuDecisionSource { characterModel, masterFallback }

class DoudizhuPlayerDecision {
  const DoudizhuPlayerDecision({
    required this.action,
    required this.source,
    required this.modelAttempts,
    this.publicLine = '',
    this.fallbackNote,
    this.engineElapsedMilliseconds,
    this.engineCandidateCount = 0,
    this.engineHandsBefore,
    this.engineHandsAfter,
    this.engineScore,
  });

  final DoudizhuAction action;
  final DoudizhuDecisionSource source;
  final int modelAttempts;
  final String publicLine;
  final String? fallbackNote;
  final int? engineElapsedMilliseconds;
  final int engineCandidateCount;
  final int? engineHandsBefore;
  final int? engineHandsAfter;
  final int? engineScore;
}

class DoudizhuHardDecision {
  const DoudizhuHardDecision({
    required this.action,
    required this.elapsedMilliseconds,
    required this.candidateCount,
    required this.handsBefore,
    required this.handsAfter,
    required this.score,
  });

  final DoudizhuAction action;
  final int elapsedMilliseconds;
  final int candidateCount;
  final int handsBefore;
  final int handsAfter;
  final int score;
}

abstract interface class DoudizhuHardMoveSelector {
  Future<DoudizhuHardDecision?> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  });
}

abstract interface class DoudizhuTurnPlayer {
  Future<DoudizhuPlayerDecision?> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  });
}

class DoudizhuCharacterPlayer implements DoudizhuTurnPlayer {
  const DoudizhuCharacterPlayer({
    required this.primary,
    required this.fallback,
  });

  final AiDoudizhuPlayer primary;
  final DoudizhuHardMoveSelector fallback;

  @override
  Future<DoudizhuPlayerDecision?> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  }) async {
    final model = await primary.decide(input, cancelToken: cancelToken);
    if (model.wasCancelled || cancelToken?.isCancelled == true) return null;
    final action = model.action;
    if (model.isSuccess &&
        action != null &&
        input.options.any((option) => _sameAction(option.action, action))) {
      return DoudizhuPlayerDecision(
        action: action,
        source: DoudizhuDecisionSource.characterModel,
        modelAttempts: model.attempts,
        publicLine: model.publicLine,
      );
    }
    if (input.phase == DoudizhuPhase.bidding) {
      return DoudizhuPlayerDecision(
        action: DoudizhuBidAction(_normalizedFallbackBid(input)),
        source: DoudizhuDecisionSource.masterFallback,
        modelAttempts: model.attempts,
        fallbackNote: _fallbackNote(model),
      );
    }

    final hard = await fallback.decide(input, cancelToken: cancelToken);
    if (cancelToken?.isCancelled == true) return null;
    if (hard != null && _isAllowed(input.options, hard.action)) {
      return DoudizhuPlayerDecision(
        action: hard.action,
        source: DoudizhuDecisionSource.masterFallback,
        modelAttempts: model.attempts,
        fallbackNote: _fallbackNote(model),
        engineElapsedMilliseconds: hard.elapsedMilliseconds,
        engineCandidateCount: hard.candidateCount,
        engineHandsBefore: hard.handsBefore,
        engineHandsAfter: hard.handsAfter,
        engineScore: hard.score,
      );
    }

    // Match upstream app.js recovery: pass while following; a lead must play.
    if (input.lastPlay != null) {
      return DoudizhuPlayerDecision(
        action: const DoudizhuPassAction(),
        source: DoudizhuDecisionSource.masterFallback,
        modelAttempts: model.attempts,
        fallbackNote: _fallbackNote(model),
      );
    }
    final moves = generateDoudizhuMoves(input.ownHand);
    if (moves.isEmpty) return null;
    return DoudizhuPlayerDecision(
      action: DoudizhuPlayAction(moves.last.cardIds),
      source: DoudizhuDecisionSource.masterFallback,
      modelAttempts: model.attempts,
      fallbackNote: _failureLabel(model.failure),
    );
  }
}

class DoudizhuBidStrategy {
  const DoudizhuBidStrategy._();

  static int score(List<int> hand) {
    final counts = DoudizhuRules.countsOf(hand);
    final points = counts[12] * 2 +
        (counts[13] > 0 ? 3 : 0) +
        (counts[14] > 0 ? 3 : 0) +
        counts[11];
    if (points >= 10) return 3;
    if (points >= 7) return 2;
    if (points >= 5) return 1;
    return 0;
  }
}

class AiDoudizhuPlayer {
  AiDoudizhuPlayer({
    required this.character,
    required this.config,
    ChatApiService? api,
    ApiCredentialResolver? credentials,
    DoudizhuBudgetResolver? budgetResolver,
    DoudizhuInputBudgetResolver? inputBudgetResolver,
    this.requestTimeout = doudizhuModelRequestTimeout,
    this.turnTimeout = doudizhuModelTurnTimeout,
  })  : _api = api ?? ChatApiService(),
        _credentials = credentials ?? SecureApiCredentialResolver(),
        _budgetResolver =
            budgetResolver ?? ((_, __) => doudizhuFallbackMaxTokens),
        _inputBudgetResolver = inputBudgetResolver ?? ((_, __) => 3840);

  final AICharacter character;
  final ApiConfig? config;
  final ChatApiService _api;
  final ApiCredentialResolver _credentials;
  final DoudizhuBudgetResolver _budgetResolver;
  final DoudizhuInputBudgetResolver _inputBudgetResolver;
  final Duration requestTimeout;
  final Duration turnTimeout;
  static const int _maxRetries = 1;

  bool get hasConfiguredModel => config?.hasCredential ?? false;

  Future<DoudizhuModelOutcome> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    if (cancelToken?.isCancelled == true) {
      return const DoudizhuModelOutcome.failed(
        DoudizhuModelFailure.cancelled,
        attempts: 0,
      );
    }
    if (input.options.isEmpty) {
      return const DoudizhuModelOutcome.failed(
        DoudizhuModelFailure.illegalAction,
        attempts: 0,
      );
    }
    final currentConfig = config;
    if (currentConfig == null || !currentConfig.hasCredential) {
      return const DoudizhuModelOutcome.failed(
        DoudizhuModelFailure.unavailable,
        attempts: 0,
      );
    }

    final String? apiKey;
    try {
      final credential = _credentials.resolve(currentConfig);
      final pending = <Future<String?>>[credential];
      if (cancelToken != null) {
        pending.add(cancelToken.whenCancel.then((_) {
          throw const _DoudizhuRequestCancelled();
        }));
      }
      apiKey = await Future.any(pending).timeout(_remaining(stopwatch));
    } on Object {
      if (cancelToken?.isCancelled == true) {
        return const DoudizhuModelOutcome.failed(
          DoudizhuModelFailure.cancelled,
          attempts: 0,
        );
      }
      return DoudizhuModelOutcome.failed(
        stopwatch.elapsed >= turnTimeout
            ? DoudizhuModelFailure.request
            : DoudizhuModelFailure.unavailable,
        attempts: 0,
      );
    }
    if (apiKey == null || apiKey.isEmpty) {
      return const DoudizhuModelOutcome.failed(
        DoudizhuModelFailure.unavailable,
        attempts: 0,
      );
    }
    if (cancelToken?.isCancelled == true) {
      return const DoudizhuModelOutcome.failed(
        DoudizhuModelFailure.cancelled,
        attempts: 0,
      );
    }

    final provider = ApiProvider.values.firstWhere(
      (candidate) => candidate.name == currentConfig.provider,
      orElse: () => ApiProvider.custom,
    );
    final outputBudget = _budgetResolver(provider, currentConfig.modelName);
    var lastFailure = DoudizhuModelFailure.request;
    // 底层结构化真实错误（连接超时 / HTTP 429 / 401 等），仅用于日志诊断。
    String? lastDetail;
    var attempts = 0;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      if (cancelToken?.isCancelled == true) {
        return DoudizhuModelOutcome.failed(
          DoudizhuModelFailure.cancelled,
          attempts: attempts,
        );
      }
      final remaining = _remaining(stopwatch);
      if (remaining <= Duration.zero) break;
      final inputBudget =
          _inputBudgetResolver(provider, currentConfig.modelName);
      var compact = attempt > 0;
      var messages = _buildMessages(input, compact: compact);
      if (ContextWindowManager.estimateRequestTokens(messages) > inputBudget &&
          !compact) {
        compact = true;
        messages = _buildMessages(input, compact: true);
      }
      if (ContextWindowManager.estimateRequestTokens(messages) > inputBudget) {
        lastFailure = DoudizhuModelFailure.promptTooLarge;
        break;
      }

      attempts++;
      final attemptTimeout =
          requestTimeout < remaining ? requestTimeout : remaining;
      final requestToken = CancelToken();
      if (cancelToken != null) {
        unawaited(cancelToken.whenCancel.then((_) {
          if (!requestToken.isCancelled) {
            requestToken.cancel('斗地主回合已取消');
          }
        }));
      }
      final Map<String, dynamic> response;
      try {
        final request = _api.sendChatMessage(
          apiKey: apiKey,
          provider: provider,
          apiProtocol: currentConfig.protocol,
          customBaseUrl: currentConfig.customBaseUrl,
          userAgent: currentConfig.userAgentOverride,
          model: currentConfig.modelName,
          messages: messages,
          temperature: 0,
          maxTokens: outputBudget,
          receiveTimeout: attemptTimeout,
          maxRetries: 0,
          cancelToken: requestToken,
          allowReasoningContentFallback: true,
        );
        final pending = <Future<Map<String, dynamic>>>[request];
        if (cancelToken != null) {
          pending.add(cancelToken.whenCancel.then((_) {
            throw const _DoudizhuRequestCancelled();
          }));
        }
        response = await Future.any(pending).timeout(
          attemptTimeout,
          onTimeout: () {
            requestToken.cancel('斗地主模型请求超时');
            throw TimeoutException('斗地主模型请求超时');
          },
        );
      } on Object {
        if (cancelToken?.isCancelled == true) {
          return DoudizhuModelOutcome.failed(
            DoudizhuModelFailure.cancelled,
            attempts: attempts,
          );
        }
        lastFailure = DoudizhuModelFailure.request;
        await _waitBeforeRetry(attempt, stopwatch, cancelToken);
        continue;
      } finally {
        if (!requestToken.isCancelled) requestToken.cancel('斗地主请求已结束');
      }

      if (cancelToken?.isCancelled == true) {
        return DoudizhuModelOutcome.failed(
          DoudizhuModelFailure.cancelled,
          attempts: attempts,
        );
      }
      if (response['success'] != true) {
        final message = response['message']?.toString().trim() ?? '';
        lastFailure =
            message.isEmpty || response['failureCode'] == 'emptyResponse'
                ? DoudizhuModelFailure.empty
                : DoudizhuModelFailure.request;
        // 记录底层真实错误：HTTP 状态码 + 友好文案 + 服务商原始错误。
        // 只保留简短一行，避免日志被冗长的 failureDetail 撑爆。
        final statusCode = response['statusCode'];
        final providerError = response['providerError']?.toString().trim();
        final parts = <String>[
          if (statusCode != null) 'HTTP $statusCode',
          if (message.isNotEmpty) message,
          if (providerError != null && providerError.isNotEmpty)
            '服务商：$providerError',
        ];
        if (parts.isNotEmpty) lastDetail = parts.join(' · ');
        await _waitBeforeRetry(attempt, stopwatch, cancelToken);
        continue;
      }

      final parsed = _parseModelReply(response['message']?.toString() ?? '');
      if (parsed == null) {
        lastFailure = DoudizhuModelFailure.format;
        await _waitBeforeRetry(attempt, stopwatch, cancelToken);
        continue;
      }
      final matches =
          input.options.where((item) => item.actionId == parsed.actionId);
      if (matches.length != 1) {
        lastFailure = DoudizhuModelFailure.illegalAction;
        await _waitBeforeRetry(attempt, stopwatch, cancelToken);
        continue;
      }
      return DoudizhuModelOutcome.success(
        matches.single.action,
        attempts,
        publicLine: parsed.publicLine,
      );
    }
    return DoudizhuModelOutcome.failed(
      lastFailure,
      attempts: attempts,
      detail: lastDetail,
    );
  }

  List<Map<String, dynamic>> _buildMessages(
    DoudizhuAiTurnInput input, {
    required bool compact,
  }) {
    final system = [
      character.rolePlaySystemPrompt,
      doudizhuTacticalPrompt,
    ].where((text) => text.trim().isNotEmpty).join('\n\n');
    final body = <String>[
      '席位：${input.seatName}；身份：${input.teamLabel}。',
      if (input.phase == DoudizhuPhase.bidding) '阶段：叫分。只可查看自己的手牌、公开叫分和选项。',
      if (input.phase == DoudizhuPhase.playing)
        '阶段：出牌。当前倍数 ×${input.multiplier}；本轮过牌数 ${input.passCount}。',
      '自己的手牌：${input.ownHand.map(DoudizhuRules.compactCard).join(' ')}。',
      if (input.phase == DoudizhuPhase.bidding) ...[
        '公开叫分：${_formatBids(input.bids)}。',
        '当前最高分：${input.highestBid}。',
      ],
      if (input.phase == DoudizhuPhase.playing) ...[
        if (input.landlord >= 0)
          '地主：${input.landlord == input.seat ? '本席' : '第${input.landlord + 1}席'}；剩余张数：${input.handSizes.join('/')}。',
        if (input.publicBottom != null)
          '已公开底牌：${input.publicBottom!.map(DoudizhuRules.compactCard).join(' ')}。',
        if (input.lastPlay != null)
          '当前待压：${input.lastPlay!.move.type.label} ${input.lastPlay!.move.cardIds.map(DoudizhuRules.compactCard).join(' ')}；由第${input.lastPlay!.seat + 1}席领出。',
        if (input.lastPlay == null) '当前无待压牌，本席必须领出。',
        '公开出牌与过牌记录：${_formatPublicLog(input.publicLog, compact: compact)}。',
      ],
      '本回合合法选项：',
      for (final option in input.options)
        '${option.actionId}=${option.typeLabel}[${_optionFace(option, compact)}]',
      '只返回一个 JSON 对象：{"actionId":"本回合列表中的 ID","say":"一句不超过 32 字的角色台词"}。say 只谈本次公开动作，不说明手牌、底牌、牌点、私下计划或详细推理；没有合适台词时返回空字符串。',
    ];
    return [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': body.join('\n')},
    ];
  }

  String _optionFace(DoudizhuActionOption option, bool compact) {
    if (option.action is DoudizhuBidAction) return option.compactLabel;
    if (option.action is DoudizhuPassAction) return '过牌';
    return option.cardIds
        .map(DoudizhuRules.compactCard)
        .join(compact ? '' : ',');
  }

  String _formatPublicLog(
    List<DoudizhuGameLogEntry> entries, {
    required bool compact,
  }) {
    if (entries.isEmpty) return '无';
    return entries.map((entry) {
      final seat = '席${entry.seat + 1}';
      return switch (entry.kind) {
        DoudizhuLogKind.bid =>
          seat + (entry.score == 0 ? '不叫' : '叫${entry.score}'),
        DoudizhuLogKind.pass => '$seat过',
        DoudizhuLogKind.play =>
          '$seat出${entry.type?.label ?? ''}:${entry.cardIds.map(DoudizhuRules.compactCard).join(compact ? '' : ',')}',
      };
    }).join('；');
  }

  Duration _remaining(Stopwatch stopwatch) {
    final remaining = turnTimeout - stopwatch.elapsed;
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  Future<void> _waitBeforeRetry(
    int attempt,
    Stopwatch stopwatch,
    CancelToken? cancelToken,
  ) async {
    if (attempt >= _maxRetries) return;
    final remaining = _remaining(stopwatch);
    if (remaining <= Duration.zero) return;
    final delay = Duration(
      milliseconds: _doudizhuRetryDelayMilliseconds * (attempt + 1),
    );
    final waits = <Future<void>>[
      Future<void>.delayed(delay < remaining ? delay : remaining),
    ];
    if (cancelToken != null) {
      waits.add(cancelToken.whenCancel.then<void>((_) {}));
    }
    await Future.any(waits);
  }
}

class _ParsedDoudizhuReply {
  const _ParsedDoudizhuReply(
      {required this.actionId, required this.publicLine});

  final String actionId;
  final String publicLine;
}

_ParsedDoudizhuReply? _parseModelReply(String text) {
  final candidates = _jsonObjectCandidates(text).toList(growable: false);
  for (final candidate in candidates.reversed) {
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is! Map<String, dynamic> || decoded['actionId'] is! String) {
        continue;
      }
      final say = decoded['say'];
      return _ParsedDoudizhuReply(
        actionId: decoded['actionId'] as String,
        // Providers sometimes append metadata despite the JSON-only request.
        // Ignore it; only the whitelisted action ID and safe public line leave
        // this parser, never free-form analysis.
        publicLine: _sanitizePublicLine(say is String ? say : ''),
      );
    } on FormatException {
      continue;
    }
  }
  return null;
}

Iterable<String> _jsonObjectCandidates(String text) sync* {
  var start = -1;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var index = 0; index < text.length; index++) {
    final character = text[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character == '\\') {
        escaped = true;
      } else if (character == '"') {
        inString = false;
      }
      continue;
    }
    if (character == '"' && depth > 0) {
      inString = true;
    } else if (character == '{') {
      if (depth == 0) start = index;
      depth++;
    } else if (character == '}' && depth > 0) {
      depth--;
      if (depth == 0 && start >= 0) {
        yield text.substring(start, index + 1);
        start = -1;
      }
    }
  }
}

String _sanitizePublicLine(String line) {
  final cleaned = line.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
  if (cleaned.isEmpty ||
      RegExp(
        r'(手牌|底牌|手里|手中|我有|我持|我留|我准备|我计划|我打算|王炸|炸弹|大王|小王|对子|顺子|连对|飞机|[2-9]|10|[AJQK]|[♠♥♣♦])',
      ).hasMatch(cleaned)) {
    return '';
  }
  final runes = cleaned.runes.toList();
  if (runes.length <= 32) return cleaned;
  return String.fromCharCodes(runes.take(32));
}

bool _isAllowed(List<DoudizhuActionOption> options, DoudizhuAction action) =>
    options.any((option) => _sameAction(option.action, action));

bool _sameAction(DoudizhuAction first, DoudizhuAction second) {
  if (first is DoudizhuBidAction && second is DoudizhuBidAction) {
    return first.score == second.score;
  }
  if (first is DoudizhuPassAction && second is DoudizhuPassAction) return true;
  if (first is DoudizhuPlayAction && second is DoudizhuPlayAction) {
    final a = first.cardIds.toSet();
    return a.length == second.cardIds.length &&
        second.cardIds.every(a.contains);
  }
  return false;
}

String _formatBids(List<int?> bids) =>
    bids.map((score) => score == null ? '未叫' : score.toString()).join('/');

int _normalizedFallbackBid(DoudizhuAiTurnInput input) {
  final score = DoudizhuBidStrategy.score(input.ownHand);
  return score != 0 && score <= input.highestBid ? 0 : score;
}

List<int> _playedCountsFromPublicLog(List<DoudizhuGameLogEntry> log) {
  final counts = List<int>.filled(doudizhuRankCount, 0);
  for (final entry in log) {
    if (entry.kind != DoudizhuLogKind.play) continue;
    for (final card in entry.cardIds) {
      counts[DoudizhuRules.rankOf(card)]++;
    }
  }
  return counts;
}

String _failureLabel(DoudizhuModelFailure? failure) => switch (failure) {
      DoudizhuModelFailure.unavailable => '角色模型或凭据不可用',
      DoudizhuModelFailure.request => '模型请求失败或超时',
      DoudizhuModelFailure.empty => '模型回复为空',
      DoudizhuModelFailure.format => '模型回复格式错误',
      DoudizhuModelFailure.illegalAction => '模型返回非法动作',
      DoudizhuModelFailure.promptTooLarge => '模型输入超出本回合预算',
      DoudizhuModelFailure.cancelled => '模型请求已取消',
      null => '模型未返回有效动作',
    };

/// 日志里的兜底原因：分类标签保持原样（测试与状态徽标依赖它），
/// 仅在底层给出了结构化真实错误时追加一段，方便定位是限流/超时/鉴权失败。
String _fallbackNote(DoudizhuModelOutcome model) {
  final label = _failureLabel(model.failure);
  final detail = model.detail?.trim();
  if (detail == null || detail.isEmpty) return label;
  return '$label（$detail）';
}

class _DoudizhuRequestCancelled implements Exception {
  const _DoudizhuRequestCancelled();
}
