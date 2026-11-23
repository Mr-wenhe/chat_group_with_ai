// Derived from boisedude/othello-game, commit ee947aebf43b1efe78a577dc6d5e0f987ed87af4.
// Copyright (c) 2025 Play Coop Games. Licensed under the MIT License.

import 'othello_types.dart';

/// Pure 8×8 Othello rules. Legal move generation is the only move validator.
class OthelloRules {
  OthelloRules._();

  /// Direction ordering matches upstream `DIRECTIONS` and its flip arrays.
  static const List<List<int>> directions = [
    [-1, -1], // NW
    [-1, 0], // N
    [-1, 1], // NE
    [0, -1], // W
    [0, 1], // E
    [1, -1], // SW
    [1, 0], // S
    [1, 1], // SE
  ];

  static OthelloBoard createEmptyBoard() => List.generate(
        othelloBoardSize,
        (_) => List<int?>.filled(othelloBoardSize, null),
      );

  /// Standard opening: white at D4/E5, black at E4/D5; black moves first.
  static OthelloBoard createInitialBoard() {
    final board = createEmptyBoard();
    const middle = othelloBoardSize ~/ 2;
    board[middle - 1][middle - 1] = othelloWhiteValue;
    board[middle - 1][middle] = othelloBlackValue;
    board[middle][middle - 1] = othelloBlackValue;
    board[middle][middle] = othelloWhiteValue;
    return board;
  }

  static OthelloGameState createInitialState() {
    final board = createInitialBoard();
    return OthelloGameState(
      board: board,
      currentSide: OthelloSide.black,
      status: OthelloGameStatus.playing,
      winner: null,
      moveHistory: const [],
      lastMove: null,
      passedSide: null,
      validMoves: getValidMoves(board, OthelloSide.black),
    );
  }

  static bool isValidPosition(int row, int col) =>
      row >= 0 && row < othelloBoardSize && col >= 0 && col < othelloBoardSize;

  static OthelloSide getOpponent(OthelloSide side) => side.opponent;

  static List<OthelloMove> getFlippedDiscs(
    OthelloBoard board,
    int row,
    int col,
    OthelloSide side,
  ) {
    if (!isValidPosition(row, col) || board[row][col] != null) {
      return const [];
    }

    final result = <OthelloMove>[];
    for (final direction in directions) {
      result.addAll(_checkDirection(board, row, col, side, direction));
    }
    return result;
  }

  static List<OthelloMove> _checkDirection(
    OthelloBoard board,
    int row,
    int col,
    OthelloSide side,
    List<int> direction,
  ) {
    final deltaRow = direction[0];
    final deltaCol = direction[1];
    final flipped = <OthelloMove>[];
    var currentRow = row + deltaRow;
    var currentCol = col + deltaCol;
    while (isValidPosition(currentRow, currentCol) &&
        board[currentRow][currentCol] == side.opponent.value) {
      flipped.add(OthelloMove(currentRow, currentCol));
      currentRow += deltaRow;
      currentCol += deltaCol;
    }
    if (isValidPosition(currentRow, currentCol) &&
        board[currentRow][currentCol] == side.value &&
        flipped.isNotEmpty) {
      return flipped;
    }
    return const [];
  }

  static bool isValidMove(
    OthelloBoard board,
    int row,
    int col,
    OthelloSide side,
  ) =>
      getFlippedDiscs(board, row, col, side).isNotEmpty;

  /// Row-major candidate order matches upstream `getValidMoves`.
  static List<OthelloValidMove> getValidMoves(
    OthelloBoard board,
    OthelloSide side,
  ) {
    final moves = <OthelloValidMove>[];
    for (var row = 0; row < othelloBoardSize; row++) {
      for (var col = 0; col < othelloBoardSize; col++) {
        final flipped = getFlippedDiscs(board, row, col, side);
        if (flipped.isNotEmpty) {
          moves.add(
            OthelloValidMove(
              move: OthelloMove(row, col),
              flippedPositions: flipped,
            ),
          );
        }
      }
    }
    return List.unmodifiable(moves);
  }

  /// Upstream-compatible immutable simulation. Invalid moves leave [board] unchanged.
  static OthelloBoard executeMove(
    OthelloBoard board,
    int row,
    int col,
    OthelloSide side,
  ) {
    final flipped = getFlippedDiscs(board, row, col, side);
    if (flipped.isEmpty) return board;
    final newBoard = board.map((line) => List<int?>.of(line)).toList();
    newBoard[row][col] = side.value;
    for (final position in flipped) {
      newBoard[position.row][position.col] = side.value;
    }
    return newBoard;
  }

