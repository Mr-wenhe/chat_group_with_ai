// 棋盘点击坐标映射单测：防止行/列写反（dx→col、dy→row）。
import 'package:chat_group/features/game/gomoku/gomoku_board.dart';
import 'package:chat_group/features/game/gomoku/gomoku_board_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 假设棋盘边长 600，padding=36，cell=(600-72)/14≈37.714
  const side = 600.0;
  const padding = side * 0.06; // 36
  const cell = (side - padding * 2) / (GomokuBoard.size - 1);

  Offset pointAt(int row, int col) =>
      Offset(padding + cell * col, padding + cell * row);

  group('点击坐标映射', () {
    test('左上角 (0,0)', () {
      expect(
        GomokuBoardView.positionFromTap(pointAt(0, 0), padding, cell),
        const GomokuPosition(0, 0),
      );
    });

    test('右下角 (14,14)', () {
      expect(
        GomokuBoardView.positionFromTap(pointAt(14, 14), padding, cell),
        const GomokuPosition(14, 14),
      );
    });

    test('行列不对称点 (行7,列3) 不颠倒', () {
      // 这个用例专门防「dx 当 row、dy 当 col」的回归 bug。
      expect(
        GomokuBoardView.positionFromTap(pointAt(7, 3), padding, cell),
        const GomokuPosition(7, 3),
      );
    });

    test('行列不对称点 (行2,列11) 不颠倒', () {
      expect(
        GomokuBoardView.positionFromTap(pointAt(2, 11), padding, cell),
        const GomokuPosition(2, 11),
      );
    });

    test('偏离交叉点太远返回 null', () {
      // 格子中间（偏移 0.5 cell）应被容差拒绝。
      final middle = pointAt(5, 5) + const Offset(18.857, 0);
      expect(
        GomokuBoardView.positionFromTap(middle, padding, cell),
        isNull,
      );
    });

    test('棋盘外的坐标返回 null', () {
      expect(
        GomokuBoardView.positionFromTap(const Offset(-10, -10), padding, cell),
        isNull,
      );
      expect(
        GomokuBoardView.positionFromTap(const Offset(700, 700), padding, cell),
        isNull,
      );
    });
  });
}
