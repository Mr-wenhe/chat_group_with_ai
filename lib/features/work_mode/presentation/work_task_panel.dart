import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/presentation/work_change_approval_dialog.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_approval_plan.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:flutter/material.dart';

typedef WorkTaskEventStream = Stream<WorkTaskEvent> Function(String taskId);
typedef WorkTaskAction = FutureOr<void> Function(String taskId);
typedef WorkTaskUndoPreview = FutureOr<List<WorkSnapshotUndoItem>> Function(
    String taskId);

/// Displays public task state without owning task execution or navigation.
///
/// Keeping this widget callback-driven makes hiding/collapsing a UI concern;
/// only the app-scoped coordinator can stop a task.
class WorkTaskPanel extends StatefulWidget {
  final List<AgentTask> tasks;
  final int hiddenTaskCount;
  final String? selectedTaskId;
  final WorkTaskEventStream eventStreamFor;
  final ValueChanged<String> onSelectTask;
  final WorkTaskAction onStop;
  final WorkTaskAction onContinue;
  final WorkTaskAction? onApprove;
  final WorkTaskAction? onApproveWithoutUndo;
  final WorkTaskAction? onReject;
  final WorkTaskAction? onRequestFolder;
  final WorkTaskAction? onInstallTool;
  final WorkTaskAction? onSelectVisionModel;
  final WorkTaskAction? onRetry;
  final WorkTaskAction? onReauthorize;
  final WorkTaskAction? onViewConflict;
  final WorkTaskAction? onUndo;
  final WorkTaskUndoPreview? undoPreviewFor;
  final ValueChanged<String> onOpenConversation;
  final VoidCallback onCollapse;
  final VoidCallback onClose;
  final BuildContext? dialogContext;
  final String Function(String characterId)? characterNameFor;
  final DateTime Function() clock;

