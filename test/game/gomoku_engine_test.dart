// 本地五子棋引擎单测：验证必胜/必防/开局/终局与落点合法性。
// 纯 Dart 逻辑，不依赖 Flutter binding、网络或模型凭据。
import 'package:chat_group/features/game/gomoku/gomoku_board.dart';
import 'package:chat_group/features/game/gomoku/gomoku_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const engine = GomokuEngine();

  group('硬优先级', () {
    test('自己四连时直接成五取胜', () {
      final board = GomokuBoard();
      for (final col in [7, 8, 9, 10]) {
        expect(board.place(7, col, GomokuStone.black), GomokuMoveResult.ok);
      }
      final move = engine.bestMove(board, GomokuStone.black)!;
      expect(move.position.row, 7);
      expect([6, 11], contains(move.position.col));
      expect(move.reason, '成五取胜');
    });

    test('对手四连时优先堵五', () {
      final board = GomokuBoard();
      for (final col in [7, 8, 9, 10]) {
        expect(board.place(7, col, GomokuStone.white), GomokuMoveResult.ok);
      }
      final move = engine.bestMove(board, GomokuStone.black)!;
      expect(move.position.row, 7);
      expect([6, 11], contains(move.position.col));
      expect(move.reason, '堵对手成五');
    });

    test('自己能赢时不会被对手的四连分心', () {
      final board = GomokuBoard();
      for (final col in [7, 8, 9, 10]) {
        board.place(7, col, GomokuStone.black);
        board.place(9, col, GomokuStone.white);
      }
      final move = engine.bestMove(board, GomokuStone.black)!;
      expect(move.position.row, 7);
      expect(move.reason, '成五取胜');
    });
  });

  group('普通决策', () {
    test('空棋盘走天元', () {
      final move = engine.bestMove(GomokuBoard(), GomokuStone.black)!;
      expect(move.position, const GomokuPosition(7, 7));
    });

    test('不会落在已占位置', () {
      final board = GomokuBoard();
      board.place(7, 7, GomokuStone.black);
      board.place(7, 8, GomokuStone.white);
      board.place(6, 6, GomokuStone.black);

      for (var i = 0; i < 20; i++) {
        final move = engine.bestMove(board, GomokuStone.white)!;
        expect(board.stoneAt(move.position.row, move.position.col), isNull);
        board.place(move.position.row, move.position.col, GomokuStone.white);
        if (board.isGameOver) break;
      }
    });

    test('对局已结束时不再给落点', () {
      final board = GomokuBoard();
      for (final col in [0, 1, 2, 3, 4]) {
        board.place(0, col, GomokuStone.black);
      }
      expect(board.winner, GomokuStone.black);
      expect(engine.bestMove(board, GomokuStone.white), isNull);
    });

    test('拦截对手活四时理由说「封堵」而不是「争夺」', () {
      final board = GomokuBoard();
      // 白棋斜线三连：黑若不占 (7,3)/(11,7)，白下一手即成活四。
      for (final p in [
        const GomokuPosition(8, 4),
        const GomokuPosition(9, 5),
        const GomokuPosition(10, 6),
      ]) {
        board.place(p.row, p.col, GomokuStone.white);
      }
      final move = engine.bestMove(board, GomokuStone.black)!;
      expect(move.position, const GomokuPosition(7, 3));
      expect(move.reason, '封堵对手活四');
    });
  });
}
