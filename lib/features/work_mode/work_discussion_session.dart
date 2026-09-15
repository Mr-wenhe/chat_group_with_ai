part of 'work_discussion_runner.dart';

/// Mutable discussion context is scoped to a single run, never shared between tasks.
class _DiscussionSession {
  final WorkDiscussionRunner runner;
  final AgentTask task;
  final WorkTaskCancellation cancellation;
  final WorkTaskDiscussionStateSink updateState;
  final ChatGroup group;
  final Map<String, _DiscussionMember> membersById;
  final List<_DiscussionMember> availableMembers;
  final List<String> qualifiedAvailableIds;
  final List<String> memberIds;
  WorkDiscussionState state;
  late int maxRounds;
  static const minimumRounds = 2;
  int noProgressRounds = 0;
  int calls = 0;
  int round = 0;
  final votes = <String, int>{};
  final publicResponses = <String>[];
  bool roundProgress = false;
  int roundPercent = 0;
  List<String> roundEvidence = [];
  List<String> roundQuestions = [];
  List<String> roundBlockers = [];
  Map<String, dynamic>? contract;
  bool userInputRequired = false;
  WorkDiscussionTurn? summary;

  _DiscussionSession(
      {required this.runner,
      required this.task,
      required this.cancellation,
      required this.updateState,
      required this.group,
      required this.membersById,
      required this.availableMembers,
      required this.qualifiedAvailableIds,
      required this.memberIds,
      required this.state}) {
    maxRounds = runner._maxRounds(task.userRequest);
  }

  Future<void> run() async {
    for (round = state.round + 1; round <= maxRounds; round++) {
      if (cancellation.isCancelled) return;
      _beginRound();
      final speakerIds = runner._speakerIds(
        round: round,
        state: state,
        allMembers: availableMembers,
        coordinatorId: state.coordinatorId,
      );

      for (final speakerId in speakerIds) {
        if (cancellation.isCancelled ||
            calls >= WorkDiscussionRunner.maxCalls) {
          break;
        }
        final member = membersById[speakerId];
        if (member == null || !member.available) continue;
        if (!await _collectMember(member)) return;
      }
      if (cancellation.isCancelled) return;
      await _electExecutor();
      await _summarize();
      if (!await _finishRound()) return;
    }
    await _finishBudget();
  }

  void _beginRound() {
    roundProgress = false;
    roundPercent = state.understandingPercent;
    roundEvidence = <String>[...state.understandingEvidence];
    roundQuestions = <String>[...state.openQuestions];
    roundBlockers = state.blockers
        .where(
          (blocker) =>
              blocker != 'discussionRequired' &&
              blocker != 'executorSelectionRequired',
        )
        .toList(growable: true);
    contract = state.deliverableContract;
    userInputRequired = false;
  }

  Future<void> _electExecutor() async {
    final elected = runner._electedExecutor(
      current: state.executorId,
      votes: votes,
      candidates: qualifiedAvailableIds,
    );
    if (state.executorId == null && elected != null) {
      final voteCount = votes[elected] ?? 0;
      final electionReason = voteCount > 0
          ? '公开推荐 $voteCount 票，职业资格已通过 S1 校验'
          : '当前仅有一名通过 S1 校验且可用的候选';
      state = state.copyWith(
        executorId: elected,
        coordinatorId: elected,
      );
      contract = state.deliverableContract;
      await runner._publish(
        task,
        group,
        '群内公开推举 ${discussionRoleLabel(membersById[elected]!.character)} 作为最终执行候选（$electionReason）；由该角色接手汇总和取舍。',
        cancellation: cancellation,
      );
    }
  }

  Future<void> _finishBudget() async {
    // The bounded round budget is also a terminal convergence boundary. A
    // productive but incomplete model must leave a truthful waiting state and
    // ask the user for the remaining decision instead of silently falling out
    // of the loop with an apparently active task.
    if (!cancellation.isCancelled && state.phase != WorkDiscussionPhase.ready) {
      final question = state.openQuestions.isEmpty
          ? '已达到本任务的讨论轮数上限，但目标、合同或最终执行人仍未全部确认。'
          : state.openQuestions.first;
      final group = runner.database.chatGroupBox.get(task.groupId);
      if (group != null) {
        await runner._publish(
          task,
          group,
          '@${runner._ownerMentionName(group)} 讨论达到 $maxRounds 轮仍未完成：$question 当前理解进度 ${state.understandingPercent}%。',
          isMention: true,
          cancellation: cancellation,
        );
      }
      await runner._pushState(
        task,
        state.copyWith(
          phase: WorkDiscussionPhase.blocked,
          understandingPercent: state.understandingPercent.clamp(0, 99).toInt(),
          openQuestions:
              runner._unique(<String>[...state.openQuestions, question]),
          blockers: runner._discussionBlockers(
            <String>[...state.blockers, 'discussionRoundLimit'],
            hasExecutor: state.executorId != null,
          ),
        ),
        updateState,
        cancellation,
      );
    }
  }
}
