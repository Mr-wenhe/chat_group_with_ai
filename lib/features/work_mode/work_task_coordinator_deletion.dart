part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorDeletion on WorkTaskCoordinator {
  /// 真删除一条任务记录。
  ///
  /// 顺序是刻意的：先按"停止"的口径把该任务占用的资源全部释放（执行中的
  /// runner、会话保留、资源锁、排队、自动续跑标记），再删 Hive 记录，最后删
  /// 事件日志。任何在删除之后发生的 `_record` 都会用同一个 taskId 重建 JSONL，
  /// 所以日志必须最后删；Hive 记录被删掉之后，运行的终局回调会因为
  /// `_running` 里已无该任务而直接返回，不会把记录写回来。
  Future<void> _implDeleteTask(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _taskBox.get(taskId);
      if (task == null) {
        throw StateError('该任务已不存在。');
      }
      // 先登记墓碑再释放：迟到的写入必须从这里开始就被拒绝，否则删除刚返回就被
      // 一个正在收尾的 runner 写回记录。
      _deletedTaskIds.add(taskId);
      // 快照账本要记真实结局：用户删掉一条**已结束**的任务时，它仍然是它原来的
      // 终态（快照还在、撤销仍可达）；只有进行中的任务才因为被删除而记 cancelled。
      final wasTerminal = task.isTerminal;
      if (wasTerminal) await _markSnapshotStatus(task);
      _releaseTaskResourcesForDeletion(task);
      await _taskBox.delete(taskId);
      // 列表流只把这次写入当作"回读 Hive"的信号，因此这里不校验对象本身。
      _publishTaskListChanged(task);
      if (!wasTerminal) await _markSnapshotStatus(task);
      await _eventStore.deleteEvents(taskId);
      _makeConversationReady(task.groupId);
      await _schedule();
    });
  }

  /// 取消并释放一条任务占用的全部内存态资源。
  ///
  /// 与 `_implStop` 的收尾同口径，但只做释放：删除路径不能再落任何事件或
  /// checkpoint，否则被删掉的记录会立刻被写回来。
  void _releaseTaskResourcesForDeletion(AgentTask task) {
    _removeQueuedTask(task);
    _running.remove(task.id)?.cancellation.cancel();
    _startingTaskIds.remove(task.id);
    _discussionCancellations.remove(task.id)?.cancel();
    _discussionRuns.remove(task.id);
    _discussionStartingIds.remove(task.id);
    _cancelInstallations(task.id);
    _folderWaiters.remove(task.id)?.cancel();
    final waiting = _waitingForResources.remove(task.id);
    waiting?.cancellation.cancel();
    final waitingLease = waiting?.lease;
    if (waitingLease != null) unawaited(waitingLease.release());
    _handoffsAwaitingLease.remove(task.id);
    _taskLockPlans.remove(task.id);
    _autoResumeTaskIds.remove(task.id);
    _conversationReservations.remove(task.groupId);
    // 启动流程可能正停在一个 await 上（讨论门禁、执行资格校验），而它的取消
    // 令牌要等那个 await 返回后才登记——上面那几行取消不到它。把内存对象标成
    // 终态并清空可执行状态，这些续跑恢复后就会看到"已终止"而自行退出。
    task
      ..status = AgentTaskStatus.cancelled
      ..resumeRequired = false
      ..pendingToolRequestJson = ''
      ..queuedUserRequests = <String>[]
      ..updatedAt = _clock();
  }
}
