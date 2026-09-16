part of 'work_task_panel.dart';

class _TaskActions extends StatelessWidget {
  final AgentTask task;
  final bool actionInFlight;
  final String? actionError;
  final ValueChanged<String> onOpenConversation;
  final WorkTaskAction? onApprove;
  final WorkTaskVersionedAction? onApproveVersioned;
  final WorkTaskAction? onApproveWithoutUndo;
  final WorkTaskVersionedAction? onApproveWithoutUndoVersioned;
  final WorkTaskAction? onReject;
  final WorkTaskVersionedAction? onRejectVersioned;
  final WorkTaskAction? onRequestFolder;
  final WorkTaskVersionedAction? onRequestFolderVersioned;
  final WorkTaskAction? onInstallTool;
  final WorkTaskVersionedAction? onInstallToolVersioned;
  final WorkTaskAction? onSelectVisionModel;
  final WorkTaskAction? onRetry;
  final WorkTaskAction? onReauthorize;
  final WorkTaskAction? onViewConflict;
  final WorkTaskAction? onUndo;
  final WorkTaskAction? onLater;
  final WorkTaskVersionedAction? onLaterVersioned;
  final WorkTaskUndoPreview? undoPreviewFor;
  final WorkTaskAction onStop;
  final WorkTaskAction onContinue;
  final WorkTaskReply? onReply;
  final TextEditingController replyController;
  final FocusNode replyFocusNode;
  final ValueChanged<bool>? onModalVisibilityChanged;
  final BuildContext? dialogContext;
  final Future<bool> Function(WorkTaskAction action) runAction;

  const _TaskActions({
    required this.task,
    required this.actionInFlight,
    required this.actionError,
    required this.onOpenConversation,
    required this.onApprove,
    required this.onApproveVersioned,
    required this.onApproveWithoutUndo,
    required this.onApproveWithoutUndoVersioned,
    required this.onReject,
    required this.onRejectVersioned,
    required this.onRequestFolder,
    required this.onRequestFolderVersioned,
    required this.onInstallTool,
    required this.onInstallToolVersioned,
    required this.onSelectVisionModel,
    required this.onRetry,
    required this.onReauthorize,
    required this.onViewConflict,
    required this.onUndo,
    required this.onLater,
    required this.onLaterVersioned,
    required this.undoPreviewFor,
    required this.onStop,
    required this.onContinue,
    required this.replyController,
    required this.replyFocusNode,
    this.onReply,
    this.onModalVisibilityChanged,
    this.dialogContext,
    required this.runAction,
  });

