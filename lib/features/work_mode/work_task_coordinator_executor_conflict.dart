part of 'work_task_coordinator.dart';

/// 群推举的执行人与请求里钉定的执行人不一致时的唯一出口。
///
/// 这条路径独立成文件：它既不是普通提交，也不是讨论运行器的一部分——它把
/// 用户对这对冲突的确认写成一个新的请求版本，然后让既有讨论门禁重新判定。
extension _WorkTaskCoordinatorExecutorConflict on WorkTaskCoordinator {
  /// Settles a checkpoint where the group elected one executor while the
  /// durable contract still pins another.
  ///
  /// The convergence gate only releases a discussion whose elected executor
  /// matches `explicitExecutorId`, so this state can never converge on its own:
  /// every further round caps the understanding at 99% and the task dies on the
  /// round limit. The owner's choice therefore has to be applied here, and only
  /// the owner may make it — the discussion may not swap a pinned role silently.
  Future<void> _implConfirmExecutorSwap(
    String taskId, {
    required int version,
    required bool swap,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      final (state, electedId, pinnedId) = _readExecutorConflict(
        task,
        version: version,
        swap: swap,
      );
      final confirmedId = swap ? electedId : pinnedId;
      _discussionCancellations[taskId]?.cancel();
      final next = _confirmedExecutorState(task, state, confirmedId);
      task
        ..characterId = confirmedId
        ..assignedCharacterIds = <String>{
          ...task.assignedCharacterIds,
          confirmedId,
        }.toList(growable: false)
        ..status = AgentTaskStatus.paused
        ..resumeRequired = false
        ..lastError = '执行人已确认，正在重新校验群讨论执行门禁。'
        ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          task.executionStateJson,
          next,
        )
        ..updatedAt = _clock();
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.queued,
        swap ? '用户确认改派最终执行人' : '用户确认保留原执行人',
      );
      _maybeStartDiscussion(task);
    });
  }

  /// Validates the confirmation against the durable checkpoint and returns the
  /// conflicting pair. A confirmation that cannot be honoured throws instead of
  /// rewriting anything, so the two roles can never be swapped by a stale
  /// button or for a role the task no longer qualifies.
  (WorkDiscussionState, String, String) _readExecutorConflict(
    AgentTask task, {
    required int version,
    required bool swap,
  }) {
    if (task.isTerminal ||
        !isUserActionCurrent(
          taskId: task.id,
          blockerId: 'executorPinConflict',
          version: version,
        )) {
      throw StateError('该任务提醒已失效，请打开任务面板查看最新状态。');
    }
    final decoded =
        WorkDiscussionState.decodeExecutionState(task.executionStateJson);
    final state = decoded.state;
    if (!decoded.isValid || state == null) {
      throw StateError('讨论状态已失效，不能确认执行人。');
    }
    final electedId = state.executorId?.trim() ?? '';
    final pinnedId = _contractExecutorId(state.deliverableContract) ?? '';
    if (electedId.isEmpty || pinnedId.isEmpty || electedId == pinnedId) {
      throw StateError('当前讨论没有需要确认的执行人变化。');
    }
    if (!swap && !state.candidateCharacterIds.contains(pinnedId)) {
      throw StateError('原执行人已不具备本任务的执行资格，请先在群内补充角色。');
    }
    return (state, electedId, pinnedId);
  }

  /// Reopens the discussion for the confirmed owner.
  ///
  /// A confirmed owner is a new request version, so the revision machinery
  /// resets blockers and open questions instead of the pin being edited in
  /// place. The understanding count and its evidence are carried over because
  /// the group did converge — only the owner's confirmation was missing, and
  /// re-asking the members would discard conclusions they already stand behind.
  /// The round budget restarts with the new version, which is also what lets
  /// the reopened discussion run the rounds its gate still requires.
  WorkDiscussionState _confirmedExecutorState(
    AgentTask task,
    WorkDiscussionState state,
    String confirmedId,
  ) {
    final contentScope = state.deliverableContract?['contentScope'];
    final renewed = _renewDiscussionForRequest(
      state,
      task.userRequest,
      activeScopeOverride: contentScope is String ? contentScope : null,
    );
    return renewed.copyWith(
      executorId: confirmedId,
      coordinatorId: confirmedId,
      candidateCharacterIds: state.candidateCharacterIds,
      understandingPercent: state.understandingPercent,
      understandingEvidence: state.understandingEvidence,
      deliverableContract: <String, dynamic>{
        ...?renewed.deliverableContract,
        'explicitExecutorId': confirmedId,
      },
    );
  }
}
