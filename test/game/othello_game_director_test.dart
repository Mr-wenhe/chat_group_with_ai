import 'dart:async';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/game/othello/ai_othello_player.dart';
import 'package:chat_group/features/game/othello/character_othello_player.dart';
import 'package:chat_group/features/game/othello/game_director.dart';
import 'package:chat_group/features/game/othello/othello_hard_engine.dart';
import 'package:chat_group/features/game/othello/othello_rules.dart';
import 'package:chat_group/features/game/othello/othello_types.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';

class _FakeCredentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key';
}

class _DelayedResponse {
  final started = Completer<void>();
  final response = Completer<Map<String, dynamic>>();
}

class _SequenceApi extends ChatApiService {
  _SequenceApi(this.script) : super();

  final List<Object> script;
  int calls = 0;
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
    cancelTokens.add(cancelToken);
    final index = calls++;
    final result = script[index < script.length ? index : script.length - 1];
    if (result is _DelayedResponse) {
      result.started.complete();
      return result.response.future;
    }
    return result as Map<String, dynamic>;
  }
}

class _ScriptedHardEngine implements OthelloMoveEngine {
  _ScriptedHardEngine(this.results);

  final List<Object?> results;
  int calls = 0;
  final List<OthelloSide> sides = [];
  final List<OthelloBoard> boards = [];

  @override
  Future<OthelloSearchResult?> bestMove(
    OthelloBoard board,
    OthelloSide player, {
    CancelToken? cancelToken,
  }) async {
    final index = calls++;
    sides.add(player);
    boards.add(board);
    final result = results[index < results.length ? index : results.length - 1];
    if (result is _DelayedResponse) {
      result.started.complete();
      final response = await result.response.future;
      return response['result'] as OthelloSearchResult?;
    }
    return result as OthelloSearchResult?;
  }
}

AICharacter _character(String name) => AICharacter(
      name: name,
      avatar: name.substring(0, 1),
      age: 20,
      role: '棋手',
      personalityTags: const [],
      systemPrompt: '棋手人设',
      apiKey: 'unused',
      apiProvider: 'custom',
    );

ApiConfig _config() => ApiConfig(
      name: 'test',
      provider: 'custom',
      modelName: 'test-model',
      hasCredential: true,
    );

CharacterOthelloPlayer _modelPlayer(
  String name,
  ChatApiService api, {
  ApiConfig? config,
  OthelloMoveEngine? hard,
  bool unavailable = false,
}) =>
    CharacterOthelloPlayer(
      primary: AiOthelloPlayer(
        character: _character(name),
        config: unavailable
            ? ApiConfig(
                name: 'unavailable',
                provider: 'custom',
                hasCredential: false,
              )
            : config ?? _config(),
        api: api,
        credentials: _FakeCredentials(),
      ),
      fallback: hard ?? _ScriptedHardEngine(const []),
    );

OthelloGameState _stateFor(OthelloBoard board, OthelloSide side) =>
    OthelloGameState(
      board: board,
      currentSide: side,
      status: OthelloGameStatus.playing,
      winner: null,
      moveHistory: const [],
      lastMove: null,
      passedSide: null,
      validMoves: OthelloRules.getValidMoves(board, side),
    );

OthelloSearchResult _result(OthelloMove move) => OthelloSearchResult(
      move: move,
      score: 0,
      completedDepth: 3,
      timedOut: false,
      elapsedMilliseconds: 2,
    );

