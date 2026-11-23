import 'dart:async';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/game/othello/ai_othello_player.dart';
import 'package:chat_group/features/game/othello/character_othello_player.dart';
import 'package:chat_group/features/game/othello/othello_hard_engine.dart';
import 'package:chat_group/features/game/othello/othello_rules.dart';
import 'package:chat_group/features/game/othello/othello_types.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';

class _FakeCredentials implements ApiCredentialResolver {
  _FakeCredentials(this.value);

  final String? value;
  int calls = 0;

  @override
  Future<String?> resolve(ApiConfig config) async {
    calls++;
    return value;
  }
}

class _DelayedResponse {
  final started = Completer<void>();
  final response = Completer<Map<String, dynamic>>();
}

class _ScriptedApi extends ChatApiService {
  _ScriptedApi(this.script) : super();

  final List<Object> script;
  int calls = 0;
  List<Map<String, dynamic>> lastMessages = const [];
  int? lastMaxRetries;
  int? lastMaxTokens;
  Duration? lastReceiveTimeout;
  bool? lastAllowReasoningContentFallback;
  CancelToken? lastCancelToken;
  final messagesHistory = <List<Map<String, dynamic>>>[];

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
    final index = calls < script.length ? calls : script.length - 1;
    calls++;
    lastMessages = messages;
    messagesHistory.add(messages);
    lastMaxRetries = maxRetries;
    lastMaxTokens = maxTokens;
    lastReceiveTimeout = receiveTimeout;
    lastAllowReasoningContentFallback = allowReasoningContentFallback;
    lastCancelToken = cancelToken;
    final outcome = script[index];
    if (outcome is _DelayedResponse) {
      outcome.started.complete();
      return outcome.response.future;
    }
    if (outcome is Exception) throw outcome;
    return outcome as Map<String, dynamic>;
  }
}

class _FakeHardEngine implements OthelloMoveEngine {
  _FakeHardEngine(this.result);

  final OthelloSearchResult? result;
  int calls = 0;
  OthelloBoard? receivedBoard;
  OthelloSide? receivedSide;

  @override
  Future<OthelloSearchResult?> bestMove(
    OthelloBoard board,
    OthelloSide player, {
    CancelToken? cancelToken,
  }) async {
    calls++;
    receivedBoard = board;
    receivedSide = player;
    return result;
  }
}

AICharacter _character() => AICharacter(
      name: '阿棋',
      avatar: '棋',
      age: 20,
      role: '棋手',
      personalityTags: const ['沉着'],
      systemPrompt: '你是一位谨慎的棋手。',
      apiKey: 'unused legacy value',
      apiProvider: 'custom',
    );

ApiConfig _config({bool hasCredential = true}) => ApiConfig(
      name: '测试配置',
      provider: 'custom',
      modelName: 'test-model',
      hasCredential: hasCredential,
    );

OthelloBoard _boardForModel() => [
      [null, null, null, null, null, null, null, null],
      [
        othelloWhiteValue,
        null,
        null,
        null,
        othelloWhiteValue,
        null,
        null,
        null
      ],
      [
        othelloBlackValue,
        null,
        null,
        othelloWhiteValue,
        othelloBlackValue,
        null,
        null,
        null
      ],
      ...List.generate(5, (_) => List<int?>.filled(8, null)),
    ];

CharacterOthelloPlayer _player({
  required ChatApiService api,
  required _FakeHardEngine fallback,
  ApiConfig? config,
  OthelloBudgetResolver? budgetResolver,
  bool allowMissingConfig = false,
  String? credential = 'test-key',
  Duration requestTimeout = othelloModelRequestTimeout,
  Duration turnTimeout = othelloModelTurnTimeout,
}) {
  return CharacterOthelloPlayer(
    primary: AiOthelloPlayer(
      character: _character(),
      config: allowMissingConfig ? config : config ?? _config(),
      api: api,
      credentials: _FakeCredentials(credential),
      budgetResolver: budgetResolver,
      requestTimeout: requestTimeout,
      turnTimeout: turnTimeout,
    ),
    fallback: fallback,
  );
}

