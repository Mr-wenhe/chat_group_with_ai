import 'package:dio/dio.dart' show CancelToken;

import 'ai_othello_player.dart';
import 'othello_hard_engine.dart';
import 'othello_types.dart';

enum OthelloDecisionSource { characterModel, hardFallback }

class OthelloMoveDecision {
  const OthelloMoveDecision({
    required this.move,
    required this.reason,
    required this.source,
    required this.modelAttempts,
    this.fallbackNote,
    this.completedSearchDepth = 0,
    this.searchTimedOut = false,
  });

  final OthelloMove move;
  final String reason;
  final OthelloDecisionSource source;
  final int modelAttempts;
  final String? fallbackNote;
  final int completedSearchDepth;
  final bool searchTimedOut;
}

/// Model-first seat. A valid model move is accepted as-is; Hard only runs after
/// an unavailable/failed/invalid model decision and retains the same side.
class CharacterOthelloPlayer {
  const CharacterOthelloPlayer({
    required this.primary,
    required this.fallback,
  });

  final AiOthelloPlayer primary;
  final OthelloMoveEngine fallback;

  Future<OthelloMoveDecision?> decideMove({
    required OthelloBoard board,
    required OthelloSide side,
    required List<OthelloValidMove> legalMoves,
    CancelToken? cancelToken,
  }) async {
    if (legalMoves.isEmpty || cancelToken?.isCancelled == true) return null;

    final modelDecision = await primary.decideMove(
      board: board,
      mySide: side,
      legalMoves: legalMoves,
      cancelToken: cancelToken,
    );
    if (modelDecision.wasCancelled || cancelToken?.isCancelled == true) {
      return null;
    }
    final modelMove = modelDecision.move;
    if (modelDecision.isSuccess &&
        modelMove != null &&
        legalMoves.any((candidate) => candidate.move == modelMove)) {
      return OthelloMoveDecision(
        move: modelMove,
        reason: modelDecision.reason,
        source: OthelloDecisionSource.characterModel,
        modelAttempts: modelDecision.attempts,
      );
    }

    final hardResult = await fallback.bestMove(
      board,
      side,
      cancelToken: cancelToken,
    );
    if (hardResult == null || cancelToken?.isCancelled == true) return null;
    final selectedMove = hardResult.move;
    final selectedLegalMove = legalMoves.where(
      (candidate) => candidate.move == selectedMove,
    );
    if (selectedLegalMove.isEmpty) return null;

    final flips = selectedLegalMove.first.flipsCount;
    return OthelloMoveDecision(
      move: selectedMove,
      reason: '${selectedMove.toCoordinate()} 是合法落点，可翻转 $flips 枚棋子。',
      source: OthelloDecisionSource.hardFallback,
      modelAttempts: modelDecision.attempts,
      fallbackNote: _fallbackNote(modelDecision.failure),
      completedSearchDepth: hardResult.completedDepth,
      searchTimedOut: hardResult.timedOut,
    );
  }

  String _fallbackNote(OthelloModelFailure? failure) => switch (failure) {
        OthelloModelFailure.unavailable => '模型配置或凭据不可用',
        OthelloModelFailure.request => '模型请求失败或超时',
        OthelloModelFailure.empty => '模型回复为空',
        OthelloModelFailure.format => '模型回复格式错误',
        OthelloModelFailure.illegalMove => '模型返回非法落点',
        OthelloModelFailure.cancelled => '模型请求已取消',
        null => '模型未返回有效落点',
      };
}
