/// 五子棋棋盘 widget：自绘网格与棋子，点击交叉点落子。
///
/// 只负责「画」与「报坐标」——落子合法性由 [GameDirector] 判定，
/// 这里不持有任何规则逻辑。命中判定用就近交叉点，容差为格距的 40%。
library;

import 'package:flutter/material.dart';

import 'gomoku_board.dart';

/// 可交互棋盘。
class GomokuBoardView extends StatelessWidget {
  final GomokuBoard board;
  final bool interactive;
  final List<GomokuPosition>? winningLine;
  final void Function(int row, int col)? onTap;

  const GomokuBoardView({
    super.key,
    required this.board,
    this.interactive = false,
    this.winningLine,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = constraints.maxWidth;
          final padding = side * 0.06;
          final cell = (side - padding * 2) / (GomokuBoard.size - 1);
          final moves = board.moves;
          final lastMove = moves.isEmpty ? null : moves.last.position;
          return GestureDetector(
            onTapDown: interactive
                ? (details) => _handleTap(details.localPosition, padding, cell)
                : null,
            child: CustomPaint(
              size: Size(side, side),
              painter: _BoardPainter(
                board: board,
                padding: padding,
                cell: cell,
                winningLine: winningLine,
                lastMove: lastMove,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 把局部点击坐标换算成棋盘 (row, col)。
  ///
  /// 横轴 dx → 列 col，纵轴 dy → 行 row（与绘制时的
  /// `Offset(padding + cell*col, padding + cell*row)` 一致）。抽成静态方法便于单测。
  static GomokuPosition? positionFromTap(
    Offset local,
    double padding,
    double cell, {
    int boardSize = GomokuBoard.size,
  }) {
    final rawCol = (local.dx - padding) / cell;
    final rawRow = (local.dy - padding) / cell;
    final col = rawCol.round();
    final row = rawRow.round();
    // 容差：点击必须落在交叉点附近，避免误触。
    if ((rawCol - col).abs() > 0.4 || (rawRow - row).abs() > 0.4) return null;
    if (row < 0 || row >= boardSize || col < 0 || col >= boardSize) return null;
    return GomokuPosition(row, col);
  }

  void _handleTap(Offset local, double padding, double cell) {
    final position = positionFromTap(local, padding, cell);
    if (position != null) onTap?.call(position.row, position.col);
  }
}

class _BoardPainter extends CustomPainter {
  final GomokuBoard board;
  final double padding;
  final double cell;
  final List<GomokuPosition>? winningLine;
  final GomokuPosition? lastMove;

  _BoardPainter({
    required this.board,
    required this.padding,
    required this.cell,
    this.winningLine,
    this.lastMove,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..color = const Color(0xFFE8C88A)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, bg);

    final linePaint = Paint()
      ..color = const Color(0xFF6B4E2E).withValues(alpha: 0.7)
      ..strokeWidth = 1.2;
    for (var i = 0; i < GomokuBoard.size; i++) {
      final offset = padding + cell * i;
      canvas.drawLine(
        Offset(padding, offset),
        Offset(padding + cell * (GomokuBoard.size - 1), offset),
        linePaint,
      );
      canvas.drawLine(
        Offset(offset, padding),
        Offset(offset, padding + cell * (GomokuBoard.size - 1)),
        linePaint,
      );
    }

    // 天元与四个星位的小圆点。
    final starPaint = Paint()..color = const Color(0xFF6B4E2E);
    const starPoints = [7, 3, 11];
    for (final row in starPoints) {
      for (final col in starPoints) {
        if (row == 7 && col == 7 || (row != 7 && col != 7)) {
          final c = Offset(padding + cell * col, padding + cell * row);
          canvas.drawCircle(c, cell * 0.08, starPaint);
        }
      }
    }

    final winSet = winningLine?.toSet() ?? const <GomokuPosition>{};
    for (var row = 0; row < GomokuBoard.size; row++) {
      for (var col = 0; col < GomokuBoard.size; col++) {
        final stone = board.stoneAt(row, col);
        if (stone == null) continue;
        final position = GomokuPosition(row, col);
        _drawStone(
          canvas,
          Offset(padding + cell * col, padding + cell * row),
          stone,
          isWinning: winSet.contains(position),
          isLastMove: position == lastMove,
        );
      }
    }
  }

  void _drawStone(Canvas canvas, Offset center, GomokuStone stone,
      {required bool isWinning, required bool isLastMove}) {
    final radius = cell * 0.44;
    // 棋子主体用纯色 + 轻微投影，不加描边；末手用对比色圆点标出。
    canvas.drawCircle(
      center + const Offset(1, 2),
      radius,
      Paint()..color = const Color(0x33000000),
    );
    final color = stone == GomokuStone.black
        ? const Color(0xFF1F1F1F)
        : const Color(0xFFFAFAFA);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
    if (isWinning) {
      canvas.drawCircle(
        center,
        radius * 0.42,
        Paint()..color = const Color(0xFFE24B4A),
      );
    }
    if (isLastMove) {
      final outlineColor = stone == GomokuStone.black
          ? const Color(0xFFFAFAFA)
          : const Color(0xFF1F1F1F);
      canvas.drawCircle(
        center,
        cell * 0.115,
        Paint()
          ..color = const Color(0xFFFF6B00)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        cell * 0.115,
        Paint()
          ..color = outlineColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * 0.025,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BoardPainter oldDelegate) =>
      !identical(oldDelegate.board, board) ||
      oldDelegate.board.moveCount != board.moveCount ||
      oldDelegate.lastMove != lastMove ||
      oldDelegate.winningLine != winningLine;
}
