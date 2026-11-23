// Derived from boisedude/othello-game, commit ee947aebf43b1efe78a577dc6d5e0f987ed87af4.
// Copyright (c) 2025 Play Coop Games. Licensed under the MIT License.

import 'dart:async';
import 'dart:isolate';

import 'package:dio/dio.dart' show CancelToken;

import 'othello_rules.dart';
import 'othello_types.dart';

const int othelloHardSearchDepth = 6;
const Duration othelloHardSearchBudget = Duration(milliseconds: 1500);

/// The upstream evaluation weights and move-ordering priorities.
class _OthelloAiConfig {
  static const int cornerValue = 100;
  static const int xSquarePenalty = 25;
  static const int cSquarePenalty = 20;
  static const int edgeValue = 5;
  static const int mobilityWeight = 2;
  static const int discCountWeight = 1;
  static const int winScore = 10000;
  static const int lossScore = -10000;
  static const int cornerPriority = 1000;
  static const int edgePriority = 500;
  static const int xSquarePriority = -100;
  static const int centerBasePriority = 100;
  static const int centerDistanceMultiplier = 10;
}

const List<OthelloMove> _corners = [
  OthelloMove(0, 0),
  OthelloMove(0, othelloBoardSize - 1),
  OthelloMove(othelloBoardSize - 1, 0),
  OthelloMove(othelloBoardSize - 1, othelloBoardSize - 1),
];

const List<_CornerSquare> _xSquares = [
  _CornerSquare(OthelloMove(1, 1), OthelloMove(0, 0)),
  _CornerSquare(OthelloMove(1, 6), OthelloMove(0, 7)),
  _CornerSquare(OthelloMove(6, 1), OthelloMove(7, 0)),
  _CornerSquare(OthelloMove(6, 6), OthelloMove(7, 7)),
];

const List<_CornerSquare> _cSquares = [
  _CornerSquare(OthelloMove(0, 1), OthelloMove(0, 0)),
  _CornerSquare(OthelloMove(1, 0), OthelloMove(0, 0)),
  _CornerSquare(OthelloMove(0, 6), OthelloMove(0, 7)),
  _CornerSquare(OthelloMove(1, 7), OthelloMove(0, 7)),
  _CornerSquare(OthelloMove(6, 0), OthelloMove(7, 0)),
  _CornerSquare(OthelloMove(7, 1), OthelloMove(7, 0)),
  _CornerSquare(OthelloMove(7, 6), OthelloMove(7, 7)),
  _CornerSquare(OthelloMove(6, 7), OthelloMove(7, 7)),
];

class _CornerSquare {
  const _CornerSquare(this.position, this.corner);

  final OthelloMove position;
  final OthelloMove corner;
}

class OthelloSearchResult {
  const OthelloSearchResult({
    required this.move,
    required this.score,
    required this.completedDepth,
    required this.timedOut,
    required this.elapsedMilliseconds,
  });

  final OthelloMove move;
  final int score;

  /// 1 means the timeout interrupted depth 2 before any iteration completed.
  final int completedDepth;
  final bool timedOut;
  final int elapsedMilliseconds;
}

abstract interface class OthelloMoveEngine {
  Future<OthelloSearchResult?> bestMove(
    OthelloBoard board,
    OthelloSide player, {
    CancelToken? cancelToken,
  });
}

/// Search implementation matching the upstream Hard strategy.
///
/// [search] is exposed for deterministic fixture comparison. Production calls
/// [OthelloHardEngine.bestMove], which runs the same search in a worker isolate.
class OthelloHardSearch {
  const OthelloHardSearch({
    this.timeBudget = othelloHardSearchBudget,
    this.maxDepth = othelloHardSearchDepth,
  });

  final Duration timeBudget;
  final int maxDepth;

