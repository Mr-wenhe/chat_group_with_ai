/// 五子棋算法决策引擎（纯 Dart，零网络、零模型调用）。
///
/// 设计目标：给五子棋一个确定、快速、有基本棋力的对手。模型调用会有
/// 空内容 / 超时 / 思考吃光预算等问题（本项目已多次实测），而一盘棋的
/// 胜负不该取决于上游网络。这里用经典的「点评分 + 攻防兼顾」启发式：
/// 枚举所有空点，对每个点按四个方向数连线、评估自己的进攻价值与对手的
/// 威胁阻断价值，取总分最高者。毫秒级完成，不可能超时或空内容。
library;

import 'gomoku_board.dart';

/// 引擎给出的一步决策。
class GomokuEngineMove {
  final GomokuPosition position;

  /// 简短战术理由，供观战区展示（如「成五」「堵对手活三」）。
  final String reason;

  const GomokuEngineMove(this.position, this.reason);
}

/// 五子棋启发式决策器。
class GomokuEngine {
  const GomokuEngine();

  /// 各连线形态的基础分值。
  ///
  /// 级别差要足够大，保证「成五 > 堵五 > 造活四 > 堵活四 > 造活三 ...」
  /// 的优先级不会被中心位置等微调分逆转。
  static const int _five = 1000000;
  static const int _openFour = 100000;
  static const int _four = 10000;
  static const int _openThree = 5000;
  static const int _three = 800;
  static const int _openTwo = 200;
  static const int _two = 40;

  /// 为 [stone] 选择最佳落点；棋盘已终局时返回 null。
  GomokuEngineMove? bestMove(GomokuBoard board, GomokuStone stone) {
    if (board.isGameOver) return null;

    // 1) 先找「一步成五」的必胜点；没有再找「堵对手成五」的必防点。
    //    这是唯一必须硬编码的优先级——其余用统一评分即可。
    final win = _findImmediateWin(board, stone);
    if (win != null) return GomokuEngineMove(win, '成五取胜');
    final block = _findImmediateWin(board, stone.opponent);
    if (block != null) return GomokuEngineMove(block, '堵对手成五');

    var best = const GomokuEngineMove(GomokuPosition(7, 7), '占据天元');
    var bestScore = -1;
    const center = GomokuBoard.size ~/ 2;

    for (var row = 0; row < GomokuBoard.size; row++) {
      for (var col = 0; col < GomokuBoard.size; col++) {
        if (board.stoneAt(row, col) != null) continue;
        // 只在已有棋子邻域内考虑，空旷处直接跳过（大幅减少枚举）。
        if (!_hasNeighbor(board, row, col)) continue;

        final attack = _scorePoint(board, row, col, stone);
        final defense = _scorePoint(board, row, col, stone.opponent);
        // 进攻略重于防守，否则会一味跟随对手；阻断价值按 0.9 折算。
        final proximity =
            (center - row).abs() + (center - col).abs();
        final score = attack + (defense * 0.9).round() - proximity;
        if (score > bestScore) {
          bestScore = score;
          best = GomokuEngineMove(
            GomokuPosition(row, col),
            _reasonFor(attack, defense),
          );
        }
      }
    }
    return best;
  }

  /// 战术理由：进攻分高说进攻，防守分高说堵截。
  ///
  /// 活四既可能是自己做成的，也可能是对手即将做成的——两者必须分开说，
  /// 否则观战区会出现「争夺活四」但实际是在拆对手活四的误导读法。
  String _reasonFor(int attack, int defense) {
    if (attack >= _openFour) return '做成活四';
    if (defense >= _openFour) return '封堵对手活四';
    if (attack >= _four) return '冲四进攻';
    if (defense >= _four) return '封堵冲四';
    if (attack >= _openThree) return '做活三';
    if (defense >= _openThree) return '堵对手活三';
    if (attack >= _three) return '扩展连线';
    if (defense >= _three) return '限制对手';
    return '布局';
  }

  /// 落一子后能否立刻成五。
  GomokuPosition? _findImmediateWin(
    GomokuBoard board,
    GomokuStone stone,
  ) {
    for (var row = 0; row < GomokuBoard.size; row++) {
      for (var col = 0; col < GomokuBoard.size; col++) {
        if (board.stoneAt(row, col) != null) continue;
        if (_wouldMakeFive(board, row, col, stone)) {
          return GomokuPosition(row, col);
        }
      }
    }
    return null;
  }

  /// 假设在 (row,col) 落 [stone]，沿四方向是否有任一连线达到五子。
  bool _wouldMakeFive(
    GomokuBoard board,
    int row,
    int col,
    GomokuStone stone,
  ) {
    for (final dir in GomokuBoard.directions) {
      var count = 1;
      count += _countDirection(board, row, col, dir[0], dir[1], stone);
      count += _countDirection(board, row, col, -dir[0], -dir[1], stone);
      if (count >= GomokuBoard.winLength) return true;
    }
    return false;
  }

  /// 从 (row,col) 沿方向连续数 [stone] 的个数（不含起点）。
  int _countDirection(
    GomokuBoard board,
    int row,
    int col,
    int dRow,
    int dCol,
    GomokuStone stone,
  ) {
    var count = 0;
    var r = row + dRow;
    var c = col + dCol;
    while (board.stoneAt(r, c) == stone) {
      count++;
      r += dRow;
      c += dCol;
    }
    return count;
  }

  /// 该点八邻域内是否已有棋子——避免在上百个空位上做无意义评分。
  bool _hasNeighbor(GomokuBoard board, int row, int col) {
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        if (dr == 0 && dc == 0) continue;
        if (board.stoneAt(row + dr, col + dc) != null) return true;
      }
    }
    return false;
  }

  /// 评估在 (row,col) 落 [stone] 的价值：四方向连线形态分之和。
  int _scorePoint(
    GomokuBoard board,
    int row,
    int col,
    GomokuStone stone,
  ) {
    var total = 0;
    for (final dir in GomokuBoard.directions) {
      total += _scoreDirection(board, row, col, dir[0], dir[1], stone);
    }
    return total;
  }

  /// 单个方向的连线分：连续子数决定级别，两端是否空决定「活/冲」。
  int _scoreDirection(
    GomokuBoard board,
    int row,
    int col,
    int dRow,
    int dCol,
    GomokuStone stone,
  ) {
    final forward = _countDirection(board, row, col, dRow, dCol, stone);
    final backward = _countDirection(board, row, col, -dRow, -dCol, stone);
    final length = forward + backward + 1;

    final blockedAhead = board.stoneAt(
          row + dRow * (forward + 1),
          col + dCol * (forward + 1),
        ) != null;
    final blockedBehind = board.stoneAt(
          row - dRow * (backward + 1),
          col - dCol * (backward + 1),
        ) != null;
    final isOpen = !blockedAhead && !blockedBehind;

    if (length >= 5) return _five;
    return switch (length) {
      4 => isOpen ? _openFour : _four,
      3 => isOpen ? _openThree : _three,
      2 => isOpen ? _openTwo : _two,
      _ => 1,
    };
  }
}
