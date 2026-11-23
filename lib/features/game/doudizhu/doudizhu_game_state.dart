import 'dart:math' as math;

import 'doudizhu_rules.dart';

enum DoudizhuPhase { bidding, playing, over }

enum DoudizhuLogKind { bid, play, pass }

sealed class DoudizhuAction {
  const DoudizhuAction();
}

final class DoudizhuBidAction extends DoudizhuAction {
  const DoudizhuBidAction(this.score);
  final int score;
}

final class DoudizhuPlayAction extends DoudizhuAction {
  DoudizhuPlayAction(Iterable<int> cardIds)
      : cardIds = List.unmodifiable(cardIds);
  final List<int> cardIds;
}

final class DoudizhuPassAction extends DoudizhuAction {
  const DoudizhuPassAction();
}

class DoudizhuTrick {
  const DoudizhuTrick({required this.seat, required this.move});
  final int seat;
  final DoudizhuMove move;
}

class DoudizhuGameLogEntry {
  DoudizhuGameLogEntry.bid({required this.seat, required this.score})
      : kind = DoudizhuLogKind.bid,
        cardIds = const [],
        type = null;

  DoudizhuGameLogEntry.play({
    required this.seat,
    required Iterable<int> cardIds,
    required this.type,
  })  : kind = DoudizhuLogKind.play,
        score = null,
        cardIds = List.unmodifiable(cardIds);

  DoudizhuGameLogEntry.pass({required this.seat})
      : kind = DoudizhuLogKind.pass,
        score = null,
        cardIds = const [],
        type = null;

  final DoudizhuLogKind kind;
  final int seat;
  final int? score;
  final List<int> cardIds;
  final DoudizhuCardType? type;
}

class DoudizhuActionOutcome {
  const DoudizhuActionOutcome({
    required this.legal,
    this.reason,
    this.redeal = false,
    this.bidsComplete = false,
    this.matchOver = false,
  });

  final bool legal;
  final String? reason;
  final bool redeal;
  final bool bidsComplete;
  final bool matchOver;
}

/// Mutable authoritative state for one game. The bottom cards stay as a
/// display record after being added to the landlord's physical hand.
class DoudizhuGameState {
  DoudizhuGameState({int? seed})
      : _random = seed == null ? math.Random().nextDouble : _mulberry32(seed) {
    deal();
  }

  final double Function() _random;
  List<List<int>> hands = [<int>[], <int>[], <int>[]];
  List<int> bottom = <int>[];
  List<int?> bids = <int?>[null, null, null];
  int bidTurn = 0;
  int highestBid = 0;
  int highestSeat = -1;
  int landlord = -1;
  DoudizhuPhase phase = DoudizhuPhase.bidding;
  int turn = 0;
  DoudizhuTrick? lastPlay;
  int passCount = 0;
  final List<int> played = <int>[];
  List<int> playedCounts = List<int>.filled(doudizhuRankCount, 0);
  List<int> playCount = <int>[0, 0, 0];
  int multiplier = 1;
  int bombCount = 0;
  bool landlordWin = false;
  int? winnerSeat;
  int dealNumber = 0;
  List<DoudizhuGameLogEntry> log = <DoudizhuGameLogEntry>[];

  bool get isOver => phase == DoudizhuPhase.over;
  bool get mustLead => phase == DoudizhuPhase.playing && lastPlay == null;

  /// Uses upstream Mulberry32 and Fisher-Yates order for reproducible deals.
  void deal() {
    final deck = List<int>.generate(doudizhuDeckSize, (index) => index);
    for (var index = deck.length - 1; index > 0; index--) {
      final other = (_random() * (index + 1)).floor();
      final value = deck[index];
      deck[index] = deck[other];
      deck[other] = value;
    }
    hands = List.generate(
      3,
      (seat) => DoudizhuRules.sortHand(deck.skip(seat * 17).take(17)),
    );
    bottom = deck.skip(51).take(3).toList();
    bids = <int?>[null, null, null];
    highestBid = 0;
    highestSeat = -1;
    landlord = -1;
    bidTurn = (_random() * 3).floor();
    phase = DoudizhuPhase.bidding;
    turn = 0;
    lastPlay = null;
    passCount = 0;
    played.clear();
    playedCounts = List<int>.filled(doudizhuRankCount, 0);
    playCount = <int>[0, 0, 0];
    multiplier = 1;
    bombCount = 0;
    landlordWin = false;
    winnerSeat = null;
    log = <DoudizhuGameLogEntry>[];
    dealNumber++;
  }

  DoudizhuActionOutcome nextBid(int seat, int score) {
    if (phase != DoudizhuPhase.bidding) {
      return const DoudizhuActionOutcome(
        legal: false,
        reason: '当前不是叫分阶段',
      );
    }
    if (seat != bidTurn) {
      return const DoudizhuActionOutcome(legal: false, reason: '还没轮到该席位叫分');
    }
    if (score != 0 && (score < 1 || score > 3)) {
      return const DoudizhuActionOutcome(
        legal: false,
        reason: '叫分只能是 1/2/3 或不叫',
      );
    }
    if (score != 0 && score <= highestBid) {
      return DoudizhuActionOutcome(
        legal: false,
        reason: '必须高于当前最高分 ${highestBid == 0 ? '无' : highestBid.toString()}',
      );
    }

    bids[seat] = score;
    if (score > highestBid) {
      highestBid = score;
      highestSeat = seat;
    }
    log.add(DoudizhuGameLogEntry.bid(seat: seat, score: score));
    final allBid = bids.every((value) => value != null);
    if (score == 3 || allBid) {
      if (highestSeat < 0) {
        deal();
        return const DoudizhuActionOutcome(legal: true, redeal: true);
      }
      landlord = highestSeat;
      return const DoudizhuActionOutcome(legal: true, bidsComplete: true);
    }
    bidTurn = nextSeat(seat);
    return const DoudizhuActionOutcome(legal: true);
  }

