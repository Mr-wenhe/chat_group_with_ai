part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorWorkspaceQueue on WorkTaskCoordinator {
  Future<bool> _ensureFolderGrant(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
      return false;
    }
    final grantService = _folderGrantService;
    if (grantService == null) {
      if (!_requireFolderGrant) return true;
      final failure = WorkFailure.fromToolFailure(
        code: 'authorizationLost',
        message: '工作目录授权服务不可用，请检查应用设置后重试。',
        completedContent: _completedContentForTask(task),
      );
      _applyFailure(
        task,
        failure,
        status: AgentTaskStatus.paused,
        clearPendingTool: false,
      );
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.paused,
        '工作目录授权不可用',
        detail: failure.technicalDetail,
      );
      return false;
    }
    try {
      await grantService.load();
    } on Object catch (error) {
      if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
        return false;
      }
      final failure = WorkFailure.fromError(
        error,
        scope: 'authorization',
        completedContent: _completedContentForTask(task),
      );
      _applyFailure(
        task,
        failure.type == WorkFailureType.internal
            ? WorkFailure.fromToolFailure(
                code: 'authorizationLost',
                message: '工作目录授权校验失败，请重新授权。',
                completedContent: _completedContentForTask(task),
              )
            : failure,
        status: AgentTaskStatus.paused,
        clearPendingTool: false,
      );
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.paused,
        '工作目录授权校验失败',
        detail:
            task.workFailure?.technicalDetail ?? sanitizeWorkTaskError(error),
      );
      return false;
    }
    if (_disposed ||
        _dataClearInProgress ||
        cancellation.isCancelled ||
        task.isTerminal) {
      return false;
    }
    final requestedPath = _requestedFolderPath(task);
    final requiresWritable = _requiresWritableFolder(task);
    if (requestedPath == null &&
        (requiresWritable
            ? grantService.hasConfirmedWritableGrant()
            : grantService.hasConfirmedAvailableGrant())) {
      if (requiresWritable) {
        if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
          return false;
        }
        // Keep the workspace capability requirement for the runner even when
        // an already-authorized writable root satisfies this task. A prior
        // read-only conversation workspace must still be replaced before a
        // write is attempted.
        task.executionStateJson = _withWritableRequirementMarker(
          task.executionStateJson,
        );
        await _save(task);
      }
      return true;
    }
    if (requestedPath != null &&
        (requiresWritable
            ? await grantService.isPathWritableResolved(requestedPath)
            : await grantService.isPathAuthorizedResolved(requestedPath))) {
      if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
        return false;
      }
      final current = _taskBox.get(task.id);
      if (current == null || current.isTerminal) return false;
      if (requiresWritable) {
        current.executionStateJson = _withWritableRequirementMarker(
          current.executionStateJson,
        );
      }
      current.executionStateJson = _withoutFolderRequest(
        current.executionStateJson,
      );
      await _save(current);
      return true;
    }

    if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
      return false;
    }
    task
      ..status = AgentTaskStatus.waitingForApproval
      ..resumeRequired = false
      // Keep a durable UI marker even when the first request has no concrete
      // path yet. The execution panel must expose the folder picker instead
      // of rendering an approval/continue action that cannot succeed.
      ..executionStateJson = _withFolderGrantPending(
        task.executionStateJson,
        requestedPath,
        requiresWritable: requiresWritable,
      )
      ..updatedAt = _clock();
    await _save(task);
    await _record(
      task,
      WorkTaskEventKind.approvalRequired,
      '需要授权工作目录',
      detail: requestedPath == null
          ? '首次执行工作模式前，需要选择一个 App 级工作目录。'
          : '请求路径未被现有授权覆盖，需要选择其所在目录。',
    );
    // The native picker is intentionally outside the serialized coordinator
    // queue. Capture the exact durable marker before awaiting it so a follow-
    // up, retry, or cancellation cannot let the late result overwrite a
    // newer task checkpoint.
    final expectedFolderActionVersion =
        WorkTaskUserAction.versionFor(task, 'folderAuthorization');
    if (expectedFolderActionVersion == 0) return false;
    if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
      return false;
    }

    final requestResult = await _requestFolder(
      grantService,
      task: task,
      requestedPath: requestedPath,
    );
    if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
      return false;
    }
    final currentTask = _taskBox.get(task.id);
    if (currentTask == null ||
        !_isCurrentFolderGrantCheckpoint(
          currentTask,
          expectedFolderActionVersion,
        )) {
      // A newer request owns this task now.  The grant itself remains in the
      // app-level store, but it must not revive or rewrite that newer scope.
      return false;
    }
    if (requestResult.granted) {
      // Rebinding can yield to a stop/revision. Re-read the durable task after
      // it completes and only then commit the planning transition.
      await _rebindWorkspaceAfterGrant(currentTask, requestResult.grant);
      if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
        return false;
      }
      final latestTask = _taskBox.get(task.id);
      if (latestTask == null ||
          !_isCurrentFolderGrantCheckpoint(
            latestTask,
            expectedFolderActionVersion,
          )) {
        return false;
      }
      latestTask
        ..status = AgentTaskStatus.planning
        ..resumeRequired = false
        ..lastError = ''
        ..executionStateJson = _withoutFolderRequest(
          latestTask.executionStateJson,
        )
        ..updatedAt = _clock();
      await _save(latestTask);
      return true;
    }

    // The execution panel can finish a second, explicit picker request while
    // this initial request is unwinding from a cancellation.  In that case
    // the panel has already persisted a queued task and removed the durable
    // folder-pending marker.  Do not let this stale cancellation overwrite
    // the newly authorized state with a paused error; the panel-owned queue
    // will start the task with the confirmed grant.
    final currentState = _decodeExecutionMap(currentTask.executionStateJson);
    if (currentTask.status == AgentTaskStatus.queued &&
        currentState['folderGrantPending'] != true &&
        _requestedFolderPath(currentTask) == null) {
      return false;
    }

    final reason =
        requestResult.reason.isEmpty ? '未完成工作目录授权。' : requestResult.reason;
    final failure = WorkFailure.fromToolFailure(
      code: 'authorizationLost',
      message: reason,
      completedContent: _completedContentForTask(currentTask),
    );
    _applyFailure(
      currentTask,
      failure,
      status: AgentTaskStatus.paused,
      clearPendingTool: false,
    );
    await _save(currentTask);
    await _record(
      currentTask,
      WorkTaskEventKind.paused,
      '等待工作目录授权',
      detail: reason,
    );
    return false;
  }

  bool _isCurrentFolderGrantCheckpoint(AgentTask task, int version) {
    if (task.isTerminal ||
        WorkTaskUserAction.versionFor(task, 'folderAuthorization') != version) {
      return false;
    }
    final metadata = _decodeExecutionMap(task.executionStateJson);
    return metadata['folderGrantPending'] == true;
  }

  Future<void> _rebindWorkspaceAfterGrant(
    AgentTask task,
    WorkFolderGrant? grant,
  ) async {
    final path = grant?.path.trim() ?? '';
    final runner = _runner;
    if (path.isEmpty || runner is! WorkTaskWorkspaceRebinder) return;
    await (runner as WorkTaskWorkspaceRebinder).rebindWorkspace(task, path);
  }

  Future<WorkFolderRequestResult> _requestFolder(
    WorkFolderGrantService grantService, {
    required AgentTask task,
    String? requestedPath,
  }) async {
    final existing = _folderRequest;
    if (existing != null) {
      // A native picker is process-global, but its result is not necessarily
      // suitable for every waiting task.  One task may be asking for a
      // read-only root while another is waiting for a different writable
      // path.  Reuse the in-flight result only when it actually covers this
      // request; otherwise open a second picker after the first one closes.
      final sharedResult = await existing;
      if (!sharedResult.granted) return sharedResult;
      final requested = requestedPath?.trim();
      final requiresWritable = _requiresWritableFolder(task);
      final grant = sharedResult.grant;
      final covers = requested == null || requested.isEmpty
          ? grant != null && (!requiresWritable || grant.writable)
          : requiresWritable
              ? await grantService.isPathWritableResolved(requested)
              : await grantService.isPathAuthorizedResolved(requested);
      if (covers) return sharedResult;
      // The selected directory belongs to another task's request.  Falling
      // through is intentional: the picker future has completed, so this is
      // no longer a concurrent native dialog.
    }
    final request = _folderPicker == null
        ? Future<WorkFolderRequestResult>.value(
            const WorkFolderRequestResult(
              status: WorkFolderRequestStatus.unavailable,
              reason: '当前没有可用的目录选择器。',
            ),
          )
        : grantService.requestFolder(
            picker: _folderPicker,
            requestedPath: requestedPath,
            forcePicker: requestedPath != null,
            requireWritable: _requiresWritableFolder(task),
            consent: _folderGrantConsent,
          );
    _folderRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_folderRequest, request)) {
        _folderRequest = null;
      }
    }
  }

  void _enqueueTask(AgentTask task, {bool prioritize = false}) {
    final queue = _conversationQueues.putIfAbsent(task.groupId, Queue.new);
    if (queue.contains(task.id)) queue.remove(task.id);
    if (prioritize) {
      queue.addFirst(task.id);
    } else {
      queue.addLast(task.id);
    }
    if (!_hasRunningConversation(task.groupId)) {
      _makeConversationReady(task.groupId);
    }
  }

  void _removeQueuedTask(AgentTask task) {
    final queue = _conversationQueues[task.groupId];
    if (queue == null) return;
    queue.remove(task.id);
    if (queue.isEmpty) _conversationQueues.remove(task.groupId);
  }

  void _makeConversationReady(String conversationId) {
    final queue = _conversationQueues[conversationId];
    if (queue == null ||
        queue.isEmpty ||
        _hasRunningConversation(conversationId)) {
      return;
    }
    if (_readyConversationIds.add(conversationId)) {
      _readyConversations.addLast(conversationId);
    }
  }

  bool _hasRunningConversation(String conversationId) =>
      _conversationReservations.contains(conversationId) ||
      _running.values.any((running) => running.task.groupId == conversationId);

  bool _hasPendingDiscussionForConversation(String conversationId) {
    return _taskBox.values.any((candidate) {
      if (!candidate.workModeTask ||
          candidate.groupId != conversationId ||
          candidate.isTerminal) {
        return false;
      }
      final discussion = WorkDiscussionState.decodeExecutionState(
        candidate.executionStateJson,
      );
      return discussion.present &&
          (discussion.state == null || !discussion.state!.isExecutionReady);
    });
  }

  Future<void> _waitForSlot() {
    if (_disposed ||
        _running.length < WorkTaskCoordinator.maximumConcurrentTasks) {
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _slotWaiters.addLast(waiter);
    return waiter.future;
  }

  void _notifySlotAvailable() {
    if (!_disposed &&
        _running.length >= WorkTaskCoordinator.maximumConcurrentTasks) {
      return;
    }
    while (_slotWaiters.isNotEmpty) {
      final waiter = _slotWaiters.removeFirst();
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  String _safeLockPath(String path) => WorkFolderGrantService.displayNameFor(
        path,
        isWindows: _resourceLockManager.isWindows,
      );

  AgentTask _requireWorkTask(String taskId) {
    final task = _taskBox.get(taskId);
    if (task == null || !task.workModeTask) {
      throw StateError('未找到工作模式任务：$taskId');
    }
    return task;
  }

  Future<void> _save(AgentTask task) async {
    await _taskBox.put(task.id, task);
    _publish(task);
    await _notifyUserAction(task);
  }

  Future<void> _notifyUserAction(AgentTask task) async {
    final notifier = _userActionNotifier;
    if (notifier == null) return;
    try {
      await notifier(task);
    } on Object {
      // A chat reminder is a best-effort projection. The Hive task and event
      // checkpoint remain authoritative when message persistence is
      // temporarily unavailable; the next task save or restore retries it.
    }
  }

  Future<void> _reportFailure(AgentTask task, WorkFailure? failure) async {
    if (failure == null) return;
    final reporter = _runner;
    if (reporter is! WorkTaskFailureReporter) return;
    try {
      await (reporter as WorkTaskFailureReporter).reportFailure(task, failure);
    } on Object {
      // The task panel and durable failure checkpoint remain authoritative if
      // chat persistence is temporarily unavailable. Never turn a best-effort
      // notification into a second task failure.
    }
  }

  void _applyFailure(
    AgentTask task,
    WorkFailure failure, {
    AgentTaskStatus status = AgentTaskStatus.failed,
    bool clearPendingTool = true,
  }) {
    task
      ..status = status
      ..resumeRequired = status == AgentTaskStatus.failed
          ? failure.retryable || task.completedOperations.isNotEmpty
          : true
      ..lastError = failure.reason
      ..updatedAt = _clock();
    if (clearPendingTool) task.pendingToolRequestJson = '';
    WorkFailure.persistOnTask(task, failure);
    _refreshTaskContext(
      task,
      nextStep: failure.suggestedAction,
      extraErrors: [failure.reason],
    );
  }

  List<String> _completedContentForTask(AgentTask task) {
    final values = <String>[
      ...task.completedOperations,
      if (task.resultSummary.trim().isNotEmpty) task.resultSummary,
      ...task.lastArtifactPaths.map((path) => '产物：$path'),
    ];
    final seen = <String>{};
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && seen.add(value))
        .take(32)
        .toList(growable: false);
  }
}
