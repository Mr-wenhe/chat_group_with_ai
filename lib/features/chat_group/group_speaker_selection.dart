import 'package:chat_group/core/models/ai_character.dart';

/// 一步选人的判定结果。
enum SpeakerStepKind {
  /// 已经可以直接确定发言者（明确点名或只剩一个候选）。
  decided,

  /// 必须问一次选人器。
  askModel,

  /// 本轮没有可发言的人，直接结束。
  finished,
}

/// 一步选人的判定。
class SpeakerStep {
  final SpeakerStepKind kind;

  /// 仅在 [SpeakerStepKind.decided] 时非空，且保证是候选集合中的 id。
  final String? characterId;

  const SpeakerStep._(this.kind, this.characterId);

  const SpeakerStep.decided(String characterId)
      : this._(SpeakerStepKind.decided, characterId);

  const SpeakerStep.askModel() : this._(SpeakerStepKind.askModel, null);

  const SpeakerStep.finished() : this._(SpeakerStepKind.finished, null);
}

/// 普通群聊「逐次选人」的决策部分。
///
/// 这里只做纯计算：候选过滤、点名优先级、回合名额与"这一步要不要问模型"。
/// 网络、Hive 与 widget 生命周期都在调用方，因此这些规则可以用单测逐个钉住，
/// 不必依赖整页行为。
class GroupSpeakerSelection {
  /// 一个用户回合里，普通群聊最多产生几条 AI 回复。
  ///
  /// 逐次选人后这个上限仍然是**整个回合**的名额，不是"每一轮再给三条"。
  static const int maxRepliesPerUserRound = 3;

  /// 被 @ 点名时的一轮回复上限：点名优先占用名额，留给额外接话的更少。
  static const int maxRepliesForMentionedRound = 2;

  /// 单次空闲自动聊天最多产生几条回复。
  static const int maxRepliesPerAutoRound = 2;

  /// 一回合能够产生多少条回复。
  static int maxReplies({
    required bool hasMentions,
    required bool isAutoChat,
  }) {
    if (isAutoChat) return maxRepliesPerAutoRound;
    return hasMentions ? maxRepliesForMentionedRound : maxRepliesPerUserRound;
  }

  /// 本轮可以被自动选中的成员。
  ///
  /// 资格判据由调用方以委托传入（启用状态、API 配置与凭据、频率上限、禁言
  /// 例外），保证与既有编排链路一致；这里只补充两条"本轮"规则：已经说过的人
  /// 不重复入选，正在执行工作任务的成员不入选（选中也只会返回空回复）。
  ///
  /// 返回**全部**合格成员，不是评分后的前几名——否则排在后面的成员永远没有
  /// 机会被模型选中。
  static List<AICharacter> candidates({
    required List<AICharacter> characters,
    required bool Function(AICharacter character) isEligible,
    required bool Function(AICharacter character) mayAutoPick,
    required Set<String> agenticRunningCharacterIds,
    required List<String> alreadySpoken,
  }) {
    return characters
        .where((character) =>
            isEligible(character) &&
            mayAutoPick(character) &&
            !agenticRunningCharacterIds.contains(character.id) &&
            !alreadySpoken.contains(character.id))
        .toList(growable: false);
  }

  /// 默认避免同一角色连续抢话。
  ///
  /// 本轮有点名时不套用这条（点名优先）；过滤后为空也保留原名单——宁可连说，
  /// 也不要整轮没人回应。
  static List<AICharacter> avoidConsecutiveSpeaker({
    required List<AICharacter> candidates,
    required String? lastAiSenderId,
    required bool hasMentions,
  }) {
    if (hasMentions || candidates.length <= 1 || lastAiSenderId == null) {
      return candidates;
    }
    final withoutLastSpeaker = candidates
        .where((character) => character.id != lastAiSenderId)
        .toList(growable: false);
    return withoutLastSpeaker.isEmpty ? candidates : withoutLastSpeaker;
  }

  /// 必须优先接话的点名者，按点名先后排列。
  ///
  /// 既包括本轮被 @ 的人，也包括此前被 @ 到但还没回应的人（`pendingMentionIds`）。
  /// 只要仍在候选里就先说话：选人器返回"结束"不能把他们吞掉——他们的请求
  /// 还没被满足。
  static List<String> priorityMentionIds({
    required List<String>? mentionedIds,
    required List<String> pendingMentionedIds,
    required List<AICharacter> candidates,
  }) {
    final candidateIds = {for (final character in candidates) character.id};
    final ordered = <String>[];
    for (final id in [...?mentionedIds, ...pendingMentionedIds]) {
      if (!candidateIds.contains(id) || ordered.contains(id)) continue;
      ordered.add(id);
    }
    return ordered;
  }

  /// 决定这一步怎么走。
  ///
  /// 没有候选就不必调用模型；明确点名或只剩一个候选时可以直接选人，省掉一次
  /// 无意义的调用；其余情况才需要问选人器。
  static SpeakerStep nextStep({
    required List<AICharacter> candidates,
    required List<String> priorityMentionIds,
  }) {
    if (candidates.isEmpty) return const SpeakerStep.finished();
    if (priorityMentionIds.isNotEmpty) {
      return SpeakerStep.decided(priorityMentionIds.first);
    }
    if (candidates.length == 1) {
      return SpeakerStep.decided(candidates.first.id);
    }
    return const SpeakerStep.askModel();
  }
}
