part of 'work_task_panel.dart';

extension _TaskActionRecovery on _TaskActions {
  bool _hasPendingDiscussionCheckpoint(AgentTask task) {
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final state = decoded.state;
    return decoded.isValid &&
        state != null &&
        !state.isExecutionReady &&
        !task.isTerminal &&
        (task.status == AgentTaskStatus.paused ||
            task.status == AgentTaskStatus.interrupted ||
            task.status == AgentTaskStatus.waitingForApproval);
  }

  bool _discussionAllowsApproval(AgentTask task) {
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    // A malformed or unfinished discussion checkpoint is a hard gate. Legacy
    // tasks without the extension remain compatible with the existing
    // approval panel, while any typed marker must first reach a valid ready
    // state before an approval action is even presented.
    if (!discussion.present) return true;
    return discussion.state?.isExecutionReady == true;
  }

  String? _pendingDiscussionQuestion(AgentTask task) {
    if (task.isTerminal ||
        (task.status != AgentTaskStatus.paused &&
            task.status != AgentTaskStatus.interrupted)) {
      return null;
    }
    final action = WorkTaskUserAction.forTask(task)
        .where(
          (item) => item.kind == WorkTaskUserActionKind.answerQuestion,
        )
        .firstOrNull;
    if (action == null || action.blockerId == 'clarificationRequired') {
      return null;
    }
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final state = decoded.state;
    if (!decoded.isValid || state == null || state.isExecutionReady) {
      return null;
    }
    final question = state.openQuestions
        .map((item) => item.trim())
        .firstWhere((item) => item.isNotEmpty, orElse: () => '');
    if (question.isNotEmpty) return question;
    return '请补充群讨论所需的必要信息。';
  }

  Future<bool> _runVersionedAction(String blockerId, WorkTaskAction? legacy,
      WorkTaskVersionedAction? versioned,
      {int? expectedVersion}) {
    final current = WorkTaskUserAction.forTask(task)
        .where((action) => action.blockerId == blockerId)
        .firstOrNull;
    final currentVersion = current?.version ??
        (blockerId == 'discussionRequired'
            ? WorkTaskUserAction.discussionCheckpointVersion(task)
            : 0);
    final version = expectedVersion ?? currentVersion;
    if (expectedVersion != null &&
        (expectedVersion == 0 || currentVersion != expectedVersion)) {
      // Once a button has a rendered checkpoint, an absent or changed marker
      // means it is stale. This guard also protects legacy callbacks supplied
      // by lightweight hosts; otherwise they could act on a newer scope.
      return runAction(
        (_) => throw StateError('该任务提醒已失效，请打开任务面板查看最新状态。'),
      );
    }
    if (versioned != null) {
      if (version == 0) {
        return runAction(
          (_) => throw StateError('该任务提醒已失效，请打开任务面板查看最新状态。'),
        );
      }
      return runAction((_) => versioned(task.id, version));
    }
    if (legacy != null) return runAction(legacy);
    return Future<bool>.value(false);
  }

  Future<void> _approveWithConfirmation(
    BuildContext context,
    WorkChangePlan? approvalPlan, {
    required int expectedVersion,
  }) async {
    if (onApprove == null && onApproveVersioned == null) return;
    if (_pendingToolRequiresPlan(task) && approvalPlan == null) return;
    if (approvalPlan == null) {
      await _runVersionedAction(
        'commandApproval',
        onApprove,
        onApproveVersioned,
        expectedVersion: expectedVersion,
      );
      return;
    }
    final decision = await _showTaskModal<WorkChangeApprovalDecision>(
      () => WorkChangeApprovalDialog.show(
        dialogContext ?? context,
        plan: approvalPlan,
      ),
    );
    if (decision == WorkChangeApprovalDecision.approved) {
      await _runVersionedAction(
        'commandApproval',
        onApprove,
        onApproveVersioned,
        expectedVersion: expectedVersion,
      );
    } else if (decision == WorkChangeApprovalDecision.rejected &&
        (onReject != null || onRejectVersioned != null)) {
      await _runVersionedAction(
        'commandApproval',
        onReject,
        onRejectVersioned,
        expectedVersion: expectedVersion,
      );
    }
  }

  Future<void> _approveWithoutUndoWithConfirmation(
    BuildContext context,
    WorkChangePlan? approvalPlan, {
    required int expectedVersion,
  }) async {
    if (onApproveWithoutUndo == null && onApproveWithoutUndoVersioned == null) {
      return;
    }
    if (_pendingToolRequiresPlan(task) && approvalPlan == null) return;
    if (approvalPlan == null) {
      final confirmed = await _confirmNoUndoMutation(context);
      if (confirmed) {
        await _runVersionedAction(
          'commandApproval',
          onApproveWithoutUndo,
          onApproveWithoutUndoVersioned,
          expectedVersion: expectedVersion,
        );
      }
      return;
    }
    final decision = await _showTaskModal<WorkChangeApprovalDecision>(
      () => WorkChangeApprovalDialog.show(
        dialogContext ?? context,
        plan: approvalPlan,
      ),
    );
    if (decision == WorkChangeApprovalDecision.approvedWithoutUndo) {
      await _runVersionedAction(
        'commandApproval',
        onApproveWithoutUndo,
        onApproveWithoutUndoVersioned,
        expectedVersion: expectedVersion,
      );
    } else if (decision == WorkChangeApprovalDecision.rejected &&
        (onReject != null || onRejectVersioned != null)) {
      await _runVersionedAction(
        'commandApproval',
        onReject,
        onRejectVersioned,
        expectedVersion: expectedVersion,
      );
    }
  }