Future<void> _flushAsyncWork() async {
  for (var attempt = 0; attempt < 8; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('席位与同一规则提交入口', () {
    test('黑先；真人黑方与 AI 白方都通过规则校验落子', () async {
      final api = _SequenceApi([
        {'success': true, 'message': '{"move":"C3","reason":"争取内侧落点。"}'},
      ]);
      final hard = _ScriptedHardEngine(const []);
      final director = OthelloGameDirector(
        seats: [
          const OthelloSeat(name: '你', avatar: '我', side: OthelloSide.black),
          OthelloSeat(
            name: '阿棋',
            avatar: '棋',
            side: OthelloSide.white,
            ai: _modelPlayer('阿棋', api, hard: hard),
          ),
        ],
        moveSpacing: Duration.zero,
      );
      director.start();
      expect(director.currentSeat.side, OthelloSide.black);
      expect(director.isHumanTurn, isTrue);

      director.humanMove(0, 0); // 空角不是合法动作
      expect(director.state.moveHistory, isEmpty);
      director.humanMove(2, 3); // 黑方 D3
      await _flushAsyncWork();

      expect(director.state.moveHistory, [
        const OthelloMove(2, 3),
        const OthelloMove(2, 2),
      ]);
      expect(director.events.first.seatName, '你');
      expect(director.events.last.source, OthelloDecisionSource.characterModel);
      expect(director.phase, OthelloPhase.playing);
      expect(hard.calls, 0);
      director.dispose();
    });

    test('真人白方后手：黑方 AI 先走后才开放白方点击', () async {
      final api = _SequenceApi([
        {'success': true, 'message': '{"move":"D3","reason":"开局夹击。"}'},
      ]);
      final director = OthelloGameDirector(
        seats: [
          OthelloSeat(
            name: '小黑',
            avatar: '黑',
            side: OthelloSide.black,
            ai: _modelPlayer('小黑', api),
          ),
          const OthelloSeat(name: '你', avatar: '我', side: OthelloSide.white),
        ],
        moveSpacing: Duration.zero,
      );
      director.start();
      expect(director.isHumanTurn, isFalse);
      await _flushAsyncWork();
      expect(director.currentSeat.side, OthelloSide.white);
      expect(director.isHumanTurn, isTrue);
      expect(director.state.moveHistory, [const OthelloMove(2, 3)]);

      director.humanMove(2, 2); // C3 是白方合法落点
      expect(director.state.moveHistory, hasLength(2));
      expect(director.state.moveHistory.last, const OthelloMove(2, 2));
      director.dispose();
    });

    test('快速重复点击只提交一手，且 AI 观战席位不接受真人点击', () {
      final director = OthelloGameDirector(
        seats: const [
          OthelloSeat(name: '甲', avatar: '甲', side: OthelloSide.black),
          OthelloSeat(name: '乙', avatar: '乙', side: OthelloSide.white),
        ],
      );
      director.start();
      director.humanMove(2, 3);
      director.humanMove(2, 3);
      expect(director.state.moveHistory, [const OthelloMove(2, 3)]);

      final spectator = OthelloGameDirector(
        seats: [
          OthelloSeat(
            name: '黑 AI',
            avatar: '黑',
            side: OthelloSide.black,
            ai: _modelPlayer(
              '黑 AI',
              _SequenceApi(const []),
              unavailable: true,
            ),
          ),
          OthelloSeat(
            name: '白 AI',
            avatar: '白',
            side: OthelloSide.white,
            ai: _modelPlayer(
              '白 AI',
              _SequenceApi(const []),
              unavailable: true,
            ),
          ),
        ],
      );
      spectator.humanMove(2, 3);
      expect(spectator.state.moveHistory, isEmpty);
      director.dispose();
      spectator.dispose();
    });

    test('无合法动作自动跳过且不调用该席位模型或 Hard', () {
      final board = OthelloRules.createEmptyBoard()
        ..[0][0] = othelloWhiteValue
        ..[0][1] = othelloBlackValue;
      final noModelApi = _SequenceApi(const []);
      final blackHard = _ScriptedHardEngine(const []);
      final director = OthelloGameDirector(
        seats: [
          OthelloSeat(
            name: '黑 AI',
            avatar: '黑',
            side: OthelloSide.black,
            ai: _modelPlayer('黑 AI', noModelApi, hard: blackHard),
          ),
          const OthelloSeat(name: '你', avatar: '我', side: OthelloSide.white),
        ],
        initialState: _stateFor(board, OthelloSide.black),
      );
      director.start();

      expect(director.currentSeat.side, OthelloSide.white);
      expect(director.isHumanTurn, isTrue);
      expect(director.events.single.kind, OthelloEventKind.pass);
      expect(director.events.single.side, OthelloSide.black);
      expect(noModelApi.calls, 0);
      expect(blackHard.calls, 0);
      director.dispose();
    });

    test('双方无步且未满盘时结算；终局回调只触发一次', () {
      final board = OthelloRules.createEmptyBoard()..[0][0] = othelloBlackValue;
      var finishedCallbacks = 0;
      final api = _SequenceApi(const []);
      final hard = _ScriptedHardEngine(const []);
      final director = OthelloGameDirector(
        seats: [
          OthelloSeat(
            name: '黑 AI',
            avatar: '黑',
            side: OthelloSide.black,
            ai: _modelPlayer('黑 AI', api, hard: hard),
          ),
          OthelloSeat(
            name: '白 AI',
            avatar: '白',
            side: OthelloSide.white,
            ai: _modelPlayer('白 AI', api, hard: hard),
          ),
        ],
        initialState: _stateFor(board, OthelloSide.white),
        onFinished: (_) => finishedCallbacks++,
      );
      director.start();
      expect(director.phase, OthelloPhase.finished);
      expect(director.state.winner, OthelloSide.black);
      expect(OthelloRules.isBoardFull(director.board), isFalse);
      expect(director.statusMessage, contains('黑 1：白 0'));
      expect(api.calls, 0);
      expect(hard.calls, 0);
      director.start();
      expect(finishedCallbacks, 1);
      director.dispose();
    });
  });

  group('迟到结果失效', () {
    test('主动停止后忽略延迟模型结果，不触发 Hard', () async {
      final delayed = _DelayedResponse();
      final api = _SequenceApi([delayed]);
      final hard = _ScriptedHardEngine(const []);
      final director = OthelloGameDirector(
        seats: [
          OthelloSeat(
            name: '黑 AI',
            avatar: '黑',
            side: OthelloSide.black,
            ai: _modelPlayer('黑 AI', api, hard: hard),
          ),
          const OthelloSeat(name: '你', avatar: '我', side: OthelloSide.white),
        ],
        moveSpacing: Duration.zero,
      );
      director.start();
      await delayed.started.future;
      director.stop();
      delayed.response.complete({
        'success': true,
        'message': '{"move":"D3","reason":"迟到结果。"}',
      });
      await _flushAsyncWork();

      expect(director.phase, OthelloPhase.stopped);
      expect(director.state.moveHistory, isEmpty);
      expect(hard.calls, 0);
      director.dispose();
    });

    test('模型行动提交后只派发一个后续回合', () async {
      final delayed = _DelayedResponse();
      final api = _SequenceApi([
        delayed,
        {
          'success': true,
          'message': '{"move":"D3","reason":"保持行动选择。"}',
        },
      ]);
      final hard = _ScriptedHardEngine(const []);
      final director = OthelloGameDirector(
        seats: [
          OthelloSeat(
            name: '黑 AI',
            avatar: '黑',
            side: OthelloSide.black,
            ai: _modelPlayer('黑 AI', api, hard: hard),
          ),
          const OthelloSeat(name: '白 AI', avatar: '白', side: OthelloSide.white),
        ],
        moveSpacing: Duration.zero,
      );
      director.start();
      await delayed.started.future;
      final requestToken = api.cancelTokens.single;

      delayed.response.complete({
        'success': true,
        'message': '{"move":"D3","reason":"模型返回。"}',
      });
      await _flushAsyncWork();
      expect(director.state.moveHistory, [const OthelloMove(2, 3)]);
      expect(director.phase, OthelloPhase.playing);
      expect(requestToken?.isCancelled, isTrue);
      expect(api.calls, 1);
      director.stop();
      director.dispose();
    });

    test('离开页面后忽略延迟模型结果', () async {
      final delayed = _DelayedResponse();
      final api = _SequenceApi([delayed]);
      final director = OthelloGameDirector(
        seats: [
          OthelloSeat(
            name: '黑 AI',
            avatar: '黑',
            side: OthelloSide.black,
            ai: _modelPlayer('黑 AI', api),
          ),
          const OthelloSeat(name: '你', avatar: '我', side: OthelloSide.white),
        ],
        moveSpacing: Duration.zero,
      );
      director.start();
      await delayed.started.future;
      director.dispose();
      delayed.response.complete({
        'success': true,
        'message': '{"move":"D3","reason":"离页迟到。"}',
      });
      await _flushAsyncWork();
      expect(director.state.moveHistory, isEmpty);
    });

    test('重开后仅接受新回合的模型结果', () async {
      final delayed = _DelayedResponse();
      final api = _SequenceApi([
        delayed,
        {'success': true, 'message': '{"move":"C4","reason":"新局落点。"}'},
      ]);
      final director = OthelloGameDirector(
        seats: [
          OthelloSeat(
            name: '黑 AI',
            avatar: '黑',
            side: OthelloSide.black,
            ai: _modelPlayer('黑 AI', api),
          ),
          const OthelloSeat(name: '你', avatar: '我', side: OthelloSide.white),
        ],
        moveSpacing: Duration.zero,
      );
      director.start();
      await delayed.started.future;
      director.restart();
      await _flushAsyncWork();
      expect(director.state.lastMove, const OthelloMove(3, 2));
      delayed.response.complete({
        'success': true,
        'message': '{"move":"E6","reason":"旧局迟到。"}',
      });
      await _flushAsyncWork();

      expect(director.state.moveHistory, [const OthelloMove(3, 2)]);
      expect(director.state.lastMove, const OthelloMove(3, 2));
      expect(api.calls, 2);
      director.dispose();
    });

    test('停止与离页后丢弃延迟 Hard 返回', () async {
      for (final shouldDispose in [false, true]) {
        final delayed = _DelayedResponse();
        final hard = _ScriptedHardEngine([delayed]);
        final api = _SequenceApi(const []);
        final director = OthelloGameDirector(
          seats: [
            OthelloSeat(
              name: '黑 AI',
              avatar: '黑',
              side: OthelloSide.black,
              ai: _modelPlayer('黑 AI', api, unavailable: true, hard: hard),
            ),
            const OthelloSeat(name: '你', avatar: '我', side: OthelloSide.white),
          ],
          moveSpacing: Duration.zero,
        );
        director.start();
        await delayed.started.future;
        if (shouldDispose) {
          director.dispose();
        } else {
          director.stop();
        }
        delayed.response.complete({'result': _result(const OthelloMove(2, 3))});
        await _flushAsyncWork();
        expect(director.state.moveHistory, isEmpty);
        if (!shouldDispose) director.dispose();
      }
    });

    test('重开后丢弃旧 Hard 结果，只提交新引擎动作', () async {
      final delayed = _DelayedResponse();
      final hard = _ScriptedHardEngine([
        delayed,
        _result(const OthelloMove(3, 2)),
      ]);
      final director = OthelloGameDirector(
        seats: [
          OthelloSeat(
            name: '黑 AI',
            avatar: '黑',
            side: OthelloSide.black,
            ai: _modelPlayer(
              '黑 AI',
              _SequenceApi(const []),
              unavailable: true,
              hard: hard,
            ),
          ),
          const OthelloSeat(name: '你', avatar: '我', side: OthelloSide.white),
        ],
        moveSpacing: Duration.zero,
      );
      director.start();
      await delayed.started.future;
      director.restart();
      await _flushAsyncWork();
      expect(director.state.lastMove, const OthelloMove(3, 2));
      delayed.response.complete({'result': _result(const OthelloMove(2, 3))});
      await _flushAsyncWork();

      expect(director.state.moveHistory, [const OthelloMove(3, 2)]);
      expect(director.state.lastMove, const OthelloMove(3, 2));
      expect(hard.calls, 2);
      director.dispose();
    });
  });
}
