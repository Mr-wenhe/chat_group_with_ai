import 'package:chat_group/features/game/othello/othello_rules.dart';
import 'package:chat_group/features/game/othello/othello_types.dart';
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

void main() {
  group('开局与合法着法', () {
    test('标准 8×8 初始局面、黑先、四个中心棋子和合法动作顺序', () {
      final state = OthelloRules.createInitialState();
      expect(state.currentSide, OthelloSide.black);
      expect(state.board, hasLength(8));
      expect(state.board.every((row) => row.length == 8), isTrue);
      expect(state.board[3][3], othelloWhiteValue);
      expect(state.board[3][4], othelloBlackValue);
      expect(state.board[4][3], othelloBlackValue);
      expect(state.board[4][4], othelloWhiteValue);
      expect(OthelloRules.countDiscs(state.board).black, 2);
      expect(OthelloRules.countDiscs(state.board).white, 2);
      expect(
        state.validMoves.map((move) => move.move.toCoordinate()),
        ['D3', 'C4', 'F5', 'E6'],
      );
    });

    test('落子必须至少翻一子；越界、已占格与无夹击都不合法', () {
      final state = OthelloRules.createInitialState();
      expect(OthelloRules.isValidPosition(-1, 0), isFalse);
      expect(OthelloRules.isValidPosition(0, 8), isFalse);
      expect(
        OthelloRules.getFlippedDiscs(
          state.board,
          -1,
          0,
          OthelloSide.black,
        ),
        isEmpty,
      );
      expect(
        OthelloRules.getFlippedDiscs(
          state.board,
          3,
          3,
          OthelloSide.black,
        ),
        isEmpty,
      );
      expect(
        OthelloRules.getFlippedDiscs(
          state.board,
          0,
          0,
          OthelloSide.black,
        ),
        isEmpty,
      );
      expect(
        OthelloRules.makeMove(state, const OthelloMove(-1, 0)),
        isNull,
      );
      expect(
        OthelloRules.makeMove(state, const OthelloMove(3, 3)),
        isNull,
      );
      expect(
        OthelloRules.makeMove(state, const OthelloMove(0, 0)),
        isNull,
      );
    });

    test('翻子顺序覆盖八个方向，并一次翻转多个方向', () {
      final board = OthelloRules.createEmptyBoard();
      board[4][4] = othelloBlackValue;
      const surrounds = <OthelloMove>[
        OthelloMove(3, 3),
        OthelloMove(3, 4),
        OthelloMove(3, 5),
        OthelloMove(4, 3),
        OthelloMove(4, 5),
        OthelloMove(5, 3),
        OthelloMove(5, 4),
        OthelloMove(5, 5),
      ];
      const anchors = <OthelloMove>[
        OthelloMove(2, 2),
        OthelloMove(2, 4),
        OthelloMove(2, 6),
        OthelloMove(4, 2),
        OthelloMove(4, 6),
        OthelloMove(6, 2),
        OthelloMove(6, 4),
        OthelloMove(6, 6),
      ];
      for (final position in surrounds) {
        board[position.row][position.col] = othelloWhiteValue;
      }
      for (final position in anchors) {
        board[position.row][position.col] = othelloBlackValue;
      }
      board[4][4] = null;

      expect(
        OthelloRules.getFlippedDiscs(board, 4, 4, OthelloSide.black),
        surrounds,
      );
      final next = OthelloRules.executeMove(board, 4, 4, OthelloSide.black);
      expect(next[4][4], othelloBlackValue);
      for (final position in surrounds) {
        expect(next[position.row][position.col], othelloBlackValue);
      }
      expect(board[4][4], isNull, reason: '模拟落子不得修改原棋盘');
    });

    test('同一方向完整翻转长链，未被己方棋子封口时不翻', () {
      final anchored = OthelloRules.createEmptyBoard();
      anchored[0][0] = othelloBlackValue;
      for (var col = 1; col < 7; col++) {
        anchored[0][col] = othelloWhiteValue;
      }
      expect(
        OthelloRules.getFlippedDiscs(anchored, 0, 7, OthelloSide.black),
        [for (var col = 6; col >= 1; col--) OthelloMove(0, col)],
      );

      anchored[0][0] = othelloWhiteValue;
      expect(
        OthelloRules.getFlippedDiscs(anchored, 0, 7, OthelloSide.black),
        isEmpty,
      );
    });
  });

  group('回合与结算', () {
    test('一方无步时自动跳过到另一方，不调用玩家决策', () {
      final board = _boardFromRows([
        'WB......',
        '........',
        '........',
        '........',
        '........',
        '........',
        '........',
        '........',
      ]);
      final state = _stateFor(board, OthelloSide.black);
      expect(state.validMoves, isEmpty);
      expect(OthelloRules.getValidMoves(board, OthelloSide.white), [
        isA<OthelloValidMove>()
            .having((move) => move.move.toCoordinate(), 'move', 'C1'),
      ]);

      final result = OthelloRules.resolveNoMoves(state);
      expect(result.passedSides, [OthelloSide.black]);
      expect(result.state.currentSide, OthelloSide.white);
      expect(result.state.validMoves.single.move.toCoordinate(), 'C1');
      expect(result.state.status, OthelloGameStatus.playing);
    });

    test('双方无步且棋盘未满时终局并按棋子数判胜', () {
      final board = OthelloRules.createEmptyBoard();
      board[0][0] = othelloBlackValue;
      final result = OthelloRules.resolveNoMoves(
        _stateFor(board, OthelloSide.white),
      );
      expect(OthelloRules.isBoardFull(board), isFalse);
      expect(result.state.status, OthelloGameStatus.finished);
      expect(result.state.winner, OthelloSide.black);
      expect(result.state.validMoves, isEmpty);
    });

    test('满盘按棋子数结算，棋子数相同为和棋', () {
      final blackBoard = List.generate(
        8,
        (_) => List<int?>.filled(8, othelloBlackValue),
      );
      expect(OthelloRules.isBoardFull(blackBoard), isTrue);
      expect(OthelloRules.isGameOver(blackBoard), isTrue);
      expect(OthelloRules.getWinner(blackBoard), OthelloSide.black);

      final tiedBoard = List.generate(
        8,
        (row) => List<int?>.filled(
          8,
          row < 4 ? othelloBlackValue : othelloWhiteValue,
        ),
      );
      expect(OthelloRules.getWinner(tiedBoard), isNull);
      expect(OthelloRules.countDiscs(tiedBoard).black, 32);
      expect(OthelloRules.countDiscs(tiedBoard).white, 32);
    });

    test('一次规则提交落子、翻子、计分、历史与自动跳过', () {
      final state = OthelloRules.createInitialState();
      final next = OthelloRules.makeMove(state, const OthelloMove(2, 3));
      expect(next, isNotNull);
      expect(next!.board[2][3], othelloBlackValue);
      expect(next.board[3][3], othelloBlackValue);
      expect(next.currentSide, OthelloSide.white);
      expect(next.moveHistory, [const OthelloMove(2, 3)]);
      expect(next.lastMove, const OthelloMove(2, 3));
      expect(OthelloRules.countDiscs(next.board).black, 4);
      expect(OthelloRules.countDiscs(next.board).white, 1);
      expect(state.board[3][3], othelloWhiteValue);
    });
  });

  group('上游固定局面对照 ee947aeb', () {
    final midgame = _boardFromRows([
      '........',
      '......W.',
      'BB..BWW.',
      '.BBWWWW.',
      '.BWBBW..',
      '..WBBBB.',
      '.WWWWW..',
      '..W.....',
    ]);

    test('24 手中盘合法落点顺序与每个方向翻子结果一致', () {
      final moves = OthelloRules.getValidMoves(midgame, OthelloSide.black);
      expect(
        moves.map((move) => move.move.toCoordinate()),
        [
          'H1',
          'F2',
          'H2',
          'C3',
          'D3',
          'H3',
          'H4',
          'G5',
          'B6',
          'A8',
          'B8',
          'D8',
          'E8',
          'F8',
          'G8',
        ],
      );
      expect(
        moves.first.flippedPositions,
        [
          const OthelloMove(1, 6),
          const OthelloMove(2, 5),
          const OthelloMove(3, 4),
        ],
      );
      expect(
        moves[8].flippedPositions,
        [
          const OthelloMove(4, 2),
          const OthelloMove(3, 3),
          const OthelloMove(5, 2),
        ],
      );
      expect(OthelloRules.countDiscs(midgame).black, 12);
      expect(OthelloRules.countDiscs(midgame).white, 16);
    });

    test('規則狀態拒絕不在本回合合法列表中的模型或真人動作', () {
      final state = _stateFor(midgame, OthelloSide.black);
      expect(OthelloRules.makeMove(state, const OthelloMove(0, 0)), isNull);
      expect(
        OthelloRules.makeMove(state, const OthelloMove(0, 7)),
        isNotNull,
      );
    });
  });
}