  OthelloSearchResult? search(
    OthelloBoard board,
    OthelloSide player, {
    int? deadlineMillisecondsSinceEpoch,
  }) {
    final watch = Stopwatch()..start();
    final validMoves = OthelloRules.getValidMoves(board, player);
    if (validMoves.isEmpty) return null;

    final orderedMoves = orderMovesByPreference(validMoves, board);
    var bestMove = orderedMoves.first.move;
    final deadline = deadlineMillisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch + timeBudget.inMilliseconds;
    var completedDepth = 1;
    var bestScore = 0;
    var timedOut = false;

    for (var depth = 2; depth <= maxDepth; depth++) {
      OthelloMove? depthBest;
      var depthBestScore = -double.infinity;
      try {
        for (final validMove in orderedMoves) {
          final nextBoard = OthelloRules.simulateMove(
            board,
            validMove.row,
            validMove.col,
            player,
          );
          final score = _minimax(
            nextBoard,
            depth - 1,
            double.negativeInfinity,
            double.infinity,
            false,
            player,
            deadline,
          );
          if (score > depthBestScore) {
            depthBestScore = score;
            depthBest = validMove.move;
          }
        }
      } on _SearchTimeout {
        timedOut = true;
        break;
      }
      if (depthBest != null) {
        bestMove = depthBest;
        bestScore = depthBestScore.toInt();
        completedDepth = depth;
      }
      if (DateTime.now().millisecondsSinceEpoch >= deadline) {
        timedOut = true;
        break;
      }
    }

    return OthelloSearchResult(
      move: bestMove,
      score: bestScore,
      completedDepth: completedDepth,
      timedOut: timedOut,
      elapsedMilliseconds: watch.elapsedMilliseconds,
    );
  }

  /// Stable descending priority sort preserves row-major order on ties,
  /// matching JavaScript's stable `Array.sort` in the upstream implementation.
  static List<OthelloValidMove> orderMovesByPreference(
    List<OthelloValidMove> moves,
    OthelloBoard board,
  ) {
    final indexed = moves.indexed.toList();
    indexed.sort((first, second) {
      final priorityComparison = _priority(second.$2.move, board)
          .compareTo(_priority(first.$2.move, board));
      return priorityComparison != 0
          ? priorityComparison
          : first.$1.compareTo(second.$1);
    });
    return indexed.map((entry) => entry.$2).toList(growable: false);
  }

  static int evaluateBoard(OthelloBoard board, OthelloSide player) {
    final opponent = player.opponent;
    var score = 0;

    for (final corner in _corners) {
      if (board[corner.row][corner.col] == player.value) {
        score += _OthelloAiConfig.cornerValue;
      } else if (board[corner.row][corner.col] == opponent.value) {
        score -= _OthelloAiConfig.cornerValue;
      }
    }

    for (final square in _xSquares) {
      if (board[square.corner.row][square.corner.col] == null) {
        if (board[square.position.row][square.position.col] == player.value) {
          score -= _OthelloAiConfig.xSquarePenalty;
        } else if (board[square.position.row][square.position.col] ==
            opponent.value) {
          score += _OthelloAiConfig.xSquarePenalty;
        }
      }
    }

    for (final square in _cSquares) {
      if (board[square.corner.row][square.corner.col] == null) {
        if (board[square.position.row][square.position.col] == player.value) {
          score -= _OthelloAiConfig.cSquarePenalty;
        } else if (board[square.position.row][square.position.col] ==
            opponent.value) {
          score += _OthelloAiConfig.cSquarePenalty;
        }
      }
    }

    for (var index = 2; index < othelloBoardSize - 2; index++) {
      score += _edgeScore(board[0][index], player, opponent);
      score += _edgeScore(board[othelloBoardSize - 1][index], player, opponent);
      score += _edgeScore(board[index][0], player, opponent);
      score += _edgeScore(board[index][othelloBoardSize - 1], player, opponent);
    }

    final playerMoves = OthelloRules.getValidMoves(board, player).length;
    final opponentMoves = OthelloRules.getValidMoves(board, opponent).length;
    score += (playerMoves - opponentMoves) * _OthelloAiConfig.mobilityWeight;

    final counts = OthelloRules.countDiscs(board);
    score += (counts.forSide(player) - counts.forSide(opponent)) *
        _OthelloAiConfig.discCountWeight;
    return score;
  }

