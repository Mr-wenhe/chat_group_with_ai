part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorStartupRecovery on WorkTaskCoordinator {
  /// Startup and transport retry are independent causes. No network retry
  /// counter or 120-second automatic-attempt marker is consumed here.
  Future<bool> _restoreCollaboration(AgentTask task) async {
    try {
      return await _restoreCollaborationChecked(task);
    } on Object {
      if (_disposed ||
          !_taskBox.containsKey(task.id) ||
          task.status == AgentTaskStatus.cancelled) {
        return true;
      }
      task
        ..status = AgentTaskStatus.paused
        ..resumeRequired = true
        ..lastError = '恢复现场核对失败，原检查点、文件与输入保留，等待处理。';
      _conversationReservations.add(task.groupId);
      await _save(task);
      return true;
    }
  }

  Future<bool> _restoreCollaborationChecked(AgentTask task) async {
    if (!_requiresDiscussionForTask(task) ||
        _runner is! WorkTaskRecoveryValidator ||
        _discussionRunner is! WorkTaskCollaborationDiscussionRunner ||
        {AgentTaskStatus.completed, AgentTaskStatus.cancelled}
            .contains(task.status)) {
      return false;
    }
    if (workExecutionCheckpointRequiresReview(task.executionStateJson)) {
      await _pauseForCheckpointReview(task);
      return true;
    }
    final decoded =
        WorkDiscussionState.decodeExecutionState(task.executionStateJson);
    if (decoded.present && !decoded.isValid) {
      await _pauseForDiscussion(task, '未知或损坏的讨论状态，原检查点保留，不能自动恢复。');
      task.resumeRequired = true;
      await _save(task);
      return true;
    }
    final originalRoot = _decodeExecutionMap(task.executionStateJson);
    if (task.status == AgentTaskStatus.runningTool &&
        originalRoot['mutationRecoveryVersion'] != 1 &&
        !originalRoot.containsKey('uncertainAction')) {
      originalRoot['uncertainAction'] = {'tool': 'legacy', 'operationKey': ''};
      task.executionStateJson = jsonEncode(originalRoot);
    }
    final wasWaiting = task.status == AgentTaskStatus.waitingForApproval ||
        task.status == AgentTaskStatus.paused && task.resumeRequired ||
        task.status == AgentTaskStatus.interrupted;
    var state = decoded.state;
    final requiresMigrationConfirmation = state?.collaboration == null;
    if (state?.collaboration == null) {
      final old = state ?? _legacyDiscussionState(task);
      state = WorkDiscussionState.fromLegacyTask(task, old,
          projectScopeId: 'unbound');
      final root = _decodeExecutionMap(task.executionStateJson);
      if (task.status == AgentTaskStatus.runningTool) {
        root['uncertainAction'] = {'tool': 'legacy', 'operationKey': ''};
      }
      // Keep artifacts, FIFO and old receipts. Legacy handoff and signatures
      // cannot drive v2; the new team must inspect and confirm a fresh plan.
      root.remove('roleHandoff');
      root.remove('handoff');
      task.executionStateJson =
          WorkDiscussionState.mergeIntoExecutionState(jsonEncode(root), state);
      await _record(task, WorkTaskEventKind.paused, '旧群任务已转换为 v2，等待重新核对方案');
    }
    if (_hasPendingV2Input(task)) {
      try {
        await _applyPendingV2Inputs(task);
      } on Object {
        task
          ..status = AgentTaskStatus.paused
          ..resumeRequired = true
          ..lastError = '待处理输入无法安全纳入，原消息与附件保留。';
        await _save(task);
        _conversationReservations.add(task.groupId);
        return true;
      }
    }
    state = WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    final collaboration = state.collaboration!;
    if (requiresMigrationConfirmation) {
      task
        ..status = AgentTaskStatus.paused
        ..resumeRequired = true
        ..lastError = '旧任务已保留产物与补充，请显式继续以重新核对 v2 方案；旧理解百分比与签字不生效。';
    }
    if (wasWaiting ||
        requiresMigrationConfirmation ||
        collaboration.projectScopeId == 'portable-unbound' ||
        collaboration.hasBlockingDecision ||
        WorkTaskClarification.isAnswerable(task) ||
        task.pendingToolRequestJson.isNotEmpty) {
      _conversationReservations.add(task.groupId);
      await _save(task);
      await _notifyUserAction(task);
      _publish(task);
      return true;
    }
    if (task.status == AgentTaskStatus.failed) {
      _scheduleAutoResume(task);
      return true;
    }
    final root =
        _decodeExecutionMap(_withoutApprovalCheckpoint(task.executionStateJson))
          ..['startupRecoveryPending'] = true;
    task
      ..executionStateJson = jsonEncode(root)
      ..resumeRequired = false;
    if (!collaboration.productionReady ||
        collaboration.phase == 'reviewing' && !collaboration.deliveryReady) {
      // Discussion rechecks project and every member before requesting a turn.
      // Uncertain tools must be resolved before any new investigation/model.
      await _pauseForDiscussion(task, '重新核对协作方案与成员。');
      if (root.containsKey('uncertainAction')) {
        task
          ..resumeRequired = true
          ..lastError = '上次操作结果不确定，请核对副作用后再继续。';
      }
      await _save(task);
      if (!task.resumeRequired) _maybeStartDiscussion(task);
    } else {
      task.status = AgentTaskStatus.queued;
      _conversationReservations.remove(task.groupId);
      await _save(task);
      _enqueueTask(task);
    }
    _publish(task);
    await _schedule();
    return true;
  }
}
