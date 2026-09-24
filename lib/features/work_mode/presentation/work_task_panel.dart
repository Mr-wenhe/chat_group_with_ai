import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/presentation/work_change_approval_dialog.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_clarification.dart';
import 'package:chat_group/features/work_mode/work_task_approval_plan.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
import 'package:chat_group/features/chat_group/widgets/blinking_cursor.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:flutter/material.dart';

part 'work_task_panel_details.dart';
part 'work_task_panel_actions.dart';
part 'work_task_panel_action_recovery.dart';
part 'work_task_panel_controls.dart';
part 'work_task_history_view.dart';
part 'work_task_panel_timeline.dart';

typedef WorkTaskEventStream = Stream<WorkTaskEvent> Function(String taskId);
typedef WorkTaskAction = FutureOr<void> Function(String taskId);
typedef WorkTaskVersionedAction = FutureOr<void> Function(
  String taskId,
  int version,
);
typedef WorkTaskReply = FutureOr<void> Function(
  String taskId,
  String reply,
);
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
  final WorkTaskReply? onReply;
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
  final ValueChanged<String> onOpenConversation;
  final VoidCallback onCollapse;
  final VoidCallback onClose;
  final ValueChanged<bool>? onModalVisibilityChanged;
  final BuildContext? dialogContext;
  final String Function(String characterId)? characterNameFor;
  final DateTime Function() clock;

  /// 当前会话的历史任务（含已被用户关掉标签的任务），按时间倒序。
  final List<AgentTask> historyTasks;

  /// 已被用户从标签栏隐藏的任务 id；历史列表用它标注"已从标签栏隐藏"，
  /// 让用户知道记录还在、可以继续基于它追加要求。
  final Set<String> hiddenTaskIds;

  /// 关掉某个任务的标签；只影响面板展示，不删除任务记录。
  final WorkTaskAction? onHideTask;

  const WorkTaskPanel({
    super.key,
    required this.tasks,
    this.hiddenTaskCount = 0,
    this.hiddenTaskIds = const <String>{},
    required this.eventStreamFor,
    required this.onSelectTask,
    required this.onStop,
    required this.onContinue,
    this.onReply,
    required this.onOpenConversation,
    required this.onCollapse,
    required this.onClose,
    this.onModalVisibilityChanged,
    this.dialogContext,
    this.selectedTaskId,
    this.onApprove,
    this.onApproveVersioned,
    this.onApproveWithoutUndo,
    this.onApproveWithoutUndoVersioned,
    this.onReject,
    this.onRejectVersioned,
    this.onRequestFolder,
    this.onRequestFolderVersioned,
    this.onInstallTool,
    this.onInstallToolVersioned,
    this.onSelectVisionModel,
    this.onRetry,
    this.onReauthorize,
    this.onViewConflict,
    this.onUndo,
    this.onLater,
    this.onLaterVersioned,
    this.undoPreviewFor,
    this.characterNameFor,
    this.historyTasks = const <AgentTask>[],
    this.onHideTask,
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
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocusNode = FocusNode();

  /// 是否处于历史任务视图。为 false 时显示正常的任务标签面板。
  bool _showHistory = false;

  /// 历史视图里被点开查看详情的任务 id；为空表示仍停在历史列表。
  String? _historyDetailTaskId;

  @override
  void didUpdateWidget(covariant WorkTaskPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedTaskId(oldWidget) != _selectedTaskId(widget)) {
      _replyController.clear();
      _actionError = null;
    }
  }

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
    _replyController.dispose();
    _replyFocusNode.dispose();
    super.dispose();
  }

  String? _selectedTaskId(WorkTaskPanel panel) {
    final selected = panel.selectedTaskId;
    if (selected != null && panel.tasks.any((task) => task.id == selected)) {
      return selected;
    }
    return panel.tasks.isEmpty ? null : panel.tasks.first.id;
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
    return Semantics(
      key: const Key('work-task-panel-semantics'),
      container: true,
      explicitChildNodes: true,
      label: '工作任务面板',
      child: Material(
        key: const Key('work-task-panel'),
        elevation: 12,
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).colorScheme.surface,
        child: ConstrainedBox(
          // Desktop overlays have enough vertical room for a readable live
          // transcript. The details section keeps its own scrollbar, so a
          // taller panel does not make the action buttons unreachable.
          constraints: const BoxConstraints(maxHeight: 720),
          child: ScrollConfiguration(
            // Material's desktop ScrollBehavior adds a scrollbar to every
            // ScrollView. The task panel deliberately owns two independent
            // scroll regions, so automatic scrollbars would overlap and make
            // the inner thumb impossible to drag.
            behavior:
                ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _showHistory
                  ? _buildHistoryBody(context)
                  : _buildLiveBody(context),
            ),
          ),
        ),
      ),
    );
  }

  /// 任务面板正文：标签 + 当前任务详情 + 操作按钮。
  ///
  /// 所有标签都被用户关掉时只显示空态文案，不能收掉整个面板，
  /// 否则「历史任务」入口也会一起消失，关掉的任务就再也看不到。
  Widget _buildLiveBody(BuildContext context) {
    final task = _selectedTask;
    if (task == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PanelHeader(
            onCollapse: widget.onCollapse,
            onClose: widget.onClose,
            onOpenHistory: _openHistory,
          ),
          const SizedBox(height: 12),
          const Text('没有正在显示的任务，可从「历史任务」里重新查看。'),
        ],
      );
    }
    final latestEvent = _latestEvents[task.id];
    final latestAction = _latestActionEvents[task.id] ?? latestEvent;
    // Tool/action fields describe the active step. Once the durable task is
    // terminal, leave the detailed event in the timeline but let the summary
    // section show the terminal status instead of a stale tool label.
    final toolName = task.isTerminal
        ? null
        : _toolName(latestEvent) ?? _toolName(_latestToolEvents[task.id]);
    final onHideTask = widget.onHideTask;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _PanelHeader(
          onCollapse: widget.onCollapse,
          onClose: widget.onClose,
          onOpenHistory: _openHistory,
        ),
        const SizedBox(height: 10),
        _TaskTabs(
          tasks: widget.tasks,
          selectedTaskId: task.id,
          onSelectTask: widget.onSelectTask,
          onHideTask: onHideTask == null
              ? null
              : (taskId) => unawaited(_runAction(onHideTask, taskId)),
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
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 180),
          child: SingleChildScrollView(
            primary: false,
            child: _TaskActions(
              task: task,
              actionInFlight: _actionInFlight,
              actionError: _actionError,
              onOpenConversation: widget.onOpenConversation,
              onApprove: widget.onApprove,
              onApproveVersioned: widget.onApproveVersioned,
              onApproveWithoutUndo: widget.onApproveWithoutUndo,
              onApproveWithoutUndoVersioned:
                  widget.onApproveWithoutUndoVersioned,
              onReject: widget.onReject,
              onRejectVersioned: widget.onRejectVersioned,
              onRequestFolder: widget.onRequestFolder,
              onRequestFolderVersioned: widget.onRequestFolderVersioned,
              onInstallTool: widget.onInstallTool,
              onInstallToolVersioned: widget.onInstallToolVersioned,
              onSelectVisionModel: widget.onSelectVisionModel,
              onRetry: widget.onRetry,
              onReauthorize: widget.onReauthorize,
              onViewConflict: widget.onViewConflict,
              onUndo: widget.onUndo,
              onLater: widget.onLater,
              onLaterVersioned: widget.onLaterVersioned,
              undoPreviewFor: widget.undoPreviewFor,
              onStop: widget.onStop,
              onContinue: widget.onContinue,
              onReply: widget.onReply,
              replyController: _replyController,
              replyFocusNode: _replyFocusNode,
              onModalVisibilityChanged: widget.onModalVisibilityChanged,
              dialogContext: widget.dialogContext,
              runAction: (action) => _runAction(action, task.id),
            ),
          ),
        ),
      ],
    );
  }

  /// 历史任务视图：先看列表（时间 + 标题），点进去才展开任务详情。
  ///
  /// 被关掉标签的任务只在这里还能看到；历史任务不会再执行，
  /// 所以详情不接动作按钮，耗时也按「创建 → 最后更新」计算。
  Widget _buildHistoryBody(BuildContext context) {
    final detailTask = _historyTaskById(_historyDetailTaskId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _PanelHeader(
          inHistory: true,
          onCollapse: widget.onCollapse,
          onClose: widget.onClose,
          onBackFromHistory: detailTask == null
              ? _closeHistory
              : () => setState(() => _historyDetailTaskId = null),
        ),
        const SizedBox(height: 10),
        if (detailTask == null)
          Expanded(
            child: _TaskHistoryList(
              tasks: widget.historyTasks,
              hiddenTaskIds: widget.hiddenTaskIds,
              onSelectTask: (taskId) =>
                  setState(() => _historyDetailTaskId = taskId),
            ),
          )
        else
          Expanded(
            child: _TaskDetails(
              task: detailTask,
              latestAction: null,
              toolName: null,
              actionError: null,
              characterNameFor: widget.characterNameFor,
              eventStreamFor: widget.eventStreamFor,
              onLatestEvent: (_) {},
              // 历史任务已经结束，用最后更新时间当基准，否则耗时会按
              // 当前时间算成几百上千小时。
              clock: () => detailTask.updatedAt ?? detailTask.createdAt,
            ),
          ),
      ],
    );
  }

  void _openHistory() {
    setState(() {
      _showHistory = true;
      _historyDetailTaskId = null;
    });
  }

  void _closeHistory() {
    setState(() {
      _showHistory = false;
      _historyDetailTaskId = null;
    });
  }

  AgentTask? _historyTaskById(String? taskId) {
    if (taskId == null) return null;
    for (final task in widget.historyTasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  Future<bool> _runAction(WorkTaskAction action, String taskId) async {
    if (_actionInFlight) return false;
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
      return true;
    } on Object catch (error) {
      if (mounted) setState(() => _actionError = sanitizeWorkTaskError(error));
      return false;
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
