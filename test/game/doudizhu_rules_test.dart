import 'package:chat_group/features/game/doudizhu/doudizhu_game_state.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_move_generator.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_rules.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _rank(int rank, int count) =>
    List<int>.generate(count, (index) => rank * 4 + index);

void main() {
  group('上游牌型与实体牌校验', () {
    test('覆盖上游定义的 14 种牌型', () {
      final hands = <List<int>>[
        [0], // 单张
        _rank(1, 2), // 对子
        _rank(2, 3), // 三张
        [..._rank(3, 3), 16], // 三带一
        [..._rank(3, 3), ..._rank(4, 2)], // 三带二
        [0, 4, 8, 12, 16], // 顺子
        [0, 1, 4, 5, 8, 9], // 连对
        [..._rank(0, 3), ..._rank(1, 3)], // 飞机
        [..._rank(0, 3), ..._rank(1, 3), 8, 12], // 飞机带单
        [..._rank(0, 3), ..._rank(1, 3), ..._rank(2, 2), ..._rank(3, 2)],
        [..._rank(0, 4), 4, 8], // 四带二，单牌可由对子拆出
        [..._rank(0, 4), ..._rank(1, 2), ..._rank(2, 2)], // 四带两对
        _rank(3, 4), // 炸弹
        [52, 53], // 火箭
      ];
      expect(
        hands.map((cards) => DoudizhuRules.classify(cards)?.type),
        DoudizhuCardType.values,
      );
    });

    test('顺子止于 A；四带二不接受双王翅膀', () {
      expect(
        DoudizhuRules.classify([28, 32, 36, 40, 44])?.type,
        DoudizhuCardType.straight,
      );
      expect(DoudizhuRules.classify([32, 36, 40, 44, 48]), isNull);
      expect(DoudizhuRules.classify([..._rank(0, 4), 52, 53]), isNull);
      expect(
        DoudizhuRules.classify([..._rank(0, 4), 4, 5])?.type,
        DoudizhuCardType.fourSolo,
      );
    });

    test('压制比较牌型、长度和点数，炸弹与王炸例外', () {
      final pair3 = DoudizhuRules.classify([0, 1])!;
      final pair4 = DoudizhuRules.classify([4, 5])!;
      final trio4 = DoudizhuRules.classify([4, 5, 6])!;
      final bomb3 = DoudizhuRules.classify(_rank(0, 4))!;
      final bomb4 = DoudizhuRules.classify(_rank(1, 4))!;
      final rocket = DoudizhuRules.classify([52, 53])!;
      expect(DoudizhuRules.beats(pair4, pair3), isTrue);
      expect(DoudizhuRules.beats(trio4, pair3), isFalse);
      expect(DoudizhuRules.beats(bomb3, pair4), isTrue);
      expect(DoudizhuRules.beats(bomb4, bomb3), isTrue);
      expect(DoudizhuRules.beats(bomb3, bomb4), isFalse);
      expect(DoudizhuRules.beats(rocket, bomb4), isTrue);
      expect(DoudizhuRules.beats(bomb4, rocket), isFalse);
    });

    test('真人实体牌入口拒绝重复、越界、不在手牌和非法牌型', () {
      const hand = [0, 1, 4, 5, 8, 9, 52];
      expect(
        DoudizhuRules.validatePlay(hand: hand, cardIds: [0, 0]).isValid,
        isFalse,
      );
      expect(
        DoudizhuRules.validatePlay(hand: hand, cardIds: [54]).reason,
        '选牌 ID 越界',
      );
      expect(
        DoudizhuRules.validatePlay(hand: hand, cardIds: [2]).reason,
        '选牌不在当前手牌中',
      );
      expect(
        DoudizhuRules.validatePlay(hand: hand, cardIds: [0, 4]).reason,
        '不构成合法牌型',
      );
      expect(
        DoudizhuRules.validatePlay(hand: hand, cardIds: [0, 1]).move?.rank,
        0,
      );
    });

    test('玩家合法组合独立于 240 个 AI 候选上限', () {
      final hand = <int>[
        ..._rank(0, 4),
        ..._rank(1, 4),
        ..._rank(2, 4),
        ..._rank(3, 4),
        16,
        20,
        24,
        28,
      ];
      final candidates = generateDoudizhuMoves(hand, maxMoves: 1);
      expect(candidates, hasLength(1));
      final playerCombination = [..._rank(0, 3), ..._rank(1, 3), 16, 20];
      expect(
        DoudizhuRules.validatePlay(hand: hand, cardIds: playerCombination)
            .isValid,
        isTrue,
      );
    });
  });

  test('Mulberry32 固定种子与上游发牌及叫分席位一致', () {
    final state = DoudizhuGameState(seed: 12345);
    expect(state.hands, [
      [53, 50, 46, 47, 33, 34, 35, 24, 26, 22, 18, 12, 14, 15, 8, 10, 7],
      [42, 43, 38, 32, 28, 29, 31, 21, 23, 19, 13, 4, 5, 6, 0, 1, 2],
      [48, 49, 51, 44, 45, 40, 41, 36, 37, 39, 30, 27, 20, 17, 9, 11, 3],
    ]);
    expect(state.bottom, [25, 16, 52]);
    expect(state.bidTurn, 0);
    expect(state.conservesPhysicalCards, isTrue);
  });

  test('三家不叫重发并让上一副牌结果失效', () {
    final state = DoudizhuGameState(seed: 12345);
    final firstDealNumber = state.dealNumber;
    final firstHands = state.hands.map(List<int>.of).toList();
    var seat = state.bidTurn;
    for (var turn = 0; turn < 3; turn++) {
      final outcome = state.nextBid(seat, 0);
      expect(outcome.legal, isTrue);
      seat = DoudizhuGameState.nextSeat(seat);
      if (turn < 2) expect(outcome.redeal, isFalse);
      if (turn == 2) expect(outcome.redeal, isTrue);
    }
    expect(state.dealNumber, firstDealNumber + 1);
    expect(state.bids, [null, null, null]);
    expect(state.highestBid, 0);
    expect(state.phase, DoudizhuPhase.bidding);
    expect(state.hands, isNot(firstHands));
    expect(state.conservesPhysicalCards, isTrue);
  });

  test('两家连续过牌后领出权回到最后出牌者', () {
    final state = DoudizhuGameState(seed: 18);
    final start = state.bidTurn;
    expect(state.nextBid(start, 3).bidsComplete, isTrue);
    expect(state.startPlay(), isTrue);
    final leader = state.landlord;
    final lead = generateDoudizhuMoves(state.hands[leader]).first;
    expect(state.play(leader, lead.cardIds).legal, isTrue);
    final next = DoudizhuGameState.nextSeat(leader);
    expect(state.pass(next).legal, isTrue);
    expect(state.lastPlay, isNotNull);
    final finalPasser = DoudizhuGameState.nextSeat(next);
    expect(state.pass(finalPasser).legal, isTrue);
    expect(state.lastPlay, isNull);
    expect(state.turn, leader);
  });

  test('炸弹、火箭、春天倍率与结算逐项叠乘', () {
    final state = DoudizhuGameState(seed: 33);
    final landlordHand = [0, 1, 2, 3, 52, 53];
    final remaining = List<int>.generate(54, (id) => id)
      ..removeWhere(landlordHand.contains);
    state.hands = [
      landlordHand,
      remaining.take(24).toList(),
      remaining.skip(24).toList()
    ];
    state.bottom = const [];
    state.phase = DoudizhuPhase.playing;
    state.landlord = 0;
    state.turn = 0;
    state.highestBid = 1;

    expect(state.play(0, [0, 1, 2, 3]).legal, isTrue);
    expect(state.multiplier, 2);
    expect(state.pass(1).legal, isTrue);
    expect(state.pass(2).legal, isTrue);
    expect(state.turn, 0);
    expect(state.play(0, [52, 53]).matchOver, isTrue);
    expect(state.multiplier, 8);
    expect(state.landlordWin, isTrue);
    expect(state.settle(), [16, -8, -8]);
  });

  test('地主仅出一手后被农民走完触发反春天', () {
    final state = DoudizhuGameState(seed: 44);
    final hands = <List<int>>[
      [0, 4],
      [8],
      List<int>.generate(54, (id) => id)
        ..removeWhere((id) => [0, 4, 8].contains(id)),
    ];
    state.hands = hands;
    state.bottom = const [];
    state.phase = DoudizhuPhase.playing;
    state.landlord = 0;
    state.turn = 0;

    expect(state.play(0, [4]).legal, isTrue);
    expect(state.play(1, [8]).matchOver, isTrue);
    expect(state.landlordWin, isFalse);
    expect(state.multiplier, 2);
    expect(state.settle(), [-4, 2, 2]);
  });

  test('每个实体牌 ID 在整副牌中恰好出现一次', () {
    final state = DoudizhuGameState(seed: 91);
    final all = [...state.hands.expand((hand) => hand), ...state.bottom];
    expect(all, hasLength(54));
    expect(all.toSet(), hasLength(54));
    expect(state.conservesPhysicalCards, isTrue);
  });
}
