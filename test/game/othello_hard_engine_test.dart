import 'package:chat_group/features/game/othello/othello_hard_engine.dart';
import 'package:chat_group/features/game/othello/othello_rules.dart';
import 'package:chat_group/features/game/othello/othello_types.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';

OthelloBoard _boardFromRows(List<String> rows) => [
      for (final row in rows)
        [
          for (final cell in row.split(''))
            switch (cell) {
              'B' => othelloBlackValue,
              'W' => othelloWhiteValue,
              _ => null,
            },
        ],
    ];

void main() {
  test('候选排序平分时保留上游行优先顺序', () {
    final board = OthelloRules.createInitialBoard();
    final validMoves = OthelloRules.getValidMoves(board, OthelloSide.black);
    final ordered = OthelloHardSearch.orderMovesByPreference(validMoves, board);
    expect(
      ordered.map((move) => move.move.toCoordinate()),
      ['F5', 'E6', 'D3', 'C4'],
    );
  });

  test('固定四空残局在完整搜索深度上选择上游 Hard 的 A1', () {
    final board = _boardFromRows([
      '.WBBBBBB',
      'WBBBBBBB',
      'WBBWBBBB',
      'WWWWWWWB',
      'WWWWWWBB',
      'BBWWWWBB',
      'BBWWWWWB',
      '.BWWW..W',
    ]);
    final moves = OthelloRules.getValidMoves(board, OthelloSide.black);
    expect(moves.map((move) => move.move.toCoordinate()), ['A1', 'F8', 'G8']);

    final result = const OthelloHardSearch().search(board, OthelloSide.black);
    expect(result, isNotNull);
    expect(result!.move.toCoordinate(), 'A1');
    expect(result.completedDepth, 6);
    expect(result.timedOut, isFalse);
    expect(moves.any((move) => move.move == result.move), isTrue);
  });

  test('截止时仍返回合法动作，并在首层中断时沿用首个排序候选', () {
    final board = OthelloRules.createInitialBoard();
    final result = const OthelloHardSearch().search(
      board,
      OthelloSide.black,
      deadlineMillisecondsSinceEpoch: 0,
    );
    expect(result, isNotNull);
    expect(result!.move.toCoordinate(), 'F5');
    expect(result.completedDepth, 1);
    expect(result.timedOut, isTrue);
    expect(
      OthelloRules.getValidMoves(board, OthelloSide.black)
          .any((move) => move.move == result.move),
      isTrue,
    );
  });

  test('生产 Hard 搜索在后台 isolate 中运行并处理预算耗尽', () async {
    final board = OthelloRules.createInitialBoard();
    final result = await const OthelloHardEngine(
      timeBudget: Duration.zero,
    ).bestMove(board, OthelloSide.black);
    expect(result, isNotNull);
    expect(result!.timedOut, isTrue);
    expect(
      OthelloRules.getValidMoves(board, OthelloSide.black)
          .any((move) => move.move == result.move),
      isTrue,
    );
  });

  test('已取消的引擎任务不会返回动作', () async {
    final token = CancelToken()..cancel('test stop');
    final result = await const OthelloHardEngine().bestMove(
      OthelloRules.createInitialBoard(),
      OthelloSide.black,
      cancelToken: token,
    );
    expect(result, isNull);
  });

  test('搜索运行中取消会结束任务且不返回动作', () async {
    final token = CancelToken();
    final pending = const OthelloHardEngine(
      timeBudget: Duration(seconds: 30),
      maxDepth: 20,
    ).bestMove(
      OthelloRules.createInitialBoard(),
      OthelloSide.black,
      cancelToken: token,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel('test stop');
    expect(await pending, isNull);
  });
}
