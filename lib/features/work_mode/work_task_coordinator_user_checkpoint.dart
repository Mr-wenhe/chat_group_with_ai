part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorUserCheckpoint on WorkTaskCoordinator {
  Future<void> _pauseForSupplement(String taskId) => _serialize(() async {
        _ensureOpen();
        final task = _requireWorkTask(taskId);
        if (task.isTerminal ||
            !WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) {
          throw StateError('当前任务不能暂停补充需求。');
        }
        WorkTaskCompletionChoice.setPaused(task, true);
        _removeQueuedTask(task);
        _autoResumeTaskIds.remove(taskId);
        final waiting = _waitingForResources.remove(taskId);
        waiting?.cancellation.cancel();
        if (waiting?.lease != null) unawaited(waiting!.lease!.release());
        if (!_running.containsKey(taskId) &&
            !_discussionRuns.containsKey(taskId)) {
          task.status = AgentTaskStatus.paused;
          task.resumeRequired = false;
        }
        task.lastError = '已请求暂停补充需求；当前动作结束后停在安全检查点，点击继续才恢复。';
        _conversationReservations.add(task.groupId);
        await _save(task);
        await _record(task, WorkTaskEventKind.paused, '用户请求暂停补充需求',
            detail: task.lastError);
      });

  Future<void> _chooseCandidateCompletion(String taskId, String identity,
          {required bool test}) =>
      _serialize(() async {
        _ensureOpen();
        final task = _requireWorkTask(taskId);
        if (isTaskInFlight(taskId) ||
            !WorkTaskCompletionChoice.pending(task) ||
            WorkTaskCompletionChoice.identity(task) != identity ||
            task.queuedUserRequests.isNotEmpty ||
            (_arrivingInputCounts[taskId] ?? 0) > 0) {
          throw StateError('候选已变化或仍有输入待处理，请等待安全停点后确认。');
        }
        final executor = _runner;
        if (!test && executor is! WorkTaskUserCandidateDelivery) {
          throw StateError('当前执行器不支持用户确认交付。');
        }
        WorkTaskCompletionChoice.setChoice(task, test ? 'test' : 'deliver');
        WorkTaskCompletionChoice.setPaused(task, false);
        await _save(task);
        if (test) {
          task
            ..status = AgentTaskStatus.queued
            ..lastError = '';
          await _save(task);
          _releaseConversationReservationFor(task);
          _enqueueTask(task, prioritize: true);
          await _record(task, WorkTaskEventKind.queued, '用户选择继续测试');
          await _schedule();
          return;
        }
        bool delivered;
        try {
          delivered = await (executor as WorkTaskUserCandidateDelivery)
              .deliverUserConfirmedCandidate(task,
                  hasArrivingInput: () =>
                      (_arrivingInputCounts[taskId] ?? 0) > 0);
        } on Object catch (error) {
          task
            ..status = AgentTaskStatus.paused
            ..resumeRequired = false
            ..lastError = sanitizeWorkTaskError(error);
          await _save(task);
          await _record(task, WorkTaskEventKind.paused, '交付未完结',
              detail: task.lastError);
          rethrow;
        }
        if ((_arrivingInputCounts[taskId] ?? 0) > 0) {
          task.status = AgentTaskStatus.paused;
          task.lastError = '新增输入待处理，尚未完结。';
        } else {
          task
            ..status =
                delivered ? AgentTaskStatus.completed : AgentTaskStatus.paused
            ..resumeRequired = false
            ..lastError = delivered ? '' : '附件投递失败，请再次选择可完成以重发同一成果。'
            ..resultSummary = '用户确认直接交付；未经过本轮测试／独立审查。';
        }
        await _save(task);
        await _markSnapshotStatus(task);
        await _record(
            task,
            task.status == AgentTaskStatus.completed
                ? WorkTaskEventKind.completed
                : WorkTaskEventKind.paused,
            task.status == AgentTaskStatus.completed
                ? '用户确认交付并完结（未测试）'
                : '交付尚未完结');
        if (task.isTerminal) {
          _releaseConversationReservationFor(task);
          _makeConversationReady(task.groupId);
          await _schedule();
        }
      });
}