  Future<bool> _confirmNoUndoMutation(BuildContext context) async {
    final confirmed = await _showTaskModal<bool>(
      () => showDialog<bool>(
        context: dialogContext ?? context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          key: const Key('work-task-no-undo-dialog'),
          title: const Text('确认无撤销执行'),
          content: Text(
            '${_safePanelText(task.lastError)}\n\n'
            '该应用内配置没有文件快照，执行后不能通过任务撤销恢复。是否继续？',
          ),
          actions: [
            TextButton(
              key: const Key('work-task-no-undo-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('work-task-no-undo-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认执行'),
            ),
          ],
        ),
      ),
    );
    return confirmed == true;
  }

  Future<void> _confirmUndo(BuildContext context) async {
    final preview = undoPreviewFor;
    List<WorkSnapshotUndoItem> items = const [];
    var previewFailed = false;
    if (preview != null) {
      try {
        items = await preview(task.id);
      } on Object {
        // Never execute an unknown undo scope. The user can retry after the
        // manifest becomes readable again.
        previewFailed = true;
      }
    }
    if (!context.mounted) return;
    final confirmed = await _showTaskModal<bool>(
      () => showDialog<bool>(
        context: dialogContext ?? context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          key: const Key('work-task-undo-dialog'),
          title: const Text('撤销本任务改动'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 360),
            child: previewFailed
                ? const Text('无法读取任务快照，未执行撤销。请稍后重试。')
                : items.isEmpty
                    ? const Text('没有可撤销的已完成文件改动。')
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: items
                              .map(
                                (item) => Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Text(_safeUndoItemText(item.label)),
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ),
          ),
          actions: [
            TextButton(
              key: const Key('work-task-undo-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('work-task-undo-confirm'),
              onPressed: previewFailed
                  ? null
                  : () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认撤销'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) await runAction(onUndo!);
  }

  Future<void> _confirmInstallTool(
    BuildContext context, {
    required int expectedVersion,
  }) async {
    if (onInstallTool == null && onInstallToolVersioned == null) return;
    final confirmed = await _showTaskModal<bool>(
      () => showDialog<bool>(
        context: dialogContext ?? context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          key: const Key('work-task-install-tool-dialog'),
          title: const Text('安装缺失工具？'),
          content: Text(
            '${_safePanelText(task.lastError)}\n\n'
            '仅执行应用识别的可信安装命令；不会加入永久授权。安装完成后将继续原任务。',
          ),
          actions: [
            TextButton(
              key: const Key('work-task-install-tool-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('work-task-install-tool-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认安装'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await _runVersionedAction(
        'toolMissing',
        onInstallTool,
        onInstallToolVersioned,
        expectedVersion: expectedVersion,
      );
    }
  }

  /// 删除是任务级不可逆操作，确认框必须把它和"关掉标签"区分开：
  /// 记录与执行日志都会消失，但已生成的文件不动。
  Future<void> _confirmDelete(BuildContext context) async {
    final onDelete = onDeleteTask;
    if (onDelete == null) return;
    onModalVisibilityChanged?.call(false);
    bool confirmed;
    try {
      confirmed = await _confirmWorkTaskDeletion(
        context,
        task: task,
        dialogContext: dialogContext,
      );
    } finally {
      onModalVisibilityChanged?.call(true);
    }
    if (confirmed) await runAction(onDelete);
  }

  /// The app-scoped panel is painted above the route Navigator. Hide it while
  /// any task modal is open so approval, cancellation, and undo controls stay
  /// reachable in narrow windows as well as wide windows.
  Future<T?> _showTaskModal<T>(Future<T?> Function() show) async {
    onModalVisibilityChanged?.call(false);
    try {
      return await show();
    } finally {
      onModalVisibilityChanged?.call(true);
    }
  }
}

/// 删除任务的确认框。
///
/// 两处入口（标签详情、历史详情）共用同一份说明，避免同一个不可逆操作在两个
/// 地方给出不同的解释。
Future<bool> _confirmWorkTaskDeletion(
  BuildContext context, {
  required AgentTask task,
  required BuildContext? dialogContext,
}) async {
  final confirmed = await showDialog<bool>(
    context: dialogContext ?? context,
    barrierDismissible: true,
    builder: (dialogContext) => AlertDialog(
      key: const Key('work-task-delete-dialog'),
      title: const Text('删除这条任务？'),
      content: Text(
        '任务记录和执行日志都会被删除，无法恢复。\n'
        '${task.isTerminal ? '' : '任务尚未结束，会先停止它；正在执行的工具会先跑完，'
            '期间仍可能产生文件改动。\n'}'
        '已经生成的文件不会被删除。',
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('work-task-delete-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('work-task-delete-confirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('删除任务'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
