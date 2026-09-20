part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorPermissionActions on WorkTaskCoordinator {
  Future<void> _installMissingTool(
    String taskId, {
    int? expectedActionVersion,
  }) async {
    if (_runner is! WorkTaskInstallHandler) {
      throw StateError('当前执行器不支持应用内安装工具。');
    }
    final handler = _runner as WorkTaskInstallHandler;
    final cancellation = WorkTaskCancellation();
    final task = await _serialize(() async {
      _ensureOpen();
      final current = _requireWorkTask(taskId);
      if (!_hasInstallableMissingTool(current)) {
        throw StateError('当前任务没有等待安装的缺失工具。');
      }
      if (expectedActionVersion != null &&
          _installActionVersion(current) != expectedActionVersion) {
        throw StateError('该安装提醒已失效，请打开任务面板查看最新状态。');
      }
      _installCancellations
          .putIfAbsent(taskId, () => <WorkTaskCancellation>{})
          .add(cancellation);
      return current;
    });
    try {
      final result = await handler.installMissingTool(task, cancellation);
      await _serialize(() async {
        if (_disposed) return;
        final stored = _taskBox.get(taskId);
        if (stored == null || stored.isTerminal) return;
        // Installation is an asynchronous side effect. The task may have been
        // cancelled, revised, or replaced with a new missing-tool checkpoint
        // while the installer was running. Only the exact checkpoint that
        // authorized this run may consume its result.
        final currentToolAction = _installActionVersion(stored);
        if (expectedActionVersion != null
            ? currentToolAction != expectedActionVersion
            : !_hasInstallableMissingTool(stored)) {
          return;
        }
        if (result.succeeded) {
          final execution = _decodeExecutionMap(stored.executionStateJson)
            ..remove('toolMissing');
          stored
            ..status = AgentTaskStatus.queued
            ..resumeRequired = false
            ..lastError = ''
            ..executionStateJson =
                execution.isEmpty ? '' : jsonEncode(execution)
            ..updatedAt = _clock();
          _conversationReservations.remove(stored.groupId);
          await _save(stored);
          _enqueueTask(stored);
          unawaited(_record(
            stored,
            WorkTaskEventKind.queued,
            '缺失工具安装完成，继续原任务',
          ));
          await _schedule();
        } else {
          final failure = WorkFailure.fromToolResult(
            WorkToolResult(
              status: result.status == WorkCommandRunStatus.toolMissing
                  ? WorkToolResultStatus.paused
                  : WorkToolResultStatus.failed,
              message: result.message,
              failureCode: result.status == WorkCommandRunStatus.toolMissing
                  ? 'toolMissing'
                  : 'commandFailed',
            ),
            completedContent: _completedContentForTask(stored),
          );
          _applyFailure(
            stored,
            failure,
            status: AgentTaskStatus.paused,
            clearPendingTool: false,
          );
          await _save(stored);
          unawaited(_record(
            stored,
            WorkTaskEventKind.paused,
            '缺失工具安装未完成',
            detail: failure.technicalDetail,
          ));
        }
      });
    } finally {
      final active = _installCancellations[taskId];
      active?.remove(cancellation);
      if (active != null && active.isEmpty) {
        _installCancellations.remove(taskId);
      }
    }
  }

  /// Opens the app-level picker from the execution panel and requeues the
  /// waiting task when the selected directory covers its requested path.
  Future<void> _implRequestFolderForTask(
    String taskId, {
    int? expectedActionVersion,
  }) {
    final runKey = _userActionRunKey(
      taskId,
      'folderAuthorization',
      expectedActionVersion,
    );
    final existing = _folderActionRuns[runKey];
    if (existing != null) return existing;
    late final Future<void> tracked;
    final operation = _requestFolderForTask(
      taskId,
      expectedActionVersion: expectedActionVersion,
    );
    tracked = operation.then<void>(
      (_) {
        if (identical(_folderActionRuns[runKey], tracked)) {
          _folderActionRuns.remove(runKey);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_folderActionRuns[runKey], tracked)) {
          _folderActionRuns.remove(runKey);
        }
        Error.throwWithStackTrace(error, stack);
      },
    );
    _folderActionRuns[runKey] = tracked;
    return tracked;
  }

  Future<void> _requestFolderForTask(
    String taskId, {
    int? expectedActionVersion,
  }) async {
    final preparation = await _serialize(() async {
      _ensureOpen();
      final grantService = _folderGrantService;
      if (grantService == null || _folderPicker == null) {
        throw StateError('当前没有可用的工作目录选择器。');
      }
      final task = _requireWorkTask(taskId);
      if (expectedActionVersion != null &&
          WorkTaskUserAction.versionFor(task, 'folderAuthorization') !=
              expectedActionVersion) {
        throw StateError('该目录授权提醒已失效，请打开任务面板查看最新状态。');
      }
      if (expectedActionVersion == null &&
          !_folderPending(
            task,
            _decodeExecutionMap(task.executionStateJson),
          )) {
        // A legacy reauthorization may not have a typed action marker, but it
        // still needs the durable folder checkpoint. Never let an unrelated
        // approval or paused task open a new native picker.
        throw StateError('当前任务没有等待目录授权。');
      }
      final requestedPath = _requestedFolderPath(task);
      // Start or join the process-global picker but do not await it while the
      // coordinator serial queue is held. Stop/revise actions must be able to
      // commit a newer checkpoint while the native dialog is open.
      final request = _requestFolder(
        grantService,
        task: task,
        requestedPath: requestedPath,
      );
      return (request: request,);
    });

    WorkFolderRequestResult folderResult;
    try {
      folderResult = await preparation.request;
    } on Object catch (error) {
      await _failFolderAuthorization(
        taskId,
        expectedActionVersion: expectedActionVersion,
        error: error,
      );
      return;
    }
    if (!folderResult.granted) {
      await _failFolderAuthorization(
        taskId,
        expectedActionVersion: expectedActionVersion,
        reason: folderResult.reason,
      );
      return;
    }

    final currentTask = await _serialize<AgentTask?>(() async {
      if (_disposed) return null;
      final current = _taskBox.get(taskId);
      if (!_canApplyFolderResult(current, expectedActionVersion)) {
        _throwIfFolderActionIsStale(current, expectedActionVersion);
        return null;
      }
      return current;
    });
    if (currentTask == null) return;

    // Workspace rebinding can involve Hive/file-system work. Keep it outside
    // the coordinator queue, then validate the exact action again before the
    // queued transition so a stop or revision during rebinding cannot revive
    // the old folder scope.
    await _rebindWorkspaceAfterGrant(currentTask, folderResult.grant);
    await _serialize(() async {
      if (_disposed) return;
      final latest = _taskBox.get(taskId);
      if (!_canApplyFolderResult(latest, expectedActionVersion)) {
        _throwIfFolderActionIsStale(latest, expectedActionVersion);
        return;
      }
      final activeTask = latest!;
      _conversationReservations.remove(activeTask.groupId);
      activeTask
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..lastError = ''
        ..executionStateJson =
            _withoutFolderRequest(activeTask.executionStateJson)
        ..updatedAt = _clock();
      await _save(activeTask);
      _enqueueTask(activeTask);
      await _schedule();
    });
  }

  Future<void> _failFolderAuthorization(
    String taskId, {
    required int? expectedActionVersion,
    Object? error,
    String? reason,
  }) {
    return _serialize(() async {
      if (_disposed) return;
      final current = _taskBox.get(taskId);
      if (!_canApplyFolderResult(current, expectedActionVersion)) {
        _throwIfFolderActionIsStale(current, expectedActionVersion);
        return;
      }
      final diagnostic = error == null
          ? null
          : WorkFailure.fromError(
              error,
              scope: 'authorization',
              completedContent: _completedContentForTask(current!),
            );
      final message =
          reason?.trim().isNotEmpty == true ? reason!.trim() : '未完成工作目录授权。';
      final failure = error == null
          ? WorkFailure.fromToolFailure(
              code: 'authorizationLost',
              message: message,
              completedContent: _completedContentForTask(current!),
            )
          : WorkFailure.fromToolFailure(
              code: 'authorizationLost',
              message: '工作目录授权请求失败，请重新选择目录。',
              completedContent: diagnostic!.completedContent,
            );
      _applyFailure(
        current!,
        failure,
        status: AgentTaskStatus.paused,
        clearPendingTool: false,
      );
      await _save(current);
      await _record(
        current,
        WorkTaskEventKind.paused,
        '等待工作目录授权',
        detail: diagnostic?.technicalDetail ?? failure.technicalDetail,
      );
    });
  }

  bool _canApplyFolderResult(AgentTask? task, int? expectedActionVersion) {
    if (_disposed || task == null || task.isTerminal) return false;
    if (expectedActionVersion != null) {
      return WorkTaskUserAction.versionFor(task, 'folderAuthorization') ==
          expectedActionVersion;
    }
    return _folderPending(task, _decodeExecutionMap(task.executionStateJson));
  }

  void _throwIfFolderActionIsStale(
    AgentTask? task,
    int? expectedActionVersion,
  ) {
    if (expectedActionVersion != null &&
        task != null &&
        !task.isTerminal &&
        WorkTaskUserAction.versionFor(task, 'folderAuthorization') !=
            expectedActionVersion) {
      throw StateError('该目录授权提醒已失效，请打开任务面板查看最新状态。');
    }
  }

  Future<void> _resolveApproval(
    String taskId,
    String decision, {
    int? expectedActionVersion,
  }) {
    final runKey = _userActionRunKey(
      taskId,
      'commandApproval:$decision',
      expectedActionVersion,
    );
    final existing = _approvalRuns[runKey];
    if (existing != null) return existing;
    late final Future<void> tracked;
    final operation = _resolveApprovalOperation(
      taskId,
      decision,
      expectedActionVersion: expectedActionVersion,
    );
    tracked = operation.then<void>(
      (_) {
        if (identical(_approvalRuns[runKey], tracked)) {
          _approvalRuns.remove(runKey);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_approvalRuns[runKey], tracked)) {
          _approvalRuns.remove(runKey);
        }
        Error.throwWithStackTrace(error, stack);
      },
    );
    _approvalRuns[runKey] = tracked;
    return tracked;
  }

  Future<void> _resolveApprovalOperation(
    String taskId,
    String decision, {
    int? expectedActionVersion,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.waitingForApproval ||
          task.pendingToolRequestJson.trim().isEmpty) {
        throw StateError('当前任务没有待处理的工具审批。');
      }
      final discussion = WorkDiscussionState.decodeExecutionState(
        task.executionStateJson,
      );
      if (discussion.present &&
          (discussion.state == null || !discussion.state!.isExecutionReady)) {
        // A pre-discussion approval checkpoint is retained for recovery, but
        // it must not become executable until the group has selected a valid
        // executor and committed the current request revision.
        throw StateError('请先完成群讨论并确定最终执行角色。');
      }
      if (expectedActionVersion != null &&
          WorkTaskUserAction.versionFor(task, 'commandApproval') !=
              expectedActionVersion) {
        throw StateError('该审批提醒已失效，请打开任务面板查看最新状态。');
      }
      final parsedDecision = WorkChangeApprovalDecision.fromWire(decision);
      if (parsedDecision == null) {
        throw ArgumentError.value(decision, 'decision', '审批决定无效');
      }
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..executionStateJson = _withApprovalDecision(
          task.executionStateJson,
          decision,
        )
        ..updatedAt = _clock();
      _conversationReservations.remove(task.groupId);
      _folderWaiters.remove(task.id)?.cancel();
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(
        task,
        WorkTaskEventKind.queued,
        parsedDecision.permitsExecution
            ? parsedDecision.permitsWithoutUndo
                ? '用户已批准无撤销执行，继续执行'
                : '用户已批准，继续执行'
            : '用户已拒绝，尝试安全替代路径',
      ));
      await _schedule();
    });
  }

  String _userActionRunKey(
    String taskId,
    String blockerId,
    int? version,
  ) =>
      '$taskId\u001f$blockerId\u001f${version ?? 0}';

  /// Stops only the requested task. Other conversations keep their slots.
  Future<void> _implStop(String taskId, {String reason = '用户已停止任务。'}) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.isTerminal) {
        throw StateError('终态任务不能停止。');
      }
      _removeQueuedTask(task);
      // Cancel before mutating the shared Hive object so a late progress
      // callback observes the cancellation and cannot resurrect running state.
      _running[taskId]?.cancellation.cancel();
      _discussionCancellations.remove(taskId)?.cancel();
      _cancelInstallations(taskId);
      _folderWaiters.remove(taskId)?.cancel();
      final waiting = _waitingForResources.remove(taskId);
      waiting?.cancellation.cancel();
      final waitingLease = waiting?.lease;
      if (waitingLease != null) unawaited(waitingLease.release());
      _conversationReservations.remove(task.groupId);
      _makeConversationReady(task.groupId);
      _taskLockPlans.remove(taskId);
      final droppedFollowUps =
          List<String>.unmodifiable(task.queuedUserRequests);
      task
        ..status = AgentTaskStatus.cancelled
        ..resumeRequired = false
        ..pendingToolRequestJson = ''
        ..queuedUserRequests = <String>[]
        ..lastError = sanitizeWorkTaskError(reason)
        ..updatedAt = _clock();
      await _save(task);
      await _markSnapshotStatus(task);
      unawaited(
        _record(task, WorkTaskEventKind.failed, '任务已停止', detail: reason),
      );
      if (droppedFollowUps.isNotEmpty) {
        // Stopping is terminal for this task, but the user's queued amendments
        // must not vanish without a trace. Record exactly what was discarded so
        // the task history explains why those messages never ran.
        unawaited(
          _record(
            task,
            WorkTaskEventKind.failed,
            '已停止任务：${droppedFollowUps.length} 条待处理的追问未执行',
            detail: droppedFollowUps.join('\n'),
          ),
        );
      }
      await _schedule();
    });
  }

  void _cancelInstallations(String taskId) {
    final cancellations = _installCancellations.remove(taskId);
    if (cancellations == null) return;
    for (final cancellation in cancellations) {
      cancellation.cancel();
    }
  }
}