  @override
  Widget build(BuildContext context) {
    final failure = _visibleWorkFailure(task);
    final continueReason = _continueUnavailableReasonForPanel(task);
    final stopReason = task.isTerminal ? '任务已结束，无法停止。' : null;
    final approvalPlan = approvalPlanForTask(task);
    final requiresPlan = _pendingToolRequiresPlan(task);
    final approvalPlanUnavailable = requiresPlan && approvalPlan == null;
    final requiresNoUndo = _pendingToolRequiresNoUndo(task, approvalPlan);
    final needsFolder = _taskNeedsFolderGrant(task);
    final hasInstallSuggestion = _taskHasInstallSuggestion(task);
    final needsVisionModel = _taskNeedsVisionModel(task);
    final discussionAllowsApproval = _discussionAllowsApproval(task);
    final canRestartFromBeginning =
        WorkTaskCoordinator.canRestartAfterUserStop(task);
    final isSoftLimitPause =
        task.softLimitReached && _isPausedStatus(task.status);
    final hasUserAction = WorkTaskUserAction.forTask(task).isNotEmpty ||
        _hasPendingDiscussionCheckpoint(task);
    // Recovery controls are meaningful only at a user-resumable boundary. A
    // terminal failure may still expose retry/reauthorize/conflict actions,
    // but must not also present a misleading generic Continue button.
    final canShowContinue = !task.isTerminal &&
        (task.status == AgentTaskStatus.paused ||
            task.status == AgentTaskStatus.interrupted) &&
        (isSoftLimitPause ||
            failure == null ||
            failure.canContinue ||
            failure.canContinueAfterRolePermissionUpdate);
    final modelClarificationPending = WorkTaskClarification.isPending(task);
    // Discussion questions use the same durable follow-up path as model
    // clarifications. Keep the panel answerable even when the runner stored
    // the question in WorkDiscussionState instead of the clarification keys.
    final discussionQuestion =
        modelClarificationPending ? null : _pendingDiscussionQuestion(task);
    final canReply = onReply != null &&
        (modelClarificationPending || discussionQuestion != null);
    final laterAction = WorkTaskUserAction.forTask(task).firstOrNull;
    final laterBlockerId = laterAction?.blockerId ?? 'discussionRequired';
    final laterActionVersion = laterAction?.version ??
        WorkTaskUserAction.discussionCheckpointVersion(task);
    final approvalActionVersion =
        WorkTaskUserAction.versionFor(task, 'commandApproval');
    final folderActionVersion =
        WorkTaskUserAction.versionFor(task, 'folderAuthorization');
    final toolActionVersion =
        WorkTaskUserAction.versionFor(task, 'toolMissing');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (canReply) ...<Widget>[
          _TaskReplyBox(
            task: task,
            discussionQuestion: discussionQuestion,
            controller: replyController,
            focusNode: replyFocusNode,
            actionInFlight: actionInFlight,
            actionError: actionError,
            onSubmit: (reply) async {
              final replyAction = onReply;
              if (replyAction == null) return;
              final sent = await runAction(
                (_) => replyAction(task.id, reply),
              );
              if (sent && replyController.text.trim() == reply) {
                replyController.clear();
              }
            },
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton.icon(
              key: const Key('work-task-open-conversation'),
              onPressed: () => onOpenConversation(task.groupId),
              icon: const Icon(Icons.forum_outlined),
              label: const Text('回到对话'),
            ),
            if (hasUserAction &&
                (onLater != null || onLaterVersioned != null) &&
                !task.isTerminal &&
                (task.status == AgentTaskStatus.paused ||
                    task.status == AgentTaskStatus.interrupted ||
                    task.status == AgentTaskStatus.waitingForApproval))
              Tooltip(
                message: '保持当前检查点等待，不会批准或降级任务。',
                child: TextButton.icon(
                  key: const Key('work-task-later'),
                  onPressed: actionInFlight
                      ? null
                      : () => _runVersionedAction(
                            laterBlockerId,
                            onLater,
                            onLaterVersioned,
                            expectedVersion: laterActionVersion,
                          ),
                  icon: const Icon(Icons.schedule_outlined),
                  label: const Text('稍后处理'),
                ),
              ),
            if (!needsFolder &&
                discussionAllowsApproval &&
                task.status == AgentTaskStatus.waitingForApproval &&
                task.pendingToolRequestJson.trim().isNotEmpty) ...<Widget>[
              if (!requiresNoUndo &&
                  (onApprove != null || onApproveVersioned != null))
                Tooltip(
                  message: approvalPlanUnavailable
                      ? '审批计划无法读取，已阻止文件变更；请让任务重新规划。'
                      : '批准当前列出的工具操作。',
                  child: FilledButton.icon(
                    key: const Key('work-task-approve'),
                    onPressed: actionInFlight || approvalPlanUnavailable
                        ? null
                        : () => _approveWithConfirmation(
                              context,
                              approvalPlan,
                              expectedVersion: approvalActionVersion,
                            ),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('批准'),
                  ),
                ),
              if ((onApproveWithoutUndo != null ||
                      onApproveWithoutUndoVersioned != null) &&
                  (requiresNoUndo ||
                      approvalPlan != null &&
                          (!approvalPlan.snapshotAvailable ||
                              !approvalPlan.reversible)))
                Tooltip(
                  message: requiresNoUndo
                      ? '技能配置没有文件快照，仅在你确认无法撤销时执行。'
                      : '仅在你确认无法撤销时使用；不会因为设置开关而自动启用。',
                  child: OutlinedButton.icon(
                    key: const Key('work-task-approve-without-undo'),
                    onPressed: actionInFlight
                        ? null
                        : () => _approveWithoutUndoWithConfirmation(
                              context,
                              approvalPlan,
                              expectedVersion: approvalActionVersion,
                            ),
                    icon: const Icon(Icons.warning_amber_rounded),
                    label: const Text('无撤销执行'),
                  ),
                ),
              if (onReject != null || onRejectVersioned != null)
                Tooltip(
                  message: '拒绝当前操作，并让任务尝试安全路径。',
                  child: OutlinedButton.icon(
                    key: const Key('work-task-reject'),
                    onPressed: actionInFlight
                        ? null
                        : () => _runVersionedAction(
                              'commandApproval',
                              onReject,
                              onRejectVersioned,
                              expectedVersion: approvalActionVersion,
                            ),
                    icon: const Icon(Icons.block_rounded),
                    label: const Text('拒绝'),
                  ),
                ),
            ],
            if (needsFolder &&
                (onRequestFolder != null || onRequestFolderVersioned != null))
              OutlinedButton.icon(
                key: const Key('work-task-add-folder'),
                onPressed: actionInFlight
                    ? null
                    : () => _runVersionedAction(
                          'folderAuthorization',
                          onRequestFolder,
                          onRequestFolderVersioned,
                          expectedVersion: folderActionVersion,
                        ),
                icon: const Icon(Icons.folder_shared_outlined),
                label: const Text('授权目录'),
              ),
            if (hasInstallSuggestion &&
                (onInstallTool != null || onInstallToolVersioned != null))
              OutlinedButton.icon(
                key: const Key('work-task-install-tool'),
                onPressed: actionInFlight
                    ? null
                    : () => _confirmInstallTool(
                          context,
                          expectedVersion: toolActionVersion,
                        ),
                icon: const Icon(Icons.download_outlined),
                label: const Text('帮助安装工具'),
              ),
            if (needsVisionModel && onSelectVisionModel != null)
              OutlinedButton.icon(
                key: const Key('work-task-select-vision-model'),
                onPressed: actionInFlight
                    ? null
                    : () => runAction(onSelectVisionModel!),
                icon: const Icon(Icons.image_search_outlined),
                label: const Text('选择视觉模型'),
              ),
            if (onRetry != null &&
                (canRestartFromBeginning ||
                    !isSoftLimitPause && failure?.canRetry == true))
              FilledButton.icon(
                key: const Key('work-task-retry'),
                onPressed: actionInFlight ? null : () => runAction(onRetry!),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(canRestartFromBeginning ? '从头开始' : '重试'),
              ),
            if (failure?.canReauthorize == true &&
                failure?.canContinueAfterRolePermissionUpdate != true &&
                (onReauthorize != null || onRequestFolder != null))
              OutlinedButton.icon(
                key: const Key('work-task-reauthorize'),
                onPressed: actionInFlight
                    ? null
                    : () => runAction(onReauthorize ?? onRequestFolder!),
                icon: const Icon(Icons.lock_open_outlined),
                label: Text(
                  failure?.canReplanAfterApprovalScopeFailure == true
                      ? '重新生成计划'
                      : '重新授权',
                ),
              ),
            if (failure?.canViewConflict == true && onViewConflict != null)
              OutlinedButton.icon(
                key: const Key('work-task-view-conflict'),
                onPressed:
                    actionInFlight ? null : () => runAction(onViewConflict!),
                icon: const Icon(Icons.compare_arrows_rounded),
                label: const Text('查看冲突'),
              ),
            if (!task.isTerminal)
              Tooltip(
                message: stopReason ?? '停止当前任务。',
                child: OutlinedButton.icon(
                  key: const Key('work-task-stop'),
                  onPressed: actionInFlight ? null : () => runAction(onStop),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('停止'),
                ),
              ),
            if (canShowContinue)
              Tooltip(
                message: continueReason ?? '继续当前任务。',
                child: FilledButton.icon(
                  key: const Key('work-task-continue'),
                  onPressed: continueReason == null && !actionInFlight
                      ? () => runAction(onContinue)
                      : null,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('继续'),
                ),
              ),
            Tooltip(
              message: task.isTerminal && onUndo != null
                  ? '撤销本任务改动。'
                  : '撤销将在任务快照完成后可用。',
              child: OutlinedButton.icon(
                key: const Key('work-task-undo'),
                onPressed: task.isTerminal && onUndo != null && !actionInFlight
                    ? () => _confirmUndo(context)
                    : null,
                icon: const Icon(Icons.undo_rounded),
                label: const Text('撤销'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
