import 'doudizhu_rules.dart';

const int doudizhuDefaultHandNodeBudget = 20000;
const int doudizhuDefaultMaxMoves = 240;

/// Port of rules.js generateMoves. This bounded list is for AI decisions only;
/// [DoudizhuRules.validatePlay] independently accepts every legal entity-card set.
List<DoudizhuMove> generateDoudizhuMoves(
  List<int> hand, {
  DoudizhuMove? lastPlay,
  int wingChoices = 1,
  int maxMoves = doudizhuDefaultMaxMoves,
}) {
  final choiceLimit = wingChoices < 1 ? 1 : wingChoices;
  final moveLimit = maxMoves < 1 ? doudizhuDefaultMaxMoves : maxMoves;
  final available = DoudizhuRules.countsOf(hand);
  final ids = _idsByRank(hand);
  final output = <DoudizhuMove>[];
  final seen = <String>{};

  void push(List<int> cards) {
    if (output.length >= moveLimit) return;
    final move = DoudizhuRules.classify(cards);
    if (move == null ||
        (lastPlay != null && !DoudizhuRules.beats(move, lastPlay))) {
      return;
    }
    final keyCards = cards.toList()..sort();
    final key = keyCards.join(',');
    if (seen.add(key)) output.add(move);
  }

  if (available[13] >= 1 && available[14] >= 1) {
    push([ids[13].first, ids[14].first]);
  }
  for (var rank = 0; rank < doudizhuRankCount; rank++) {
    if (available[rank] == 4) push(ids[rank].take(4).toList());
  }
  for (var rank = 0; rank < doudizhuRankCount; rank++) {
    if (available[rank] >= 1) push([ids[rank][0]]);
    if (available[rank] >= 2) push(ids[rank].take(2).toList());
    if (available[rank] >= 3) push(ids[rank].take(3).toList());
  }

  for (var trioRank = 0; trioRank < doudizhuRankCount; trioRank++) {
    if (available[trioRank] < 3) continue;
    final body = ids[trioRank].take(3).toList();
    final excluded = {trioRank};
    for (var variant = 0; variant < choiceLimit; variant++) {
      final singleWings = _wingRanks(available, excluded, 1, 1, variant);
      if (singleWings != null) {
        push([...body, ..._cardsFor(ids, singleWings, 1)]);
      }
      final pairWings = _wingRanks(available, excluded, 1, 2, variant);
      if (pairWings != null) {
        push([...body, ..._cardsFor(ids, pairWings, 2)]);
      }
    }
  }

  for (var start = 0; start <= doudizhuMaxChainRank - 4; start++) {
    var run = 0;
    while (start + run <= doudizhuMaxChainRank && available[start + run] >= 1) {
      run++;
    }
    for (var length = 5; length <= run; length++) {
      push(_cardsFor(ids, _range(start, length), 1));
    }
  }
  for (var start = 0; start <= doudizhuMaxChainRank - 2; start++) {
    var run = 0;
    while (start + run <= doudizhuMaxChainRank && available[start + run] >= 2) {
      run++;
    }
    for (var length = 3; length <= run; length++) {
      push(_cardsFor(ids, _range(start, length), 2));
    }
  }
  for (var start = 0; start <= doudizhuMaxChainRank - 1; start++) {
    var run = 0;
    while (start + run <= doudizhuMaxChainRank && available[start + run] >= 3) {
      run++;
    }
    if (run < 2) continue;
    for (var length = 2; length <= run; length++) {
      final bodyRanks = _range(start, length);
      final body = _cardsFor(ids, bodyRanks, 3);
      push(body);
      final excluded = bodyRanks.toSet();
      final spare = available.toList();
      for (final rank in bodyRanks) {
        spare[rank] -= 3;
      }
      for (var variant = 0; variant < choiceLimit; variant++) {
        final singles = _wingRanks(spare, excluded, length, 1, variant);
        if (singles != null) {
          push([...body, ..._cardsFor(ids, singles, 1)]);
        }
        final pairs = _wingRanks(spare, excluded, length, 2, variant);
        if (pairs != null) {
          push([...body, ..._cardsFor(ids, pairs, 2)]);
        }
      }
    }
  }

  for (var rank = 0; rank < doudizhuRankCount; rank++) {
    if (available[rank] != 4) continue;
    final body = ids[rank].take(4).toList();
    final excluded = {rank};
    final singles = _wingRanks(available, excluded, 2, 1, 0);
    if (singles != null) push([...body, ..._cardsFor(ids, singles, 1)]);
    final pairs = _wingRanks(available, excluded, 2, 2, 0);
    if (pairs != null) push([...body, ..._cardsFor(ids, pairs, 2)]);
  }
  return output;
}

