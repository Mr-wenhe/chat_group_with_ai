/// 斗地主牌面、14 种牌型和真人/模型共用的合法出牌校验。
///
/// 卡牌 ID 与 justa-cai/doudizhu 的 rules.js 相同：0..51 是四种花色的
/// 3..2，52 是小王，53 是大王。规则比较只看点数；提交时仍核验实体 ID。
library;

const int doudizhuRankCount = 15;
const int doudizhuDeckSize = 54;
const int doudizhuMaxChainRank = 11;
const List<String> doudizhuRankNames = [
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  '10',
  'J',
  'Q',
  'K',
  'A',
  '2',
  '小王',
  '大王',
];
const List<String> doudizhuSuitSymbols = ['♠', '♥', '♣', '♦'];
const List<int> doudizhuTotalOfRank = [
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  1,
  1,
];

enum DoudizhuCardType {
  solo('solo', '单张'),
  pair('pair', '对子'),
  trio('trio', '三张'),
  trioSolo('trio_solo', '三带一'),
  trioPair('trio_pair', '三带二'),
  straight('straight', '顺子'),
  pairStraight('pair_straight', '连对'),
  plane('plane', '飞机'),
  planeSolo('plane_solo', '飞机带单'),
  planePair('plane_pair', '飞机带对'),
  fourSolo('four_solo', '四带二'),
  fourPair('four_pair', '四带两对'),
  bomb('bomb', '炸弹'),
  rocket('rocket', '火箭');

  const DoudizhuCardType(this.key, this.label);
  final String key;
  final String label;

  static DoudizhuCardType? fromKey(String key) {
    for (final type in values) {
      if (type.key == key) return type;
    }
    return null;
  }
}

class DoudizhuMove {
  DoudizhuMove({
    required List<int> cardIds,
    required this.type,
    required this.rank,
    required this.len,
  }) : cardIds = List.unmodifiable(cardIds);

  final List<int> cardIds;
  final DoudizhuCardType type;
  final int rank;
  final int len;

  String get shapeKey =>
      '${type.key}|$rank|$len';
  bool get isBombLike =>
      type == DoudizhuCardType.bomb || type == DoudizhuCardType.rocket;
}

class DoudizhuPlayValidation {
  const DoudizhuPlayValidation._(this.move, this.reason);

  const DoudizhuPlayValidation.valid(DoudizhuMove move) : this._(move, null);

  const DoudizhuPlayValidation.invalid(String reason) : this._(null, reason);

  final DoudizhuMove? move;
  final String? reason;
  bool get isValid => move != null;
}

class DoudizhuRules {
  const DoudizhuRules._();

  static int rankOf(int cardId) {
    if (cardId < 0 || cardId >= doudizhuDeckSize) {
      throw RangeError.range(cardId, 0, doudizhuDeckSize - 1, 'cardId');
    }
    if (cardId < 52) return cardId >> 2;
    return cardId == 52 ? 13 : 14;
  }

  static int suitOf(int cardId) {
    if (cardId < 0 || cardId >= doudizhuDeckSize) {
      throw RangeError.range(cardId, 0, doudizhuDeckSize - 1, 'cardId');
    }
    return cardId < 52 ? cardId & 3 : -1;
  }

  static String cardLabel(int cardId) => doudizhuRankNames[rankOf(cardId)];

  static String compactCard(int cardId) {
    final suit = suitOf(cardId);
    return suit < 0
        ? (cardId == 52 ? '小王' : '大王')
        : cardLabel(cardId) + doudizhuSuitSymbols[suit];
  }

  static List<int> countsOf(Iterable<int> cards) {
    final counts = List<int>.filled(doudizhuRankCount, 0);
    for (final card in cards) {
      counts[rankOf(card)]++;
    }
    return counts;
  }

  static String countsLabel(List<int> counts) {
    final parts = <String>[];
    for (var rank = doudizhuRankCount - 1; rank >= 0; rank--) {
      final count = counts[rank];
      if (count == 0) continue;
      parts.add(count > 1
          ? '${doudizhuRankNames[rank]}×$count'
          : doudizhuRankNames[rank]);
    }
    return parts.isEmpty ? '—' : parts.join(' ');
  }

  static String cardsLabel(Iterable<int> cards) => countsLabel(countsOf(cards));

  static List<int> sortHand(Iterable<int> hand) {
    final sorted = hand.toList();
    sorted.sort((a, b) {
      final rankOrder = rankOf(b).compareTo(rankOf(a));
      return rankOrder != 0 ? rankOrder : a.compareTo(b);
    });
    return sorted;
  }

