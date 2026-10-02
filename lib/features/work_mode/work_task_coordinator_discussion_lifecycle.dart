part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorDiscussionLifecycle on WorkTaskCoordinator {
  /// 这份讨论状态是否携带 v2 协作记录。
  ///
  /// v2 只能通过带 `expectedRevision` 的增量入口（`applyCollaborationUpdate`）推进。
  /// 旧讨论入口产出的都是 v1，用它覆盖 v2 会把认可、待决事项与验收整块丢掉；而
  /// `mergeIntoExecutionState` 的降级守卫在"先清空检查点再合并"的调用方那里看不到
  /// 上一份 v2 状态，只有这里能提前拦住。
  bool _carriesV2Collaboration(WorkDiscussionState? state) =>
      state?.schemaVersion == WorkDiscussionState.currentSchemaVersion &&
      state?.collaboration != null;

  WorkDiscussionState _renewDiscussionForRequest(
      WorkDiscussionState previous, String request,
      {WorkFollowUpDecision? decision,
      String? contractRequest,
      String? activeScopeOverride}) {
    if (_carriesV2Collaboration(previous)) {
      throw StateError('v2 协作状态不能通过旧讨论入口重建。');
    }
    final revision = previous.requestRevision + 1;
    final pinnedExecutor = _contractExecutorId(previous.deliverableContract);
    final parsed = WorkRoleRouter.deliverableContractForRequest(
      contractRequest ?? request,
      requestRevision: revision,
      explicitExecutorId: pinnedExecutor,
    );
    final previousContract = previous.deliverableContract;
    final previousType = previousContract?['deliverableType'];
    final previousFormat = previousContract?['format'];
    final previousLocation = previousContract?['location'];
    final changedDeliverable = previousContract != null &&
        (parsed.deliverableType != 'generic' &&
                previousType is String &&
                previousType != 'generic' &&
                parsed.deliverableType != previousType ||
            parsed.format != 'unspecified' &&
                previousFormat is String &&
                previousFormat != 'unspecified' &&
                parsed.format != previousFormat ||
            parsed.location != 'unspecified' &&
                previousLocation is String &&
                previousLocation != 'unspecified' &&
                parsed.location != previousLocation);
    final activeScope = activeScopeOverride?.trim().isNotEmpty == true
        ? activeScopeOverride!.trim()
        : contractRequest?.trim().isNotEmpty == true && changedDeliverable
            ? contractRequest!.trim()
            : request;
    final preserveContract = activeScopeOverride?.trim().isNotEmpty == true;
    final contract = previous.deliverableContract == null
        ? parsed.toJson()
        : Map<String, dynamic>.from(previous.deliverableContract!);
    // Keep confirmed fields when a supplement only adds context, but let an
    // explicit new format/location/path in the latest request replace them.
    // This makes target changes visible to the next discussion instead of
    // silently carrying a stale Markdown/HTML contract forward.
    if (!preserveContract) {
      if (previous.deliverableContract == null ||
          parsed.deliverableType != 'generic') {
        contract['deliverableType'] = parsed.deliverableType;
      }
      if (parsed.format != 'unspecified') contract['format'] = parsed.format;
      if (parsed.location != 'unspecified') {
        contract['location'] = parsed.location;
      }
      if (decision?.artifactPath?.trim().isNotEmpty == true) {
        contract['revisionTarget'] = decision!.artifactPath!.trim();
      } else if (parsed.revisionTarget.isNotEmpty) {
        contract['revisionTarget'] = parsed.revisionTarget;
      }
    }
    contract
      ..['contentScope'] = activeScope
      ..['requestRevision'] = revision;
    return WorkDiscussionState.initial(
      conversationId: previous.conversationId,
      requestRevision: revision,
      coordinatorId: previous.coordinatorId,
      // A user-specified executor remains pinned. A role elected by the group
      // belongs to the previous request version; a revision must reopen the
      // election so the new deliverable is matched against current skills.
      executorId: pinnedExecutor == null ? null : previous.executorId,
      candidateCharacterIds:
          pinnedExecutor == null ? const [] : previous.candidateCharacterIds,
      participantCharacterIds:
          previous.participants.map((item) => item.characterId),
      deliverableContract: contract,
    );
  }

  String? _contractExecutorId(Map<String, dynamic>? contract) {
    final value = contract?['explicitExecutorId'];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  bool _discussionExecutorIsPinned(WorkDiscussionState state) =>
      _contractExecutorId(state.deliverableContract) != null;

  Stream<AgentTask> _implWatchTask(String taskId) async* {
    final initial = _taskBox.get(taskId);
    if (initial != null && initial.workModeTask) yield initial;
    yield* _taskUpdates.stream
        .where((task) => task.id == taskId)
        .map((task) => task);
  }

  Stream<List<AgentTask>> _implWatchAllTasks() async* {
    yield _allWorkTasks();
    yield* _taskUpdates.stream.map((_) => _allWorkTasks());
  }

  /// The app scope can release listeners at shutdown; it deliberately does
  /// not stop active work merely because a chat room disappeared.
  Future<void> _implDispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    for (final running in _running.values) {
      running.cancellation.cancel();
    }
    for (final cancellation in _discussionCancellations.values) {
      cancellation.cancel();
    }
    _discussionCancellations.clear();
    for (final cancellations in _installCancellations.values) {
      for (final cancellation in cancellations) {
        cancellation.cancel();
      }
    }
    _installCancellations.clear();
    for (final waiting in _waitingForResources.values) {
      waiting.cancellation.cancel();
      final lease = waiting.lease;
      if (lease != null) unawaited(lease.release());
    }
    for (final cancellation in _folderWaiters.values) {
      cancellation.cancel();
    }
    _folderWaiters.clear();
    _waitingForResources.clear();
    _conversationReservations.clear();
    _handoffsAwaitingLease.clear();
    _autoResumeTaskIds.clear();
    _taskLockPlans.clear();
    _notifySlotAvailable();
    _readyConversations.clear();
    _readyConversationIds.clear();
    _conversationQueues.clear();
    final drain = Future.wait<void>(<Future<void>>[
      ..._activeRuns.values,
      ..._discussionRuns.values,
      ..._installRuns.values,
    ], eagerError: false)
        .then<void>((_) async {
      if (!_taskUpdates.isClosed) await _taskUpdates.close();
    });
    _disposeFuture = drain;
    return drain;
  }

  void _maybeStartDiscussion(AgentTask task) {
    final runner = _discussionRunner;
    if (runner == null ||
        _disposed ||
        _dataClearInProgress ||
        task.isTerminal) {
      return;
    }
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    if (!decoded.isValid ||
        (decoded.state!.schemaVersion ==
                WorkDiscussionState.currentSchemaVersion &&
            (runner is! WorkTaskCollaborationDiscussionRunner ||
                decoded.state!.isPlanReady &&
                    decoded.state!.collaboration!.phase != 'reviewing' ||
                decoded.state!.collaboration!.hasBlockingDecision ||
                decoded.state!.collaboration!.hasPendingDecision &&
                    decoded.state!.collaboration!.workItems.isNotEmpty &&
                    decoded.state!.collaboration!.workItems
                        .every((i) => i['status'] == 'done'))) ||
        decoded.state!.isExecutionReady ||
        (decoded.state!.schemaVersion ==
                WorkDiscussionState.legacySchemaVersion &&
            decoded.state!.phase == WorkDiscussionPhase.blocked) ||
        _discussionWaitsForUser(decoded.state!)) {
      // A blocked discussion is a durable user-facing checkpoint.  It may be
      // renewed by a follow-up or explicit retry, but restore/submit must not
      // silently restart it and defeat the bounded no-progress boundary.
      return;
    }
    if (_discussionRuns.containsKey(task.id) ||
        !_discussionStartingIds.add(task.id)) {
      return;
    }
    final cancellation = WorkTaskCancellation();
    _discussionCancellations[task.id] = cancellation;
    final run = _runDiscussion(
      task,
      runner,
      cancellation,
      expectedRevision: decoded.state!.requestRevision,
    );
    _discussionRuns[task.id] = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_discussionRuns[task.id], run)) {
          _discussionRuns.remove(task.id);
          _discussionCancellations.remove(task.id);
          _discussionStartingIds.remove(task.id);
          _restartPendingDiscussion(task.id);
        }
      }),
    );
    _discussionStartingIds.remove(task.id);
  }

  Future<void> _runDiscussion(AgentTask task, WorkTaskDiscussionRunner runner,
      WorkTaskCancellation cancellation,
      {required int expectedRevision}) async {
    try {
      while (!cancellation.isCancelled && !_disposed) {
        final acquired = await _serialize(() async {
          if (_occupiedSlots >= WorkTaskCoordinator.maximumConcurrentTasks) {
            return false;
          }
          _discussionSlotIds.add(task.id);
          return true;
        });
        if (acquired) break;
        await Future.any([_waitForSlot(), cancellation.whenCancelled]);
      }
      if (cancellation.isCancelled || _disposed || task.isTerminal) return;
      final state =
          WorkDiscussionState.fromExecutionState(task.executionStateJson);
      if (state?.schemaVersion == WorkDiscussionState.currentSchemaVersion &&
          runner is WorkTaskCollaborationDiscussionRunner) {
        await (runner as WorkTaskCollaborationDiscussionRunner)
            .runCollaboration(
          task,
          cancellation,
          (update) =>
              _applyCollaborationUpdate(update, fromDiscussionRunner: true),
        );
        await _serialize(() async {
          final stored = _taskBox.get(task.id);
          if (stored == null ||
              stored.isTerminal ||
              cancellation.isCancelled ||
              _disposed) {
            return;
          }
          final collaboration =
              WorkDiscussionState.fromExecutionState(stored.executionStateJson)
                  ?.collaboration;
          if (collaboration != null &&
              collaboration.productionReady &&
              (collaboration.phase == 'ready' || collaboration.deliveryReady)) {
            stored
              ..status = AgentTaskStatus.queued
              ..resumeRequired = false
              ..lastError = '';
            await _save(stored);
            _conversationReservations.remove(stored.groupId);
            _enqueueTask(stored);
            await _schedule();
          }
        });
        return;
      }
      await runner.runDiscussion(
        task,
        cancellation,
        (state) => _updateDiscussionState(
          task.id,
          state,
          fromDiscussionRunner: true,
        ),
      );
    } on Object catch (error) {
      if (_disposed || _dataClearInProgress || cancellation.isCancelled) return;
      try {
        final stored = _taskBox.get(task.id);
        if (stored == null || stored.isTerminal) return;
        final current = WorkDiscussionState.decodeExecutionState(
          stored.executionStateJson,
        ).state;
        if (current == null) return;
        if (current.schemaVersion == WorkDiscussionState.currentSchemaVersion) {
          stored.lastError = '协作讨论未完成：${sanitizeWorkTaskError(error)}';
          stored.resumeRequired = true;
          await _save(stored);
          return;
        }
        // A cancelled/late model callback may fail while a newer request
        // revision is already durable.  That failure belongs to the old run;
        // never turn the current revision into a blocked state or overwrite
        // its progress with an obsolete diagnostic.
        if (current.requestRevision > expectedRevision) return;
        await _updateDiscussionState(
          task.id,
          current.copyWith(
            phase: WorkDiscussionPhase.blocked,
            understandingPercent:
                current.understandingPercent.clamp(0, 99).toInt(),
            openQuestions: <String>[
              ...current.openQuestions,
              '讨论运行器未完成：${sanitizeWorkTaskError(error)}',
            ],
            blockers: <String>[...current.blockers, 'discussionRunnerFailed'],
          ),
          fromDiscussionRunner: true,
        );
      } on Object {
        // The task's last durable state remains authoritative if even the
        // failure checkpoint cannot be written during shutdown/recovery.
      }
    } finally {
      _discussionSlotIds.remove(task.id);
      _notifySlotAvailable();
      if (!_disposed && !_dataClearInProgress) unawaited(_schedule());
    }
  }

  bool _discussionWaitsForUser(WorkDiscussionState state) =>
      state.schemaVersion == WorkDiscussionState.currentSchemaVersion
          ? state.collaboration!.hasBlockingDecision
          : state.blockers.any(
              (blocker) =>
                  blocker == 'mentionClarification' ||
                  blocker == 'missingUserInformation' ||
                  blocker == 'executorUnavailable' ||
                  blocker == 'missingQualifiedRole' ||
                  blocker == 'groupUnavailable',
            );

  void _restartPendingDiscussion(String taskId) {
    unawaited(_serialize(() async {
      if (_disposed || _dataClearInProgress) return;
      final stored = _taskBox.get(taskId);
      if (stored == null ||
          stored.isTerminal ||
          stored.status != AgentTaskStatus.paused ||
          stored.resumeRequired) {
        return;
      }
      if (_hasPendingV2Input(stored)) await _applyPendingV2Inputs(stored);
      final decoded = WorkDiscussionState.decodeExecutionState(
        stored.executionStateJson,
      );
      if (!decoded.isValid ||
          decoded.state!.isExecutionReady ||
          decoded.state!.isPlanReady &&
              decoded.state!.collaboration!.phase != 'reviewing' ||
          decoded.state!.collaboration?.hasBlockingDecision == true ||
          (decoded.state!.schemaVersion ==
                  WorkDiscussionState.legacySchemaVersion &&
              decoded.state!.phase == WorkDiscussionPhase.blocked) ||
          _discussionWaitsForUser(decoded.state!)) {
        return;
      }
      _maybeStartDiscussion(stored);
    }));
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final scheduled = _operations.then((_) => operation());
    _operations = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return scheduled;
  }

  Future<void> _pauseForDiscussion(AgentTask task, String reason) async {
    _removeQueuedTask(task);
    _taskLockPlans.remove(task.id);
    task
      ..status = AgentTaskStatus.paused
      ..resumeRequired = false
      ..lastError = sanitizeWorkTaskError(reason)
      ..updatedAt = _clock();
    // The conversation remains serially owned by this durable discussion, but
    // no folder or file lock is acquired while it waits for people/roles.
    _conversationReservations.add(task.groupId);
    _refreshTaskContext(
      task,
      nextStep: task.lastError,
      extraErrors: [task.lastError],
    );
    await _record(
      task,
      WorkTaskEventKind.paused,
      '等待群讨论完成',
      detail: task.lastError,
    );
  }

  String _discussionWaitingReason(WorkDiscussionState state) {
    if (state.collaboration != null) {
      return state.isPlanReady ? '方案已确认，等待工作项调度。' : '等待相关团队查证问题并逐人确认当前方案。';
    }
    if (state.executorId == null || state.executorId!.trim().isEmpty) {
      return '等待群内确定符合职业资格的最终执行角色。';
    }
    if (state.blockers.isNotEmpty) {
      return '等待群讨论解决：${state.blockers.take(3).join('、')}。';
    }
    if (state.openQuestions.isNotEmpty) {
      return '等待群讨论回答未决问题：${state.openQuestions.take(3).join('；')}';
    }
    if (state.understandingPercent < 100) {
      return '执行人对需求的理解度为 ${state.understandingPercent}%，达到 100% 后才能执行。';
    }
    if (state.phase != WorkDiscussionPhase.ready) {
      return '群讨论尚未达到执行前门禁。';
    }
    return '群讨论状态暂不可执行。';
  }

  String? _discussionIdentityError(
    AgentTask task,
    WorkDiscussionState state,
  ) {
    final executor = state.executorId?.trim() ?? '';
    if (executor.isEmpty) return '群讨论尚未选定最终执行角色。';
    if (task.characterId.trim().isNotEmpty && task.characterId != executor) {
      return '任务记录的执行角色与群讨论最终执行人不一致，已阻止执行。';
    }
    if (task.assignedCharacterIds.isNotEmpty &&
        !task.assignedCharacterIds.contains(executor)) {
      return '群讨论最终执行人不在任务的合格角色范围内，已阻止执行。';
    }
    final contract = state.deliverableContract;
    final contractRevision = contract?['requestRevision'];
    if (contractRevision is! num ||
        contractRevision.toInt() != state.requestRevision) {
      return '讨论状态与最新请求版本不一致，已阻止执行。';
    }
    final explicitExecutor = contract?['explicitExecutorId'];
    if (explicitExecutor is String &&
        explicitExecutor.trim().isNotEmpty &&
        explicitExecutor.trim() != executor) {
      return '讨论状态与产物合同中的最终执行人不一致，已阻止执行。';
    }
    return null;
  }

  Future<String?> _discussionGateFailure(AgentTask task) async {
    if (!_requiresDiscussionForTask(task)) return null;
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    if (!decoded.present) {
      // Legacy tasks without the extension remain recoverable through the old
      // coordinator path; newly-created group work tasks always carry it.
      return null;
    }
    final state = decoded.state;
    if (state == null) return '讨论状态无效，已阻止执行。';
    if (state.conversationId != task.groupId) {
      return '讨论状态属于另一个群组，已阻止执行。';
    }
    if (state.collaboration != null) {
      final root = _decodeExecutionMap(task.executionStateJson);
      if (state.collaboration!.productionReady &&
          (root['startupRecoveryPending'] == true ||
              root.containsKey('uncertainAction'))) {
        // Prepare only after recovery proves local receipts under a fresh lease.
        return null;
      }
      if (_isArtifactDeliveryRetryOnly(task)) return null;
      if (_runner case final WorkTaskCollaborationExecutor executor) {
        if (state.collaboration!.productionReady &&
            await executor.prepareCollaborationWork(task)) {
          return null;
        }
      }
      return _discussionWaitingReason(state);
    }
    if (!state.isExecutionReady) return _discussionWaitingReason(state);
    final identityError = _discussionIdentityError(task, state);
    if (identityError != null) return identityError;
    // An attachment-only recovery must not re-enter the model/tool execution
    // path or require a fresh model credential. The runner still performs the
    // structural executor and qualification checks before it reuses the
    // already-generated artifact.
    if (_isArtifactDeliveryRetryOnly(task)) return null;
    if (_runner case final WorkTaskDiscussionExecutorValidator validator) {
      try {
        final error = await validator.validateDiscussionExecutor(task, state);
        if (error != null && error.trim().isNotEmpty) {
          return sanitizeWorkTaskError(error);
        }
      } on Object catch (error) {
        return '执行角色可用性校验失败：${sanitizeWorkTaskError(error)}';
      }
    }
    return null;
  }

  bool _isArtifactDeliveryRetryOnly(AgentTask task) {
    final metadata = _decodeExecutionMap(task.executionStateJson);
    final messageId = metadata['artifactDeliveryMessageId'];
    return metadata['artifactDeliveryNoticePublished'] == true &&
        metadata['artifactDeliveryRetryOnly'] == true &&
        messageId is String &&
        messageId.trim().isNotEmpty;
  }

  bool _requiresDiscussionForTask(AgentTask task) =>
      WorkDiscussionState.requiresDiscussionForConversation(task.groupId);

  Future<void> _schedule() async {
    if (_disposed || _dataClearInProgress) return;
    while (!_disposed &&
        !_dataClearInProgress &&
        _occupiedSlots < WorkTaskCoordinator.maximumConcurrentTasks) {
      final task = _takeNextTask();
      if (task == null) return;
      // A native directory picker is user-driven and can remain open for an
      // arbitrary time. Do not hold the serialized submit operation while it
      // is open: another conversation must still be able to claim the second
      // global slot and start (or wait for its own grant) independently.
      if (_folderGrantService != null || _requireFolderGrant) {
        _launchStart(task);
      } else {
        await _start(task);
      }
    }
  }

  void _launchStart(AgentTask task) {
    _startingTaskIds.add(task.id);
    final start = _start(task);
    unawaited(
      start.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) async {
          await _handleStartFailure(task, error);
        },
      ).whenComplete(() {
        _startingTaskIds.remove(task.id);
        if (!_disposed && !_dataClearInProgress) unawaited(_schedule());
      }),
    );
  }

  Future<void> _handleStartFailure(AgentTask task, Object error) async {
    if (_disposed) return;
    try {
      await _serialize(() async {
        _folderWaiters.remove(task.id)?.cancel();
        _conversationReservations.remove(task.groupId);
        final stored = _taskBox.get(task.id);
        if (stored != null && !stored.isTerminal) {
          final failure = WorkFailure.fromError(
            error,
            scope: 'start',
            completedContent: _completedContentForTask(stored),
          );
          _applyFailure(stored, failure);
          await _save(stored);
          await _reportFailure(stored, failure);
          unawaited(
            _record(
              stored,
              WorkTaskEventKind.failed,
              '任务启动失败',
              detail: failure.technicalDetail,
            ),
          );
        }
        _makeConversationReady(task.groupId);
      });
    } on Object {
      // A startup persistence failure must not become an unhandled async
      // error. The durable task state remains authoritative when available.
    }
  }
}
