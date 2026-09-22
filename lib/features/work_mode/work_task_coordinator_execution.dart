part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorExecution on WorkTaskCoordinator {
  Future<void> _run(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    Object? error;
    StackTrace? stackTrace;
    try {
      if ((_folderGrantService != null || _requireFolderGrant) &&
          !await _ensureFolderGrant(task, cancellation)) {
        await _serialize(() async {
          _running.remove(task.id);
          final stored = _taskBox.get(task.id);
          if (!_disposed &&
              !cancellation.isCancelled &&
              stored != null &&
              !stored.isTerminal) {
            _folderWaiters[task.id] = cancellation;
          } else {
            _folderWaiters.remove(task.id);
          }
          // A failed revalidation is a paused boundary, not an active run.
          // Release the conversation reservation so a later manual resume or
          // another queued task cannot be permanently starved by a stale
          // folder picker/authorization state.
          _conversationReservations.remove(task.groupId);
          _makeConversationReady(task.groupId);
          _notifySlotAvailable();
        });
        return;
      }
      await _runner.run(task, cancellation);
    } on Object catch (caught, trace) {
      error = caught;
      stackTrace = trace;
    }
    // Disposal is cooperative, but the runner may finish one microtask after
    // cancellation. Never touch Hive or the event store after shutdown starts.
    if (_disposed) return;
    await _serialize(() async {
      if (_disposed) return;
      final running = _running[task.id];
      if (running == null || !identical(running.cancellation, cancellation)) {
        return;
      }
      _running.remove(task.id);
      _notifySlotAvailable();
      final stored = _taskBox.get(task.id);
      if (stored == null) {
        _conversationReservations.remove(task.groupId);
        await _schedule();
        return;
      }

      // stop()/data-clear commits the terminal cancellation before the
      // cooperative runner necessarily returns. A late runner result must
      // only release in-memory ownership; it must not refresh context, emit a
      // completion event/message, promote FIFO, or save a newer checkpoint.
      if (cancellation.isCancelled ||
          stored.status == AgentTaskStatus.cancelled) {
        _folderWaiters.remove(task.id);
        _conversationReservations.remove(task.groupId);
        _makeConversationReady(task.groupId);
        await _schedule();
        return;
      }

      WorkFailure? failureToReport;
      if (error != null && !stored.isTerminal) {
        final failure = WorkFailure.fromError(
          error,
          scope: 'runner',
          completedContent: _completedContentForTask(stored),
        );
        failureToReport = failure;
        _applyFailure(stored, failure);
        await _save(stored);
        unawaited(_record(
          stored,
          WorkTaskEventKind.failed,
          '任务执行失败',
          detail: failure.technicalDetail,
        ));
      } else if (!stored.isTerminal &&
          stored.status != AgentTaskStatus.queued &&
          stored.status != AgentTaskStatus.paused &&
          stored.status != AgentTaskStatus.interrupted &&
          stored.status != AgentTaskStatus.waitingForApproval) {
        stored
          ..status = AgentTaskStatus.completed
          ..updatedAt = _clock();
        await _save(stored);
        unawaited(
          _record(stored, WorkTaskEventKind.completed, '任务已完成'),
        );
      }

      // Fake and production runners may finish on different persistence
      // boundaries. Refresh the canonical Task 15 summary after the terminal
      // status is known so a result/error is still recoverable when a runner
      // did not publish its own checkpoint callback.
      final handedOff = _advanceCompletedHandoff(stored);
      if (!handedOff) {
        await _applyQueuedAuthorizationRootCorrection(stored);
      }
      _refreshTaskContext(
        stored,
        nextStep: handedOff
            ? '当前阶段已完成，下一角色将在释放资源后接手。'
            : stored.status == AgentTaskStatus.completed
                ? '已完成，可继续追问。'
                : null,
      );
      await _save(stored);

      if (!handedOff && stored.status == AgentTaskStatus.failed) {
        final failure = stored.workFailure ??
            failureToReport ??
            WorkFailure.fromToolFailure(
              code: 'internal',
              message: stored.lastError.trim().isEmpty
                  ? '任务执行失败。'
                  : stored.lastError,
              scope: 'runner',
              completedContent: _completedContentForTask(stored),
            );
        if (stored.workFailure == null) {
          _applyFailure(stored, failure);
          await _save(stored);
        }
        await _reportFailure(stored, failure);
      }

      // A follow-up is promoted only after a successful stage. Failures and
      // pauses must leave the FIFO untouched so the recovery action can resume
      // the same checkpoint before any later request changes the task context.
      if (!handedOff && stored.status == AgentTaskStatus.completed) {
        await _promoteQueuedFollowUp(stored);
      }
      await _markSnapshotStatus(stored);

      final holdConversation = !handedOff &&
          ((!stored.isTerminal &&
                  (stored.status == AgentTaskStatus.waitingForApproval ||
                      stored.status == AgentTaskStatus.paused ||
                      stored.status == AgentTaskStatus.interrupted)) ||
              _hasPendingDiscussionForConversation(task.groupId));
      if (!holdConversation && !handedOff) {
        _conversationReservations.remove(task.groupId);
      }
      _folderWaiters.remove(task.id);

      if (stackTrace != null) {
        // The public event only contains the error message; stack traces stay
        // out of persisted task output and can be surfaced by a future logger.
      }
      if (handedOff) {
        // Keep the conversation reservation until _runWithLease releases the
        // previous role's resource lease. This remains serial even when a
        // stage has no explicit file lock plan (for example a skill-only
        // stage), so the next role cannot start in the same microtask.
        _handoffsAwaitingLease.add(task.id);
        _enqueueTask(stored);
        unawaited(_record(
          stored,
          WorkTaskEventKind.queued,
          '当前阶段完成，已排队下一角色接手',
          detail: stored.characterId,
        ));
      } else {
        _makeConversationReady(task.groupId);
      }
      await _schedule();
    });
  }

  /// Promotes a routed task to its next role after the current runner returns.
  /// Keeping this transition in the coordinator guarantees that one
  /// conversation never runs two assigned roles at the same time.
  bool _advanceCompletedHandoff(AgentTask task) {
    // A failed, cancelled or partially-completed stage must remain terminal;
    // only an actual successful stage completion may release the next role.
    if (!task.workModeTask || task.status != AgentTaskStatus.completed) {
      return false;
    }
    // A group discussion elects one final executor for the whole request.
    // Legacy multi-stage handoff metadata may still be present on a routed
    // task, but it must not silently replace that elected identity after the
    // discussion gate has granted execution.
    if (_requiresDiscussionForTask(task) &&
        WorkDiscussionState.decodeExecutionState(task.executionStateJson)
            .present) {
      return false;
    }
    final state = WorkHandoffState.fromTask(task);
    if (state == null || state.isComplete) return false;
    try {
      if (!state.needsHandoff) {
        // Persist the terminal marker for the last stage as well. This keeps
        // a restarted task from looking as if it could still be handed off.
        WorkHandoffState.persistToTask(
          task,
          state.advance(
            previousRoleReleased: true,
            deliveredArtifacts: task.lastArtifactPaths,
            summary: task.resultSummary,
          ),
        );
        return false;
      }
      final waiting = state.advance(
        previousRoleReleased: true,
        deliveredArtifacts: task.lastArtifactPaths,
        summary: task.resultSummary,
      );
      final active = waiting.activateReceiver();
      task
        ..characterId = active.currentRoleId
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..pendingToolRequestJson = ''
        ..resultSummary = ''
        ..lastError = ''
        // The action/time budget belongs to the durable task, not to an
        // individual role.  A handoff must not reset it and thereby let a
        // product→developer→tester chain exceed the global 100/60-minute
        // safety boundary.
        ..softLimitReached = false;
      WorkHandoffState.persistToTask(task, active);
      return true;
    } on Object catch (error) {
      _applyFailure(
        task,
        WorkFailure.fromError(
          error,
          scope: 'handoff',
          completedContent: _completedContentForTask(task),
        ),
      );
      return false;
    }
  }
}
