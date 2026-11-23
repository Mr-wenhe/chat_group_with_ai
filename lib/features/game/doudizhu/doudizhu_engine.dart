import 'doudizhu_difficulty.dart';
import 'doudizhu_move_generator.dart';
import 'doudizhu_rules.dart';

const int _freePlayBonus = 400;
const int _bombCost = 2500;
const int _topBonus = 400;
const int _teamPassBonus = 900;
const int _dangerPenalty = 2200;
const int _leadSoloPenalty = 1500;

class DoudizhuEngineContext {
  const DoudizhuEngineContext({
    required this.seat,
    required this.landlord,
    required this.handSizes,
    required this.playedCounts,
    required this.passCount,
    this.lastPlaySeat = -1,
  });

  final int seat;
  final int landlord;
  final List<int> handSizes;
  final List<int> playedCounts;
  final int passCount;
  final int lastPlaySeat;
}

class DoudizhuEngineResult {
  const DoudizhuEngineResult({
    required this.candidates,
    required this.handsBefore,
    required this.handsAfter,
    required this.candidateCount,
    required this.elapsedMilliseconds,
    this.forced = 'none',
    this.note,
  });

  final List<DoudizhuAiCandidate> candidates;
  final int handsBefore;
  final int handsAfter;
  final int candidateCount;
  final int elapsedMilliseconds;
  final String forced;
  final String? note;
}

/// Direct Dart port of js/ai/engine.js using only this seat's hand and public data.
class DoudizhuEngine {
  const DoudizhuEngine();

  DoudizhuEngineResult decide({
    required List<int> hand,
    required DoudizhuMove? lastPlay,
    required DoudizhuEngineContext context,
  }) {
    final stopwatch = Stopwatch()..start();
    final ownCounts = DoudizhuRules.countsOf(hand);
    final handsBefore = minDoudizhuHands(ownCounts);
    final leading = lastPlay == null;
    final moves = generateDoudizhuMoves(
      hand,
      lastPlay: lastPlay,
      wingChoices: doudizhuWingChoices,
    );
    final publicContext = DoudizhuEngineContext(
      seat: context.seat,
      landlord: context.landlord,
      handSizes: List.unmodifiable(context.handSizes),
      playedCounts: context.playedCounts.length == doudizhuRankCount
          ? List.unmodifiable(context.playedCounts)
          : List<int>.filled(doudizhuRankCount, 0),
      passCount: context.passCount,
      lastPlaySeat: context.lastPlaySeat,
    );

    if (handsBefore == 1 && moves.isNotEmpty) {
      for (final move in moves) {
        if (_countsEqual(DoudizhuRules.countsOf(move.cardIds), ownCounts)) {
          final forced = DoudizhuAiCandidate(
            cardIds: move.cardIds,
            score: doudizhuWinBase + doudizhuHandUnit,
            type: move.type.label,
            rank: move.rank,
            len: move.len,
            handsAfter: 0,
            bomb: move.isBombLike,
            endgame: doudizhuEndgame,
            remembered: false,
            forcedWin: true,
          );
          return _finish(
            [forced],
            1,
            0,
            1,
            stopwatch,
            forced: 'win',
          );
        }
      }
    }

    if (moves.isEmpty) {
      final pass = DoudizhuAiCandidate(
        cardIds: null,
        score: 0,
        type: '不出',
        rank: -1,
        len: 0,
        handsAfter: handsBefore,
      );
      return _finish(
        [pass],
        handsBefore,
        handsBefore,
        1,
        stopwatch,
        note: '无牌可压',
      );
    }

    final scored = <DoudizhuAiCandidate>[];
    for (final move in moves) {
      final afterCounts = _subtractCounts(ownCounts, move.cardIds);
      final handsAfter = minDoudizhuHands(afterCounts);
      var score = -handsAfter * doudizhuHandUnit;
      score -= _cardCost(move.cardIds);
      if (handsAfter <= handsBefore) score += _freePlayBonus;
      if (move.isBombLike) score -= _bombCost;
      if (leading &&
          doudizhuRemember &&
          _likelyUnbeatable(move, ownCounts, publicContext)) {
        score += _topBonus;
      }
      if (doudizhuEndgame) {
        score += _endgameAdjust(move, publicContext, leading);
      }
      scored.add(
        DoudizhuAiCandidate(
          cardIds: move.cardIds,
          score: score,
          type: move.type.label,
          rank: move.rank,
          len: move.len,
          handsAfter: handsAfter,
          bomb: move.isBombLike,
          endgame: doudizhuEndgame,
          remembered: doudizhuRemember &&
              _likelyUnbeatable(move, ownCounts, publicContext),
        ),
      );
    }

    // Linked insertion order matches JS Map: replacing a shape keeps its slot.
    final bestByShape = <String, DoudizhuAiCandidate>{};
    for (final candidate in scored) {
      final move = DoudizhuRules.classify(candidate.cardIds!);
      final key = move!.shapeKey;
      final previous = bestByShape[key];
      if (previous == null || candidate.score > previous.score) {
        bestByShape[key] = candidate;
      }
    }
    final candidates = bestByShape.values.toList();

    if (!leading) {
      final teammateLead = doudizhuTeamwork &&
          context.seat != context.landlord &&
          context.lastPlaySeat != context.landlord;
      var passScore = -handsBefore * doudizhuHandUnit;
      if (teammateLead) {
        passScore += _teamPassBonus;
      } else {
        final danger = _minOpponentSize(publicContext, context.seat);
        if (danger <= 2) {
          passScore -= _dangerPenalty;
        } else if (danger <= 4) {
          passScore -= _dangerPenalty ~/ 3;
        }
      }
      candidates.add(
        DoudizhuAiCandidate(
          cardIds: null,
          score: passScore,
          type: '不出',
          rank: -1,
          len: 0,
          handsAfter: handsBefore,
          teammatePass: teammateLead,
        ),
      );
    }

    final after = candidates
        .map((candidate) => candidate.handsAfter)
        .fold<int>(1 << 30, (best, value) => value < best ? value : best);
    return _finish(
      candidates,
      handsBefore,
      after,
      candidates.length,
      stopwatch,
    );
  }

