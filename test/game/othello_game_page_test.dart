import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/game/game_lobby_page.dart';
import 'package:chat_group/features/game/othello/othello_board_view.dart';
import 'package:chat_group/features/game/othello/othello_game_providers.dart';
import 'package:chat_group/features/game/othello/othello_hard_engine.dart';
import 'package:chat_group/features/game/othello/othello_rules.dart';
import 'package:chat_group/features/game/othello/othello_types.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';

class _FirstLegalEngine implements OthelloMoveEngine {
  @override
  Future<OthelloSearchResult?> bestMove(
    OthelloBoard board,
    OthelloSide player, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) return null;
    final legal = OthelloRules.getValidMoves(board, player);
    if (legal.isEmpty) return null;
    return OthelloSearchResult(
      move: legal.first.move,
      score: 0,
      completedDepth: 6,
      timedOut: false,
      elapsedMilliseconds: 0,
    );
  }
}

class _DeferredLegalEngine implements OthelloMoveEngine {
  final requests = <_PendingEngineRequest>[];

  @override
  Future<OthelloSearchResult?> bestMove(
    OthelloBoard board,
    OthelloSide player, {
    CancelToken? cancelToken,
  }) {
    final completer = Completer<OthelloSearchResult?>();
    requests.add(_PendingEngineRequest(
      board: board,
      player: player,
      cancelToken: cancelToken,
      completer: completer,
    ));
    return completer.future;
  }

  void complete(int index) {
    final request = requests[index];
    final legal = OthelloRules.getValidMoves(request.board, request.player);
    request.completer.complete(
      OthelloSearchResult(
        move: legal.first.move,
        score: 0,
        completedDepth: 6,
        timedOut: false,
        elapsedMilliseconds: 0,
      ),
    );
  }
}

class _PendingEngineRequest {
  const _PendingEngineRequest({
    required this.board,
    required this.player,
    required this.cancelToken,
    required this.completer,
  });

  final OthelloBoard board;
  final OthelloSide player;
  final CancelToken? cancelToken;
  final Completer<OthelloSearchResult?> completer;
}

AICharacter _character(String name) => AICharacter(
      name: name,
      avatar: name.substring(0, 1),
      age: 22,
      role: '棋手',
      personalityTags: const [],
      systemPrompt: '棋手人设',
      apiKey: 'unused',
      apiProvider: 'custom',
    );

Future<void> _openLobby(
  WidgetTester tester,
  DatabaseService database, {
  OthelloMoveEngine? engine,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseServiceProvider.overrideWithValue(database),
        userManagedAICharactersProvider.overrideWith(
          (ref) => [_character('黑豆'), _character('白果')],
        ),
        othelloApiConfigsProvider.overrideWith((ref) => const <ApiConfig>[]),
        othelloHardMoveEngineProvider.overrideWith(
          (ref) => engine ?? _FirstLegalEngine(),
        ),
        othelloMoveSpacingProvider.overrideWith((ref) => Duration.zero),
      ],
      child: const MaterialApp(home: GameLobbyPage()),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text('3 款'), findsOneWidget);
  await tester.tap(find.text('黑白棋'));
  await tester.pumpAndSettle();
}

