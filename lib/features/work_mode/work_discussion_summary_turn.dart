part of 'work_discussion_runner.dart';

extension _DiscussionSummaryTurn on _DiscussionSession {
  Future<void> _summarize() async {
    final chairId = state.executorId ?? state.coordinatorId;
    final chair = chairId == null ? null : membersById[chairId];
    summary = null;
    if (chair?.available == true && calls < WorkDiscussionRunner.maxCalls) {
      calls++;
      await runner._recordEvent(
        task,
        WorkTaskEventKind.stepStarted,
        '${chair!.character.name}正在汇总本轮讨论',
        current: calls,
        total: WorkDiscussionRunner.maxCalls,
        metadata: <String, Object?>{
          'phase': 'discussion-summary',
          'round': round,
          'roleId': chair.character.id,
          'understandingPercent': state.understandingPercent,
        },
      );
      final summary = await runner._requestTurn(
        task: task,
        group: group,
        member: chair,
        state: state,
        // Member replies are appended to [publicResponses] as they arrive;
        // pass that single source so a large first round cannot duplicate
        // and crowd out the current round in the coordinator prompt.
        publicResponses: publicResponses,
        isCoordinator: true,
        cancellation: cancellation,
      );
      this.summary = summary;
      if (!summary.valid) {
        roundBlockers.add('coordinatorResponseInvalid');
        await runner._publishFailure(
          task,
          group,
          chair.character,
          '${summary.failureReason}，不能宣称已理解完成。',
          cancellation,
        );
      } else {
        final previousPercent = roundPercent;
        final previousEvidence = List<String>.from(roundEvidence);
        final previousQuestions = List<String>.from(roundQuestions);
        final previousBlockers = List<String>.from(roundBlockers);
        final escalateToOwner = runner._shouldEscalateOwnerQuestion(
          state: state,
          qualifiedAvailableIds: qualifiedAvailableIds,
          availableMembers: availableMembers,
          question: summary.userQuestion,
        );
        roundBlockers.remove('coordinatorResponseInvalid');
        // The latest executor assessment is authoritative; new information
        // may reduce confidence even within the same request revision.
        roundPercent = summary.understandingPercent;
        roundEvidence.addAll(summary.understandingEvidence);
        roundQuestions = runner
            ._removeResolved(
              roundQuestions,
              summary.resolvedQuestions,
            )
            .toList(growable: true);
        // Keep a question newly raised by the coordinator open even when a
        // malformed response lists it in both open and resolved fields.
        roundQuestions.addAll(summary.openQuestions);
        final extensionReason = summary.blockers
            .map(runner._discussionExtensionReason)
            .whereType<String>()
            .firstWhere((reason) => reason.isNotEmpty, orElse: () => '');
        roundBlockers = runner
            ._removeResolved(
              roundBlockers,
              summary.resolvedBlockers,
            )
            .toList(growable: true);
        roundBlockers.addAll(
          summary.blockers.where(
            (blocker) =>
                runner._discussionExtensionReason(blocker) == null &&
                (blocker != 'missingUserInformation' || escalateToOwner) &&
                (blocker != 'missingQualifiedRole' ||
                    qualifiedAvailableIds.isEmpty),
          ),
        );
        final summaryProgress = runner._hasProgressChange(
          previousPercent: previousPercent,
          nextPercent: roundPercent,
          previousEvidence: previousEvidence,
          nextEvidence: roundEvidence,
          previousQuestions: previousQuestions,
          nextQuestions: roundQuestions,
          previousBlockers: previousBlockers,
          nextBlockers: roundBlockers,
          publicUpdate: summary.publicUpdate,
          priorPublicResponses: publicResponses,
          contractChanged: summary.contractPatch?.isNotEmpty == true,
        );
        roundProgress = roundProgress ||
            ((summary.substantiveProgress ||
                    summary.contractPatch?.isNotEmpty == true ||
                    summary.resolvedQuestions.isNotEmpty ||
                    summary.resolvedBlockers.isNotEmpty) &&
                summaryProgress);
        if (extensionReason.isNotEmpty &&
            runner._maxRounds(task.userRequest) >= 6) {
          final extendedLimit = runner._maxRounds(task.userRequest) +
              WorkDiscussionRunner.maxComplexityExtensionRounds;
          if (maxRounds < extendedLimit) {
            maxRounds = extendedLimit;
            await runner._publish(
              task,
              group,
              '复杂任务讨论经执行人说明“$extensionReason”延长至 $maxRounds 轮，仍受调用预算和无进展收敛限制。',
              senderId: chair.character.id,
              cancellation: cancellation,
            );
          }
        }
        if (summary.recommendedExecutorId != null &&
            qualifiedAvailableIds.contains(summary.recommendedExecutorId)) {
          final id = summary.recommendedExecutorId!;
          votes[id] = (votes[id] ?? 0) + 1;
        }
        if (summary.contractPatch != null) {
          contract = runner._mergeContract(
            contract,
            runner._safeDiscussionContractPatch(
              summary.contractPatch!,
              executorId: state.executorId,
              qualifiedExecutorIds: qualifiedAvailableIds.toSet(),
            ),
          );
        }
        if (summary.needsUser && summary.userQuestion.isNotEmpty) {
          if (escalateToOwner) {
            userInputRequired = true;
            roundQuestions.add(summary.userQuestion);
            roundBlockers.add('missingUserInformation');
            await runner._publish(
              task,
              group,
              '@${runner._ownerMentionName(group)} 执行人需要你补充：${summary.userQuestion}',
              isMention: true,
              cancellation: cancellation,
            );
          } else {
            // The executor may ask for a detail while still being able to
            // choose a defensible default. Keep that decision inside the
            // group rather than turning it into an owner-facing blocker.
            roundQuestions.add(summary.userQuestion);
            roundEvidence.add('执行人已将普通方案取舍留在群内继续讨论，未升级群主。');
          }
        }
        final percent = runner._safeUnderstandingPercent(
          roundPercent,
          contract,
          roundQuestions,
          roundBlockers,
          evidence: roundEvidence,
          publicUpdate: summary.publicUpdate,
          executorId: state.executorId,
        );
        final publicSummary = summary.publicUpdate.isEmpty
            ? '执行人本轮未提供公开摘要，理解进度不能据此提高。'
            : summary.publicUpdate;
        await runner._publish(
          task,
          group,
          '${state.executorId == null ? '[暂定协调] ' : ''}[理解进度 $percent%] '
          '$publicSummary${runner._missingSuffix(roundQuestions, roundBlockers)}',
          senderId: chair.character.id,
          cancellation: cancellation,
        );
        await runner._recordEvent(
          task,
          WorkTaskEventKind.modelOutput,
          '${chair.character.name}已完成公开讨论汇总',
          current: calls,
          total: WorkDiscussionRunner.maxCalls,
          metadata: <String, Object?>{
            'phase': 'discussion-summary',
            'roleId': chair.character.id,
            'stream': 'public_update',
            'publicDraft': publicSummary,
            'understandingPercent': percent,
          },
        );
        publicResponses.add('${chair.character.name}：$publicSummary');
      }
    } else if (chairId != null) {
      roundBlockers.add('coordinatorUnavailable');
    }
  }
}