  const WorkTaskPanel({
    super.key,
    required this.tasks,
    this.hiddenTaskCount = 0,
    required this.eventStreamFor,
    required this.onSelectTask,
    required this.onStop,
    required this.onContinue,
    required this.onOpenConversation,
    required this.onCollapse,
    required this.onClose,
    this.dialogContext,
    this.selectedTaskId,
    this.onApprove,
    this.onApproveWithoutUndo,
    this.onReject,
    this.onRequestFolder,
    this.onInstallTool,
    this.onSelectVisionModel,
    this.onRetry,
    this.onReauthorize,
    this.onViewConflict,
    this.onUndo,
    this.undoPreviewFor,
    this.characterNameFor,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  @override
  State<WorkTaskPanel> createState() => _WorkTaskPanelState();
}

class _WorkTaskPanelState extends State<WorkTaskPanel> {
  final Map<String, WorkTaskEvent> _latestEvents = <String, WorkTaskEvent>{};
  final Map<String, WorkTaskEvent> _latestActionEvents =
      <String, WorkTaskEvent>{};
  final Map<String, WorkTaskEvent> _latestToolEvents =
      <String, WorkTaskEvent>{};
  Timer? _durationTicker;
  bool _actionInFlight = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _durationTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _durationTicker?.cancel();
    super.dispose();
  }

  AgentTask? get _selectedTask {
    final selectedTaskId = widget.selectedTaskId;
    if (selectedTaskId != null) {
      for (final task in widget.tasks) {
        if (task.id == selectedTaskId) return task;
      }
    }
    return widget.tasks.isEmpty ? null : widget.tasks.first;
  }

  @override
  Widget build(BuildContext context) {
    final task = _selectedTask;
    if (task == null) return const SizedBox.shrink();
    final latestEvent = _latestEvents[task.id];
    final latestAction = _latestActionEvents[task.id] ?? latestEvent;
    final toolName =
        _toolName(latestEvent) ?? _toolName(_latestToolEvents[task.id]);

    return Material(
      key: const Key('work-task-panel'),
      elevation: 12,
      borderRadius: BorderRadius.circular(20),
      color: Theme.of(context).colorScheme.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _PanelHeader(
                onCollapse: widget.onCollapse,
                onClose: widget.onClose,
              ),
              const SizedBox(height: 10),
              _TaskTabs(
                tasks: widget.tasks,
                selectedTaskId: task.id,
                onSelectTask: widget.onSelectTask,
              ),
              if (widget.hiddenTaskCount > 0) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  '还有 ${widget.hiddenTaskCount} 个任务在队列中，当前面板优先显示执行中的任务。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Expanded(
                child: _TaskDetails(
                  task: task,
                  latestAction: latestAction,
                  toolName: toolName,
                  actionError: _actionError,
                  characterNameFor: widget.characterNameFor,
                  eventStreamFor: widget.eventStreamFor,
                  onLatestEvent: _rememberLatestEvent,
                  clock: widget.clock,
                ),
              ),
              const SizedBox(height: 12),
              _TaskActions(
                task: task,
                actionInFlight: _actionInFlight,
                onOpenConversation: widget.onOpenConversation,
                onApprove: widget.onApprove,
                onApproveWithoutUndo: widget.onApproveWithoutUndo,
                onReject: widget.onReject,
                onRequestFolder: widget.onRequestFolder,
                onInstallTool: widget.onInstallTool,
                onSelectVisionModel: widget.onSelectVisionModel,
                onRetry: widget.onRetry,
                onReauthorize: widget.onReauthorize,
                onViewConflict: widget.onViewConflict,
                onUndo: widget.onUndo,
                undoPreviewFor: widget.undoPreviewFor,
                onStop: widget.onStop,
                onContinue: widget.onContinue,
                dialogContext: widget.dialogContext,
                runAction: (action) => _runAction(action, task.id),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runAction(WorkTaskAction action, String taskId) async {
    if (_actionInFlight) return;
    // The panel can be hidden while a confirmation dialog is open. Keep the
    // app-scoped action alive, but never touch State after the overlay route
    // has disposed this widget.
    if (mounted) {
      setState(() {
        _actionInFlight = true;
        _actionError = null;
      });
    }
    try {
      await action(taskId);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _actionError = sanitizeWorkTaskError(error));
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
  }

  void _rememberLatestEvent(WorkTaskEvent event) {
    final current = _latestEvents[event.taskId];
    if (current != null && current.sequence >= event.sequence) return;
    if (!mounted) return;
    setState(() {
      _latestEvents[event.taskId] = event;
      if (_isActionEvent(event)) {
        _latestActionEvents[event.taskId] = event;
      }
      if (_toolName(event) != null) {
        _latestToolEvents[event.taskId] = event;
      }
    });
  }

  bool _isActionEvent(WorkTaskEvent event) {
    return event.kind == WorkTaskEventKind.planning ||
        event.kind == WorkTaskEventKind.stepStarted ||
        event.kind == WorkTaskEventKind.approvalRequired ||
        event.kind == WorkTaskEventKind.paused;
  }

  String? _toolName(WorkTaskEvent? event) {
    if (event == null) return null;
    final tool = event.safeMetadata['tool'];
    return tool is String && tool.trim().isNotEmpty ? tool : null;
  }
}

class _TaskDetails extends StatelessWidget {
  final AgentTask task;
  final WorkTaskEvent? latestAction;
  final String? toolName;
  final String? actionError;
  final String Function(String characterId)? characterNameFor;
  final WorkTaskEventStream eventStreamFor;
  final ValueChanged<WorkTaskEvent> onLatestEvent;
  final DateTime Function() clock;

  const _TaskDetails({
    required this.task,
    required this.latestAction,
    required this.toolName,
    required this.actionError,
    required this.characterNameFor,
    required this.eventStreamFor,
    required this.onLatestEvent,
    required this.clock,
  });

  @override
  Widget build(BuildContext context) {
    final approvalText =
        task.status == AgentTaskStatus.waitingForApproval ? '等待你批准当前操作。' : null;
    final failure = task.workFailure;
    final characterName = characterNameFor?.call(task.characterId).trim();
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _safePanelText(task.userRequest),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '执行角色：${characterName == null || characterName.isEmpty ? task.characterId : characterName}',
          ),
          const SizedBox(height: 4),
          // currentStep is the index of the current tool operation and may
          // intentionally lag behind model decisions. The user-facing budget
          // must reflect every counted agent action.
          Text('步骤 ${task.actionCount} / ${task.actionLimit}'),
          const SizedBox(height: 4),
          Text(_durationLabel(task, clock())),
          const SizedBox(height: 12),
          _PublicDetail(
            title: '计划摘要',
            text: task.plan.trim().isEmpty
                ? '尚未生成公开计划。'
                : _safePanelText(task.plan),
          ),
          const SizedBox(height: 8),
          _PublicDetail(
            title: '当前动作',
            text: latestAction == null
                ? _statusLabel(task.status)
                : _safePanelText(latestAction!.title),
            inline: true,
          ),
          if (toolName != null) ...<Widget>[
            const SizedBox(height: 8),
            _PublicDetail(
              title: '工具',
              text: _safePanelText(toolName!),
              inline: true,
            ),
          ],
          if (approvalText != null) ...<Widget>[
            const SizedBox(height: 8),
            _PublicDetail(
              title: '审批',
              text: _safePanelText(approvalText),
              inline: true,
            ),
          ],
          if (task.resultSummary.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            _PublicDetail(
              title: '结论',
              text: _safePanelText(task.resultSummary),
            ),
          ],
          if (failure != null) ...<Widget>[
            const SizedBox(height: 10),
            _FailureDetails(failure: failure),
          ],
          if (task.eventLogIncomplete) ...<Widget>[
            const SizedBox(height: 8),
            const _PublicDetail(
              title: '日志',
              text: '部分执行动态保存失败，以上日志可能不完整。',
            ),
          ],
          if (actionError != null) ...<Widget>[
            const SizedBox(height: 8),
            _PublicDetail(title: '操作失败', text: _safePanelText(actionError!)),
          ],
          const SizedBox(height: 14),
          Text('执行动态', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          SizedBox(
            height: 180,
            child: _TaskEventTimeline(
              key: ValueKey<String>(task.id),
              taskId: task.id,
              eventStreamFor: eventStreamFor,
              onLatestEvent: onLatestEvent,
            ),
          ),
        ],
      ),
    );
  }
}

