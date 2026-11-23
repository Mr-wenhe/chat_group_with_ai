import 'dart:async';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_ai_player.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_budget_resolver.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_game_state.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_rules.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';

AICharacter _character() => AICharacter(
      name: '白果',
      avatar: '白',
      age: 24,
      role: '棋手',
      personalityTags: const ['冷静'],
      systemPrompt: '角色专属人设',
      apiKey: '',
      apiProvider: 'custom',
    );

ApiConfig _config() => ApiConfig(
      name: '测试模型',
      provider: ApiProvider.custom.name,
      modelName: 'test-model',
      customBaseUrl: 'http://127.0.0.1/v1',
      hasCredential: true,
    );

class _Credentials implements ApiCredentialResolver {
  _Credentials(this.value);

  final String? value;
  int calls = 0;

  @override
  Future<String?> resolve(ApiConfig config) async {
    calls++;
    return value;
  }
}

class _NeverCredentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) => Completer<String?>().future;
}

class _ScriptedApi extends ChatApiService {
  _ScriptedApi(this.script) : super();

  final List<Object> script;
  int calls = 0;
  int? maxTokens;
  int? maxRetries;
  Duration? receiveTimeout;
  List<Map<String, dynamic>>? messages;
  final cancelTokens = <CancelToken?>[];

  @override
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    String? userAgent,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = 5,
    CancelToken? cancelToken,
    bool allowReasoningContentFallback = false,
    String? promptCacheKey,
  }) async {
    final index = calls++;
    this.maxTokens = maxTokens;
    this.maxRetries = maxRetries;
    this.receiveTimeout = receiveTimeout;
    this.messages = messages;
    cancelTokens.add(cancelToken);
    final outcome = script[index < script.length ? index : script.length - 1];
    if (outcome is Exception) throw outcome;
    if (outcome is Future<Map<String, dynamic>>) return outcome;
    return outcome as Map<String, dynamic>;
  }
}

class _HardSelector implements DoudizhuHardMoveSelector {
  _HardSelector(this.action);

  final DoudizhuAction? Function(DoudizhuAiTurnInput input) action;
  int calls = 0;

  @override
  Future<DoudizhuHardDecision?> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  }) async {
    calls++;
    final chosen = action(input);
    if (chosen == null) return null;
    final cards = chosen is DoudizhuPlayAction ? chosen.cardIds : null;
    return DoudizhuHardDecision(
      action: chosen,
      elapsedMilliseconds: 3,
      candidateCount: 4,
      handsBefore: 3,
      handsAfter: cards == null ? 3 : 2,
      score: 100,
    );
  }
}

DoudizhuAiTurnInput _bidInput({
  List<int> hand = const [0, 4, 8],
  int highestBid = 0,
}) =>
    DoudizhuAiTurnInput(
      seat: 0,
      seatName: '白果',
      teamLabel: '叫分中',
      phase: DoudizhuPhase.bidding,
      ownHand: hand,
      bids: const [null, null, null],
      handSizes: const [17, 17, 17],
      publicLog: const [],
      options: [
        const DoudizhuActionOption(
          actionId: 'b0',
          action: DoudizhuBidAction(0),
          typeLabel: '叫分',
          cardIds: [],
          bidScore: 0,
        ),
        if (highestBid < 3)
          const DoudizhuActionOption(
            actionId: 'b3',
            action: DoudizhuBidAction(3),
            typeLabel: '叫分',
            cardIds: [],
            bidScore: 3,
          ),
      ],
      highestBid: highestBid,
      landlord: -1,
      passCount: 0,
      multiplier: 1,
      publicBottom: null,
    );