  static int _edgeScore(int? cell, OthelloSide player, OthelloSide opponent) {
    if (cell == player.value) return _OthelloAiConfig.edgeValue;
    if (cell == opponent.value) return -_OthelloAiConfig.edgeValue;
    return 0;
  }

  static int _priority(OthelloMove move, OthelloBoard board) {
    if (_corners.contains(move)) return _OthelloAiConfig.cornerPriority;
    if (move.row == 0 ||
        move.row == othelloBoardSize - 1 ||
        move.col == 0 ||
        move.col == othelloBoardSize - 1) {
      return _OthelloAiConfig.edgePriority;
    }
    for (final square in _xSquares) {
      if (square.position == move &&
          board[square.corner.row][square.corner.col] == null) {
        return _OthelloAiConfig.xSquarePriority;
      }
    }
    final centerDistance = (move.row - othelloBoardSize ~/ 2).abs() +
        (move.col - othelloBoardSize ~/ 2).abs();
    return _OthelloAiConfig.centerBasePriority -
        centerDistance * _OthelloAiConfig.centerDistanceMultiplier;
  }

  static double _minimax(
    OthelloBoard board,
    int depth,
    double alpha,
    double beta,
    bool isMaximizing,
    OthelloSide aiPlayer,
    int deadline,
  ) {
    if (DateTime.now().millisecondsSinceEpoch > deadline) {
      throw const _SearchTimeout();
    }
    final opponent = aiPlayer.opponent;
    if (OthelloRules.isGameOver(board)) {
      final winner = OthelloRules.getWinner(board);
      if (winner == aiPlayer) {
        return _OthelloAiConfig.winScore + depth.toDouble();
      }
      if (winner == opponent) {
        return _OthelloAiConfig.lossScore - depth.toDouble();
      }
      return 0;
    }
    if (depth == 0) return evaluateBoard(board, aiPlayer).toDouble();

    final currentPlayer = isMaximizing ? aiPlayer : opponent;
    final validMoves = OthelloRules.getValidMoves(board, currentPlayer);
    if (validMoves.isEmpty) {
      return _minimax(
        board,
        depth - 1,
        alpha,
        beta,
        !isMaximizing,
        aiPlayer,
        deadline,
      );
    }

    final orderedMoves = orderMovesByPreference(validMoves, board);
    if (isMaximizing) {
      var maxScore = double.negativeInfinity;
      for (final move in orderedMoves) {
        final score = _minimax(
          OthelloRules.simulateMove(board, move.row, move.col, aiPlayer),
          depth - 1,
          alpha,
          beta,
          false,
          aiPlayer,
          deadline,
        );
        if (score > maxScore) maxScore = score;
        if (score > alpha) alpha = score;
        if (beta <= alpha) break;
      }
      return maxScore;
    }

    var minScore = double.infinity;
    for (final move in orderedMoves) {
      final score = _minimax(
        OthelloRules.simulateMove(board, move.row, move.col, opponent),
        depth - 1,
        alpha,
        beta,
        true,
        aiPlayer,
        deadline,
      );
      if (score < minScore) minScore = score;
      if (score < beta) beta = score;
      if (beta <= alpha) break;
    }
    return minScore;
  }
}

class _SearchTimeout implements Exception {
  const _SearchTimeout();
}

/// Runs Hard search off the UI isolate so the board and stop action stay live.
class OthelloHardEngine implements OthelloMoveEngine {
  const OthelloHardEngine({
    this.timeBudget = othelloHardSearchBudget,
    this.maxDepth = othelloHardSearchDepth,
  });

