/// The upstream sixth tier: no sampling, full wings, memory, teamwork, endgame.
const int doudizhuDifficultyLevel = 6;
const String doudizhuDifficultyLabel = '宗师';
const int doudizhuWingChoices = 3;
const bool doudizhuRemember = true;
const bool doudizhuTeamwork = true;
const bool doudizhuEndgame = true;
const int doudizhuTemperature = 0;
const double doudizhuBlunder = 0;
const int doudizhuHandUnit = 1000;
const int doudizhuLossCap = 0;
const int doudizhuBlunderCap = 2600;
const int doudizhuWinBase = 90000;

class DoudizhuAiCandidate {
  const DoudizhuAiCandidate({
    required this.cardIds,
    required this.score,
    required this.type,
    required this.rank,
    required this.len,
    required this.handsAfter,
    this.bomb = false,
    this.endgame = false,
    this.remembered = false,
    this.forcedWin = false,
    this.teammatePass = false,
  });

  /// Null means pass.
  final List<int>? cardIds;
  final int score;
  final String type;
  final int rank;
  final int len;
  final int handsAfter;
  final bool bomb;
  final bool endgame;
  final bool remembered;
  final bool forcedWin;
  final bool teammatePass;
}

class DoudizhuAiPick {
  const DoudizhuAiPick({required this.candidate, required this.suboptimal});
  final DoudizhuAiCandidate candidate;
  final bool suboptimal;
}

DoudizhuAiPick? pickDoudizhuMove(List<DoudizhuAiCandidate> candidates) {
  if (candidates.isEmpty) return null;
  final indexed = <({int index, DoudizhuAiCandidate candidate})>[
    for (var index = 0; index < candidates.length; index++)
      (index: index, candidate: candidates[index]),
  ];
  // JS Array.sort is stable; index preserves its same-score first-candidate tie.
  indexed.sort((a, b) {
    final scoreOrder = b.candidate.score.compareTo(a.candidate.score);
    return scoreOrder != 0 ? scoreOrder : a.index.compareTo(b.index);
  });
  final top = indexed.first.candidate;
  return DoudizhuAiPick(candidate: top, suboptimal: false);
}