void main() {
  final board = _boardForModel();
  final legalMoves = OthelloRules.getValidMoves(board, OthelloSide.black);

  test('合法但较差的模型动作原样执行，不调用 Hard 比较或替换', () async {
    final hardMove = const OthelloHardSearch().search(board, OthelloSide.black);
    expect(hardMove!.move.toCoordinate(), 'C3');
    final api = _ScriptedApi([
      {
        'success': true,
        'message': '{"move":"E1","reason":"先控制上边缘并翻转棋子。"}',
      },
    ]);
    final hard = _FakeHardEngine(null);
    final result = await _player(api: api, fallback: hard).decideMove(
      board: board,
      side: OthelloSide.black,
      legalMoves: legalMoves,
    );

    expect(result, isNotNull);
    expect(result!.move.toCoordinate(), 'E1');
    expect(result.source, OthelloDecisionSource.characterModel);
    expect(hard.calls, 0);
    expect(api.calls, 1);
  });

  test('提示包含角色人设、执子方、完整棋盘、坐标规则与所有合法动作', () async {
    final api = _ScriptedApi([
      {
        'success': true,
        'message': '{"move":"E1","reason":"控制边缘。"}',
      },
    ]);
    final hard = _FakeHardEngine(null);
    await _player(api: api, fallback: hard).decideMove(
      board: board,
      side: OthelloSide.black,
      legalMoves: legalMoves,
    );

    final system = api.lastMessages.first['content'] as String;
    final user = api.lastMessages.last['content'] as String;
    expect(system, contains('你是一位谨慎的棋手。'));
    expect(system, contains(AiOthelloPlayer.tacticalPrompt));
    expect(user, contains('你执黑方'));
    expect(user, contains('列为 A–H，行从上到下为 1–8'));
    expect(user, contains('当前完整棋盘'));
    expect(user, contains('全部合法落点：A1, E1, C3'));
    expect(user, contains('W'));
    expect(user, contains('B'));
    expect(api.lastMaxRetries, 0);
    expect(api.lastMaxTokens, othelloFallbackMaxTokens);
    expect(api.lastAllowReasoningContentFallback, isTrue);
    expect(api.lastReceiveTimeout, othelloModelRequestTimeout);
  });

  test('使用模型能力预算 resolver 生成输出预算', () async {
    final api = _ScriptedApi([
      {
        'success': true,
        'message': '{"move":"E1","reason":"控制边缘。"}',
      },
    ]);
    await _player(
      api: api,
      fallback: _FakeHardEngine(null),
      budgetResolver: (_, __) => 4096,
    ).decideMove(
      board: board,
      side: OthelloSide.black,
      legalMoves: legalMoves,
    );

    expect(api.lastMaxTokens, 4096);
  });

  test('第二次尝试使用更紧凑提示并保留完整合法落点列表', () async {
    final api = _ScriptedApi([
      {'success': false, 'message': 'service error'},
      {'success': true, 'message': '{"move":"E1","reason":"控制边缘。"}'},
    ]);
    await _player(api: api, fallback: _FakeHardEngine(null)).decideMove(
      board: board,
      side: OthelloSide.black,
      legalMoves: legalMoves,
    );

    final firstPrompt = api.messagesHistory.first.last['content'] as String;
    final retryPrompt = api.messagesHistory.last.last['content'] as String;
    expect(retryPrompt.length, lessThan(firstPrompt.length));
    expect(retryPrompt, contains('合法落点：A1, E1, C3'));
    expect(retryPrompt, contains('B 黑，W 白，. 空'));
    expect(api.lastMaxTokens, othelloFallbackMaxTokens);
  });

  test('AI 回合总时限会取消请求并进入 Hard', () async {
    final delayed = _DelayedResponse();
    final api = _ScriptedApi([delayed]);
    final hard = _FakeHardEngine(
      OthelloSearchResult(
        move: legalMoves.first.move,
        score: 1,
        completedDepth: 2,
        timedOut: true,
        elapsedMilliseconds: 30,
      ),
    );
    final watch = Stopwatch()..start();
    final result = await _player(
      api: api,
      fallback: hard,
      requestTimeout: const Duration(seconds: 2),
      turnTimeout: const Duration(milliseconds: 40),
    ).decideMove(
      board: board,
      side: OthelloSide.black,
      legalMoves: legalMoves,
    );

    expect(result?.source, OthelloDecisionSource.hardFallback);
    expect(api.calls, 1);
    expect(api.lastCancelToken?.isCancelled, isTrue);
    expect(hard.calls, 1);
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('空回复、格式错误、非法动作、超时与服务错误重试后才进 Hard', () async {
    final scenarios = <(String, Object)>[
      ('空回复', {'success': true, 'message': ''}),
      ('格式错误', {'success': true, 'message': '我选择 E1'}),
      (
        '非法动作',
        {'success': true, 'message': '{"move":"B2","reason":"试走。"}'},
      ),
      ('超时', TimeoutException('stub timeout')),
      ('服务错误', {'success': false, 'message': 'service error'}),
    ];

    for (final (label, failure) in scenarios) {
      final legalFallbackMove = legalMoves.first.move;
      final api = _ScriptedApi([
        failure,
        failure,
      ]);
      final hard = _FakeHardEngine(
        OthelloSearchResult(
          move: legalFallbackMove,
          score: 1,
          completedDepth: 2,
          timedOut: false,
          elapsedMilliseconds: 5,
        ),
      );
      final result = await _player(api: api, fallback: hard).decideMove(
        board: board,
        side: OthelloSide.black,
        legalMoves: legalMoves,
      );
      expect(result, isNotNull, reason: label);
      expect(result!.source, OthelloDecisionSource.hardFallback, reason: label);
      expect(result.move, legalFallbackMove, reason: label);
      expect(api.calls, 2, reason: '$label 应执行首次请求和一次重试');
      expect(hard.calls, 1, reason: '$label 耗尽重试后只调用一次 Hard');
      expect(hard.receivedSide, OthelloSide.black, reason: label);
      expect(identical(hard.receivedBoard, board), isTrue, reason: label);
    }
  });

  test('未绑定配置或凭据不可用时直接 Hard，不请求模型', () async {
    for (final scenario in [
      (config: null, credential: 'test-key'),
      (config: _config(hasCredential: false), credential: 'test-key'),
      (config: _config(), credential: null),
    ]) {
      final api = _ScriptedApi([
        {'success': true, 'message': '{"move":"E1","reason":"边缘。"}'},
      ]);
      final hard = _FakeHardEngine(
        OthelloSearchResult(
          move: legalMoves.first.move,
          score: 0,
          completedDepth: 1,
          timedOut: true,
          elapsedMilliseconds: 1500,
        ),
      );
      final result = await _player(
        api: api,
        fallback: hard,
        config: scenario.config,
        allowMissingConfig: scenario.config == null,
        credential: scenario.credential,
      ).decideMove(
        board: board,
        side: OthelloSide.black,
        legalMoves: legalMoves,
      );
      expect(result!.source, OthelloDecisionSource.hardFallback);
      expect(result.fallbackNote, contains('配置或凭据不可用'));
      expect(api.calls, 0);
      expect(hard.calls, 1);
    }
  });

  test('主动停止模型请求后不进入 Hard 兜底', () async {
    final delayed = _DelayedResponse();
    final api = _ScriptedApi([delayed]);
    final hard = _FakeHardEngine(null);
    final token = CancelToken();
    final pending = _player(api: api, fallback: hard).decideMove(
      board: board,
      side: OthelloSide.black,
      legalMoves: legalMoves,
      cancelToken: token,
    );
    await delayed.started.future;
    token.cancel('user stop');
    delayed.response.complete({
      'success': true,
      'message': '{"move":"E1","reason":"控制边缘。"}',
    });

    expect(await pending, isNull);
    expect(hard.calls, 0);
  });

  test('Hard 兜底公开可验证的翻子说明，不冒充模型推理', () async {
    final api = _ScriptedApi([
      {'success': false, 'message': 'request failed'},
      {'success': false, 'message': 'request failed'},
    ]);
    final hardMove = legalMoves.first;
    final hard = _FakeHardEngine(
      OthelloSearchResult(
        move: hardMove.move,
        score: 0,
        completedDepth: 6,
        timedOut: false,
        elapsedMilliseconds: 20,
      ),
    );
    final result = await _player(api: api, fallback: hard).decideMove(
      board: board,
      side: OthelloSide.black,
      legalMoves: legalMoves,
    );
    expect(result!.reason, contains('${hardMove.flipsCount} 枚棋子'));
    expect(result.fallbackNote, '模型请求失败或超时');
    expect(result.reason, isNot(contains('模型认为')));
    expect(result.completedSearchDepth, 6);
  });
}