/// Finds an actual response even when the AI's wing or move cap omitted it.
/// It only runs when bounded generation returned no move, and visits rank-count
/// combinations of the target size instead of treating a candidate count as proof.
DoudizhuMove? findAnyLegalDoudizhuResponse(
  List<int> hand,
  DoudizhuMove lastPlay,
) {
  final byRank = _idsByRank(hand);
  final available = List<int>.generate(
    doudizhuRankCount,
    (rank) => byRank[rank].length,
  );
  if (available[13] > 0 && available[14] > 0) {
    final rocket = DoudizhuRules.classify([byRank[13].first, byRank[14].first]);
    if (DoudizhuRules.beats(rocket, lastPlay)) return rocket;
  }
  for (var rank = lastPlay.rank + 1; rank < doudizhuRankCount; rank++) {
    if (available[rank] == 4) {
      final bomb = DoudizhuRules.classify(byRank[rank].take(4));
      if (DoudizhuRules.beats(bomb, lastPlay)) return bomb;
    }
  }

  final targetSize = switch (lastPlay.type) {
    DoudizhuCardType.solo => 1,
    DoudizhuCardType.pair => 2,
    DoudizhuCardType.trio => 3,
    DoudizhuCardType.trioSolo => 4,
    DoudizhuCardType.trioPair => 5,
    DoudizhuCardType.straight => lastPlay.len,
    DoudizhuCardType.pairStraight => lastPlay.len * 2,
    DoudizhuCardType.plane => lastPlay.len * 3,
    DoudizhuCardType.planeSolo => lastPlay.len * 4,
    DoudizhuCardType.planePair => lastPlay.len * 5,
    DoudizhuCardType.fourSolo => 6,
    DoudizhuCardType.fourPair => 8,
    DoudizhuCardType.bomb => 4,
    DoudizhuCardType.rocket => 2,
  };
  if (targetSize > hand.length) return null;
  final chosen = List<int>.filled(doudizhuRankCount, 0);
  DoudizhuMove? found;

  bool visit(int rank, int remaining) {
    if (remaining == 0) {
      final cards = <int>[];
      for (var index = 0; index < chosen.length; index++) {
        cards.addAll(byRank[index].take(chosen[index]));
      }
      final move = DoudizhuRules.classify(cards);
      if (DoudizhuRules.beats(move, lastPlay)) {
        found = move;
        return true;
      }
      return false;
    }
    if (rank == doudizhuRankCount) return false;
    final maxHere = available[rank] < remaining ? available[rank] : remaining;
    for (var count = 0; count <= maxHere; count++) {
      chosen[rank] = count;
      if (visit(rank + 1, remaining - count)) return true;
    }
    chosen[rank] = 0;
    return false;
  }

  visit(0, targetSize);
  return found;
}