DoudizhuAiTurnInput _playInput() => DoudizhuAiTurnInput(
      seat: 0,
      seatName: '白果',
      teamLabel: '地主',
      phase: DoudizhuPhase.playing,
      ownHand: const [0, 4],
      bids: const [3, 0, 0],
      handSizes: const [2, 17, 17],
      publicLog: const [],
      options: [
        DoudizhuActionOption(
          actionId: 'm0',
          action: DoudizhuPlayAction([0]),
          typeLabel: '单张',
          cardIds: [0],
        ),
        DoudizhuActionOption(
          actionId: 'm1',
          action: DoudizhuPlayAction([4]),
          typeLabel: '单张',
          cardIds: [4],
        ),
      ],
      highestBid: 3,
      landlord: 0,
      passCount: 0,
      multiplier: 3,
      publicBottom: const [52, 53, 50],
    );

Map<String, dynamic> _reply(String text) => {'success': true, 'message': text};

void main() {
  test('合法但较差的模型叫分和出牌原样采纳，宗师调用为零', () async {
    final bidApi = _ScriptedApi([_reply('{"actionId":"b0"}')]);
    final hard = _HardSelector((_) => const DoudizhuBidAction(3));
    final bidder = DoudizhuCharacterPlayer(
      primary: AiDoudizhuPlayer(
        character: _character(),
        config: _config(),
        api: bidApi,
        credentials: _Credentials('test-key'),
      ),
      fallback: hard,
    );
    final bid = await bidder.decide(_bidInput());
    expect((bid!.action as DoudizhuBidAction).score, 0);
    expect(bid.source, DoudizhuDecisionSource.characterModel);
    expect(hard.calls, 0);

    final playApi = _ScriptedApi([_reply('{"actionId":"m0"}')]);
    final playHard = _HardSelector((_) => DoudizhuPlayAction([4]));
    final player = DoudizhuCharacterPlayer(
      primary: AiDoudizhuPlayer(
        character: _character(),
        config: _config(),
        api: playApi,
        credentials: _Credentials('test-key'),
      ),
      fallback: playHard,
    );
    final play = await player.decide(_playInput());
    expect((play!.action as DoudizhuPlayAction).cardIds, [0]);
    expect(play.source, DoudizhuDecisionSource.characterModel);
    expect(playHard.calls, 0);
  });

  test('模型把合法 JSON 包在说明文字和代码块中时仍采纳 actionId', () async {
    final api = _ScriptedApi([
      _reply('''
我已完成判断：
```json
{"actionId":"m0","say":"稳住阵脚，继续观察。","confidence":0.72,"analysis":"这段分析不能公开"}
```
'''),
    ]);
    final hard = _HardSelector((_) => DoudizhuPlayAction([4]));
    final player = DoudizhuCharacterPlayer(
      primary: AiDoudizhuPlayer(
        character: _character(),
        config: _config(),
        api: api,
        credentials: _Credentials('test-key'),
      ),
      fallback: hard,
    );

    final result = await player.decide(_playInput());

    expect((result!.action as DoudizhuPlayAction).cardIds, [0]);
    expect(result.source, DoudizhuDecisionSource.characterModel);
    expect(result.publicLine, '稳住阵脚，继续观察。');
    expect(result.publicLine, isNot(contains('分析')));
    expect(hard.calls, 0);
  });

  test('无凭据时直接走叫分策略或宗师兜底', () async {
    final api = _ScriptedApi([_reply('{"actionId":"m0"}')]);
    final hard = _HardSelector((_) => DoudizhuPlayAction([4]));
    final player = DoudizhuCharacterPlayer(
      primary: AiDoudizhuPlayer(
        character: _character(),
        config: null,
        api: api,
        credentials: _Credentials('unused'),
      ),
      fallback: hard,
    );
    final bid = await player.decide(_bidInput(hand: [50, 51, 52, 53]));
    expect((bid!.action as DoudizhuBidAction).score, 3);
    final play = await player.decide(_playInput());
    expect((play!.action as DoudizhuPlayAction).cardIds, [4]);
    expect(api.calls, 0);
    expect(hard.calls, 1);
  });

  test('空回复与非法动作各重试一次，随后用宗师合法动作兜底', () async {
    final api = _ScriptedApi([
      {'success': false, 'message': '', 'failureCode': 'emptyResponse'},
      _reply('{"actionId":"unknown"}'),
    ]);
    final hard = _HardSelector((_) => DoudizhuPlayAction([4]));
    final player = DoudizhuCharacterPlayer(
      primary: AiDoudizhuPlayer(
        character: _character(),
        config: _config(),
        api: api,
        credentials: _Credentials('test-key'),
      ),
      fallback: hard,
    );
    final result = await player.decide(_playInput());
    expect(api.calls, 2);
    expect(api.maxRetries, 0);
    expect(hard.calls, 1);
    expect((result!.action as DoudizhuPlayAction).cardIds, [4]);
    expect(result.fallbackNote, '模型返回非法动作');
  });

  test('JSON 格式错误重试一次后交给宗师', () async {
    final api = _ScriptedApi([_reply('not-json'), _reply('not-json')]);
    final hard = _HardSelector((_) => DoudizhuPlayAction([4]));
    final player = DoudizhuCharacterPlayer(
      primary: AiDoudizhuPlayer(
        character: _character(),
        config: _config(),
        api: api,
        credentials: _Credentials('test-key'),
      ),
      fallback: hard,
    );

    final result = await player.decide(_playInput());
    expect(api.calls, 2);
    expect(hard.calls, 1);
    expect(result!.fallbackNote, '模型回复格式错误');
  });

  test('服务错误重试一次后交给宗师', () async {
    final api = _ScriptedApi(
        [Exception('service unavailable'), Exception('service unavailable')]);
    final hard = _HardSelector((_) => DoudizhuPlayAction([4]));
    final player = DoudizhuCharacterPlayer(
      primary: AiDoudizhuPlayer(
        character: _character(),
        config: _config(),
        api: api,
        credentials: _Credentials('test-key'),
      ),
      fallback: hard,
    );

    final result = await player.decide(_playInput());
    expect(api.calls, 2);
    expect(hard.calls, 1);
    expect(result!.fallbackNote, '模型请求失败或超时');
  });

  test('37 秒总时限取消持续等待的传输并立即交给宗师', () async {
    final pending = Completer<Map<String, dynamic>>();
    final api = _ScriptedApi([pending.future]);
    final hard = _HardSelector((_) => DoudizhuPlayAction([4]));
    final player = DoudizhuCharacterPlayer(
      primary: AiDoudizhuPlayer(
        character: _character(),
        config: _config(),
        api: api,
        credentials: _Credentials('test-key'),
        requestTimeout: const Duration(seconds: 2),
        turnTimeout: const Duration(milliseconds: 40),
      ),
      fallback: hard,
    );
    final decision = await player.decide(_playInput());
    expect(api.calls, 1);
    expect(api.cancelTokens.single!.isCancelled, isTrue);
    expect(hard.calls, 1);
    expect((decision!.action as DoudizhuPlayAction).cardIds, [4]);
  });

  test('凭据读取也计入回合总时限', () async {
    final api = _ScriptedApi([_reply('{"actionId":"m0"}')]);
    final hard = _HardSelector((_) => DoudizhuPlayAction([4]));
    final player = DoudizhuCharacterPlayer(
      primary: AiDoudizhuPlayer(
        character: _character(),
        config: _config(),
        api: api,
        credentials: _NeverCredentials(),
        turnTimeout: const Duration(milliseconds: 30),
      ),
      fallback: hard,
    );
    final decision = await player.decide(_playInput());
    expect(api.calls, 0);
    expect(hard.calls, 1);
    expect((decision!.action as DoudizhuPlayAction).cardIds, [4]);
  });

  test('提示只含本席和公开数据，叫分时不含底牌', () async {
    final api = _ScriptedApi([
      _reply('{"actionId":"b0","say":"这轮先稳住。"}'),
    ]);
    final input = _bidInput(hand: const [0, 4, 8]);
    final model = AiDoudizhuPlayer(
      character: _character(),
      config: _config(),
      api: api,
      credentials: _Credentials('test-key'),
    );
    final response = await model.decide(input);
    final prompt =
        api.messages!.map((message) => message['content']).join('\n');

    expect(response.isSuccess, isTrue);
    expect(response.publicLine, '这轮先稳住。');
    expect(input.publicBottom, isNull);
    expect(input.ownHand, [0, 4, 8]);
    expect(prompt, contains('角色专属人设'));
    expect(prompt, contains('3♠'));
    expect(prompt, isNot(contains('A♦')));
    expect(prompt, contains('"actionId"'));
    expect(prompt, contains('"say"'));
    expect(prompt, contains('b0='));
    expect(prompt, contains('不能把剩余手数更少当作充分理由'));
    expect(prompt, contains('不要只因对子 2 点数最大就把它当普通开局牌打掉'));
  });

  test('公开模型台词过滤手牌与牌点泄露', () async {
    final api = _ScriptedApi([
      _reply('{"actionId":"b0","say":"我手里还有大王。"}'),
    ]);
    final model = AiDoudizhuPlayer(
      character: _character(),
      config: _config(),
      api: api,
      credentials: _Credentials('test-key'),
    );

    final response = await model.decide(_bidInput());

    expect(response.isSuccess, isTrue);
    expect(response.publicLine, isEmpty);
  });

  test('按模型能力保留推理模型预算并压低小窗口预算', () {
    final resolver = RegistryDoudizhuBudgetResolver(
      customCapability: (_, model) => model == 'reasoning-large'
          ? const CustomModelCapability(contextWindow: 32768, maxOutput: 8192)
          : const CustomModelCapability(contextWindow: 2048, maxOutput: 2048),
    );
    expect(resolver.resolve(ApiProvider.custom, 'reasoning-large'), 4096);
    expect(resolver.resolveInputTokens(ApiProvider.custom, 'reasoning-large'),
        28416);
    expect(resolver.resolve(ApiProvider.custom, 'small-window'), 1024);
    expect(
        resolver.resolveInputTokens(ApiProvider.custom, 'small-window'), 768);
  });

  test('候选列表超输入预算时先压缩牌面再发送', () async {
    final base = _playInput();
    final cards = List<int>.generate(8, (index) => index);
    final options = List<DoudizhuActionOption>.generate(
      200,
      (index) => DoudizhuActionOption(
        actionId: 'm$index',
        action: DoudizhuPlayAction(cards),
        typeLabel: '飞机带双翼',
        cardIds: cards,
      ),
    );
    final input = DoudizhuAiTurnInput(
      seat: base.seat,
      seatName: base.seatName,
      teamLabel: base.teamLabel,
      phase: base.phase,
      ownHand: base.ownHand,
      bids: base.bids,
      handSizes: base.handSizes,
      publicLog: base.publicLog,
      options: options,
      highestBid: base.highestBid,
      landlord: base.landlord,
      passCount: base.passCount,
      multiplier: base.multiplier,
      lastPlay: base.lastPlay,
      publicBottom: base.publicBottom,
    );
    final api = _ScriptedApi([_reply('{"actionId":"m0"}')]);
    final model = AiDoudizhuPlayer(
      character: _character(),
      config: _config(),
      api: api,
      credentials: _Credentials('test-key'),
      inputBudgetResolver: (_, __) => 2400,
    );

    final result = await model.decide(input);
    final prompt =
        api.messages!.map((message) => message['content']).join('\n');
    expect(result.isSuccess, isTrue);
    expect(api.calls, 1);
    expect(ContextWindowManager.estimateRequestTokens(api.messages!),
        lessThanOrEqualTo(2400));
    expect(prompt, contains('3♠3♥3♣3♦'));
    expect(prompt, isNot(contains('3♠,3♥')));
  });

  test('叫分阈值与上游 aiBidScore 一致', () {
    expect(DoudizhuBidStrategy.score([50, 51, 52, 53]), 3);
    expect(DoudizhuBidStrategy.score([50, 44, 45, 53]), 2);
    expect(DoudizhuBidStrategy.score([50, 53]), 1);
    expect(DoudizhuBidStrategy.score([0, 4, 8]), 0);
    expect(DoudizhuRules.rankOf(53), 14);
  });
}
