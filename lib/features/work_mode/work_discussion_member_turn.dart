part of 'work_discussion_runner.dart';

extension _DiscussionMemberTurn on _DiscussionSession {
  Future<bool> _collectMember(_DiscussionMember member) async {
    calls++;
    await runner._recordEvent(
      task,
      WorkTaskEventKind.stepStarted,
      '正在收集${member.character.name}的职业意见',
      current: calls,
      total: WorkDiscussionRunner.maxCalls,
      metadata: <String, Object?>{
        'phase': 'discussion',
        'round': round,
        'roleId': member.character.id,
        'understandingPercent': state.understandingPercent,
      },
    );
    final turn = await runner._requestTurn(
      task: task,
      group: group,
      member: member,
      state: state,
      publicResponses: publicResponses,
      isCoordinator: false,
      cancellation: cancellation,
    );
    if (cancellation.isCancelled) return false;
    if (!turn.valid) {
      final isQualifiedMember = qualifiedAvailableIds.contains(
        member.character.id,
      );
      if (isQualifiedMember) {
        roundBlockers.add(
          _isModelRequestFailure(turn.failureReason)
              ? 'modelRequestFailed:${member.character.id}'
              : 'structuredResponseInvalid:${member.character.id}',
        );
      }
      await runner._recordDiagnostic(
        task,
        '${member.character.name}：${turn.failureReason}',
      );
      await runner._publishFailure(
        task,
        group,
        member.character,
        '${turn.failureReason}，暂不计入理解进度。',
        cancellation,
      );
      state = runner._markParticipant(
        state,
        member.character.id,
        status: 'failed',
        contribution: turn.failureReason,
      );
      final pushedFailure = await runner._pushState(
        task,
        state.copyWith(
          round: round,
          blockers: runner._unique(roundBlockers),
          participants: runner._ensureParticipants(state, memberIds),
        ),
        updateState,
        cancellation,
      );
      if (!pushedFailure) return false;
      return true;
    }
    final previousPercent = roundPercent;
    final previousEvidence = List<String>.from(roundEvidence);
    final previousQuestions = List<String>.from(roundQuestions);
    final previousBlockers = List<String>.from(roundBlockers);
    final previousPublicResponses = List<String>.from(publicResponses);
    final contractSuggestion =
        runner._formatContractSuggestion(turn.contractPatch);
    if (turn.publicUpdate.isNotEmpty || contractSuggestion.isNotEmpty) {
      final text = turn.publicUpdate.isEmpty
          ? '交付合同建议（待执行人取舍）：$contractSuggestion'
          : '职责意见：${turn.publicUpdate}'
              '${contractSuggestion.isEmpty ? '' : '\n交付合同建议（待执行人取舍）：$contractSuggestion'}';
      await runner._publish(
        task,
        group,
        text,
        senderId: member.character.id,
        cancellation: cancellation,
      );
      await runner._recordEvent(
        task,
        WorkTaskEventKind.modelOutput,
        '${member.character.name}已发表公开职责意见',
        current: calls,
        total: WorkDiscussionRunner.maxCalls,
        metadata: <String, Object?>{
          'phase': 'discussion',
          'roleId': member.character.id,
          'stream': 'public_update',
          'publicDraft': turn.publicUpdate,
        },
      );
      if (turn.publicUpdate.isNotEmpty) {
        publicResponses.add('${member.character.name}：${turn.publicUpdate}');
      }
      if (contractSuggestion.isNotEmpty) {
        final suggestion =
            '${member.character.name}提出交付合同建议（待执行人取舍）：$contractSuggestion';
        publicResponses.add(suggestion);
      }
    }
    roundBlockers
      ..remove('structuredResponseInvalid:${member.character.id}')
      ..remove('modelRequestFailed:${member.character.id}');
    // Member confidence is evidence, not the executor's understanding.
    if (state.executorId == null) {
      roundPercent = turn.understandingPercent;
    }
    roundEvidence.addAll(turn.understandingEvidence);
    roundQuestions = runner
        ._removeResolved(
          roundQuestions,
          turn.resolvedQuestions,
        )
        .toList(growable: true);
    // A question introduced by this turn must remain open even if the
    // model repeats it in resolved_questions; only facts from an earlier
    // state can be resolved by this response.
    roundQuestions.addAll(turn.openQuestions);
    roundBlockers = runner
        ._removeResolved(
          roundBlockers,
          turn.resolvedBlockers,
        )
        .toList(growable: true);
    roundBlockers.addAll(turn.blockers);
    final turnProgress = runner._hasProgressChange(
      previousPercent: previousPercent,
      nextPercent: roundPercent,
      previousEvidence: previousEvidence,
      nextEvidence: roundEvidence,
      previousQuestions: previousQuestions,
      nextQuestions: roundQuestions,
      previousBlockers: previousBlockers,
      nextBlockers: roundBlockers,
      publicUpdate: turn.publicUpdate,
      priorPublicResponses: previousPublicResponses,
      contractChanged: turn.contractPatch?.isNotEmpty == true,
    );
    roundProgress = roundProgress ||
        ((turn.substantiveProgress ||
                turn.contractPatch?.isNotEmpty == true ||
                turn.resolvedQuestions.isNotEmpty ||
                turn.resolvedBlockers.isNotEmpty) &&
            turnProgress);
    if (turn.recommendedExecutorId != null) {
      final id = turn.recommendedExecutorId!;
      if (qualifiedAvailableIds.contains(id)) {
        votes[id] = (votes[id] ?? 0) + 1;
      }
    }
    if (turn.needsUser && turn.userQuestion.isNotEmpty) {
      userInputRequired = true;
      roundQuestions.add(turn.userQuestion);
      roundBlockers.add('missingUserInformation');
      await runner._publish(
        task,
        group,
        '@${runner._ownerMentionName(group)} ${member.character.name} 请求补充：${turn.userQuestion}',
        isMention: true,
        cancellation: cancellation,
      );
    }
    roundPercent = runner._safeUnderstandingPercent(
      roundPercent,
      contract,
      roundQuestions,
      roundBlockers,
      evidence: roundEvidence,
      publicUpdate: turn.publicUpdate,
      executorId: state.executorId,
    );
    state = runner._updateParticipant(
      state,
      member.character.id,
      status: 'contributed',
      contribution: turn.publicUpdate,
    );
    final contributionState = state.copyWith(
      round: round,
      understandingPercent: roundPercent,
      understandingEvidence: runner._unique(roundEvidence),
      openQuestions: runner._unique(roundQuestions),
      blockers: runner._unique(roundBlockers),
      deliverableContract: contract,
      phase: state.executorId == null
          ? WorkDiscussionPhase.awaitingExecutor
          : WorkDiscussionPhase.awaitingDiscussion,
    );
    final pushedContribution = await runner._pushState(
      task,
      contributionState,
      updateState,
      cancellation,
    );
    if (!pushedContribution) return false;
    state = contributionState;
    if (userInputRequired) {
      final blockedForUser = state.copyWith(
        phase: WorkDiscussionPhase.blocked,
        understandingPercent: state.understandingPercent.clamp(0, 99).toInt(),
        blockers: runner._discussionBlockers(
          state.blockers,
          hasExecutor: state.executorId != null,
        ),
      );
      if (!await runner._pushState(
        task,
        blockedForUser,
        updateState,
        cancellation,
      )) {
        return false;
      }
      return false;
    }
    return true;
  }

  bool _isModelRequestFailure(String reason) =>
      reason.startsWith('模型请求失败（HTTP ') ||
      reason == '任务网络连接失败' ||
      reason == '任务权限不足' ||
      reason == '任务执行超时' ||
      reason == '模型请求异常';
}
