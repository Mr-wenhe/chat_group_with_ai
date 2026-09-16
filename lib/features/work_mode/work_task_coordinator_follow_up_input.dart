part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorFollowUpInput on WorkTaskCoordinator {
  /// A runner may publish a terminal-looking checkpoint just before its
  /// coordinator finalizer releases the slot.  Callers use this predicate to
  /// keep those last-microtask inputs in the execution FIFO.
  bool _implIsTaskInFlight(String taskId) =>
      _running.containsKey(taskId) ||
      _startingTaskIds.contains(taskId) ||
      _discussionRuns.containsKey(taskId) ||
      _waitingForResources.containsKey(taskId);

  /// Exposes the single follow-up classifier to the input router and the
  /// coordinator.  Keeping this decision at the durable boundary prevents a
  /// widget from accidentally routing a completed revision as a new task (or
  /// applying a different collision/path rule than FIFO promotion).
  WorkFollowUpDecision _implFollowUpDecisionForTask(
    String taskId,
    String request,
  ) {
    final task = _requireWorkTask(taskId);
    return _followUpPolicy.resolve(
      request: request,
      lastArtifactPaths: _followUpArtifactPaths(task),
      failedArtifactPath: task.workFailure?.failureTargetPath,
    );
  }

  /// Tells the chat input whether a completed group checkpoint must be routed
  /// as a new task.  The boundary conditions live here with the follow-up
  /// classifier; widgets only use the result to choose the existing route
  /// entry point.
  bool _implShouldRouteNewTaskForFollowUp(String taskId, String request) {
    final task = _requireWorkTask(taskId);
    final decision = followUpDecisionForTask(taskId, request);
    return task.isTerminal &&
        !isTaskInFlight(task.id) &&
        task.queuedUserRequests.isEmpty &&
        _newArtifactRequiresFreshTask(task, decision);
  }

  bool _newArtifactRequiresFreshTask(
    AgentTask task,
    WorkFollowUpDecision decision, {
    bool answeringModelClarification = false,
  }) {
    return _requiresDiscussionForTask(task) &&
        decision.kind == WorkFollowUpKind.newArtifact &&
        !answeringModelClarification;
  }

  /// Adds user input to the same durable task instead of replacing its run.
  Future<void> _implEnqueueFollowUp(
    String taskId,
    String request, {
    String? attachmentMessageId,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final normalized = request.trim();
      if (normalized.isEmpty) return;
      final task = _requireWorkTask(taskId);
      if (task.status == AgentTaskStatus.cancelled) {
        throw StateError('已停止的任务不能继续追问，请创建新的工作任务。');
      }
      // A command/test/build proposal pauses with an explicit authorization
      // marker rather than a replayable tool checkpoint.  Treat the user's
      // concrete validation request as an authorization/re-plan for this
      // same durable task; placing it in the ordinary follow-up FIFO would
      // leave the marker in place and make both “继续” and the follow-up
      // loop forever.
      if (_requiresExplicitCommandRequest(task) &&
          (task.status == AgentTaskStatus.paused ||
              task.status == AgentTaskStatus.interrupted) &&
          isExplicitWorkValidationRequest(normalized)) {
        await _authorizeExplicitValidation(task, normalized);
        await _schedule();
        return;
      }
      final answeringFollowUpClarification =
          task.status == AgentTaskStatus.paused &&
              _isFollowUpClarification(task) &&
              task.queuedUserRequests.isNotEmpty;
      final answeringModelClarification =
          (task.status == AgentTaskStatus.paused ||
                  task.status == AgentTaskStatus.interrupted) &&
              WorkTaskClarification.isPending(task);
      final answeringClarification =
          answeringFollowUpClarification || answeringModelClarification;
      final attachmentId = attachmentMessageId?.trim();
      final discussionMarker =
          WorkDiscussionState.decodeExecutionState(task.executionStateJson);
      // Classify at the coordinator boundary so the same path/collision rule
      // is used by the input router, discussion revisions, and FIFO promotion.
      final followUpDecision = _followUpPolicy.resolve(
        request: normalized,
        lastArtifactPaths: _followUpArtifactPaths(task),
        failedArtifactPath: task.workFailure?.failureTargetPath,
      );
      final approvalScopeChanged =
          task.status == AgentTaskStatus.waitingForApproval &&
              _followUpChangesApprovalScope(followUpDecision);
      if (approvalScopeChanged) {
        // A checkpoint approval is bound to one concrete operation.  A path,
        // artifact, or target revision must invalidate that decision before
        // the new request can be discussed or queued; the old grant is never
        // widened to cover the supplement.
        _folderWaiters.remove(task.id)?.cancel();
        task
          ..pendingToolRequestJson = ''
          ..executionStateJson = _withoutApprovalCheckpoint(
            task.executionStateJson,
          )
          ..status = AgentTaskStatus.paused
          ..resumeRequired = false
          ..lastError = '操作范围已变化，旧审批已失效，等待重新确认。'
          ..updatedAt = _clock();
        _conversationReservations.add(task.groupId);
      }
      if (_requiresDiscussionForTask(task) &&
          discussionMarker.present &&
          (discussionMarker.state == null ||
              discussionMarker.state!.conversationId != task.groupId)) {
        await _pauseForDiscussion(
          task,
          '讨论状态无效或属于另一个群组，已阻止追问绕过讨论门禁。',
        );
        await _save(task);
        await _markSnapshotStatus(task);
        return;
      }
      final pendingDiscussion = _requiresDiscussionForTask(task) &&
          !answeringClarification &&
          discussionMarker.present &&
          discussionMarker.state != null &&
          !discussionMarker.state!.isExecutionReady;
      final readyDiscussionRevision = _requiresDiscussionForTask(task) &&
          !answeringClarification &&
          discussionMarker.present &&
          discussionMarker.state != null &&
          discussionMarker.state!.isExecutionReady &&
          !_running.containsKey(task.id) &&
          !_startingTaskIds.contains(task.id) &&
          (followUpDecision.isRevision || approvalScopeChanged);
      if (pendingDiscussion || readyDiscussionRevision) {
        // A new request revision invalidates every in-flight model conclusion.
        // Cancel the old discussion before replacing the shared Hive object;
        // its completion callback will start the renewed revision after the
        // old run has drained.
        _discussionCancellations[task.id]?.cancel();
        final currentRequest = task.userRequest.trim();
        final continuationLine = '用户补充要求：$normalized';
        // Retrying the same in-panel discussion action must not keep growing
        // the durable prompt.  Preserve the first occurrence (so the user's
        // intent remains auditable) and discard only identical duplicates.
        var seenContinuation = false;
        final canonicalLines = currentRequest.split('\n').where((line) {
          if (line.trim() != continuationLine) return true;
          if (seenContinuation) return false;
          seenContinuation = true;
          return true;
        });
        final canonicalRequest = canonicalLines.join('\n').trim();
        final mergedRequest = canonicalRequest.isEmpty
            ? normalized
            : seenContinuation
                ? canonicalRequest
                : '$canonicalRequest\n$continuationLine';
        if (!_discussionExecutorIsPinned(discussionMarker.state!)) {
          // A group election is scoped to the previous request revision. Clear
          // the task-level lease before reopening it so a new qualified role
          // can be elected without tripping the stale identity gate.
          task
            ..characterId = ''
            ..assignedCharacterIds = <String>[];
        }
        task
          ..userRequest = mergedRequest
          ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
            task.executionStateJson,
            _renewDiscussionForRequest(
              discussionMarker.state!,
              mergedRequest,
              decision: followUpDecision,
              contractRequest: normalized,
            ),
          )
          ..updatedAt = _clock();
        task.executionStateJson = _withDiscussionAttachmentMetadata(
          task.executionStateJson,
          attachmentId,
        );
        task.executionStateJson = _withFollowUpDecision(
          task.executionStateJson,
          followUpDecision,
        );
        await _pauseForDiscussion(
          task,
          pendingDiscussion
              ? '已纳入最新补充要求，等待群讨论重新确认方案。'
              : '执行尚未开始，补充要求已触发新一轮群讨论确认。',
        );
        await _save(task);
        // The old run may already have drained before this follow-up reaches
        // the serialized mutation. In that case there is no completion
        // callback left to restart the renewed revision, so schedule it here;
        // an active run remains responsible for its own post-cancellation
        // restart.
        if (!_discussionRuns.containsKey(task.id)) {
          _maybeStartDiscussion(task);
        }
        return;
      }
      final queuedAttachmentIds = _queuedAttachmentMessageIds(
        task.executionStateJson,
        expectedLength: task.queuedUserRequests.length,
      );
      if (answeringFollowUpClarification) {
        task.queuedUserRequests = <String>[
          '${task.queuedUserRequests.first}\n用户明确目标：$normalized',
          ...task.queuedUserRequests.skip(1),
        ];
      } else if (answeringModelClarification) {
        // The clarification answer belongs to the current request, but later
        // inputs may already be waiting in the durable FIFO. Put the answer at
        // the head so promotion can merge it with [task.userRequest] without
        // discarding those later requests.
        task.queuedUserRequests = <String>[
          normalized,
          ...task.queuedUserRequests,
        ];
      } else {
        task.queuedUserRequests = <String>[
          ...task.queuedUserRequests,
          normalized
        ];
      }
      if (answeringFollowUpClarification) {
        if (attachmentId != null && attachmentId.isNotEmpty) {
          queuedAttachmentIds[0] = attachmentId;
        }
      } else if (answeringModelClarification) {
        queuedAttachmentIds.insert(
          0,
          attachmentId == null || attachmentId.isEmpty ? '' : attachmentId,
        );
      } else {
        queuedAttachmentIds.add(
          attachmentId == null || attachmentId.isEmpty ? '' : attachmentId,
        );
      }
      task.executionStateJson = _withQueuedAttachmentMessageIds(
        task.executionStateJson,
        queuedAttachmentIds,
      );
      _refreshTaskContext(
        task,
        nextStep: '当前任务完成后处理第 ${task.queuedUserRequests.length} 条追问。',
      );

      // A completed/failed/partially-completed task is a durable conversation
      // checkpoint. Promote its first follow-up immediately so the same task
      // id, artifacts, completed operations and context summary are reused.
      // Active tasks keep the queue and are promoted only after their current
      // run releases the slot.
      if ((task.isTerminal && !isTaskInFlight(task.id)) ||
          answeringClarification) {
        await _promoteQueuedFollowUp(
          task,
          resetRunBudget: true,
          allowPausedClarification: answeringClarification,
        );
        await _schedule();
        return;
      }
      await _save(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '已排队新的追问'));
    });
  }

  Future<void> _authorizeExplicitValidation(
    AgentTask task,
    String request,
  ) async {
    final original = task.userRequest.trim();
    final mergedRequest = original.isEmpty || original == request
        ? request
        : '$original\n用户明确要求：$request';
    final execution = _decodeExecutionMap(
      _withoutApprovalCheckpoint(task.executionStateJson),
    )..remove('explicitCommandRequestRequired');
    task
      ..userRequest = mergedRequest
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false
      ..pendingToolRequestJson = ''
      ..lastError = ''
      ..executionStateJson = execution.isEmpty ? '' : jsonEncode(execution)
      ..updatedAt = _clock();
    _conversationReservations.remove(task.groupId);
    await _save(task);
    _enqueueTask(task);
    unawaited(
      _record(
        task,
        WorkTaskEventKind.queued,
        '用户已明确授权测试、构建或分析，继续原任务',
        detail: request,
      ),
    );
  }

  /// Persists a tool-approval checkpoint without requiring a chat page to
  /// retain the pending request in memory.
  Future<void> _implPauseForApproval(
    String taskId, {
    required String pendingToolRequestJson,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.isTerminal) {
        throw StateError('终态任务不能再等待工具审批。');
      }
      task
        ..status = AgentTaskStatus.waitingForApproval
        // Keep only a display-safe checkpoint in Hive. The full request is
        // retained by the in-process runner while the approval dialog is open.
        ..pendingToolRequestJson =
            safeToolRequestCheckpointJson(pendingToolRequestJson)
        ..updatedAt = _clock();
      await _save(task);
      await _markSnapshotStatus(task);
      unawaited(
        _record(task, WorkTaskEventKind.approvalRequired, '等待用户批准操作'),
      );
    });
  }

  /// Records that the app-level approval prompt has been presented for this
  /// checkpoint. The marker prevents route rebuilds or app restarts from
  /// repeatedly interrupting the user while the task panel remains available.
  Future<bool> _implMarkApprovalPromptShown(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.waitingForApproval ||
          task.pendingToolRequestJson.trim().isEmpty) {
        return false;
      }
      final metadata = _decodeExecutionMap(task.executionStateJson);
      if (metadata['approvalPromptShown'] == true) return false;
      metadata['approvalPromptShown'] = true;
      task
        ..executionStateJson = jsonEncode(metadata)
        ..updatedAt = _clock();
      await _save(task);
      return true;
    });
  }

  /// Clears a prompt marker when the host failed before presenting the dialog.
  ///
  /// Presentation failures are recoverable (for example, a route can be
  /// rebuilt between the post-frame callback and [showDialog]). Keeping the
  /// marker in that case would suppress every later automatic retry and leave
  /// only the manual task panel as a workaround.
  Future<void> _implResetApprovalPromptShown(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.waitingForApproval ||
          task.pendingToolRequestJson.trim().isEmpty) {
        return;
      }
      final metadata = _decodeExecutionMap(task.executionStateJson);
      if (metadata.remove('approvalPromptShown') == null) return;
      task
        ..executionStateJson = metadata.isEmpty ? '' : jsonEncode(metadata)
        ..updatedAt = _clock();
      await _save(task);
    });
  }

  /// Approves the pending tool request and queues the same durable task.
  ///
  /// The decision is stored in the task checkpoint so a runner can consume it
  /// after the current process has released its slot, without relying on a
  /// chat-page object or an in-memory dialog callback.
  Future<void> _implApprove(String taskId, {int? expectedActionVersion}) =>
      _resolveApproval(
        taskId,
        WorkChangeApprovalDecision.approved.wireName,
        expectedActionVersion: expectedActionVersion,
      );

  /// Rejects the pending tool request and queues the same durable task. The
  /// runner receives a structured rejection and may continue with safe work.
  Future<void> _implReject(String taskId, {int? expectedActionVersion}) =>
      _resolveApproval(
        taskId,
        WorkChangeApprovalDecision.rejected.wireName,
        expectedActionVersion: expectedActionVersion,
      );

  /// Approves a mutation after the user has explicitly accepted that this
  /// operation cannot be undone. This decision is durable and is never
  /// inferred from the ordinary-write setting.
  Future<void> _implApproveWithoutUndo(String taskId,
          {int? expectedActionVersion}) =>
      _resolveApproval(
        taskId,
        WorkChangeApprovalDecision.approvedWithoutUndo.wireName,
        expectedActionVersion: expectedActionVersion,
      );

  /// Explicitly named aliases for UI integrations that prefer task wording.
  Future<void> _implApproveTask(String taskId, {int? expectedActionVersion}) =>
      approve(taskId, expectedActionVersion: expectedActionVersion);

  Future<void> _implRejectTask(String taskId, {int? expectedActionVersion}) =>
      reject(taskId, expectedActionVersion: expectedActionVersion);

  Future<void> _implApproveTaskWithoutUndo(
    String taskId, {
    int? expectedActionVersion,
  }) =>
      approveWithoutUndo(taskId, expectedActionVersion: expectedActionVersion);

  /// Runs a trusted package-manager suggestion only after the user chooses the
  /// install action in the execution panel. The original pending tool request
  /// remains intact so a successful install resumes the same loop turn.
  Future<void> _implInstallMissingTool(
    String taskId, {
    int? expectedActionVersion,
  }) {
    // The panel and the chat reminder can invoke this same action in the same
    // event loop. Share one future per task/checkpoint so the trusted
    // installer cannot be started twice, while a newer checkpoint never
    // piggybacks on an older installation request.
    final runKey = _userActionRunKey(
      taskId,
      'toolMissing',
      expectedActionVersion,
    );
    final existing = _installRuns[runKey];
    if (existing != null) return existing;
    late final Future<void> tracked;
    final operation = _installMissingTool(
      taskId,
      expectedActionVersion: expectedActionVersion,
    );
    tracked = operation.whenComplete(() {
      if (identical(_installRuns[runKey], tracked)) {
        _installRuns.remove(runKey);
      }
    });
    _installRuns[runKey] = tracked;
    return tracked;
  }
}
