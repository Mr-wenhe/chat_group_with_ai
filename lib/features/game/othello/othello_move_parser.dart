import 'dart:convert';

import 'othello_types.dart';

/// Strict parser for the single JSON action requested from an Othello model.
class OthelloMoveParser {
  OthelloMoveParser._();

  static OthelloModelMove? parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map<String, dynamic> ||
          decoded.length != 2 ||
          !decoded.containsKey('move') ||
          !decoded.containsKey('reason')) {
        return null;
      }
      final coordinate = decoded['move'];
      final reason = decoded['reason'];
      if (coordinate is! String || reason is! String) return null;
      final move = OthelloMove.fromCoordinate(coordinate);
      final cleanReason = reason.trim();
      if (move == null || cleanReason.isEmpty || cleanReason.length > 120) {
        return null;
      }
      return OthelloModelMove(move: move, reason: cleanReason);
    } on FormatException {
      return null;
    }
  }
}

class OthelloModelMove {
  const OthelloModelMove({required this.move, required this.reason});

  final OthelloMove move;
  final String reason;
}
