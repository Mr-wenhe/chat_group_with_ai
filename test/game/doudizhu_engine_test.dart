import 'package:chat_group/features/game/doudizhu/doudizhu_difficulty.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_engine.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_game_state.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('第六档配置保留宗师开关、评分常量和稳定同分顺序', () {
    expect(doudizhuDifficultyLevel, 6);
    expect(doudizhuDifficultyLabel, '宗师');
    expect(doudizhuWingChoices, 3);
    expect(doudizhuRemember, isTrue);
    expect(doudizhuTeamwork, isTrue);
    expect(doudizhuEndgame, isTrue);
    expect(doudizhuTemperature, 0);
    expect(doudizhuBlunder, 0);
    expect(doudizhuHandUnit, 1000);
    expect(doudizhuLossCap, 0);
    expect(doudizhuBlunderCap, 2600);
    expect(doudizhuWinBase, 90000);
    const first = DoudizhuAiCandidate(
      cardIds: [0],
      score: 10,
      type: '单张',
      rank: 0,
      len: 1,
      handsAfter: 1,
    );
    const second = DoudizhuAiCandidate(
      cardIds: [4],
      score: 10,
      type: '单张',
      rank: 1,
      len: 1,
      handsAfter: 1,
    );
    expect(pickDoudizhuMove([first, second])?.candidate, same(first));
  });

  test('seed 12345 的第六档候选分数、顺序和最终选择匹配上游', () {
    final game = DoudizhuGameState(seed: 12345);
    final hand = game.hands[0];
    final result = const DoudizhuEngine().decide(
      hand: hand,
      lastPlay: null,
      context: DoudizhuEngineContext(
        seat: 0,
        landlord: 0,
        handSizes: const [17, 17, 17],
        playedCounts: List<int>.filled(doudizhuRankCount, 0),
        passCount: 0,
      ),
    );

    expect(
      result.candidates
          .map((candidate) => [candidate.cardIds, candidate.score])
          .toList(),
      [
        [
          [7],
          -6616
        ],
        [
          [8],
          -5624
        ],
        [
          [8, 10],
          -6648
        ],
        [
          [12],
          -6632
        ],
        [
          [12, 14],
          -5664
        ],
        [
          [12, 14, 15],
          -8096
        ],
        [
          [18],
          -6640
        ],
        [
          [22],
          -6648
        ],
        [
          [24],
          -5656
        ],
        [
          [24, 26],
          -5712
        ],
        [
          [33],
          -8072
        ],
        [
          [33, 34],
          -8144
        ],
        [
          [33, 34, 35],
          -6816
        ],
        [
          [46],
          -6696
        ],
        [
          [46, 47],
          -5792
        ],
        [
          [50],
          -5704
        ],
        [
          [53],
          -5720
        ],
        [
          [12, 14, 15, 7],
          -6712
        ],
        [
          [12, 14, 15, 8, 10],
          -6744
        ],
        [
          [33, 34, 35, 7],
          -6832
        ],
        [
          [33, 34, 35, 24, 26],
          -5928
        ],
        [
          [7, 8, 12, 18, 22],
          -5760
        ],
        [
          [7, 8, 12, 18, 22, 24],
          -5816
        ],
        [
          [8, 12, 18, 22, 24],
          -6800
        ],
      ],
    );
    expect(
      pickDoudizhuMove(result.candidates)?.candidate.cardIds,
      [8],
    );
  });

  test('农民公开上下文能识别队友领出并应用让牌分', () {
    final result = const DoudizhuEngine().decide(
      hand: const [24, 28, 32],
      lastPlay: DoudizhuRules.classify([20])!,
      context: DoudizhuEngineContext(
        seat: 1,
        landlord: 0,
        handSizes: const [4, 4, 4],
        playedCounts: List<int>.filled(doudizhuRankCount, 0),
        passCount: 0,
        lastPlaySeat: 2,
      ),
    );
    final pass = result.candidates.last;
    expect(
      result.candidates
          .map((candidate) => [candidate.cardIds, candidate.score])
          .toList(),
      [
        [
          [24],
          -1656,
        ],
        [
          [28],
          -1664,
        ],
        [
          [32],
          -1672,
        ],
        [null, -2100],
      ],
    );
    expect(pass.cardIds, isNull);
    expect(pass.teammatePass, isTrue);
    expect(pass.score, 900 - result.handsBefore * 1000);
  });

  test('20 张极端手牌仍在 DP 节点预算内返回候选和动作', () {
    final hand = <int>[
      for (var rank = 0; rank < 5; rank++)
        for (var suit = 0; suit < 4; suit++) rank * 4 + suit,
    ];
    final result = const DoudizhuEngine().decide(
      hand: hand,
      lastPlay: null,
      context: DoudizhuEngineContext(
        seat: 0,
        landlord: 0,
        handSizes: const [20, 17, 17],
        playedCounts: List<int>.filled(doudizhuRankCount, 0),
        passCount: 0,
      ),
    );
    expect(result.candidates, isNotEmpty);
    expect(result.candidateCount, lessThanOrEqualTo(240));
    expect(pickDoudizhuMove(result.candidates), isNotNull);
  });
}
