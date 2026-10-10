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

  /// 群推举结果与合同钉定人不一致时的唯一出口：改派还是保留必须由用户选择。
  /// 讨论既不会自行改派钉定角色，也不会替用户把钉定角色重新推举回来，所以
  /// 没有这条确认，任务只会在轮数上限上反复暂停。
  Future<void> _confirmExecutorSwap(
    BuildContext context, {
    required int expectedVersion,
    required bool canKeepPinned,
  }) async {
    final callback = onConfirmExecutorSwap;
    if (callback == null) return;
    final state = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    ).state;
    final electedId = state?.executorId?.trim() ?? '';
    final pinnedValue = state?.deliverableContract?['explicitExecutorId'];
    final pinnedId = pinnedValue is String ? pinnedValue.trim() : '';
    final electedName = _executorDisplayName(electedId);
    final pinnedName = _executorDisplayName(pinnedId);
    final choice = await _showTaskModal<bool>(
      () => showDialog<bool>(
        context: dialogContext ?? context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          key: const Key('work-task-confirm-executor-dialog'),
          title: const Text('确认最终执行人'),
          content: Text(
            '群讨论推举「$electedName」执行本任务，但这条请求里钉定的是'
            '「$pinnedName」，两者不一致时讨论无法收敛。\n\n'
            '${canKeepPinned ? '改派后由「$electedName」接手；保留则由「$pinnedName」接手。' : '「$pinnedName」已不在本任务的合格候选内，只能改派。'}',
          ),
          actions: [
            TextButton(
              key: const Key('work-task-confirm-executor-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            if (canKeepPinned)
              OutlinedButton(
                key: const Key('work-task-confirm-executor-keep'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text('保留「$pinnedName」执行'),
              ),
            FilledButton(
              key: const Key('work-task-confirm-executor-swap'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text('改派给「$electedName」'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    await runAction((_) => callback(task.id, expectedVersion, choice));
  }

  String _executorDisplayName(String characterId) {
    final trimmed = characterId.trim();
    if (trimmed.isEmpty) return '未指定角色';
    final name = characterNameFor?.call(trimmed).trim() ?? '';
    return name.isEmpty ? trimmed : name;
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

  /// 「继续」的入口。
  ///
  /// 被停止打断的追问是有主的数据：继续之前必须问一次要不要一并执行，不能由
  /// 面板替用户决定。宿主没提供第二个答案时（纯展示用法）保持原样直接继续。
  Future<void> _startContinue(BuildContext context) async {
    final discard = onContinueWithoutFollowUps;
    if (!task.isUserStopped ||
        task.queuedUserRequests.isEmpty ||
        discard == null) {
      await runAction(onContinue);
      return;
    }
    final interrupted = task.queuedUserRequests.length;
    final keep = await _showTaskModal<bool>(
      () => showDialog<bool>(
        context: dialogContext ?? context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          key: const Key('work-task-continue-dialog'),
          title: const Text('继续这个任务'),
          content: Text('停止时有 $interrupted 条待处理的追问被打断，要一并执行吗？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('work-task-continue-drop-follow-ups'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('只继续，丢弃追问'),
            ),
            FilledButton(
              key: const Key('work-task-continue-keep-follow-ups'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('一并执行'),
            ),
          ],
        ),
      ),
    );
    if (keep == null) return;
    await runAction(keep ? onContinue : discard);
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

/// 删除"还没结束"的任务时的确认框。
///
/// 只有非终态任务才会走到这里：删除会先停止它，正在执行的工具会先跑完，期间
/// 仍可能产生文件改动，所以要用户点头。终态任务不弹窗，直接删。
/// 任务标签旁的 ✕ 是"关掉标签"，记录仍在，必须和这里给出不同的说明。
Future<bool> _confirmWorkTaskDeletion(
  BuildContext context, {
  required BuildContext? dialogContext,
}) async {
  final confirmed = await showDialog<bool>(
    context: dialogContext ?? context,
    barrierDismissible: true,
    builder: (dialogContext) => AlertDialog(
      key: const Key('work-task-delete-dialog'),
      title: const Text('删除这条任务？'),
      content: const Text(
        '任务记录和执行日志都会被删除，无法恢复。\n'
        '任务尚未结束，会先停止它；正在执行的工具会先跑完，期间仍可能产生文件改动。\n'
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