int minDoudizhuHands(
  List<int> counts, {
  int nodeBudget = doudizhuDefaultHandNodeBudget,
}) {
  if (counts.length != doudizhuRankCount) {
    throw ArgumentError.value(counts.length, 'counts.length');
  }
  final working = counts.toList();
  final memo = <String, int>{};
  var nodes = 0;
  final limit = nodeBudget < 1 ? doudizhuDefaultHandNodeBudget : nodeBudget;

  int search() {
    if (working.every((count) => count == 0)) return 0;
    final key = working.join(',');
    final cached = memo[key];
    if (cached != null) return cached;
    nodes++;
    var best = _restHands(working);

    if (nodes <= limit) {
      for (var start = 0; start <= doudizhuMaxChainRank - 4; start++) {
        var run = 0;
        while (
            start + run <= doudizhuMaxChainRank && working[start + run] >= 1) {
          run++;
        }
        for (var length = 5; length <= run; length++) {
          for (var index = 0; index < length; index++) {
            working[start + index]--;
          }
          final score = 1 + search();
          for (var index = 0; index < length; index++) {
            working[start + index]++;
          }
          if (score < best) best = score;
          if (nodes > limit) break;
        }
        if (nodes > limit) break;
      }
    }
    if (nodes <= limit) {
      for (var start = 0; start <= doudizhuMaxChainRank - 2; start++) {
        var run = 0;
        while (
            start + run <= doudizhuMaxChainRank && working[start + run] >= 2) {
          run++;
        }
        for (var length = 3; length <= run; length++) {
          for (var index = 0; index < length; index++) {
            working[start + index] -= 2;
          }
          final score = 1 + search();
          for (var index = 0; index < length; index++) {
            working[start + index] += 2;
          }
          if (score < best) best = score;
          if (nodes > limit) break;
        }
        if (nodes > limit) break;
      }
    }
    if (nodes <= limit) {
      for (var start = 0; start <= doudizhuMaxChainRank - 1; start++) {
        var run = 0;
        while (
            start + run <= doudizhuMaxChainRank && working[start + run] >= 3) {
          run++;
        }
        if (run < 2) continue;
        for (var length = 2; length <= run; length++) {
          final bodyRanks = _range(start, length);
          for (final rank in bodyRanks) {
            working[rank] -= 3;
          }
          final bareScore = 1 + search();
          for (final rank in bodyRanks) {
            working[rank] += 3;
          }
          if (bareScore < best) best = bareScore;

          for (final unit in [1, 2]) {
            final wings = _smallestWings(working, bodyRanks, length, unit);
            if (wings == null) continue;
            _applyWings(working, wings, -1);
            for (final rank in bodyRanks) {
              working[rank] -= 3;
            }
            final wingScore = 1 + search();
            for (final rank in bodyRanks) {
              working[rank] += 3;
            }
            _applyWings(working, wings, 1);
            if (wingScore < best) best = wingScore;
          }
          if (nodes > limit) break;
        }
        if (nodes > limit) break;
      }
    }
    memo[key] = best;
    return best;
  }

  return search();
}

final Map<int, int> _restDpMemo = <int, int>{};

int _dpRest(int singles, int pairs, int trios, int bombs) {
  if (singles < 0 || pairs < 0 || trios < 0 || bombs < 0) return 1 << 28;
  if (singles == 0 && pairs == 0 && trios == 0 && bombs == 0) return 0;
  final key = ((singles * 64 + pairs) * 64 + trios) * 64 + bombs;
  final cached = _restDpMemo[key];
  if (cached != null) return cached;
  var best = 1 << 28;
  if (singles > 0) {
    best = _min(best, 1 + _dpRest(singles - 1, pairs, trios, bombs));
  }
  if (pairs > 0) {
    best = _min(best, 1 + _dpRest(singles, pairs - 1, trios, bombs));
  }
  if (trios > 0) {
    best = _min(best, 1 + _dpRest(singles, pairs, trios - 1, bombs));
  }
  if (bombs > 0) {
    best = _min(best, 1 + _dpRest(singles, pairs, trios, bombs - 1));
  }
  if (trios > 0 && singles > 0) {
    best = _min(best, 1 + _dpRest(singles - 1, pairs, trios - 1, bombs));
  }
  if (trios > 0 && pairs > 0) {
    best = _min(best, 1 + _dpRest(singles, pairs - 1, trios - 1, bombs));
  }
  if (bombs > 0 && singles >= 2) {
    best = _min(best, 1 + _dpRest(singles - 2, pairs, trios, bombs - 1));
  }
  if (bombs > 0 && pairs >= 2) {
    best = _min(best, 1 + _dpRest(singles, pairs - 2, trios, bombs - 1));
  }
  if (bombs > 0) {
    best = _min(best, _dpRest(singles + 1, pairs, trios + 1, bombs - 1));
  }
  if (bombs > 0) {
    best = _min(best, _dpRest(singles, pairs + 2, trios, bombs - 1));
  }
  if (trios > 0) {
    best = _min(best, _dpRest(singles + 1, pairs + 1, trios - 1, bombs));
  }
  if (trios > 0) {
    best = _min(best, _dpRest(singles + 3, pairs, trios - 1, bombs));
  }
  if (pairs > 0) {
    best = _min(best, _dpRest(singles + 2, pairs - 1, trios, bombs));
  }
  _restDpMemo[key] = best;
  return best;
}