  final Duration timeBudget;
  final int maxDepth;

  @override
  Future<OthelloSearchResult?> bestMove(
    OthelloBoard board,
    OthelloSide player, {
    CancelToken? cancelToken,
  }) async {
    final validMoves = OthelloRules.getValidMoves(board, player);
    if (validMoves.isEmpty || cancelToken?.isCancelled == true) return null;
    final fallbackMove = OthelloHardSearch.orderMovesByPreference(
      validMoves,
      board,
    ).first.move;
    final resultPort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final completer = Completer<OthelloSearchResult?>();
    Isolate? isolate;
    Timer? watchdog;
    StreamSubscription<Object?>? resultSubscription;
    StreamSubscription<Object?>? errorSubscription;
    StreamSubscription<Object?>? exitSubscription;
    var completed = false;

    void finish(OthelloSearchResult? result) {
      if (completed) return;
      completed = true;
      watchdog?.cancel();
      resultSubscription?.cancel();
      errorSubscription?.cancel();
      exitSubscription?.cancel();
      resultPort.close();
      errorPort.close();
      exitPort.close();
      isolate?.kill(priority: Isolate.immediate);
      completer.complete(result);
    }

    final fallback = OthelloSearchResult(
      move: fallbackMove,
      score: 0,
      completedDepth: 1,
      timedOut: true,
      elapsedMilliseconds: timeBudget.inMilliseconds,
    );

    resultSubscription = resultPort.listen((message) {
      if (message is! List || message.length < 5) {
        finish(fallback);
        return;
      }
      finish(
        OthelloSearchResult(
          move: OthelloMove(message[0] as int, message[1] as int),
          score: message[2] as int,
          completedDepth: message[3] as int,
          timedOut: message[4] as bool,
          elapsedMilliseconds: message.length > 5 ? message[5] as int : 0,
        ),
      );
    });
    errorSubscription = errorPort.listen((_) => finish(fallback));
    exitSubscription = exitPort.listen((_) {
      if (!completed) finish(fallback);
    });
    cancelToken?.whenCancel.then((_) => finish(null));

    try {
      isolate = await Isolate.spawn<List<Object?>>(
        _runOthelloSearch,
        [
          resultPort.sendPort,
          _flattenBoard(board),
          player.value,
          timeBudget.inMilliseconds,
          maxDepth,
        ],
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
      );
      if (completed || cancelToken?.isCancelled == true) {
        isolate.kill(priority: Isolate.immediate);
        if (!completed) finish(null);
      } else {
        watchdog = Timer(
          timeBudget + const Duration(milliseconds: 100),
          () => finish(fallback),
        );
      }
    } on Object {
      finish(fallback);
    }
    return completer.future;
  }
}

List<int> _flattenBoard(OthelloBoard board) => [
      for (final row in board)
        for (final cell in row) cell ?? 0,
    ];

void _runOthelloSearch(List<Object?> arguments) {
  final replyPort = arguments[0] as SendPort;
  final flatBoard = arguments[1] as List<int>;
  final player = OthelloSide.fromValue(arguments[2] as int);
  final timeBudgetMilliseconds = arguments[3] as int;
  final maxDepth = arguments[4] as int;
  final board = List.generate(
    othelloBoardSize,
    (row) => List<int?>.generate(
      othelloBoardSize,
      (col) {
        final value = flatBoard[row * othelloBoardSize + col];
        return value == 0 ? null : value;
      },
    ),
  );
  final result = OthelloHardSearch(
    timeBudget: Duration(milliseconds: timeBudgetMilliseconds),
    maxDepth: maxDepth,
  ).search(
    board,
    player,
  );
  if (result == null) {
    replyPort.send(const []);
    return;
  }
  replyPort.send([
    result.move.row,
    result.move.col,
    result.score,
    result.completedDepth,
    result.timedOut,
    result.elapsedMilliseconds,
  ]);
}