  bool startPlay() {
    if (landlord < 0 || phase != DoudizhuPhase.bidding) return false;
    hands[landlord] = DoudizhuRules.sortHand([...hands[landlord], ...bottom]);
    phase = DoudizhuPhase.playing;
    turn = landlord;
    lastPlay = null;
    passCount = 0;
    multiplier = highestBid > 0 ? highestBid : 1;
    return true;
  }

  DoudizhuActionOutcome play(int seat, List<int> cardIds) {
    if (phase != DoudizhuPhase.playing) {
      return const DoudizhuActionOutcome(
        legal: false,
        reason: '当前不是出牌阶段',
      );
    }
    if (isOver) {
      return const DoudizhuActionOutcome(legal: false, reason: '对局已结束');
    }
    if (seat != turn) {
      return const DoudizhuActionOutcome(legal: false, reason: '还没轮到该席位出牌');
    }
    final validation = DoudizhuRules.validatePlay(
      hand: hands[seat],
      cardIds: cardIds,
      lastPlay: lastPlay?.move,
    );
    if (!validation.isValid) {
      return DoudizhuActionOutcome(legal: false, reason: validation.reason);
    }

    final move = validation.move!;
    final removed = cardIds.toSet();
    hands[seat] = hands[seat].where((card) => !removed.contains(card)).toList();
    played.addAll(cardIds);
    for (final card in cardIds) {
      playedCounts[DoudizhuRules.rankOf(card)]++;
    }
    playCount[seat]++;
    if (move.isBombLike) {
      bombCount++;
      multiplier *= 2;
    }
    lastPlay = DoudizhuTrick(seat: seat, move: move);
    passCount = 0;
    log.add(
      DoudizhuGameLogEntry.play(
        seat: seat,
        cardIds: cardIds,
        type: move.type,
      ),
    );
    if (hands[seat].isEmpty) {
      _finish(seat);
      return const DoudizhuActionOutcome(legal: true, matchOver: true);
    }
    turn = nextSeat(seat);
    return const DoudizhuActionOutcome(legal: true);
  }

  DoudizhuActionOutcome pass(int seat) {
    if (phase != DoudizhuPhase.playing) {
      return const DoudizhuActionOutcome(
        legal: false,
        reason: '当前不是出牌阶段',
      );
    }
    if (isOver) {
      return const DoudizhuActionOutcome(legal: false, reason: '对局已结束');
    }
    if (seat != turn) {
      return const DoudizhuActionOutcome(legal: false, reason: '还没轮到该席位');
    }
    final trick = lastPlay;
    if (trick == null) {
      return const DoudizhuActionOutcome(
        legal: false,
        reason: '领出时必须出牌',
      );
    }
    passCount++;
    log.add(DoudizhuGameLogEntry.pass(seat: seat));
    if (passCount >= 2) {
      lastPlay = null;
      passCount = 0;
      turn = trick.seat;
    } else {
      turn = nextSeat(seat);
    }
    return const DoudizhuActionOutcome(legal: true);
  }

  List<int> settle() {
    final scores = List<int>.filled(3, 0);
    for (var seat = 0; seat < 3; seat++) {
      if (seat == landlord) {
        scores[seat] = landlordWin ? multiplier * 2 : multiplier * -2;
      } else {
        scores[seat] = landlordWin ? -multiplier : multiplier;
      }
    }
    return scores;
  }

  /// Physical-card invariant: after bottom pickup, bottom is a display record.
  bool get conservesPhysicalCards {
    final physical = <int>[...hands.expand((hand) => hand), ...played];
    if (phase == DoudizhuPhase.bidding) physical.addAll(bottom);
    if (physical.length != doudizhuDeckSize) return false;
    final counts = List<int>.filled(doudizhuDeckSize, 0);
    for (final card in physical) {
      if (card < 0 || card >= doudizhuDeckSize) return false;
      counts[card]++;
    }
    return counts.every((count) => count == 1);
  }

  void _finish(int seat) {
    phase = DoudizhuPhase.over;
    winnerSeat = seat;
    landlordWin = seat == landlord;
    final farmersHaveNotPlayed = List<int>.generate(3, (index) => index)
        .where((farmer) => farmer != landlord)
        .every((farmer) => playCount[farmer] == 0);
    if (landlordWin && farmersHaveNotPlayed) {
      multiplier *= 2;
    } else if (!landlordWin && playCount[landlord] <= 1) {
      multiplier *= 2;
    }
  }

  static int nextSeat(int seat) => (seat + 1) % 3;
}

double Function() _mulberry32(int seed) {
  var state = seed & 0xffffffff;
  return () {
    state = (state + 0x6d2b79f5) & 0xffffffff;
    var value = ((state ^ (state >> 15)) * (1 | state)) & 0xffffffff;
    final mixed = (((value ^ (value >> 7)) * (61 | value)) & 0xffffffff);
    value = (((value + mixed) & 0xffffffff) ^ value) & 0xffffffff;
    return ((value ^ (value >> 14)) & 0xffffffff) / 4294967296;
  };
}
