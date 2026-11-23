// 五子棋规则引擎单测：纯逻辑，不依赖 Flutter binding 或 Hive。
import 'package:chat_group/features/game/gomoku/gomoku_board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按顺序落子，便于测试里快速摆出棋形。
GomokuMoveResult _play(GomokuBoard board, List<GomokuPosition> positions,
    GomokuStone stone) {
  var result = GomokuMoveResult.ok;
  for (final p in positions) {
    result = board.place(p.row, p.col, stone);
  }
  return result;
}

void main() {
  group('落子校验', () {
    test('合法落子返回 ok 并写入棋盘', () {
      final board = GomokuBoard();
      expect(board.place(7, 7, GomokuStone.black), GomokuMoveResult.ok);
      expect(board.stoneAt(7, 7), GomokuStone.black);
      expect(board.moveCount, 1);
    });

    test('越界坐标被拒绝', () {
      final board = GomokuBoard();
      expect(board.place(-1, 0, GomokuStone.black),
          GomokuMoveResult.outOfBounds);
      expect(board.place(0, 15, GomokuStone.black),
          GomokuMoveResult.outOfBounds);
      expect(board.moveCount, 0);
    });

    test('已有棋子的位置被拒绝', () {
      final board = GomokuBoard();
      board.place(7, 7, GomokuStone.black);
      expect(board.place(7, 7, GomokuStone.white), GomokuMoveResult.occupied);
      expect(board.stoneAt(7, 7), GomokuStone.black);
      expect(board.moveCount, 1);
    });
  });

  group('胜负判定', () {
    test('横向五连判黑胜', () {
      final board = GomokuBoard();
      _play(board, [
        const GomokuPosition(7, 3),
        const GomokuPosition(7, 4),
        const GomokuPosition(7, 5),
        const GomokuPosition(7, 6),
        const GomokuPosition(7, 7),
      ], GomokuStone.black);
      expect(board.winner, GomokuStone.black);
      expect(board.winningLine, hasLength(5));
      expect(board.isGameOver, isTrue);
    });

    test('竖向五连判白胜', () {
      final board = GomokuBoard();
      _play(board, [
        const GomokuPosition(3, 8),
        const GomokuPosition(4, 8),
        const GomokuPosition(5, 8),
        const GomokuPosition(6, 8),
        const GomokuPosition(7, 8),
      ], GomokuStone.white);
      expect(board.winner, GomokuStone.white);
      expect(board.winningLine, hasLength(5));
    });

    test('主对角五连判胜', () {
      final board = GomokuBoard();
      _play(board, [
        const GomokuPosition(3, 3),
        const GomokuPosition(4, 4),
        const GomokuPosition(5, 5),
        const GomokuPosition(6, 6),
        const GomokuPosition(7, 7),
      ], GomokuStone.black);
      expect(board.winner, GomokuStone.black);
      expect(board.winningLine, hasLength(5));
    });

    test('副对角五连判胜', () {
      final board = GomokuBoard();
      _play(board, [
        const GomokuPosition(3, 9),
        const GomokuPosition(4, 8),
        const GomokuPosition(5, 7),
        const GomokuPosition(6, 6),
        const GomokuPosition(7, 5),
      ], GomokuStone.white);
      expect(board.winner, GomokuStone.white);
      expect(board.winningLine, hasLength(5));
    });

    test('第五子落下即终局，胜线为连续五子且坐标正确', () {
      final board = GomokuBoard();
      _play(board, [
        const GomokuPosition(2, 2),
        const GomokuPosition(2, 3),
        const GomokuPosition(2, 4),
        const GomokuPosition(2, 5),
      ], GomokuStone.black);
      expect(board.winner, isNull);
      // 逐手落子规则下，第 5 手就已判胜，不可能再落出逐手的第六子。
      expect(board.place(2, 6, GomokuStone.black), GomokuMoveResult.ok);
      expect(board.winner, GomokuStone.black);
      expect(board.winningLine, hasLength(5));
      expect(
        board.winningLine,
        [
          const GomokuPosition(2, 2),
          const GomokuPosition(2, 3),
          const GomokuPosition(2, 4),
          const GomokuPosition(2, 5),
          const GomokuPosition(2, 6),
        ],
      );
      // 终局后第 6 手被拒绝。
      expect(board.place(2, 7, GomokuStone.black), GomokuMoveResult.gameOver);
    });

    test('中间落子补成五连也能判定（非仅末端成线）', () {
      final board = GomokuBoard();
      // 先摆 3、4、6、7，再在中间 5 落子补成 3..7 五连。
      board.place(9, 3, GomokuStone.black);
      board.place(9, 4, GomokuStone.black);
      board.place(9, 6, GomokuStone.black);
      board.place(9, 7, GomokuStone.black);
      expect(board.winner, isNull);
      expect(board.place(9, 5, GomokuStone.black), GomokuMoveResult.ok);
      expect(board.winner, GomokuStone.black);
      expect(board.winningLine, hasLength(5));
    });

    test('四子不成胜', () {
      final board = GomokuBoard();
      _play(board, [
        const GomokuPosition(0, 0),
        const GomokuPosition(0, 1),
        const GomokuPosition(0, 2),
        const GomokuPosition(0, 3),
      ], GomokuStone.black);
      expect(board.winner, isNull);
      expect(board.isGameOver, isFalse);
    });
  });

  group('终局约束', () {
    test('分出胜负后拒绝继续落子', () {
      final board = GomokuBoard();
      _play(board, [
        const GomokuPosition(1, 1),
        const GomokuPosition(1, 2),
        const GomokuPosition(1, 3),
        const GomokuPosition(1, 4),
        const GomokuPosition(1, 5),
      ], GomokuStone.black);
      expect(board.place(10, 10, GomokuStone.white),
          GomokuMoveResult.gameOver);
      expect(board.moveCount, 5);
    });

    test('棋盘填满未成五连视为和棋', () {
      final board = GomokuBoard();
      // 线性模 4 填充：((row + 2*col) % 4) < 2 决定颜色。
      // 横 Δ=2、竖 Δ=1、主对角 Δ=3、副对角 Δ=3（模 4），
      // 每个方向连续同色段都不超过 2 格，绝不成五连。
      for (var row = 0; row < GomokuBoard.size; row++) {
        for (var col = 0; col < GomokuBoard.size; col++) {
          final isBlack = (row + 2 * col) % 4 < 2;
          final stone = isBlack ? GomokuStone.black : GomokuStone.white;
          expect(board.place(row, col, stone), GomokuMoveResult.ok);
        }
      }
      expect(board.isFull, isTrue);
      expect(board.winner, isNull);
      expect(board.isGameOver, isTrue);
    });
  });

  group('文本渲染', () {
    test('渲染包含表头、棋子符号与落子清单', () {
      final board = GomokuBoard();
      board.place(7, 7, GomokuStone.black);
      board.place(7, 8, GomokuStone.white);
      final text = board.renderAsText();
      expect(text, contains('落子清单'));
      expect(text, contains('黑 X：(7,7)'));
      expect(text, contains('白 O：(7,8)'));
      // 15 行棋盘 + 表头 + 落子清单区。
      expect(text.split('\n').length, greaterThan(15));
    });
  });
}
