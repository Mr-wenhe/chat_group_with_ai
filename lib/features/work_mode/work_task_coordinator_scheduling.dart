part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorScheduling on WorkTaskCoordinator {
  AgentTask? _takeNextTask() {
    while (_readyConversations.isNotEmpty) {
      final conversationId = _readyConversations.removeFirst();
      _readyConversationIds.remove(conversationId);
      if (_hasRunningConversation(conversationId)) continue;
      final queue = _conversationQueues[conversationId];
      if (queue == null) continue;
      while (queue.isNotEmpty) {
        final taskId = queue.removeFirst();
        final task = _taskBox.get(taskId);
        if (task == null ||
            !task.workModeTask ||
            task.status != AgentTaskStatus.queued) {
          continue;
        }
        if (queue.isEmpty) _conversationQueues.remove(conversationId);
        return task;
      }
      _conversationQueues.remove(conversationId);
    }
    return null;
  }

  Future<void> _start(AgentTask task) async {
    if (_disposed ||
        _dataClearInProgress ||
        task.isTerminal ||
        task.status != AgentTaskStatus.queued) {
      return;
    }
    if (workExecutionCheckpointRequiresReview(task.executionStateJson)) {
      await _pauseForCheckpointReview(task);
      await _schedule();
      return;
    }
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    if (discussion.present) {
      final discussionError = await _discussionGateFailure(task);
      // Folder-grant coordinators start outside the serialized submit chain.
      // A user stop (or another recovery action) may therefore change the
      // task while the executor validator is awaiting. Re-check the durable
      // state before a gate result can pause or start that task.
      if (_disposed ||
          _dataClearInProgress ||
          task.isTerminal ||
          task.status != AgentTaskStatus.queued) {
        return;
      }
      if (discussionError != null) {
        await _pauseForDiscussion(task, discussionError);
        await _save(task);
        await _schedule();
        return;
      }
    }
    final cancellation = WorkTaskCancellation();
    _conversationReservations.add(task.groupId);
    _folderWaiters[task.id] = cancellation;
    // The first task may be the one that opens the OS folder picker. Resolve
    // that grant before planning locks; otherwise the planner sees an empty
    // grant list, starts without a lease, and only obtains the directory after
    // the runner has already crossed the mutation boundary.
    if ((_folderGrantService != null || _requireFolderGrant) &&
        !await _ensureFolderGrant(task, cancellation)) {
      _folderWaiters.remove(task.id);
      // The picker was resolved before a runner/lease was started. A denied
      // or unavailable grant therefore has no waiter that should hold the
      // conversation reservation; release it so a later manual continuation
      // (or another queued task in the conversation) is not deadlocked.
      _conversationReservations.remove(task.groupId);
      cancellation.cancel();
      _makeConversationReady(task.groupId);
      return;
    }
    _folderWaiters.remove(task.id);
    if (_disposed ||
        _dataClearInProgress ||
        cancellation.isCancelled ||
        task.isTerminal ||
        (task.status != AgentTaskStatus.queued &&
            task.status != AgentTaskStatus.planning)) {
      cancellation.cancel();
      _conversationReservations.remove(task.groupId);
      _makeConversationReady(task.groupId);
      return;
    }
    late final List<WorkResourceLockRequest> locks;
    try {
      locks = _resourceLocksFor(task);
    } on Object catch (error) {
      await _failInvalidResourcePlan(task, error);
      return;
    }

    if (locks.isNotEmpty) {
      WorkResourceLockLease? lease;
      try {
        lease = _resourceLockManager.tryAcquire(task.id, locks);
      } on Object catch (error) {
        await _failInvalidResourcePlan(task, error);
        return;
      }
      if (lease == null) {
        await _waitForResource(task, cancellation, locks);
        return;
      }
      await _startRunning(task, cancellation, lease);
      return;
    }

    await _startRunning(task, cancellation, null);
  }

  Future<void> _pauseForCheckpointReview(AgentTask task) async {
    _removeQueuedTask(task);
    _taskLockPlans.remove(task.id);
    const reason = '任务检查点版本不受支持，已暂停，请确认后重新继续。';
    final decoded = _decodeExecutionMap(task.executionStateJson);
    task
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..pendingToolRequestJson = ''
      ..lastError = task.lastError.trim().isEmpty ? reason : task.lastError
      ..executionStateJson = jsonEncode(
        workExecutionCheckpointReviewMetadata(decoded),
      )
      ..updatedAt = _clock();
    _conversationReservations.add(task.groupId);
    _refreshTaskContext(
      task,
      nextStep: reason,
      extraErrors: [reason],
    );
    await _save(task);
    await _markSnapshotStatus(task);
    await _record(
      task,
      WorkTaskEventKind.paused,
      '等待确认任务检查点',
      detail: reason,
    );
  }

  /// Migrates a group task that reaches an explicit continuation without a
  /// typed discussion extension after an unsupported checkpoint was reviewed.
  /// The marker check keeps the legacy coordinator fixtures and terminal
  /// restart semantics intact; normal old records are migrated by [restore].
  Future<bool> _ensureDiscussionBeforeUserContinuation(
    AgentTask task, {
    bool resetSoftLimit = false,
  }) async {
    if (!_requiresDiscussionForTask(task)) return false;
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final invalidDiscussion = discussion.present && discussion.state == null;
    if (!invalidDiscussion &&
        !workExecutionCheckpointRequiresReview(task.executionStateJson)) {
      return false;
    }
    if (discussion.present && discussion.state != null) return false;

    final previousError = resetSoftLimit ? '' : task.lastError.trim();
    const reason = '旧任务需要补充群讨论后才能继续。';
    final safeCheckpoint = discussion.present
        ? jsonEncode(
            workExecutionCheckpointReviewMetadata(
              _decodeExecutionMap(task.executionStateJson),
            ),
          )
        : _withoutApprovalCheckpoint(task.executionStateJson);
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      _withoutApprovalCheckpoint(safeCheckpoint),
      _legacyDiscussionState(task),
    );
    WorkFailure.clearFromTask(task);
    if (resetSoftLimit) {
      task
        ..softLimitReached = false
        ..actionCount = 0
        ..startedAt = _clock();
    }
    await _pauseForDiscussion(task, reason);
    task
      ..resumeRequired = false
      ..lastError = previousError.isEmpty ? reason : previousError
      ..updatedAt = _clock();
    _refreshTaskContext(
      task,
      nextStep: reason,
      extraErrors: <String>[
        reason,
        if (previousError.isNotEmpty) previousError
      ],
    );
    await _save(task);
    await _markSnapshotStatus(task);
    _maybeStartDiscussion(task);
    return true;
  }

  Future<void> _failInvalidResourcePlan(AgentTask task, Object error) async {
    _conversationReservations.remove(task.groupId);
    final failure = WorkFailure.fromError(
      error,
      scope: 'resource',
      completedContent: _completedContentForTask(task),
    );
    _applyFailure(task, failure);
    await _save(task);
    await _reportFailure(task, failure);
    unawaited(_record(task, WorkTaskEventKind.failed, '资源锁计划无效'));
    _makeConversationReady(task.groupId);
    await _schedule();
  }

  Future<void> _startRunning(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkResourceLockLease? lease,
  ) async {
    if (_disposed ||
        _dataClearInProgress ||
        cancellation.isCancelled ||
        task.isTerminal ||
        // 记录已被删除（启动流程的 await 期间用户删了它）：绝不能为一条已删除的
        // 任务启动 runner，否则模型与工具会继续跑用户已经删掉的工作。
        !_taskBox.containsKey(task.id) ||
        (task.status != AgentTaskStatus.queued &&
            task.status != AgentTaskStatus.planning)) {
      cancellation.cancel();
      _conversationReservations.remove(task.groupId);
      if (lease != null) await lease.release();
      return;
    }
    _running[task.id] = _RunningTask(task: task, cancellation: cancellation);
    var runStarted = false;
    try {
      task
        ..status = AgentTaskStatus.planning
        ..startedAt ??= _clock()
        // 每次真正开跑都重新计一次"本次尝试"的展示耗时；任务级时间预算仍按
        // `startedAt` 计算，不受追问影响。
        ..attemptStartedAt = _clock()
        ..updatedAt = _clock();
      await _save(task);
      await _markSnapshotStatus(task);
      if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
        cancellation.cancel();
        return;
      }
      unawaited(_record(task, WorkTaskEventKind.planning, '任务开始执行'));
      final run = _runWithLease(task, cancellation, lease);
      _activeRuns[task.id] = run;
      runStarted = true;
      unawaited(
        run.then<void>(
          (_) => _removeActiveRun(task.id, run),
          onError: (Object _, StackTrace __) => _removeActiveRun(task.id, run),
        ),
      );
    } finally {
      if (!runStarted) {
        _running.remove(task.id);
        _conversationReservations.remove(task.groupId);
        cancellation.cancel();
        if (lease != null) await lease.release();
        _notifySlotAvailable();
      }
    }
  }

  List<WorkResourceLockRequest> _resourceLocksFor(AgentTask task) {
    final explicit = _taskLockPlans[task.id];
    if (explicit != null) return List<WorkResourceLockRequest>.from(explicit);
    final persisted = _persistedResourceLocks(task.executionStateJson);
    if (persisted != null) {
      _taskLockPlans[task.id] = persisted;
      return List<WorkResourceLockRequest>.from(persisted);
    }
    final callback = _resourceLockPlan;
    if (callback != null) {
      return _normalizeAndPersistResourceLocks(task, callback(task));
    }
    if (_runner case final WorkTaskResourceLockPlanner planner) {
      return _normalizeAndPersistResourceLocks(
        task,
        planner.planResourceLocks(task),
      );
    }
    return const <WorkResourceLockRequest>[];
  }

  List<WorkResourceLockRequest> _normalizeAndPersistResourceLocks(
    AgentTask task,
    Iterable<WorkResourceLockRequest> planned,
  ) {
    final normalized = _resourceLockManager.normalizeLockSet(planned);
    if (normalized.isEmpty) return const <WorkResourceLockRequest>[];
    _taskLockPlans[task.id] = normalized;
    // The runner may be created after a process restart, so the first plan
    // computed from the current grant must be persisted before execution can
    // cross the file boundary. _startRunning saves this same task object.
    task.executionStateJson = _withResourceLockPlan(
      task.executionStateJson,
      normalized,
    );
    return List<WorkResourceLockRequest>.from(normalized);
  }

  Future<void> _waitForResource(
    AgentTask task,
    WorkTaskCancellation cancellation,
    List<WorkResourceLockRequest> locks,
  ) async {
    final waiting = _WaitingResourceTask(
      task: task,
      cancellation: cancellation,
    );
    _waitingForResources[task.id] = waiting;
    task
      ..status = AgentTaskStatus.queued
      ..updatedAt = _clock();
    await _save(task);
    final conflict =
        _resourceLockManager.conflictPath(locks) ?? locks.first.path;
    final safePath = _safeLockPath(conflict);
    await _record(
      task,
      WorkTaskEventKind.queued,
      '等待另一个任务释放 $safePath',
      detail: '资源锁等待不会增加 Agent 动作数。',
    );
    unawaited(_awaitResourceLease(waiting, locks));
  }

  Future<void> _awaitResourceLease(
    _WaitingResourceTask waiting,
    List<WorkResourceLockRequest> locks,
  ) async {
    final task = waiting.task;
    try {
      final lease = await _resourceLockManager.acquire(
        task.id,
        locks,
        cancellation: waiting.cancellation.whenCancelled,
        isCancelled: () => waiting.cancellation.isCancelled,
      );
      if (!_isWaiting(waiting) ||
          _disposed ||
          _dataClearInProgress ||
          waiting.cancellation.isCancelled ||
          _taskBox.get(task.id)?.status != AgentTaskStatus.queued) {
        await lease.release();
        return;
      }
      waiting.lease = lease;
      while (!_disposed &&
          _running.length >= WorkTaskCoordinator.maximumConcurrentTasks &&
          !waiting.cancellation.isCancelled) {
        await Future.any<void>([
          _waitForSlot(),
          waiting.cancellation.whenCancelled,
        ]);
      }
      if (!_isWaiting(waiting) ||
          _disposed ||
          _dataClearInProgress ||
          waiting.cancellation.isCancelled ||
          _taskBox.get(task.id)?.status != AgentTaskStatus.queued) {
        await lease.release();
        return;
      }
      _waitingForResources.remove(task.id);
      _startingTaskIds.add(task.id);
      try {
        await _startRunning(task, waiting.cancellation, lease);
      } finally {
        _startingTaskIds.remove(task.id);
      }
    } on WorkResourceLockCancelled {
      _dropWaiting(waiting);
    } on Object catch (error) {
      await _failResourceWait(waiting, error);
    }
  }

  Future<void> _failResourceWait(
    _WaitingResourceTask waiting,
    Object error,
  ) async {
    await _serialize(() async {
      if (!_isWaiting(waiting) || _disposed || _dataClearInProgress) return;
      _dropWaiting(waiting);
      final stored = _taskBox.get(waiting.task.id);
      if (stored == null || stored.isTerminal) return;
      final failure = WorkFailure.fromError(
        error,
        scope: 'resource',
        completedContent: _completedContentForTask(stored),
      );
      _applyFailure(stored, failure);
      await _save(stored);
      await _reportFailure(stored, failure);
      unawaited(
        _record(stored, WorkTaskEventKind.failed, '资源锁等待失败'),
      );
      _makeConversationReady(stored.groupId);
      await _schedule();
    });
  }

  bool _isWaiting(_WaitingResourceTask waiting) =>
      identical(_waitingForResources[waiting.task.id], waiting);

  void _dropWaiting(_WaitingResourceTask waiting) {
    if (!_isWaiting(waiting)) return;
    _waitingForResources.remove(waiting.task.id);
    _conversationReservations.remove(waiting.task.groupId);
    _makeConversationReady(waiting.task.groupId);
  }

  Future<void> _runWithLease(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkResourceLockLease? lease,
  ) async {
    try {
      await _run(task, cancellation);
    } finally {
      try {
        if (lease != null) await lease.release();
      } finally {
        await _releaseHandoffAfterLease(task);
      }
    }
  }

  Future<void> _releaseHandoffAfterLease(AgentTask task) async {
    if (!_handoffsAwaitingLease.contains(task.id)) return;
    if (_disposed || _dataClearInProgress) {
      _handoffsAwaitingLease.remove(task.id);
      _conversationReservations.remove(task.groupId);
      return;
    }
    await _serialize(() async {
      if (!_handoffsAwaitingLease.remove(task.id)) return;
      _conversationReservations.remove(task.groupId);
      if (_disposed || _dataClearInProgress) return;
      _makeConversationReady(task.groupId);
      await _schedule();
    });
  }
}