  static DoudizhuMove? classify(Iterable<int> cards) {
    final ids = cards.toList(growable: false);
    if (ids.isEmpty) return null;
    final counts = countsOf(ids);
    final byCount = List.generate(5, (_) => <int>[]);
    var maxRank = -1;
    for (var rank = 0; rank < counts.length; rank++) {
      if (counts[rank] > 4) return null;
      if (counts[rank] > 0) byCount[counts[rank]].add(rank);
      if (counts[rank] > 0) maxRank = rank;
    }
    final size = ids.length;

    if (size == 2 && counts[13] == 1 && counts[14] == 1) {
      return _move(ids, DoudizhuCardType.rocket, 14, 1);
    }
    if (size == 4 && byCount[4].length == 1) {
      return _move(ids, DoudizhuCardType.bomb, byCount[4].single, 1);
    }
    if (size == 1) return _move(ids, DoudizhuCardType.solo, maxRank, 1);
    if (size == 2 && byCount[2].length == 1) {
      return _move(ids, DoudizhuCardType.pair, byCount[2].single, 1);
    }
    if (size == 3 && byCount[3].length == 1) {
      return _move(ids, DoudizhuCardType.trio, byCount[3].single, 1);
    }
    if (size >= 5 &&
        byCount[1].length == size &&
        maxRank <= doudizhuMaxChainRank &&
        _isConsecutive(byCount[1])) {
      return _move(ids, DoudizhuCardType.straight, maxRank, size);
    }
    if (size >= 6 &&
        size.isEven &&
        byCount[2].length * 2 == size &&
        maxRank <= doudizhuMaxChainRank &&
        _isConsecutive(byCount[2])) {
      return _move(
        ids,
        DoudizhuCardType.pairStraight,
        maxRank,
        byCount[2].length,
      );
    }
    if (size == 4 && byCount[3].length == 1 && byCount[1].length == 1) {
      return _move(ids, DoudizhuCardType.trioSolo, byCount[3].single, 1);
    }
    if (size == 5 && byCount[3].length == 1 && byCount[2].length == 1) {
      return _move(ids, DoudizhuCardType.trioPair, byCount[3].single, 1);
    }

    if (byCount[3].length >= 2) {
      final trios = byCount[3];
      var lo = 0;
      while (lo < trios.length) {
        var hi = lo;
        while (hi + 1 < trios.length && trios[hi + 1] == trios[hi] + 1) {
          hi++;
        }
        final run = trios.sublist(lo, hi + 1);
        if (run.length >= 2 && run.last <= doudizhuMaxChainRank) {
          final plane = _classifyPlane(counts, size, run, ids);
          if (plane != null) return plane;
        }
        lo = hi + 1;
      }
    }

    if (size == 6 && byCount[4].length == 1) {
      if (!(counts[13] == 1 && counts[14] == 1)) {
        return _move(ids, DoudizhuCardType.fourSolo, byCount[4].single, 1);
      }
    }
    if (size == 8 && byCount[4].length == 1 && byCount[2].length == 2) {
      return _move(ids, DoudizhuCardType.fourPair, byCount[4].single, 1);
    }
    return null;
  }

  static bool beats(DoudizhuMove? challenger, DoudizhuMove? target) {
    if (challenger == null || target == null) return false;
    if (target.type == DoudizhuCardType.rocket) return false;
    if (challenger.type == DoudizhuCardType.rocket) return true;
    if (challenger.type == DoudizhuCardType.bomb) {
      return target.type != DoudizhuCardType.bomb ||
          challenger.rank > target.rank;
    }
    if (target.type == DoudizhuCardType.bomb) return false;
    return challenger.type == target.type &&
        challenger.len == target.len &&
        challenger.rank > target.rank;
  }

  /// Legal action validation is independent of the bounded AI candidate list.
  static DoudizhuPlayValidation validatePlay({
    required List<int> hand,
    required List<int> cardIds,
    DoudizhuMove? lastPlay,
  }) {
    if (cardIds.isEmpty) {
      return const DoudizhuPlayValidation.invalid('请选择要出的牌');
    }
    if (cardIds.toSet().length != cardIds.length) {
      return const DoudizhuPlayValidation.invalid('选牌包含重复实体牌');
    }
    for (final card in cardIds) {
      if (card < 0 || card >= doudizhuDeckSize) {
        return const DoudizhuPlayValidation.invalid('选牌 ID 越界');
      }
    }
    final handIds = hand.toSet();
    if (handIds.length != hand.length) {
      return const DoudizhuPlayValidation.invalid('当前手牌含重复实体牌');
    }
    if (cardIds.any((card) => !handIds.contains(card))) {
      return const DoudizhuPlayValidation.invalid('选牌不在当前手牌中');
    }
    final move = classify(cardIds);
    if (move == null) {
      return const DoudizhuPlayValidation.invalid('不构成合法牌型');
    }
    if (lastPlay != null && !beats(move, lastPlay)) {
      return DoudizhuPlayValidation.invalid(
        '压不过上家的${lastPlay.type.label}',
      );
    }
    return DoudizhuPlayValidation.valid(move);
  }

  static DoudizhuMove _move(
    List<int> ids,
    DoudizhuCardType type,
    int rank,
    int len,
  ) =>
      DoudizhuMove(cardIds: ids, type: type, rank: rank, len: len);

  static DoudizhuMove? _classifyPlane(
    List<int> counts,
    int size,
    List<int> run,
    List<int> ids,
  ) {
    final groups = run.length;
    final rest = size - 3 * groups;
    if (rest == 0) {
      return _move(ids, DoudizhuCardType.plane, run.last, groups);
    }
    final bodyRanks = run.toSet();
    final restCounts = List<int>.generate(
      doudizhuRankCount,
      (rank) => counts[rank] - (bodyRanks.contains(rank) ? 3 : 0),
    );
    if (rest == groups && restCounts.every((count) => count <= 2)) {
      return _move(ids, DoudizhuCardType.planeSolo, run.last, groups);
    }
    if (rest == groups * 2 &&
        restCounts.every((count) => count == 0 || count == 2)) {
      return _move(ids, DoudizhuCardType.planePair, run.last, groups);
    }
    return null;
  }

  static bool _isConsecutive(List<int> ranks) {
    for (var index = 1; index < ranks.length; index++) {
      if (ranks[index] != ranks[index - 1] + 1) return false;
    }
    return true;
  }
}