int _restHands(List<int> counts) {
  var singles = 0;
  var pairs = 0;
  var trios = 0;
  var bombs = 0;
  for (var rank = 0; rank < 13; rank++) {
    switch (counts[rank]) {
      case 1:
        singles++;
        break;
      case 2:
        pairs++;
        break;
      case 3:
        trios++;
        break;
      case 4:
        bombs++;
        break;
    }
  }
  final jokers = (counts[13] > 0 ? 1 : 0) + (counts[14] > 0 ? 1 : 0);
  if (jokers == 2) {
    return _min(
      1 + _dpRest(singles, pairs, trios, bombs),
      _dpRest(singles + 2, pairs, trios, bombs),
    );
  }
  return _dpRest(singles + jokers, pairs, trios, bombs);
}

int _min(int first, int second) => first < second ? first : second;

List<List<int>> _idsByRank(List<int> hand) {
  final ids = List.generate(doudizhuRankCount, (_) => <int>[]);
  for (final card in hand) {
    ids[DoudizhuRules.rankOf(card)].add(card);
  }
  return ids;
}

List<int> _range(int start, int length) =>
    List<int>.generate(length, (index) => start + index);

List<int> _cardsFor(List<List<int>> ids, List<int> ranks, int unit) {
  final cards = <int>[];
  for (final rank in ranks) {
    cards.addAll(ids[rank].take(unit));
  }
  return cards;
}

List<int>? _wingRanks(
  List<int> available,
  Set<int> excluded,
  int count,
  int unit,
  int variant,
) {
  final candidates = <int>[
    for (var rank = 0; rank < doudizhuRankCount; rank++)
      if (!excluded.contains(rank) && available[rank] >= unit) rank,
  ];
  candidates.sort((a, b) {
    final aGroup = available[a] == unit ? 0 : 1;
    final bGroup = available[b] == unit ? 0 : 1;
    final groupOrder = aGroup.compareTo(bGroup);
    return groupOrder != 0 ? groupOrder : a.compareTo(b);
  });
  if (candidates.length - variant < count) return null;
  return candidates.skip(variant).take(count).toList();
}

class _Wings {
  const _Wings(this.ranks, this.unit);
  final List<int> ranks;
  final int unit;
}

_Wings? _smallestWings(
  List<int> counts,
  List<int> bodyRanks,
  int count,
  int unit,
) {
  final excluded = bodyRanks.toSet();
  final ranks = <int>[
    for (var rank = 0; rank < doudizhuRankCount; rank++)
      if (!excluded.contains(rank) && counts[rank] >= unit) rank,
  ];
  if (ranks.length < count) return null;
  return _Wings(ranks.take(count).toList(), unit);
}

void _applyWings(List<int> counts, _Wings wings, int delta) {
  for (final rank in wings.ranks) {
    counts[rank] += delta * wings.unit;
  }
}