  static OthelloBoard simulateMove(
    OthelloBoard board,
    int row,
    int col,
    OthelloSide side,
  ) =>
      executeMove(board, row, col, side);

  static OthelloDiscCounts countDiscs(OthelloBoard board) {
    var black = 0;
    var white = 0;
    for (var row = 0; row < othelloBoardSize; row++) {
      for (var col = 0; col < othelloBoardSize; col++) {
        if (board[row][col] == othelloBlackValue) {
          black++;
        } else if (board[row][col] == othelloWhiteValue) {
          white++;
        }
      }
    }
    return OthelloDiscCounts(black: black, white: white);
  }

  static bool isBoardFull(OthelloBoard board) {
    for (var row = 0; row < othelloBoardSize; row++) {
      for (var col = 0; col < othelloBoardSize; col++) {
        if (board[row][col] == null) return false;
      }
    }
    return true;
  }

  static bool isGameOver(OthelloBoard board) =>
      isBoardFull(board) ||
      (getValidMoves(board, OthelloSide.black).isEmpty &&
          getValidMoves(board, OthelloSide.white).isEmpty);

  static OthelloSide? getWinner(OthelloBoard board) {
    final counts = countDiscs(board);
    if (counts.black > counts.white) return OthelloSide.black;
    if (counts.white > counts.black) return OthelloSide.white;
    return null;
  }

  /// Apply a move only if it appears in this exact state's generated legal list.
  /// Returns null for stale, out-of-turn, occupied, or otherwise illegal actions.
  static OthelloGameState? makeMove(
    OthelloGameState currentState,
    OthelloMove move,
  ) {
    if (currentState.isFinished ||
        !currentState.validMoves.any((candidate) => candidate.move == move)) {
      return null;
    }

    final side = currentState.currentSide;
    final newBoard = executeMove(
      currentState.board,
      move.row,
      move.col,
      side,
    );
    final opponentMoves = getValidMoves(newBoard, side.opponent);
    final currentMoves = getValidMoves(newBoard, side);
    final finished = isBoardFull(newBoard) ||
        (opponentMoves.isEmpty && currentMoves.isEmpty);
    final nextSide = opponentMoves.isNotEmpty ? side.opponent : side;
    final availableMoves = nextSide == side ? currentMoves : opponentMoves;

    return OthelloGameState(
      board: newBoard,
      currentSide: nextSide,
      status: finished ? OthelloGameStatus.finished : OthelloGameStatus.playing,
      winner: finished ? getWinner(newBoard) : null,
      moveHistory: [...currentState.moveHistory, move],
      lastMove: move,
      passedSide: !finished && opponentMoves.isEmpty ? side.opponent : null,
      validMoves: finished ? const [] : availableMoves,
    );
  }

  /// Resolve a turn with no legal move. One pass is recorded; two empty move
  /// lists settle the game immediately even when empty squares remain.
  static OthelloTurnResolution resolveNoMoves(OthelloGameState state) {
    if (state.isFinished || state.validMoves.isNotEmpty) {
      return OthelloTurnResolution(state: state, passedSides: const []);
    }

    final otherSide = state.currentSide.opponent;
    final otherMoves = getValidMoves(state.board, otherSide);
    if (otherMoves.isNotEmpty) {
      return OthelloTurnResolution(
        state: OthelloGameState(
          board: state.board,
          currentSide: otherSide,
          status: OthelloGameStatus.playing,
          winner: null,
          moveHistory: state.moveHistory,
          lastMove: state.lastMove,
          passedSide: state.currentSide,
          validMoves: otherMoves,
        ),
        passedSides: [state.currentSide],
      );
    }

    final finalState = OthelloGameState(
      board: state.board,
      currentSide: state.currentSide,
      status: OthelloGameStatus.finished,
      winner: getWinner(state.board),
      moveHistory: state.moveHistory,
      lastMove: state.lastMove,
      passedSide: state.currentSide,
      validMoves: const [],
    );
    return OthelloTurnResolution(
      state: finalState,
      passedSides: [state.currentSide],
    );
  }
}

class OthelloDiscCounts {
  const OthelloDiscCounts({required this.black, required this.white});

  final int black;
  final int white;
  int get total => black + white;

  int forSide(OthelloSide side) => side == OthelloSide.black ? black : white;
}

class OthelloTurnResolution {
  const OthelloTurnResolution({required this.state, required this.passedSides});

  final OthelloGameState state;
  final List<OthelloSide> passedSides;
}
