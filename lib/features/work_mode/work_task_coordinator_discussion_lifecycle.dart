part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorDiscussionLifecycle on WorkTaskCoordinator {
  WorkDiscussionState _renewDiscussionForRequest(
      WorkDiscussionState previous, String request,
      {WorkFollowUpDecision? decision,
      String? contractRequest,
      String? answeredQuestion}) {
    final revision = previous.requestRevision + 1;
    final pinnedExecutor = _contractExecutorId(previous.deliverableContract);
    final parsed = WorkRoleRouter.deliverableContractForRequest(
      contractRequest ?? request,
      requestRevision: revision,
      explicitExecutorId: pinnedExecutor,
    );
    final contract = previous.deliverableContract == null
        ? parsed.toJson()
        : Map<String, dynamic>.from(previous.deliverableContract!);
    // Keep confirmed fields when a supplement only adds context, but let an
    // explicit new format/location/path in the latest request replace them.
    // This makes target changes visible to the next discussion instead of
    // silently carrying a stale Markdown/HTML contract forward.
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
    contract
      ..['contentScope'] = request
      ..['requestRevision'] = revision;

    // A supplement that keeps the same deliverable is a revision of the same
    // plan, not a new one. Only a real target change (another artifact type,
    // format, place or path) may discard what the group already confirmed.
    final deliverableChanged = _deliverableIdentityChanged(
      previous.deliverableContract,
      contract,
    );
    final keepElection = pinnedExecutor != null || !deliverableChanged;
    final renewed = WorkDiscussionState.initial(
      conversationId: previous.conversationId,
      requestRevision: revision,
      coordinatorId: previous.coordinatorId,
      // A user-specified executor remains pinned. A role elected by the group
      // belongs to the previous request version; a revision that retargets the
      // deliverable must reopen the election so the new deliverable is matched
      // against current skills. A supplement that keeps the same deliverable
      // keeps its elected owner.
      executorId: keepElection ? previous.executorId : null,
      candidateCharacterIds:
          keepElection ? previous.candidateCharacterIds : const [],
      participantCharacterIds:
          previous.participants.map((item) => item.characterId),
      deliverableContract: contract,
    );
    if (deliverableChanged) return renewed;
    // Carrying the confirmed understanding over is what stops a one-line
    // supplement from wiping the whole discussion back to 0%. Evidence and
    // still-open questions travel with it so the group continues where it
    // stopped instead of re-asking what it already agreed on.
    //
    // Two fields are deliberately *not* carried over:
    // - `round`: the previous run may already have burnt its round budget;
    //   keeping the old count would let the renewed discussion hit the limit
    //   before it can even answer the supplement.
    // - `blockers`: terminal ones (discussionNotConverged /
    //   discussionRoundLimit / structuredResponseInvalid) are model-proof and
    //   would pin the task forever, and user-decision ones would make
    //   `_discussionWaitsForUser` refuse to restart the discussion at all.
    // `initial()` also re-arms it, so its phase never looks ready by accident.
    return renewed.copyWith(
      understandingPercent: previous.understandingPercent,
      understandingEvidence: previous.understandingEvidence,
      openQuestions: _withoutAnsweredQuestion(
        previous.openQuestions,
        answeredQuestion,
      ),
    );
  }

  /// Drops the one question the user just answered. Carrying it over would make
  /// the renewed discussion print it again under `待解决：` in its very first
  /// round, which reads as "the same question was asked twice" right after the
  /// user replied. Questions the user did not answer stay open.
  List<String> _withoutAnsweredQuestion(
    List<String> questions,
    String? answeredQuestion,
  ) {
    final answered = answeredQuestion?.trim() ?? '';
    if (answered.isEmpty) return questions;
    return questions
        .where((item) => item.trim() != answered)
        .toList(growable: false);
  }

  /// The question the group last surfaced to the user. The task panel answers
  /// exactly this one (first non-empty entry of `openQuestions`, presented while
  /// the discussion is not execution-ready), so a new user input is its answer.
  String? _pendingDiscussionQuestion(WorkDiscussionState state) {
    if (state.isExecutionReady) return null;
    for (final item in state.openQuestions) {
      final trimmed = item.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// Whether the latest request points at a different artifact than the one the
  /// group already confirmed. `contentScope` is intentionally excluded: it
  /// always absorbs the new wording and is not part of the deliverable identity.
  bool _deliverableIdentityChanged(
    Map<String, dynamic>? before,
    Map<String, dynamic> after,
  ) {
    const identityFields = <String>[
      'deliverableType',
      'format',
      'location',
      'revisionTarget',
    ];
    if (before == null) return true;
    for (final field in identityFields) {
      if (_contractIdentityValue(before[field]) !=
          _contractIdentityValue(after[field])) {
        return true;
      }
    }
    return false;
  }

  /// Normalises "no target specified" to an empty string so an omitted field is
  /// never mistaken for a target change.
  String _contractIdentityValue(Object? value) {
    if (value is! String) return '';
    final trimmed = value.trim();
    return trimmed == 'unspecified' ? '' : trimmed;
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
        decoded.state!.isExecutionReady ||
        decoded.state!.phase == WorkDiscussionPhase.blocked ||
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
    }
  }

  bool _discussionWaitsForUser(WorkDiscussionState state) => state.blockers.any(
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
          stored.status != AgentTaskStatus.paused) {
        return;
      }
      final decoded = WorkDiscussionState.decodeExecutionState(
        stored.executionStateJson,
      );
      if (!decoded.isValid ||
          decoded.state!.isExecutionReady ||
          decoded.state!.phase == WorkDiscussionPhase.blocked ||
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
        _running.length + _startingTaskIds.length <
            WorkTaskCoordinator.maximumConcurrentTasks) {
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
