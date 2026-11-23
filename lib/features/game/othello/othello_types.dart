// Derived from boisedude/othello-game, commit ee947aebf43b1efe78a577dc6d5e0f987ed87af4.
// Copyright (c) 2025 Play Coop Games. Licensed under the MIT License.

/// Standard Othello board dimensions and player encodings from the upstream.
const int othelloBoardSize = 8;
const int othelloBlackValue = 1;
const int othelloWhiteValue = 2;

typedef OthelloBoard = List<List<int?>>;

enum OthelloSide {
  black(othelloBlackValue, '黑方', '黑'),
  white(othelloWhiteValue, '白方', '白');

  const OthelloSide(this.value, this.label, this.shortLabel);

  final int value;
  final String label;
  final String shortLabel;

  OthelloSide get opponent => this == black ? white : black;

  static OthelloSide fromValue(int value) => switch (value) {
        othelloBlackValue => black,
        othelloWhiteValue => white,
        _ => throw ArgumentError.value(value, 'value', 'Unknown Othello side'),
      };
}

/// A zero-based board position. UI/model coordinates use [toCoordinate].
class OthelloMove {
  final int row;
  final int col;

  const OthelloMove(this.row, this.col);

  bool get isOnBoard =>
      row >= 0 && row < othelloBoardSize && col >= 0 && col < othelloBoardSize;

  /// Maps row 0 to rank 1 and column 0 to file A, matching the UI and prompt.
  String toCoordinate() => '${String.fromCharCode(65 + col)}${row + 1}';

  static OthelloMove? fromCoordinate(String value) {
    final match = RegExp(r'^([A-Ha-h])([1-8])$').firstMatch(value.trim());
    if (match == null) return null;
    return OthelloMove(
      int.parse(match.group(2)!) - 1,
      match.group(1)!.toUpperCase().codeUnitAt(0) - 65,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OthelloMove && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);

  @override
  String toString() => 'OthelloMove(${toCoordinate()})';
}

/// A legal move and the discs it flips, kept in upstream direction order.
class OthelloValidMove {
  final OthelloMove move;
  final List<OthelloMove> flippedPositions;

  OthelloValidMove(
      {required this.move, required List<OthelloMove> flippedPositions})
      : flippedPositions = List.unmodifiable(flippedPositions);

  int get row => move.row;
  int get col => move.col;
  int get flipsCount => flippedPositions.length;

  @override
  bool operator ==(Object other) =>
      other is OthelloValidMove &&
      other.move == move &&
      _sameMoves(other.flippedPositions, flippedPositions);

  @override
  int get hashCode => Object.hash(move, Object.hashAll(flippedPositions));
}

bool _sameMoves(List<OthelloMove> first, List<OthelloMove> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

enum OthelloGameStatus { playing, finished }

/// Immutable match snapshot. No state is persisted between matches.
class OthelloGameState {
  OthelloGameState({
    required OthelloBoard board,
    required this.currentSide,
    required this.status,
    required this.winner,
    required List<OthelloMove> moveHistory,
    required this.lastMove,
    required this.passedSide,
    required List<OthelloValidMove> validMoves,
  })  : board = _freezeBoard(board),
        moveHistory = List.unmodifiable(moveHistory),
        validMoves = List.unmodifiable(validMoves);

  final OthelloBoard board;
  final OthelloSide currentSide;
  final OthelloGameStatus status;
  final OthelloSide? winner;
  final List<OthelloMove> moveHistory;
  final OthelloMove? lastMove;

  /// The side automatically skipped after the previous committed move.
  final OthelloSide? passedSide;
  final List<OthelloValidMove> validMoves;

  bool get isFinished => status == OthelloGameStatus.finished;

  OthelloGameState copyWith({
    OthelloBoard? board,
    OthelloSide? currentSide,
    OthelloGameStatus? status,
    OthelloSide? winner,
    bool clearWinner = false,
    List<OthelloMove>? moveHistory,
    OthelloMove? lastMove,
    bool clearLastMove = false,
    OthelloSide? passedSide,
    bool clearPassedSide = false,
    List<OthelloValidMove>? validMoves,
  }) {
    return OthelloGameState(
      board: board ?? this.board,
      currentSide: currentSide ?? this.currentSide,
      status: status ?? this.status,
      winner: clearWinner ? null : winner ?? this.winner,
      moveHistory: moveHistory ?? this.moveHistory,
      lastMove: clearLastMove ? null : lastMove ?? this.lastMove,
      passedSide: clearPassedSide ? null : passedSide ?? this.passedSide,
      validMoves: validMoves ?? this.validMoves,
    );
  }
}

OthelloBoard _freezeBoard(OthelloBoard board) =>
    List<List<int?>>.unmodifiable(board.map(List<int?>.unmodifiable));
