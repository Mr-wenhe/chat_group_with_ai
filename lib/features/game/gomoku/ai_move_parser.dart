/// 从 LLM 自由文本中解析五子棋落子坐标。
///
/// 模型输出格式的健壮性是这类功能的主要风险点：它常把坐标包在 markdown
/// 代码块里、夹带思考过程、或用中文/自然语言描述位置。这里按「结构化优先，
/// 自然语言兜底」的顺序解析，任何解析结果都要经过棋盘范围校验才返回。
library;

import 'gomoku_board.dart';

/// 坐标解析的纯函数工具。
class GomokuMoveParser {
  /// JSON 对象：容忍 row/col 任意顺序、多余字段与空白。
  /// 模型常输出单引号、全角冒号甚至无引号，这里统一兼容。
  static final RegExp _jsonObject = RegExp(r'\{[^{}]*\}');

  // 用 \u0027 表示单引号，避免与 Dart 单引号字符串字面量冲突。
  static final RegExp _jsonRow = RegExp(
    r'["\u0027]?row["\u0027]?\s*[:：]\s*["\u0027]?(\d{1,2})["\u0027]?',
    caseSensitive: false,
  );
  static final RegExp _jsonCol = RegExp(
    r'["\u0027]?col(?:umn)?["\u0027]?\s*[:：]\s*["\u0027]?(\d{1,2})["\u0027]?',
    caseSensitive: false,
  );

  /// 括号坐标：(7,7) / （7，7）
  static final RegExp _parenCoord =
      RegExp(r'[\(（]\s*(\d{1,2})\s*[,，]\s*(\d{1,2})\s*[\)）]');

  /// 中文「第7行第7列」（数字在字前），兼容中间带「第」。
  static final RegExp _cnCoordNumFirst =
      RegExp(r'第?\s*(\d{1,2})\s*行\s*第?\s*(\d{1,2})\s*列');

  /// 中文「行 7 列 3」（字在数字前）。
  static final RegExp _cnCoordWordFirst =
      RegExp(r'行\s*[:：]?\s*(\d{1,2})\s*列\s*[:：]?\s*(\d{1,2})');

  /// 英文标签：row: 7, col: 7
  static final RegExp _labeledCoord = RegExp(
    r'row\s*[:：]\s*(\d{1,2})[\s,，]+col(?:umn)?\s*[:：]\s*(\d{1,2})',
    caseSensitive: false,
  );

  GomokuMoveParser._();

  /// 从文本中解析出一个合法坐标；无法解析或越界时返回 null。
  ///
  /// 解析顺序：JSON 对象 → 带标签坐标 → 中文坐标 → 括号坐标。
  /// 结构化格式优先，避免模型在思考文字里提到的坐标抢占真正的答案。
  static GomokuPosition? parse(String text, {int boardSize = GomokuBoard.size}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    final parsers = <GomokuPosition? Function()>[
      () => _parseJson(trimmed, boardSize),
      () => _parseFirstMatch(_labeledCoord, trimmed, boardSize),
      () => _parseFirstMatch(_cnCoordNumFirst, trimmed, boardSize),
      () => _parseFirstMatch(_cnCoordWordFirst, trimmed, boardSize),
      () => _parseFirstMatch(_parenCoord, trimmed, boardSize),
    ];
    for (final parser in parsers) {
      final position = parser();
      if (position != null) return position;
    }
    return null;
  }

  /// 遍历所有 JSON 对象，取第一个同时含 row 与 col 的。
  static GomokuPosition? _parseJson(String text, int boardSize) {
    for (final match in _jsonObject.allMatches(text)) {
      final object = match.group(0)!;
      final rowMatch = _jsonRow.firstMatch(object);
      final colMatch = _jsonCol.firstMatch(object);
      if (rowMatch == null || colMatch == null) continue;
      final row = int.tryParse(rowMatch.group(1)!);
      final col = int.tryParse(colMatch.group(1)!);
      final position = _validated(row, col, boardSize);
      if (position != null) return position;
    }
    return null;
  }

  /// 用「行在前、列在后」的二分组正则取第一个匹配。
  static GomokuPosition? _parseFirstMatch(
    RegExp pattern,
    String text,
    int boardSize,
  ) {
    final match = pattern.firstMatch(text);
    if (match == null) return null;
    final row = int.tryParse(match.group(1)!);
    final col = int.tryParse(match.group(2)!);
    return _validated(row, col, boardSize);
  }

  /// 越界或解析失败一律返回 null。
  static GomokuPosition? _validated(int? row, int? col, int boardSize) {
    if (row == null || col == null) return null;
    if (row < 0 || row >= boardSize || col < 0 || col >= boardSize) {
      return null;
    }
    return GomokuPosition(row, col);
  }
}