Future<void> _startHumanGame(
  WidgetTester tester, {
  required OthelloSide humanSide,
}) async {
  await tester.tap(find.text('真人参与'));
  await tester.pumpAndSettle();
  if (humanSide == OthelloSide.white) {
    await tester.tap(find.text('我执白 · 后手'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text('开局'));
  await tester.pumpAndSettle();
}

void main() {
  late Directory directory;
  late DatabaseService database;

  setUpAll(() async {
    directory = await openLifecycleHive();
    database = DatabaseService();
  });

  tearDownAll(() => closeLifecycleHive(directory, database));

  testWidgets('大厅黑白棋入口在五子棋下方，并显示 3 款游戏', (tester) async {
    await _openLobby(tester, database);
    expect(find.text('黑白棋 · Othello'), findsOneWidget);
    expect(find.text('上帝视角'), findsOneWidget);
    expect(find.text('真人参与'), findsOneWidget);
  });

  testWidgets('真人执黑先手：合法点击后 AI 正常回合，非法点不落子', (tester) async {
    await _openLobby(tester, database);
    await _startHumanGame(tester, humanSide: OthelloSide.black);
    var board = tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.interactive, isTrue);
    expect(board.state.currentSide, OthelloSide.black);
    expect(board.state.validMoves.map((move) => move.move.toCoordinate()),
        ['D3', 'C4', 'F5', 'E6']);

    await tester.tap(find.byKey(OthelloBoardView.cellKey(0, 0)));
    await tester.pump();
    board = tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.state.moveHistory, isEmpty);

    await tester.tap(find.byKey(OthelloBoardView.cellKey(2, 3)));
    await tester.pumpAndSettle();
    board = tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.state.moveHistory, hasLength(2));
    expect(board.state.moveHistory.first, const OthelloMove(2, 3));
    expect(board.state.moveHistory.last, const OthelloMove(2, 2));
    expect(board.interactive, isTrue);
    expect(find.textContaining('模型未落子：模型配置或凭据不可用'), findsOneWidget);
  });

  testWidgets('真人执白后手：黑方 AI 先走，白方合法点击后推进回合', (tester) async {
    await _openLobby(tester, database);
    await _startHumanGame(tester, humanSide: OthelloSide.white);
    await tester.pumpAndSettle();
    var board = tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.state.currentSide, OthelloSide.white);
    expect(board.state.moveHistory, hasLength(1));
    expect(board.interactive, isTrue);

    await tester.tap(find.byKey(OthelloBoardView.cellKey(2, 2)));
    await tester.pumpAndSettle();
    board = tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.state.moveHistory, hasLength(3));
    expect(board.state.moveHistory[1], const OthelloMove(2, 2));
  });

  testWidgets('上帝视角棋盘只读，停止后可重开', (tester) async {
    final engine = _DeferredLegalEngine();
    await _openLobby(tester, database, engine: engine);
    await tester.tap(find.text('开局'));
    await tester.pumpAndSettle();
    var board = tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.interactive, isFalse);
    expect(find.text('黑豆'), findsWidgets);
    expect(find.text('白果'), findsWidgets);
    expect(engine.requests, hasLength(1));

    await tester.tap(find.byTooltip('停止对局'));
    await tester.pump();
    expect(find.text('对局已停止'), findsOneWidget);
    engine.complete(0);
    await tester.pump();
    board = tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.state.moveHistory, isEmpty);

    await tester.tap(find.byTooltip('重新开局'));
    await tester.pumpAndSettle();
    final restarted =
        tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(restarted.state.moveHistory, isEmpty);
    expect(restarted.state.currentSide, OthelloSide.black);
    expect(restarted.interactive, isFalse);
    expect(engine.requests, hasLength(2));
    await tester.tap(find.byTooltip('停止对局'));
    await tester.pump();
    engine.complete(1);
    await tester.pump();
    board = tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.state.moveHistory, isEmpty);
  });

  testWidgets('离开观战页会取消 Hard 请求并忽略迟到结果', (tester) async {
    final engine = _DeferredLegalEngine();
    await _openLobby(tester, database, engine: engine);
    await tester.tap(find.text('开局'));
    await tester.pumpAndSettle();
    expect(engine.requests, hasLength(1));
    final token = engine.requests.single.cancelToken;
    expect(token, isNotNull);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(token!.isCancelled, isTrue);
    engine.complete(0);
    await tester.pump();

    expect(find.text('游戏大厅'), findsOneWidget);
    expect(find.text('黑白棋 · Othello'), findsNothing);
  });

  testWidgets('切入后台不暂停回合，用户停止仍取消模型任务', (tester) async {
    final engine = _DeferredLegalEngine();
    await _openLobby(tester, database, engine: engine);
    await tester.tap(find.text('开局'));
    await tester.pumpAndSettle();
    expect(engine.requests, hasLength(1));
    final oldToken = engine.requests.first.cancelToken!;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(oldToken.isCancelled, isFalse);
    expect(find.textContaining('应用已暂停'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    engine.complete(0);
    await tester.pumpAndSettle();
    final board =
        tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.state.moveHistory, hasLength(1));
    expect(engine.requests, hasLength(2));
    await tester.tap(find.byTooltip('停止对局'));
    await tester.pump();
    expect(engine.requests[1].cancelToken?.isCancelled, isTrue);
    engine.complete(1);
    await tester.pump();
  });

  testWidgets('两个角色能在大厅入口完整跑完一局观战对弈', (tester) async {
    await _openLobby(tester, database);
    await tester.tap(find.text('开局'));
    await tester.pumpAndSettle();

    var finished = false;
    for (var frame = 0; frame < 300; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (find.textContaining('获胜').evaluate().isNotEmpty ||
          find.textContaining('和棋').evaluate().isNotEmpty) {
        finished = true;
        break;
      }
    }
    expect(finished, isTrue, reason: 'AI 对弈应在有限帧内结算');
    final board =
        tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.state.isFinished, isTrue);
    expect(board.state.moveHistory.length, greaterThan(0));
    expect(board.interactive, isFalse);
    expect(find.byTooltip('重新开局'), findsOneWidget);
  });

  testWidgets('真人执黑通过大厅完整跑完一局人机对弈', (tester) async {
    await _openLobby(tester, database);
    await _startHumanGame(tester, humanSide: OthelloSide.black);

    var finished = false;
    for (var frame = 0; frame < 240; frame++) {
      final board =
          tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
      if (board.state.isFinished) {
        finished = true;
        break;
      }
      if (board.interactive) {
        final move = board.state.validMoves.first.move;
        await tester.tap(find.byKey(
          OthelloBoardView.cellKey(move.row, move.col),
        ));
      }
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(finished, isTrue, reason: '人机对局应在有限步数内结算');
    final board =
        tester.widget<OthelloBoardView>(find.byType(OthelloBoardView));
    expect(board.state.isFinished, isTrue);
    expect(board.state.moveHistory.length, greaterThan(0));
    expect(board.interactive, isFalse);
    expect(
      find.textContaining('获胜').evaluate().isNotEmpty ||
          find.textContaining('和棋').evaluate().isNotEmpty,
      isTrue,
    );
  });
}