class _FailureDetails extends StatelessWidget {
  final WorkFailure failure;

  const _FailureDetails({required this.failure});

  @override
  Widget build(BuildContext context) {
    final completed = failure.completedContent;
    return DecoratedBox(
      key: const Key('work-task-failure'),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${_safePanelText(failure.title)} · ${failure.type.name}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            _PublicDetail(
              title: '具体原因',
              text: _safePanelText(failure.reason),
            ),
            const SizedBox(height: 4),
            _PublicDetail(
              title: '技术细节',
              text: _safePanelText(failure.technicalDetail),
            ),
            if (completed.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              _PublicDetail(
                title: '已完成内容',
                text: completed.map(_safePanelText).join('；'),
              ),
            ],
            const SizedBox(height: 4),
            _PublicDetail(
              title: '下一步',
              text: _safePanelText(failure.suggestedAction),
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskActions extends StatelessWidget {
  final AgentTask task;
  final bool actionInFlight;
  final ValueChanged<String> onOpenConversation;
  final WorkTaskAction? onApprove;
  final WorkTaskAction? onApproveWithoutUndo;
  final WorkTaskAction? onReject;
  final WorkTaskAction? onRequestFolder;
  final WorkTaskAction? onInstallTool;
  final WorkTaskAction? onSelectVisionModel;
  final WorkTaskAction? onRetry;
  final WorkTaskAction? onReauthorize;
  final WorkTaskAction? onViewConflict;
  final WorkTaskAction? onUndo;
  final WorkTaskUndoPreview? undoPreviewFor;
  final WorkTaskAction onStop;
  final WorkTaskAction onContinue;
  final BuildContext? dialogContext;
  final Future<void> Function(WorkTaskAction action) runAction;

  const _TaskActions({
    required this.task,
    required this.actionInFlight,
    required this.onOpenConversation,
    required this.onApprove,
    required this.onApproveWithoutUndo,
    required this.onReject,
    required this.onRequestFolder,
    required this.onInstallTool,
    required this.onSelectVisionModel,
    required this.onRetry,
    required this.onReauthorize,
    required this.onViewConflict,
    required this.onUndo,
    required this.undoPreviewFor,
    required this.onStop,
    required this.onContinue,
    this.dialogContext,
    required this.runAction,
  });

  @override
  Widget build(BuildContext context) {
    final failure = task.workFailure;
    final continueReason = _continueUnavailableReasonForPanel(task);
    final stopReason = task.isTerminal ? '任务已结束，无法停止。' : null;
    final approvalPlan = approvalPlanForTask(task);
    final requiresPlan = _pendingToolRequiresPlan(task);
    final approvalPlanUnavailable = requiresPlan && approvalPlan == null;
    final requiresNoUndo = _pendingToolRequiresNoUndo(task, approvalPlan);
    final needsFolder = _taskNeedsFolderGrant(task);
    final hasInstallSuggestion = _taskHasInstallSuggestion(task);
    final needsVisionModel = _taskNeedsVisionModel(task);
    // Recovery controls are meaningful only at a user-resumable boundary. A
    // terminal failure may still expose retry/reauthorize/conflict actions,
    // but must not also present a misleading generic Continue button.
    final canShowContinue = !task.isTerminal &&
        (task.status == AgentTaskStatus.paused ||
            task.status == AgentTaskStatus.interrupted) &&
        (failure == null || failure.canContinue);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        OutlinedButton.icon(
          key: const Key('work-task-open-conversation'),
          onPressed: () => onOpenConversation(task.groupId),
          icon: const Icon(Icons.forum_outlined),
          label: const Text('回到对话'),
        ),
        if (!needsFolder &&
            task.status == AgentTaskStatus.waitingForApproval &&
            task.pendingToolRequestJson.trim().isNotEmpty) ...<Widget>[
          if (!requiresNoUndo && onApprove != null)
            Tooltip(
              message: approvalPlanUnavailable
                  ? '审批计划无法读取，已阻止文件变更；请让任务重新规划。'
                  : '批准当前列出的工具操作。',
              child: FilledButton.icon(
                key: const Key('work-task-approve'),
                onPressed: actionInFlight || approvalPlanUnavailable
                    ? null
                    : () => _approveWithConfirmation(context, approvalPlan),
                icon: const Icon(Icons.check_rounded),
                label: const Text('批准'),
              ),
            ),
          if (onApproveWithoutUndo != null &&
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
                        ),
                icon: const Icon(Icons.warning_amber_rounded),
                label: const Text('无撤销执行'),
              ),
            ),
          if (onReject != null)
            Tooltip(
              message: '拒绝当前操作，并让任务尝试安全路径。',
              child: OutlinedButton.icon(
                key: const Key('work-task-reject'),
                onPressed: actionInFlight ? null : () => runAction(onReject!),
                icon: const Icon(Icons.block_rounded),
                label: const Text('拒绝'),
              ),
            ),
        ],
        if (needsFolder && onRequestFolder != null)
          OutlinedButton.icon(
            key: const Key('work-task-add-folder'),
            onPressed:
                actionInFlight ? null : () => runAction(onRequestFolder!),
            icon: const Icon(Icons.folder_shared_outlined),
            label: const Text('授权目录'),
          ),
        if (hasInstallSuggestion && onInstallTool != null)
          OutlinedButton.icon(
            key: const Key('work-task-install-tool'),
            onPressed:
                actionInFlight ? null : () => _confirmInstallTool(context),
            icon: const Icon(Icons.download_outlined),
            label: const Text('帮助安装工具'),
          ),
        if (needsVisionModel && onSelectVisionModel != null)
          OutlinedButton.icon(
            key: const Key('work-task-select-vision-model'),
            onPressed:
                actionInFlight ? null : () => runAction(onSelectVisionModel!),
            icon: const Icon(Icons.image_search_outlined),
            label: const Text('选择视觉模型'),
          ),
        if (failure?.canRetry == true && onRetry != null)
          FilledButton.icon(
            key: const Key('work-task-retry'),
            onPressed: actionInFlight ? null : () => runAction(onRetry!),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        if (failure?.canReauthorize == true &&
            (onReauthorize != null || onRequestFolder != null))
          OutlinedButton.icon(
            key: const Key('work-task-reauthorize'),
            onPressed: actionInFlight
                ? null
                : () => runAction(onReauthorize ?? onRequestFolder!),
            icon: const Icon(Icons.lock_open_outlined),
            label: const Text('重新授权'),
          ),
        if (failure?.canViewConflict == true && onViewConflict != null)
          OutlinedButton.icon(
            key: const Key('work-task-view-conflict'),
            onPressed: actionInFlight ? null : () => runAction(onViewConflict!),
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
          message:
              task.isTerminal && onUndo != null ? '撤销本任务改动。' : '撤销将在任务快照完成后可用。',
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
    );
  }

  Future<void> _approveWithConfirmation(
    BuildContext context,
    WorkChangePlan? approvalPlan,
  ) async {
    final approve = onApprove;
    if (approve == null) return;
    if (_pendingToolRequiresPlan(task) && approvalPlan == null) return;
    if (approvalPlan == null) {
      await runAction(approve);
      return;
    }
    final decision = await WorkChangeApprovalDialog.show(
      dialogContext ?? context,
      plan: approvalPlan,
    );
    if (decision == WorkChangeApprovalDecision.approved) {
      await runAction(approve);
    } else if (decision == WorkChangeApprovalDecision.rejected &&
        onReject != null) {
      await runAction(onReject!);
    }
  }

  Future<void> _approveWithoutUndoWithConfirmation(
    BuildContext context,
    WorkChangePlan? approvalPlan,
  ) async {
    final approveWithoutUndo = onApproveWithoutUndo;
    if (approveWithoutUndo == null) return;
    if (_pendingToolRequiresPlan(task) && approvalPlan == null) return;
    if (approvalPlan == null) {
      final confirmed = await _confirmNoUndoMutation(context);
      if (confirmed) await runAction(approveWithoutUndo);
      return;
    }
    final decision = await WorkChangeApprovalDialog.show(
      dialogContext ?? context,
      plan: approvalPlan,
    );
    if (decision == WorkChangeApprovalDecision.approvedWithoutUndo) {
      await runAction(approveWithoutUndo);
    } else if (decision == WorkChangeApprovalDecision.rejected &&
        onReject != null) {
      await runAction(onReject!);
    }
  }

  Future<bool> _confirmNoUndoMutation(BuildContext context) async {
    final confirmed = await showDialog<bool>(
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
    final confirmed = await showDialog<bool>(
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
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
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
    );
    if (confirmed == true) await runAction(onUndo!);
  }

  Future<void> _confirmInstallTool(BuildContext context) async {
    final install = onInstallTool;
    if (install == null) return;
    final confirmed = await showDialog<bool>(
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
    );
    if (confirmed == true) await runAction(install);
  }
}

class _PanelHeader extends StatelessWidget {
  final VoidCallback onCollapse;
  final VoidCallback onClose;

  const _PanelHeader({required this.onCollapse, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Icon(Icons.auto_awesome_rounded),
        const SizedBox(width: 8),
        Expanded(
          child: Text('工作任务', style: Theme.of(context).textTheme.titleLarge),
        ),
        IconButton(
          key: const Key('work-task-collapse'),
          tooltip: '收起执行面板（任务继续运行）',
          onPressed: onCollapse,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
        IconButton(
          key: const Key('work-task-close'),
          tooltip: '隐藏执行面板（任务继续运行）',
          onPressed: onClose,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }
}

class _TaskTabs extends StatelessWidget {
  final List<AgentTask> tasks;
  final String selectedTaskId;
  final ValueChanged<String> onSelectTask;

  const _TaskTabs({
    required this.tasks,
    required this.selectedTaskId,
    required this.onSelectTask,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: tasks
          .map(
            (task) => ChoiceChip(
              key: Key('work-task-tab-${task.id}'),
              label: Text('任务 ${tasks.indexOf(task) + 1}'),
              selected: task.id == selectedTaskId,
              onSelected: (_) => onSelectTask(task.id),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _PublicDetail extends StatelessWidget {
  final String title;
  final String text;
  final bool inline;

  const _PublicDetail({
    required this.title,
    required this.text,
    this.inline = false,
  });

  @override
  Widget build(BuildContext context) {
    if (inline) return Text('$title：$text');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 2),
        Text(text),
      ],
    );
  }
}

class _TaskEventTimeline extends StatefulWidget {
  final String taskId;
  final WorkTaskEventStream eventStreamFor;
  final ValueChanged<WorkTaskEvent> onLatestEvent;

  const _TaskEventTimeline({
    super.key,
    required this.taskId,
    required this.eventStreamFor,
    required this.onLatestEvent,
  });

  @override
  State<_TaskEventTimeline> createState() => _TaskEventTimelineState();
}

class _TaskEventTimelineState extends State<_TaskEventTimeline> {
  final List<WorkTaskEvent> _events = <WorkTaskEvent>[];
  StreamSubscription<WorkTaskEvent>? _subscription;
  String? _streamError;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant _TaskEventTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId == widget.taskId) return;
    _events.clear();
    _streamError = null;
    unawaited(_subscription?.cancel());
    _listen();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _listen() {
    _subscription = widget.eventStreamFor(widget.taskId).listen(
      (event) {
        if (event.taskId != widget.taskId ||
            _events.any((item) => item.sequence == event.sequence)) {
          return;
        }
        if (!mounted) return;
        setState(() {
          _events.add(event);
          _events
              .sort((left, right) => left.sequence.compareTo(right.sequence));
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onLatestEvent(event);
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted) return;
        setState(() {
          _streamError = sanitizeWorkTaskError(error);
        });
      },
    );
  }

  void _retry() {
    unawaited(_subscription?.cancel());
    if (!mounted) return;
    setState(() {
      _events.clear();
      _streamError = null;
    });
    _listen();
  }

  @override
  Widget build(BuildContext context) {
    final error = _streamError;
    if (_events.isEmpty && error == null) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text('等待公开执行动态…'),
      );
    }
    return SingleChildScrollView(
      key: const Key('work-task-event-timeline'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (error != null)
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Text('执行动态读取失败：${_safePanelText(error)}'),
                    ),
                    TextButton(
                      key: const Key('work-task-event-retry'),
                      onPressed: _retry,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          if (error != null && _events.isNotEmpty) const SizedBox(height: 6),
          ..._events.expand<Widget>((event) => <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(_safePanelText(event.title)),
                        if (event.detail.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(_safePanelText(event.detail)),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
              ]),
        ],
      ),
    );
  }
}

String _safePanelText(String value) {
  var safe = const SearchSecretScanner().redact(
    value.trim(),
    includeOpaqueTokens: true,
  );
  safe = safe.replaceAll(RegExp(r'https?://[^\s,;）)]+'), '[外部地址]');
  safe = safe.replaceAll(
    RegExp(
      r'(?:(?:[A-Za-z]:[\\/])|(?:\\\\|//)|/(?:Users|home|Volumes|private|tmp|var|etc|usr|opt|bin|sbin|Applications|System|Library|Desktop|Documents|Downloads)/)[^\s,;）)]*',
    ),
    '[本地路径]',
  );
  return safe.length <= 4000 ? safe : '${safe.substring(0, 3999)}…';
}

/// Undo confirmation must retain exact local paths so the user can verify the
/// restore/delete scope; only credential-like tokens are redacted here.
String _safeUndoItemText(String value) {
  var safe = const SearchSecretScanner().redact(
    value.trim(),
    includeOpaqueTokens: true,
  );
  return safe.length <= 4000 ? safe : '${safe.substring(0, 3999)}…';
}

bool _pendingToolRequiresPlan(AgentTask task) {
  final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
  return pending?.tool == AgentToolName.workspacePatch ||
      pending?.tool == AgentToolName.workspaceRename ||
      pending?.tool == AgentToolName.workspaceDelete;
}

bool _pendingToolRequiresNoUndo(
  AgentTask task,
  WorkChangePlan? approvalPlan,
) {
  final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
  if (pending?.tool == AgentToolName.skillCreate ||
      pending?.tool == AgentToolName.skillDownload) {
    return true;
  }
  return approvalPlan != null &&
      (!approvalPlan.snapshotAvailable || !approvalPlan.reversible);
}

bool _taskNeedsFolderGrant(AgentTask task) {
  if (task.status != AgentTaskStatus.waitingForApproval &&
      task.status != AgentTaskStatus.paused) {
    return false;
  }
  try {
    final decoded = jsonDecode(task.executionStateJson);
    if (decoded is! Map) return false;
    final path = decoded['folderRequestPath'];
    return decoded['folderGrantPending'] == true ||
        path is String && path.trim().isNotEmpty;
  } on Object {
    return false;
  }
}

bool _taskHasInstallSuggestion(AgentTask task) {
  if (task.status != AgentTaskStatus.paused) return false;
  try {
    final decoded = jsonDecode(task.contextSummary);
    if (decoded is! Map) return false;
    final results = decoded['recentToolResults'];
    if (results is! List) return false;
    for (final result in results.whereType<Map>()) {
      final data = result['data'];
      final suggestion = data is Map ? data['installSuggestion'] : null;
      // Only expose the in-app CTA when the runner supplied a concrete,
      // trusted install command. Some executables (for example flutter/dart)
      // can be diagnosed but intentionally have no automatic installer.
      if (suggestion is Map && suggestion['installCommand'] is Map) {
        return true;
      }
    }
  } on Object {
    // A malformed checkpoint must not expose an install action. The runner
    // will publish a fresh redacted checkpoint before the panel can retry.
  }
  return false;
}

bool _taskNeedsVisionModel(AgentTask task) {
  if (task.status != AgentTaskStatus.paused &&
      task.status != AgentTaskStatus.interrupted) {
    return false;
  }
  try {
    final decoded = jsonDecode(task.executionStateJson);
    if (decoded is Map && decoded['visionModelRequired'] == true) return true;
  } on Object {
    // Fall through to the safe user-facing message check below.
  }
  return task.lastError.contains('视觉模型') ||
      task.lastError.toLowerCase().contains('vision model');
}

String? _continueUnavailableReasonForPanel(AgentTask task) {
  if (task.isTerminal) return '任务已结束，无需继续。';
  final failure = task.workFailure;
  if (failure != null) {
    if (failure.canReauthorize) return failure.suggestedAction;
    if (failure.canViewConflict) return failure.suggestedAction;
    if (failure.canRetry) return '请先点击“重试”从安全检查点继续。';
    if (failure.canContinue) return null;
  }
  if (_taskNeedsVisionModel(task)) return '请先选择支持图片的视觉模型。';
  if (_requiresExplicitCommandRequest(task)) {
    return '请发送明确的测试、构建或分析请求后继续。';
  }
  if (task.softLimitReached &&
      (task.status == AgentTaskStatus.paused ||
          task.status == AgentTaskStatus.interrupted)) {
    return null;
  }
  if (task.status == AgentTaskStatus.interrupted ||
      task.status == AgentTaskStatus.paused) {
    return null;
  }
  if (task.status == AgentTaskStatus.waitingForApproval) {
    return '请先批准当前操作。';
  }
  return '任务正在执行，无需继续。';
}

bool _requiresExplicitCommandRequest(AgentTask task) {
  try {
    final decoded = jsonDecode(task.executionStateJson);
    return decoded is Map && decoded['explicitCommandRequestRequired'] == true;
  } on Object {
    return false;
  }
}

String _durationLabel(AgentTask task, DateTime now) {
  final startedAt = task.startedAt ?? task.createdAt;
  final duration = now.difference(startedAt);
  if (duration.inMinutes <= 0) return '刚刚开始执行';
  if (duration.inHours > 0) {
    return '已执行 ${duration.inHours} 小时 ${duration.inMinutes.remainder(60)} 分钟';
  }
  return '已执行 ${duration.inMinutes} 分钟';
}

String _statusLabel(AgentTaskStatus status) {
  return switch (status) {
    AgentTaskStatus.queued => '任务正在排队。',
    AgentTaskStatus.planning => '正在规划下一步。',
    AgentTaskStatus.waitingForApproval => '等待你批准当前操作。',
    AgentTaskStatus.runningTool => '正在执行工具。',
    AgentTaskStatus.completed => '任务已完成。',
    AgentTaskStatus.failed => '任务执行失败。',
    AgentTaskStatus.cancelled => '任务已停止。',
    AgentTaskStatus.partiallyCompleted => '任务部分完成。',
    AgentTaskStatus.paused => '任务已暂停，等待继续。',
    AgentTaskStatus.interrupted => '任务已中断，等待继续。',
  };
}
