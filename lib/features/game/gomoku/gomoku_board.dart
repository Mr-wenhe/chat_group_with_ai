/// 五子棋规则引擎（纯 Dart，零 Flutter 依赖）。
///
/// 设计目标：让 AI 角色和真人都通过同一套 API 落子，规则判定与 UI 解耦，
/// 便于单测覆盖胜负、边界与和棋。棋盘坐标统一用 (行 row, 列 col)，范围 0..14。
library;

/// 棋子颜色。
enum GomokuStone {
  black,
  white;

  /// 对手颜色，用于轮转与「对方视角」渲染。
  GomokuStone get opponent =>
      this == GomokuStone.black ? GomokuStone.white : GomokuStone.black;

  /// 给 LLM 与日志用的可读名称。
  String get label => this == GomokuStone.black ? '黑' : '白';

  /// 棋盘文本符号：用 ASCII 而非全角字符，避免等宽对齐错位、便于模型读取。
  String get symbol => this == GomokuStone.black ? 'X' : 'O';
}

/// 棋盘上的一个坐标。
class GomokuPosition {
  final int row;
  final int col;

  const GomokuPosition(this.row, this.col);

  @override
  bool operator ==(Object other) =>
      other is GomokuPosition && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);

  @override
  String toString() => '($row,$col)';
}

/// 一步落子的记录，供对局回放与观战使用。
class GomokuMove {
  final GomokuPosition position;
  final GomokuStone stone;

  const GomokuMove(this.position, this.stone);

  @override
  String toString() => '${stone.label}$position';
}

/// 落子校验结果。
enum GomokuMoveResult {
  /// 落子成功。
  ok,

  /// 坐标越界。
  outOfBounds,

  /// 该位置已有棋子。
  occupied,

  /// 对局已结束（已有胜负或和棋），拒绝继续落子。
  gameOver,
}

/// 五子棋棋盘状态机。
///
/// 不持有「轮到谁」的概念——轮转由上层 [GameDirector] 管理，
/// 这里只负责落子合法性、胜负判定与棋盘渲染。
class GomokuBoard {
  /// 标准五子棋 15 路棋盘。
  static const int size = 15;

  /// 连成五子即获胜。
  static const int winLength = 5;

  /// 四个判定方向：横、竖、主对角、副对角。
  static const List<List<int>> directions = [
    [0, 1],
    [1, 0],
    [1, 1],
    [1, -1],
  ];

  final List<List<GomokuStone?>> _cells = List.generate(
    size,
    (_) => List<GomokuStone?>.filled(size, null),
  );
  final List<GomokuMove> _moves = <GomokuMove>[];

  GomokuStone? _winner;
  List<GomokuPosition>? _winningLine;

  /// 已落子总数，用于和棋判定，避免每次遍历全盘。
  int get moveCount => _moves.length;

  /// 落子序列，供观战回放。
  List<GomokuMove> get moves => List.unmodifiable(_moves);

  /// 获胜方；未分胜负时为 null。
  GomokuStone? get winner => _winner;

  /// 构成五连的坐标，供 UI 高亮；无胜负时为 null。
  List<GomokuPosition>? get winningLine => _winningLine;

  /// 棋盘是否已满（和棋条件）。
  bool get isFull => _moves.length >= size * size;

  /// 对局是否结束（分出胜负或和棋）。
  bool get isGameOver => _winner != null || isFull;

  /// 坐标是否在棋盘内。
  bool inBounds(int row, int col) =>
      row >= 0 && row < size && col >= 0 && col < size;

  /// 读取某格棋子；越界返回 null。
  GomokuStone? stoneAt(int row, int col) =>
      inBounds(row, col) ? _cells[row][col] : null;

  /// 落子。先校验，再写入，最后从该点出发判定五连。
  ///
  /// 返回 [GomokuMoveResult.ok] 表示落子生效，其余为拒绝原因。
  GomokuMoveResult place(int row, int col, GomokuStone stone) {
    if (isGameOver) return GomokuMoveResult.gameOver;
    if (!inBounds(row, col)) return GomokuMoveResult.outOfBounds;
    if (_cells[row][col] != null) return GomokuMoveResult.occupied;

    _cells[row][col] = stone;
    _moves.add(GomokuMove(GomokuPosition(row, col), stone));

    final line = _findWinningLine(row, col, stone);
    if (line != null) {
      _winner = stone;
      _winningLine = line;
    }
    return GomokuMoveResult.ok;
  }

  /// 从最后落子点出发，沿四方向找五连。
  ///
  /// 只检查最后落子的棋子——任何五连必然包含最后一手，这是五子棋判定
  /// 的必要条件，避免每次落子都全盘扫描。
  List<GomokuPosition>? _findWinningLine(int row, int col, GomokuStone stone) {
    for (final direction in directions) {
      final line = _lineInDirection(row, col, direction[0], direction[1], stone);
      if (line.length >= winLength) return line;
    }
    return null;
  }

  /// 收集某一方向上穿过 (row,col) 的连续同色棋子坐标。
  List<GomokuPosition> _lineInDirection(
    int row,
    int col,
    int dRow,
    int dCol,
    GomokuStone stone,
  ) {
    // 先沿反方向回溯到连续段的起点，再从起点正向收集，保证坐标有序。
    var startRow = row;
    var startCol = col;
    while (_sameStone(startRow - dRow, startCol - dCol, stone)) {
      startRow -= dRow;
      startCol -= dCol;
    }

    final line = <GomokuPosition>[];
    var r = startRow;
    var c = startCol;
    while (_sameStone(r, c, stone)) {
      line.add(GomokuPosition(r, c));
      r += dRow;
      c += dCol;
    }
    return line;
  }

  /// 越界或异色都视为不连续。
  bool _sameStone(int row, int col, GomokuStone stone) =>
      inBounds(row, col) && _cells[row][col] == stone;

  /// 渲染成给 LLM 看的文本棋盘。
  ///
  /// 同时给出网格图和精确落子清单：网格便于模型直观判断形状，
  /// 清单便于模型精确定位坐标（纯网格读坐标是模型最易出错的地方）。
  String renderAsText() {
    final buffer = StringBuffer();

    buffer.write('    ');
    for (var c = 0; c < size; c++) {
      buffer.write('${c.toString().padLeft(2)} ');
    }
    buffer.writeln();

    for (var r = 0; r < size; r++) {
      buffer.write('${r.toString().padLeft(2)}  ');
      for (var c = 0; c < size; c++) {
        final stone = _cells[r][c];
        buffer.write('${stone?.symbol ?? '.'}  ');
      }
      buffer.writeln();
    }

    buffer.writeln();
    buffer.writeln('落子清单（行,列）：');
    final blackMoves = _moves
        .where((m) => m.stone == GomokuStone.black)
        .map((m) => m.position.toString())
        .join(' ');
    final whiteMoves = _moves
        .where((m) => m.stone == GomokuStone.white)
        .map((m) => m.position.toString())
        .join(' ');
    buffer.writeln('黑 X：$blackMoves');
    buffer.writeln('白 O：$whiteMoves');
    return buffer.toString();
  }
}
