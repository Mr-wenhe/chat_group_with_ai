part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorSubmission on WorkTaskCoordinator {
  int get _implRunningTaskCount => _running.length;

  /// Quiesces every work task before the app-wide data lifecycle service
  /// removes event logs and snapshots. Active runners are cancelled
  /// cooperatively, while their finalizers are drained outside [_serialize]
  /// to avoid the runner's own completion checkpoint deadlocking the queue.
  Future<void> _implStopAllForDataClear() async {
    var activeRuns = <Future<void>>[];
    await _serialize(() async {
      if (_disposed) return;
      _dataClearInProgress = true;
      _eventStore.suspendAppendsForDataClear();
      // Terminal tasks are skipped by the loop below, so clear every pending
      // automatic-resume marker outright.
      _autoResumeTaskIds.clear();
      activeRuns = List<Future<void>>.from(_activeRuns.values);
      activeRuns.addAll(_discussionRuns.values);
      activeRuns.addAll(_installRuns.values);
      for (final task in _allWorkTasks()) {
        if (task.isTerminal) continue;
        _removeQueuedTask(task);
        _running[task.id]?.cancellation.cancel();
        _discussionCancellations.remove(task.id)?.cancel();
        _cancelInstallations(task.id);
        _folderWaiters.remove(task.id)?.cancel();
        final waiting = _waitingForResources.remove(task.id);
        waiting?.cancellation.cancel();
        final lease = waiting?.lease;
        if (lease != null) unawaited(lease.release());
        _conversationReservations.remove(task.groupId);
        _handoffsAwaitingLease.remove(task.id);
        _taskLockPlans.remove(task.id);
        task
          ..status = AgentTaskStatus.cancelled
          ..resumeRequired = false
          ..pendingToolRequestJson = ''
          ..queuedUserRequests = <String>[]
          ..lastError = sanitizeWorkTaskError('App 数据清除前已停止工作任务。')
          ..updatedAt = _clock();
        await _save(task);
        await _markSnapshotStatus(task);
        unawaited(
          _record(task, WorkTaskEventKind.failed, 'App 数据清除前已停止任务'),
        );
      }
      _readyConversations.clear();
      _readyConversationIds.clear();
      _conversationQueues.clear();
      _notifySlotAvailable();
    });
    if (activeRuns.isNotEmpty) {
      await Future.wait<void>(activeRuns, eagerError: false);
    }
    // Wait for runner finalizers and any cancellation callbacks queued behind
    // the first serialized operation before the event/snapshot trees are
    // deleted. The no-op also makes this method a durable barrier for callers.
    await _serialize(() async {});
  }

  /// Reopens scheduling after a clear attempt has finished. The coordinator
  /// instance remains app-scoped; clearing data must not dispose it.
  Future<void> _implResumeAfterDataClear() {
    return _serialize(() async {
      if (_disposed) return;
      _dataClearInProgress = false;
      _eventStore.resumeAppendsAfterDataClear();
      // 删除闸门**不**在这里清：清除后的记录要么不存在（闸门无害），要么由导入
      // 带回来（导入路径会逐 id 核对解禁）。整表清空会给"记录仍不存在"的 id
      // 开一个口子，让迟到续跑把它们写回来。
      await _schedule();
    });
  }

  /// Lets the app-level overlay provide the one-time cloud-disclosure dialog
  /// without coupling the scheduler to a particular [BuildContext].
  void _implSetFolderGrantConsent(WorkFolderGrantConsent? consent) {
    _folderGrantConsent = consent;
  }

  /// Persists and schedules a new V1 work task. The task is queued before a
  /// runner can observe it, which makes state recoverable at every boundary.
  Future<AgentTask> _implSubmit(
    AgentTask task, {
    Iterable<WorkResourceLockRequest>? resourceLocks,
  }) {
    return _serialize(() async {
      _ensureOpen();
      if (!task.workModeTask) {
        throw ArgumentError.value(task, 'task', '协调器只接受工作模式任务');
      }
      if (_taskBox.containsKey(task.id)) {
        throw StateError('工作任务已存在：${task.id}');
      }
      // Review the complete execution payload before decoding the discussion
      // extension. A malformed payload makes the discussion decoder report an
      // invalid marker; handling that first prevents submit from leaving the
      // raw string in place and treating it as a legacy runnable task later.
      if (workExecutionCheckpointRequiresReview(task.executionStateJson)) {
        await _pauseForCheckpointReview(task);
        return task;
      }
      final discussion = WorkDiscussionState.decodeExecutionState(
        task.executionStateJson,
      );
      if (resourceLocks != null) {
        final normalizedLocks = _resourceLockManager.normalizeLockSet(
          resourceLocks,
        );
        _taskLockPlans[task.id] = normalizedLocks;
        task.executionStateJson = _withResourceLockPlan(
          task.executionStateJson,
          normalizedLocks,
        );
      }
      if (discussion.present && _requiresDiscussionForTask(task)) {
        final state = discussion.state;
        if (state == null || state.conversationId != task.groupId) {
          await _pauseForDiscussion(
            task,
            '讨论状态无效或属于另一个群组，已等待重新确定讨论结果。',
          );
          await _save(task);
          return task;
        }
        if (state.isExecutionReady) {
          final identityError = _discussionIdentityError(task, state);
          if (identityError != null) {
            await _pauseForDiscussion(task, identityError);
            await _save(task);
            return task;
          }
          task.characterId = state.executorId!;
        } else {
          await _pauseForDiscussion(
            task,
            _discussionWaitingReason(state),
          );
          await _save(task);
          _maybeStartDiscussion(task);
          return task;
        }
      }
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..updatedAt = _clock();
      _refreshTaskContext(task);
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '任务已排队'));
      await _schedule();
      return task;
    });
  }

  /// Atomically records a discussion transition. S3 can call this method after
  /// the group has actually discussed and elected an executor; S2 keeps the
  /// transition durable and refuses stale revisions without starting a runner.
  Future<AgentTask> _implUpdateDiscussionState(
    String taskId,
    WorkDiscussionState next,
  ) =>
      _updateDiscussionState(taskId, next, fromDiscussionRunner: false);

  Future<AgentTask> _updateDiscussionState(
    String taskId,
    WorkDiscussionState next, {
    required bool fromDiscussionRunner,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.isTerminal) {
        throw StateError('终态任务不能再修改讨论状态。');
      }
      if (!_requiresDiscussionForTask(task)) {
        throw StateError('私聊任务不支持群讨论状态。');
      }
      if (_running.containsKey(taskId) || _startingTaskIds.contains(taskId)) {
        throw StateError('任务正在执行，不能并发修改讨论状态。');
      }
      if (_discussionRuns.containsKey(taskId) && !fromDiscussionRunner) {
        throw StateError('群讨论正在进行，不能从外部覆盖当前讨论状态。');
      }
      if (next.conversationId != task.groupId) {
        throw StateError('讨论状态属于另一个群组。');
      }
      final previous = WorkDiscussionState.decodeExecutionState(
        task.executionStateJson,
      );
      if (previous.present && previous.state == null) {
        throw StateError('旧讨论状态无法解析，不能用新状态覆盖安全边界。');
      }
      if (previous.state != null) {
        if (previous.state!.conversationId != task.groupId) {
          throw StateError('旧讨论状态属于另一个群组，不能覆盖安全边界。');
        }
        final previousRevision = previous.state!.requestRevision;
        if (next.requestRevision < previousRevision) {
          throw StateError('讨论请求版本已过期。');
        }
        if (next.requestRevision > previousRevision + 1) {
          throw StateError('讨论请求版本跳跃，不能覆盖中间版本。');
        }
      } else if (next.requestRevision != 1) {
        throw StateError('首个讨论请求版本必须从 1 开始。');
      }
      if (!next.isWithinBounds) {
        throw StateError('讨论状态字段越界或未规范化，不能写入执行门禁。');
      }
      final bounded = next.bounded();
      final identityError = bounded.isExecutionReady
          ? _discussionIdentityError(task, bounded)
          : null;
      if (identityError != null) {
        throw StateError(identityError);
      }
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        bounded,
      );
      if (bounded.isExecutionReady) {
        final execution = _decodeExecutionMap(task.executionStateJson);
        final hasPendingTool = task.pendingToolRequestJson.trim().isNotEmpty;
        final preservesFolderGate = _folderPending(task, execution) ||
            execution['toolMissing'] == true ||
            execution['visionModelRequired'] == true;
        // A legacy task may have been paused for the new discussion gate while
        // retaining a valid command checkpoint. Once discussion is ready,
        // restore the explicit approval surface instead of leaving a paused
        // task with an invisible pending operation.
        final preservesApprovalGate = hasPendingTool && !preservesFolderGate;
        final preservesPause = preservesFolderGate || preservesApprovalGate;
        task
          ..characterId = bounded.executorId!
          // Discussion readiness is independent from a tool approval that may
          // already be waiting on this task. Never turn a ready discussion
          // update into an implicit approval or discard its replay checkpoint.
          ..status = preservesApprovalGate
              ? AgentTaskStatus.waitingForApproval
              : preservesFolderGate
                  ? task.status
                  : AgentTaskStatus.queued
          ..resumeRequired = preservesPause ? task.resumeRequired : false
          ..lastError = preservesPause ? task.lastError : ''
          ..pendingToolRequestJson =
              preservesPause ? task.pendingToolRequestJson : ''
          ..updatedAt = _clock();
        if (!preservesApprovalGate) {
          _conversationReservations.remove(task.groupId);
        }
        _refreshTaskContext(
          task,
          nextStep:
              preservesApprovalGate ? '讨论已完成，仍等待工具审批。' : '讨论已完成，等待执行角色开始任务。',
        );
        await _save(task);
        await _markSnapshotStatus(task);
        if (preservesApprovalGate) {
          unawaited(
            _record(task, WorkTaskEventKind.approvalRequired, '讨论完成，仍等待工具审批'),
          );
        } else {
          _enqueueTask(task, prioritize: true);
          unawaited(
            _record(task, WorkTaskEventKind.queued, '讨论完成，任务已获得执行资格'),
          );
          await _schedule();
        }
      } else {
        await _pauseForDiscussion(
          task,
          _discussionWaitingReason(bounded),
        );
        await _save(task);
        await _markSnapshotStatus(task);
      }
      return task;
    });
  }

  /// Read-only helper used by panels/tests to avoid parsing the untrusted JSON
  /// extension in more than one place.
  WorkDiscussionDecodeResult _implDiscussionStateForTask(String taskId) {
    final task = _taskBox.get(taskId);
    if (task == null || !task.workModeTask) {
      return const WorkDiscussionDecodeResult.absent();
    }
    return WorkDiscussionState.decodeExecutionState(task.executionStateJson);
  }

  /// Returns the exact durable task addressed by a chat action. Callers must
  /// never replace this lookup with a "latest task" sort because an older
  /// paused checkpoint may still own the conversation.
  AgentTask? _implTaskById(String taskId) {
    final task = _taskBox.get(taskId);
    return task != null && task.workModeTask ? task : null;
  }

  /// Validates a message action against the current checkpoint. A completed,
  /// cancelled or revised task therefore makes the old button inert before
  /// any panel or coordinator operation is attempted.
  bool _implIsUserActionCurrent({
    required String taskId,
    required String blockerId,
    required int version,
  }) {
    final task = taskById(taskId);
    return task != null &&
        WorkTaskUserAction.isCurrent(
          task,
          blockerId: blockerId,
          version: version,
          isWindows: _installerIsWindows,
          isMacOS: _installerIsMacOS,
        );
  }

  /// Reopens the same discussion checkpoint after the user returns from the
  /// existing group-member management page. The role requirement is cleared
  /// only temporarily; the discussion runner must revalidate the actual
  /// membership, occupation and credentials before it can elect an executor.
  Future<void> _implRefreshDiscussionAfterMemberChange(
    String taskId, {
    required String blockerId,
    required int version,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.isTerminal ||
          !isUserActionCurrent(
            taskId: taskId,
            blockerId: blockerId,
            version: version,
          )) {
        throw StateError('该任务提醒已失效，请打开任务面板查看最新状态。');
      }
      final decoded = WorkDiscussionState.decodeExecutionState(
        task.executionStateJson,
      );
      final state = decoded.state;
      if (!decoded.isValid || state == null) {
        throw StateError('讨论状态已失效，不能重新验证群成员。');
      }
      if (!WorkTaskUserAction.roleBlockersForValidation.contains(blockerId)) {
        throw StateError('当前提醒不是群成员资格检查。');
      }
      _discussionCancellations[taskId]?.cancel();
      final nextRevision = state.requestRevision + 1;
      if (nextRevision > 2147483647) {
        throw StateError('讨论请求版本已达到上限，请重新发起任务。');
      }
      final contract = state.deliverableContract == null
          ? null
          : <String, dynamic>{
              ...state.deliverableContract!,
              'requestRevision': nextRevision,
            };
      final next = state.copyWith(
        phase: WorkDiscussionPhase.awaitingExecutor,
        requestRevision: nextRevision,
        clearExecutorId: true,
        candidateCharacterIds: const <String>[],
        blockers: state.blockers.where(
          (item) =>
              !WorkTaskUserAction.roleBlockersForValidation.contains(item) &&
              item != 'discussionRequired' &&
              item != 'executorSelectionRequired',
        ),
        deliverableContract: contract,
        clearDeliverableContract: contract == null,
      );
      task
        ..characterId = ''
        ..assignedCharacterIds = <String>[]
        ..status = AgentTaskStatus.paused
        ..resumeRequired = false
        ..lastError = '群成员已更新，正在重新验证符合职业资格的执行角色。'
        ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          task.executionStateJson,
          next,
        )
        ..updatedAt = _clock();
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.queued,
        '群成员已更新，重新开始讨论资格校验',
      );
      _maybeStartDiscussion(task);
    });
  }

  /// Leaves a blocker paused and records that the user deliberately deferred
  /// it. This is an explicit, idempotent panel action rather than an implicit
  /// downgrade or a hidden retry.
  Future<void> _implDeferUserAction(
    String taskId, {
    String? blockerId,
    int? version,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.isTerminal) throw StateError('终态任务不能稍后处理。');
      if (blockerId != null &&
          version != null &&
          !(blockerId == 'discussionRequired'
              ? WorkTaskUserAction.discussionCheckpointVersion(task) == version
              : isUserActionCurrent(
                  taskId: taskId,
                  blockerId: blockerId,
                  version: version,
                ))) {
        throw StateError('该任务提醒已失效，请打开任务面板查看最新状态。');
      }
      if (task.status != AgentTaskStatus.paused &&
          task.status != AgentTaskStatus.waitingForApproval &&
          task.status != AgentTaskStatus.interrupted) {
        throw StateError('当前任务没有可稍后处理的阻碍。');
      }
      task.updatedAt = _clock();
      await _save(task);
      await _record(task, WorkTaskEventKind.paused, '用户选择稍后处理当前阻碍');
    });
  }

  /// Returns the durable task that currently owns a conversation.  The chat
  /// page must not decide ownership by sorting the newest Hive row: after a
  /// restart an older paused task can still own the conversation, while a
  /// completed task may have a newer timestamp from a diagnostic checkpoint.
  /// Prefer in-process ownership, then any non-terminal checkpoint, and only
  /// use a terminal task as the follow-up lineage fallback.
  AgentTask? _implTaskForConversation(String conversationId) {
    final normalized = conversationId.trim();
    if (normalized.isEmpty) return null;
    final tasks = _taskBox.values
        .where((task) =>
            task.workModeTask &&
            task.groupId == normalized &&
            task.status != AgentTaskStatus.cancelled)
        .toList();
    if (tasks.isEmpty) return null;
    int ownershipRank(AgentTask task) {
      if (_running.containsKey(task.id)) return 4;
      if (_discussionRuns.containsKey(task.id) ||
          _discussionStartingIds.contains(task.id)) {
        return 3;
      }
      if (task.isTerminal) return 0;
      if (_conversationReservations.contains(normalized)) return 2;
      return 1;
    }

    tasks.sort((left, right) {
      final rank = ownershipRank(right).compareTo(ownershipRank(left));
      if (rank != 0) return rank;
      final rightTime = right.updatedAt ?? right.createdAt;
      final leftTime = left.updatedAt ?? left.createdAt;
      return rightTime.compareTo(leftTime);
    });
    return tasks.first;
  }
}
