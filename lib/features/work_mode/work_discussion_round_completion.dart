part of 'work_discussion_runner.dart';

extension _DiscussionRoundCompletion on _DiscussionSession {
  Future<bool> _finishRound() async {
    final actualPercent = runner._safeUnderstandingPercent(
      roundPercent,
      contract,
      roundQuestions,
      roundBlockers,
      evidence: roundEvidence,
      publicUpdate: summary?.publicUpdate ?? '',
      executorId: state.executorId,
    );
    final cleanQuestions = runner._unique(roundQuestions);
    final cleanBlockers = runner._unique(roundBlockers);
    final cleanEvidence = runner._unique(roundEvidence);
    final complete = round >= _DiscussionSession.minimumRounds &&
        state.executorId != null &&
        summary?.valid == true &&
        summary?.understandingPercent == 100 &&
        actualPercent == 100 &&
        cleanQuestions.isEmpty &&
        cleanBlockers.isEmpty &&
        runner._contractComplete(contract, executorId: state.executorId) &&
        cleanEvidence.length >= WorkDiscussionRunner.minimumEvidenceItems;
    final next = state.copyWith(
      round: round,
      phase: userInputRequired
          ? WorkDiscussionPhase.blocked
          : complete
              ? WorkDiscussionPhase.ready
              : state.executorId == null
                  ? WorkDiscussionPhase.awaitingExecutor
                  : WorkDiscussionPhase.awaitingDiscussion,
      coordinatorId: state.executorId ?? state.coordinatorId,
      executorId: state.executorId,
      candidateCharacterIds: qualifiedAvailableIds,
      understandingPercent: userInputRequired
          ? actualPercent.clamp(0, 99).toInt()
          : complete
              ? 100
              : actualPercent,
      understandingEvidence: cleanEvidence,
      openQuestions: cleanQuestions,
      blockers: complete && !userInputRequired
          ? const <String>[]
          : runner._discussionBlockers(
              cleanBlockers,
              hasExecutor: state.executorId != null,
            ),
      deliverableContract: contract,
      // An invalid coordinator response may still carry a sanitized plain
      // text preview for diagnostics. It is not a protocol conclusion and
      // may contain line breaks rejected by the durable state contract, so
      // only a valid structured summary may replace the decision summary.
      decisionSummary: summary?.valid == true
          ? summary!.publicUpdate
          : state.decisionSummary,
      participants: runner._ensureParticipants(state, memberIds),
    );
    if (!await runner._pushState(task, next, updateState, cancellation)) {
      return false;
    }
    state = next;
    if (complete) return false;
    if (userInputRequired) return false;

    if (!roundProgress) {
      noProgressRounds++;
    } else {
      noProgressRounds = 0;
    }
    if (noProgressRounds >= WorkDiscussionRunner.noProgressRoundLimit ||
        calls >= WorkDiscussionRunner.maxCalls) {
      final question = state.openQuestions.isEmpty
          ? '连续两轮没有形成新的可验证结论，请补充必要信息或调整参与角色。'
          : state.openQuestions.first;
      await runner._publish(
        task,
        group,
        '@${runner._ownerMentionName(group)} 讨论暂未收敛：$question 当前理解进度 ${state.understandingPercent}%，任务等待你的补充。',
        isMention: true,
        cancellation: cancellation,
      );
      final blocked = state.copyWith(
        phase: WorkDiscussionPhase.blocked,
        understandingPercent: state.understandingPercent.clamp(0, 99).toInt(),
        openQuestions:
            runner._unique(<String>[...state.openQuestions, question]),
        blockers: runner._discussionBlockers(
          <String>[...state.blockers, 'discussionNotConverged'],
          hasExecutor: state.executorId != null,
        ),
      );
      await runner._pushState(task, blocked, updateState, cancellation);
      return false;
    }
    return true;
  }
}
