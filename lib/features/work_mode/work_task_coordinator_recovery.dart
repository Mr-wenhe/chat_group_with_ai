part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorRecovery on WorkTaskCoordinator {
  /// Requeues a terminal approval-scope failure after clearing the stale
  /// one-shot capability. Directory authorization failures keep their native
  /// picker flow, so this action cannot turn a missing role or folder grant
  /// into an implicit permission.
  Future<void> _implReauthorizeTask(String taskId) async {
    final shouldReplan = await _serialize<bool>(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      return task.workFailure?.canReplanAfterApprovalScopeFailure == true;
    });
    if (!shouldReplan) {
      await _implRequestFolderForTask(taskId);
      return;
    }

    await _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      final failure = _approvalScopeReplanFailure(task);
      _resetApprovalScopeReplanTask(task);
      _refreshTaskContext(
        task,
        nextStep: '已清除失效审批范围，正在重新生成变更计划。',
        extraErrors: [failure.reason],
        clearApprovalScope: true,
      );
      await _save(task);
      _enqueueTask(task, prioritize: true);
      await _record(
        task,
        WorkTaskEventKind.queued,
        '已重新生成变更计划，继续任务',
        detail: failure.reason,
      );
      await _schedule();
    });
  }

  WorkFailure _approvalScopeReplanFailure(AgentTask task) {
    final failure = task.workFailure;
    if (failure?.canReplanAfterApprovalScopeFailure != true) {
      throw StateError('该权限提醒已失效，请打开任务面板查看最新状态。');
    }
    if (_running.containsKey(task.id) || _startingTaskIds.contains(task.id)) {
      throw StateError('任务正在执行，不能重新生成变更计划。');
    }
    if (_discussionRuns.containsKey(task.id) ||
        _discussionStartingIds.contains(task.id)) {
      throw StateError('群讨论正在进行，不能重新生成变更计划。');
    }
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    if (_requiresDiscussionForTask(task) &&
        discussion.present &&
        (discussion.state == null || !discussion.state!.isExecutionReady)) {
      throw StateError('请先完成群讨论并确定最终执行角色。');
    }
    return failure!;
  }

  void _resetApprovalScopeReplanTask(AgentTask task) {
    _removeQueuedTask(task);
    _waitingForResources.remove(task.id)?.cancellation.cancel();
    _folderWaiters.remove(task.id)?.cancel();
    _conversationReservations.remove(task.groupId);
    _taskLockPlans.remove(task.id);
    task
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false
      ..plan = ''
      ..lastError = ''
      ..pendingToolRequestJson = ''
      // Approval decisions and scopes are one-shot credentials. Replanning
      // must start with the current request and current workspace state.
      ..executionStateJson = _withoutApprovalCheckpoint(
        task.executionStateJson,
      )
      // Waiting time must not consume the next execution window, while the
      // durable action count and committed-operation keys remain intact.
      ..startedAt = _clock()
      ..updatedAt = _clock();
    task.requestedPermissions.clear();
  }

  /// Queues an interrupted or paused task only after an explicit user action.
  Future<void> _implResumeByUser(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.interrupted &&
          task.status != AgentTaskStatus.paused) {
        throw StateError('当前任务不需要手动继续。');
      }
      // A malformed/unsupported checkpoint is normalized to a safe marker.
      // Once the user explicitly opens that checkpoint, a group task still
      // needs the same discussion gate as a fresh task; never let the
      // continuation turn the marker into a runnable legacy task.
      if (await _ensureDiscussionBeforeUserContinuation(task)) return;
      final discussion = WorkDiscussionState.decodeExecutionState(
        task.executionStateJson,
      );
      if (_requiresDiscussionForTask(task) &&
          discussion.present &&
          (discussion.state == null || !discussion.state!.isExecutionReady)) {
        throw StateError('请先完成群讨论并确定最终执行角色。');
      }
      if (task.status == AgentTaskStatus.paused &&
          _isFollowUpClarification(task)) {
        // A clarification pause is waiting for the user's target answer, not
        // a generic task restart. Resuming it would run the old request while
        // leaving the ambiguous FIFO head untouched.
        throw StateError('请先明确要修改的文件路径，再继续任务。');
      }
      if (WorkTaskClarification.isPending(task)) {
        throw StateError('请先在任务面板回答模型的问题。');
      }
      if (_requiresExplicitCommandRequest(task)) {
        throw StateError('请发送明确的测试、构建或分析请求后再继续任务。');
      }
      if (_requiresMissingToolAction(task)) {
        throw StateError(
          '当前任务依赖的工具尚未安装；请先处理安装提示，或改用已存在的工具后重新发起任务。',
        );
      }
      if (_requiresVisionModelSelection(task)) {
        throw StateError('请先选择支持图片的视觉模型后再继续任务。');
      }
      WorkFailure.clearFromTask(task);
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..lastError = ''
        // The durable request is redacted and may contain stale paths or
        // content. A manual restart always asks the model to re-plan against
        // current state; only the in-process approval continuation can replay
        // its full request.
        ..pendingToolRequestJson = ''
        // A pending request payload is intentionally not persisted in full.
        // A manual restart must re-plan against the current filesystem and
        // grant state; never reuse a stale path scope.
        ..executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        )
        ..updatedAt = _clock();
      // A manual continuation is a fresh plan against the current role
      // configuration. The old list was a snapshot of capabilities at task
      // creation and would otherwise keep a newly granted role permission
      // excluded by the runner's safety intersection.
      task.requestedPermissions.clear();
      _conversationReservations.remove(task.groupId);
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '用户已继续任务'));
      await _schedule();
    });
  }

  /// Retries a classified failure from the last durable checkpoint.
  ///
  /// The failure marker is intentionally kept while the task is queued so the
  /// panel can still explain why it stopped. [WorkAgentLoop] removes it only
  /// when a new attempt actually starts. Completed operation keys and artifact
  /// paths are never reset, so a committed mutation cannot be replayed.
  Future<void> _implRetry(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (_running.containsKey(taskId) || _startingTaskIds.contains(taskId)) {
        throw StateError('任务正在执行，不能同时重试。');
      }
      if (_discussionRuns.containsKey(taskId) ||
          _discussionStartingIds.contains(taskId)) {
        throw StateError('群讨论正在进行，不能同时重试。');
      }
      // A retry that is allowed to proceed takes the task over from any pending
      // automatic resume: without this the user's own run would inherit the
      // round deadline that exists only to bound an app-initiated attempt. A
      // rejected retry above leaves the pending attempt untouched.
      _autoResumeTaskIds.remove(taskId);
      final restartFromBeginning =
          WorkTaskCoordinator.canRestartAfterUserStop(task);
      // A finished task can still be waiting to re-send a deliverable that was
      // saved but whose chat attachment failed. That resend runs through this
      // same retry path, so a completed task stays retryable exactly while its
      // delivery marker is pending.
      final deliveryRetryPending =
          workArtifactDeliveryRetryPending(task.executionStateJson);
      if ((task.status == AgentTaskStatus.cancelled && !restartFromBeginning) ||
          task.status == AgentTaskStatus.completed && !deliveryRetryPending) {
        throw StateError('已停止或已完成的任务不能重试。');
      }

      if (restartFromBeginning) {
        final discussionMarker =
            WorkDiscussionState.decodeExecutionState(task.executionStateJson);
        if (_requiresDiscussionForTask(task) &&
            discussionMarker.present &&
            (discussionMarker.state == null ||
                discussionMarker.state!.conversationId != task.groupId)) {
          throw StateError('讨论状态无效或属于另一个群组，不能重试绕过讨论门禁。');
        }
        final existingDiscussion =
            _requiresDiscussionForTask(task) ? discussionMarker.state : null;
        final currentScope = existingDiscussion == null
            ? task.userRequest
            : WorkDiscussionState.currentRequestScope(task);
        _removeQueuedTask(task);
        _waitingForResources.remove(taskId)?.cancellation.cancel();
        _folderWaiters.remove(taskId)?.cancel();
        _conversationReservations.remove(task.groupId);
        _taskLockPlans.remove(taskId);
        task
          ..status = AgentTaskStatus.queued
          ..resumeRequired = false
          ..plan = ''
          ..resultSummary = ''
          ..currentStep = 0
          ..completedOperations = <String>[]
          ..pendingToolRequestJson = ''
          ..queuedUserRequests = <String>[]
          ..contextSummary = ''
          ..lastError = ''
          ..startedAt = _clock()
          ..actionCount = 0
          ..softLimitReached = false
          ..executionStateJson = ''
          ..lastArtifactPaths = <String>[]
          ..eventLogIncomplete = false
          ..updatedAt = _clock();
        if (existingDiscussion != null) {
          if (!_discussionExecutorIsPinned(existingDiscussion)) {
            task
              ..characterId = ''
              ..assignedCharacterIds = <String>[];
          }
          task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
            '',
            _renewDiscussionForRequest(
              existingDiscussion,
              task.userRequest,
              activeScopeOverride: currentScope,
            ),
          );
        }
        final needsDiscussion = existingDiscussion != null &&
            !WorkDiscussionState.decodeExecutionState(task.executionStateJson)
                .state!
                .isExecutionReady;
        if (needsDiscussion) {
          // Do not enqueue a non-ready group task while the discussion runner
          // is being started. The scheduler could otherwise enter _start in
          // the same turn, race the first discussion callback, and reject a
          // legitimate state update as a concurrent execution.
          await _pauseForDiscussion(
            task,
            _discussionWaitingReason(existingDiscussion),
          );
        }
        await _save(task);
        await _markSnapshotStatus(task);
        if (needsDiscussion) {
          _maybeStartDiscussion(task);
          return;
        }
        _enqueueTask(task);
        await _record(
          task,
          WorkTaskEventKind.queued,
          '已请求从头开始执行',
          detail: '上次停止前未提交文件变更，已清空运行检查点。',
        );
        _maybeStartDiscussion(task);
        await _schedule();
        return;
      }

      final failure = task.workFailure;
      if (failure == null) {
        throw StateError('当前任务没有可重试的结构化失败。');
      }
      if (!failure.retryable) {
        throw StateError(failure.suggestedAction);
      }
      await _requeueFailedTask(
        task,
        failure,
        title: '已请求重试，继续最近安全检查点',
        nextStep: '已请求重试：${failure.suggestedAction}',
      );
    });
  }

  /// Re-queues a failed task from its last durable checkpoint.
  ///
  /// The caller must hold the coordinator lock and must already have verified
  /// that [failure] is retryable. Completed operations, artifact paths and the
  /// approval scope are deliberately left untouched, so a resumed run cannot
  /// replay a committed mutation. This is the single path shared by the user's
  /// retry and the coordinator's automatic resume, which is what keeps the two
  /// from drifting apart.
  Future<void> _requeueFailedTask(
    AgentTask task,
    WorkFailure failure, {
    required String title,
    required String nextStep,
  }) async {
    _removeQueuedTask(task);
    _waitingForResources.remove(task.id)?.cancellation.cancel();
    _folderWaiters.remove(task.id)?.cancel();
    _conversationReservations.remove(task.groupId);
    task
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false
      ..pendingToolRequestJson = ''
      ..updatedAt = _clock();
    _refreshTaskContext(
      task,
      nextStep: nextStep,
      extraErrors: [failure.reason],
    );
    await _save(task);
    _enqueueTask(task);
    await _record(
      task,
      WorkTaskEventKind.queued,
      title,
      detail: failure.reason,
    );
    await _schedule();
  }

  Future<void> _implRetryTask(String taskId) => retry(taskId);

  /// Switches the current task to a user-selected visual character and
  /// resumes the same durable task. Production runners implement the optional
  /// validator so a caller cannot bypass the panel's capability list.
  Future<void> _implSelectVisionModel(String taskId, String characterId) {
    return _serialize(() async {
      _ensureOpen();
      final normalized = characterId.trim();
      if (normalized.isEmpty) {
        throw ArgumentError.value(characterId, 'characterId');
      }
      final task = _requireWorkTask(taskId);
      if (!_requiresVisionModelSelection(task)) {
        throw StateError('当前任务不在等待视觉模型选择的状态。');
      }
      if (task.status != AgentTaskStatus.paused &&
          task.status != AgentTaskStatus.interrupted) {
        throw StateError('当前任务不在等待视觉模型选择的状态。');
      }
      if (_runner case final WorkTaskVisionModelValidator validator) {
        if (!validator.supportsVisionModelForTask(task, normalized)) {
          throw StateError('所选角色不是可用的视觉模型。');
        }
      } else {
        throw StateError('当前执行器无法验证视觉模型，已阻止继续。');
      }
      final execution = _decodeExecutionMap(task.executionStateJson)
        ..['visionModelRequired'] = false
        ..['visionModelCharacterId'] = normalized;
      // A visual model supplies capability; the elected executor retains
      // its identity, role prompt and skills throughout the task.
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..lastError = ''
        ..pendingToolRequestJson = ''
        ..executionStateJson = jsonEncode(execution)
        ..updatedAt = _clock();
      _conversationReservations.remove(task.groupId);
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '已选择视觉模型并继续任务'));
      await _schedule();
    });
  }

  /// Grants a fresh soft-limit budget only after the user chooses to continue.
  Future<void> _implContinueAfterSoftLimit(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (_running.containsKey(taskId)) {
        throw StateError('任务正在收尾，请稍后再点继续。');
      }
      if (!task.softLimitReached ||
          (task.status != AgentTaskStatus.paused &&
              task.status != AgentTaskStatus.interrupted)) {
        throw StateError('当前任务不在等待超限继续的状态。');
      }
      // A soft-limit action is another explicit continuation boundary. It
      // must not be able to bypass discussion when a legacy or malformed
      // group checkpoint has no typed discussion state yet.
      if (await _ensureDiscussionBeforeUserContinuation(
        task,
        resetSoftLimit: true,
      )) {
        return;
      }
      // A resumed group task may spend time in its discussion runner before
      // WorkAgentLoop gets a chance to clear the prior soft-limit failure.
      // Remove that stale action marker now so the panel does not offer an
      // invalid second continuation while the discussion gate is still open.
      WorkFailure.clearFromTask(task);
      task
        ..status = AgentTaskStatus.queued
        ..actionCount = 0
        ..startedAt = _clock()
        ..softLimitReached = false
        ..resumeRequired = false
        ..lastError = ''
        ..executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        )
        ..updatedAt = _clock();
      // A paused soft-limit task still owns its conversation reservation so a
      // later request cannot bypass the checkpoint. Continuing is the explicit
      // handoff that releases that reservation and makes the queued task
      // visible to the scheduler again.
      _conversationReservations.remove(task.groupId);
      await _save(task);
      _enqueueTask(task, prioritize: true);
      unawaited(
        _record(task, WorkTaskEventKind.queued, '用户已继续超限任务'),
      );
      await _schedule();
    });
  }

  /// Reloads durable task state without invoking any runner automatically.
  Future<void> _implRestore() {
    return _serialize(() async {
      _ensureOpen();
      for (final task in _allWorkTasks()) {
        final needsCheckpointReview =
            workExecutionCheckpointRequiresReview(task.executionStateJson);
        if (needsCheckpointReview && !task.isTerminal) {
          // Normalize an unknown checkpoint once on restore. The review marker
          // remains until an explicit user continuation, while any typed
          // discussion state and known folder blockers stay visible.
          await _pauseForCheckpointReview(task);
        }
        var discussion = WorkDiscussionState.decodeExecutionState(
          task.executionStateJson,
        );
        var migratedLegacy = false;
        if (!discussion.present &&
            _requiresDiscussionForTask(task) &&
            _needsLegacyDiscussionRecovery(task)) {
          migratedLegacy = true;
          final migrated = _legacyDiscussionState(task);
          task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
            task.executionStateJson,
            migrated,
          );
          discussion = WorkDiscussionState.decodeExecutionState(
            task.executionStateJson,
          );
          // Keep the original failure as the primary diagnostic. The
          // discussion gate is an additional recovery requirement and must
          // not erase evidence of a failed/partial operation.
          final previousError = task.lastError.trim();
          const legacyDiscussionReason = '旧任务需要补充群讨论后才能继续。';
          _refreshTaskContext(
            task,
            nextStep: legacyDiscussionReason,
            extraErrors: <String>[
              legacyDiscussionReason,
              if (previousError.isNotEmpty) previousError,
            ],
          );
          task
            ..status = AgentTaskStatus.paused
            ..resumeRequired = false
            ..lastError =
                previousError.isEmpty ? legacyDiscussionReason : previousError
            ..updatedAt = _clock();
          await _save(task);
          await _markSnapshotStatus(task);
          _conversationReservations.add(task.groupId);
        }
        if (discussion.present &&
            _requiresDiscussionForTask(task) &&
            !task.isTerminal) {
          final state = discussion.state;
          // A waiting discussion is a durable conversation reservation, not a
          // runnable checkpoint. Restore it without reacquiring file locks or
          // replaying any old model/tool command.
          if (!migratedLegacy &&
              (state == null ||
                  state.conversationId != task.groupId ||
                  !state.isExecutionReady)) {
            _removeQueuedTask(task);
            _conversationReservations.add(task.groupId);
            task
              ..status = AgentTaskStatus.paused
              ..resumeRequired = false
              ..lastError = state == null
                  ? '讨论状态无效，等待重新确定讨论结果。'
                  : _discussionWaitingReason(state)
              ..updatedAt = _clock();
            _refreshTaskContext(
              task,
              nextStep: task.lastError,
              extraErrors: [task.lastError],
            );
            await _save(task);
          }
          if (state != null &&
              state.conversationId == task.groupId &&
              !state.isExecutionReady) {
            _maybeStartDiscussion(task);
          }
        }
        // A process restart invalidates every in-memory runner and lock. Only
        // an explicit user continuation may re-plan and reacquire resources.
        if (!_running.containsKey(task.id) &&
            !_waitingForResources.containsKey(task.id) &&
            !task.isTerminal &&
            task.status != AgentTaskStatus.paused &&
            task.status != AgentTaskStatus.interrupted) {
          _applyFailure(
            task,
            WorkFailure.fromSignalsForUserAction(
              '应用已关闭，请由用户手动继续任务。',
              completedContent: _completedContentForTask(task),
            ),
            status: AgentTaskStatus.interrupted,
            clearPendingTool: false,
          );
          await _save(task);
        }
        if ((task.status == AgentTaskStatus.paused ||
                task.status == AgentTaskStatus.interrupted) &&
            (_isFollowUpClarification(task) ||
                WorkTaskClarification.isPending(task))) {
          // An unanswered target question still owns this conversation. A
          // second task must not bypass it while the user is deciding which
          // artifact the queued revision may overwrite.
          _conversationReservations.add(task.groupId);
        }
        // A restart leaves no in-memory queue or runner ownership. Every
        // non-terminal user-waiting checkpoint must still retain the
        // conversation reservation until the user explicitly repairs,
        // approves, resumes, or stops it; otherwise a new task could bypass
        // an older approval/installation/authorization blocker in the same
        // group while the original task is only visible in the overlay.
        if (!task.isTerminal &&
            (task.status == AgentTaskStatus.paused ||
                task.status == AgentTaskStatus.interrupted ||
                task.status == AgentTaskStatus.waitingForApproval)) {
          _conversationReservations.add(task.groupId);
        }
        // Re-project existing checkpoints after an app restart. The message
        // bridge is idempotent by task/blocker/version, so this repairs a
        // transient write failure without duplicating a prior reminder.
        await _notifyUserAction(task);
        _publish(task);
      }
    });
  }

  WorkDiscussionState _legacyDiscussionState(AgentTask task) {
    final executor = task.characterId.trim();
    final participants = <String>{
      ...task.assignedCharacterIds,
      if (executor.isNotEmpty) executor,
    };
    return WorkDiscussionState.initial(
      conversationId: task.groupId,
      requestRevision: 1,
      executorId: executor.isEmpty ? null : executor,
      candidateCharacterIds: participants,
      participantCharacterIds: participants,
      deliverableContract: <String, dynamic>{
        'deliverableType': 'legacy',
        'format': 'unspecified',
        'location': 'unspecified',
        'contentScope': task.userRequest,
        'explicitExecutorId': executor.isEmpty ? null : executor,
        'revisionTarget': '',
        'requestRevision': 1,
      },
      blockers: const ['legacyDiscussionRequired'],
    );
  }

  /// A completed or explicitly cancelled legacy task is already a durable
  /// outcome and must not be rewritten as if it had never discussed. Failed
  /// and partially-completed tasks, however, still have unfinished work and
  /// need the current group-discussion gate before a retry or follow-up can
  /// run. Keep the old task's failure, operation and approval fields intact;
  /// only add the missing discussion checkpoint and pause it for the user.
  bool _needsLegacyDiscussionRecovery(AgentTask task) =>
      !task.isTerminal ||
      task.status == AgentTaskStatus.failed ||
      task.status == AgentTaskStatus.partiallyCompleted;
}