  DoudizhuAiCandidate? bestMove({
    required List<int> hand,
    required DoudizhuMove? lastPlay,
    required DoudizhuEngineContext context,
  }) {
    final result = decide(hand: hand, lastPlay: lastPlay, context: context);
    return pickDoudizhuMove(result.candidates)?.candidate;
  }
}

DoudizhuEngineResult _finish(
  List<DoudizhuAiCandidate> candidates,
  int handsBefore,
  int handsAfter,
  int candidateCount,
  Stopwatch stopwatch, {
  String forced = 'none',
  String? note,
}) =>
    DoudizhuEngineResult(
      candidates: List.unmodifiable(candidates),
      handsBefore: handsBefore,
      handsAfter: handsAfter,
      candidateCount: candidateCount,
      elapsedMilliseconds: stopwatch.elapsedMilliseconds,
      forced: forced,
      note: note,
    );

bool _countsEqual(List<int> first, List<int> second) {
  for (var rank = 0; rank < doudizhuRankCount; rank++) {
    if (first[rank] != second[rank]) return false;
  }
  return true;
}

List<int> _subtractCounts(List<int> counts, List<int> cards) {
  final result = counts.toList();
  for (final card in cards) {
    result[DoudizhuRules.rankOf(card)]--;
  }
  return result;
}

int _cardCost(List<int> cards) => cards.fold<int>(
      0,
      (sum, card) => sum + (DoudizhuRules.rankOf(card) + 1) * 8,
    );

List<int> _opponentsOf(int seat, int landlord) {
  if (seat == landlord) {
    return [
      for (var other = 0; other < 3; other++)
        if (other != seat) other
    ];
  }
  return [landlord];
}

int _minOpponentSize(DoudizhuEngineContext context, int seat) {
  final opponents = _opponentsOf(seat, context.landlord);
  return opponents
      .map((opponent) => context.handSizes[opponent])
      .fold<int>(1 << 30, (best, value) => value < best ? value : best);
}

List<int> _remainingForOpponents(
  List<int> ownCounts,
  DoudizhuEngineContext context,
) =>
    List<int>.generate(
      doudizhuRankCount,
      (rank) {
        final remaining = doudizhuTotalOfRank[rank] -
            context.playedCounts[rank] -
            ownCounts[rank];
        return remaining > 0 ? remaining : 0;
      },
    );

bool _likelyUnbeatable(
  DoudizhuMove move,
  List<int> ownCounts,
  DoudizhuEngineContext context,
) {
  final remaining = _remainingForOpponents(ownCounts, context);
  final rocketPossible = remaining[13] >= 1 && remaining[14] >= 1;
  if (move.type == DoudizhuCardType.rocket) return true;
  if (move.type == DoudizhuCardType.bomb) {
    if (rocketPossible) return false;
    for (var rank = move.rank + 1; rank < doudizhuRankCount; rank++) {
      if (remaining[rank] >= 4) return false;
    }
    return true;
  }
  if (rocketPossible) return false;
  for (final count in remaining) {
    if (count >= 4) return false;
  }
  final unit = switch (move.type) {
    DoudizhuCardType.solo => 1,
    DoudizhuCardType.pair => 2,
    DoudizhuCardType.trio => 3,
    _ => 0,
  };
  if (unit == 0) return false;
  for (var rank = move.rank + 1; rank < doudizhuRankCount; rank++) {
    if (remaining[rank] >= unit) return false;
  }
  return true;
}

int _endgameAdjust(
  DoudizhuMove move,
  DoudizhuEngineContext context,
  bool leading,
) {
  final opponents = _minOpponentSize(context, context.seat);
  if (!leading || opponents > 1) return 0;
  if (move.type == DoudizhuCardType.solo) {
    return -_leadSoloPenalty + move.rank * 30;
  }
  return 300;
}
