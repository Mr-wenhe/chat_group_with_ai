import 'dart:async';
import 'dart:convert';
import 'package:chat_group/features/work_mode/work_public_update_stream.dart';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/presentation/work_change_approval_dialog.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_confirmation.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_run_boundary.dart';
import 'package:chat_group/features/work_mode/work_task_action_notice.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_clarification.dart';
import 'package:chat_group/features/work_mode/work_task_approval_plan.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_task_execution_policy.dart';
import 'package:chat_group/features/work_mode/work_follow_up_policy.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
import 'package:chat_group/features/work_mode/work_task_decision.dart';
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

/// 执行人冲突的两种确认结果：`swap` 为真表示改派给群推举的角色，否则保留
/// 请求里钉定的角色。两个分支都必须由用户明确选择，讨论不能自行改派。
typedef WorkTaskExecutorChoice = FutureOr<void> Function(
  String taskId,
  int version,
  bool swap,
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
  final WorkTaskAction? onOpenDecision;
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

  /// 群推举的执行人与请求里钉定的人不一致时的确认入口。
  final WorkTaskExecutorChoice? onConfirmExecutorSwap;

  /// 确认把本次运行写出的文件当作交付物。为 null 时不展示该入口。
  ///
  /// 它回答的是完成门禁提出的问题：门禁认不出这些文件是否符合要求，于是暂停
  /// 等用户确认。用户也可以用回复框改说要什么，那条路走的是普通追问。
  final WorkTaskAction? onConfirmArtifactDelivery;

  /// 真删除一条任务记录（不可逆）。为 null 时不展示删除入口。
  ///
  /// 入口只在历史任务详情里：「删除任务」曾同时放在操作区，但那里紧邻任务标签，
  /// 用户会把它和标签旁的 ✕ 当成同一件事，而后者只是把标签收起来、记录仍在。
  final WorkTaskAction? onDeleteTask;

  /// 把历史任务重新放回标签栏并选中它。
  ///
  /// 历史详情本身不接执行动作，但"这条旧任务我要接着处理"是正常诉求：它需要先
  /// 回到标签栏（被关掉的标签也要恢复），面板上的回复框/继续/重试才会出现。
  final WorkTaskAction? onOpenInTabStrip;
  final ValueChanged<String> onOpenConversation;
  final VoidCallback onCollapse;
  final VoidCallback onClose;
  final ValueChanged<bool>? onModalVisibilityChanged;
  final BuildContext? dialogContext;
  final String Function(String characterId)? characterNameFor;
  final DateTime Function() clock;

  /// 当前会话的历史任务（含已被用户关掉标签的任务），按时间倒序。
  final List<AgentTask> historyTasks;

  /// 是否渲染面板上半区（「任务详情」开关、任务需求 / 运行状态 / 执行细节三张卡、
  /// 失败提示与「异常与日志」卡）。
  ///
  /// 默认关闭：面板自上而下只保留任务标签、执行动态与底部操作按钮，把高度全部
  /// 让给执行动态。上半区代码仍完整保留，显式传 true 即可整块恢复
  /// （回归测试覆盖上半区内容时就是这么打开的）。
  final bool showTaskSummarySection;

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
    this.onOpenDecision,
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
    this.onConfirmExecutorSwap,
    this.onConfirmArtifactDelivery,
    this.onDeleteTask,
    this.onOpenInTabStrip,
    this.characterNameFor,
    this.historyTasks = const <AgentTask>[],
    this.onHideTask,
    this.showTaskSummarySection = false,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  @override
  State<WorkTaskPanel> createState() => _WorkTaskPanelState();
}

class _WorkTaskPanelState extends State<WorkTaskPanel> {
  /// 面板静止（鼠标不在其上）时的不透明度。
  ///
  /// 面板覆盖在聊天区之上，全实体时会挡住正在进行的对话。取 0.85 是为了让
  /// 下方的聊天仍能透出来，同时面板正文不与背景内容糊在一起。
  static const double _idleOpacity = 0.85;

  /// 悬停切换的过渡时长。过长显得拖沓，过短像闪一下。
  static const Duration _hoverTransitionDuration = Duration(milliseconds: 160);

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

  /// 指针是否停在面板上。只有 [_supportsHoverReveal] 为真时才会改变绘制。
  bool _isPointerInside = false;

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

  /// 触屏平台收不到 hover 事件，静止态会永远停在半透明，用户无从把它变实体。
  /// 所以"未悬停半透明"只在桌面平台生效，移动端恒定实体。
  ///
  /// 读 Theme 的 platform 而非 defaultTargetPlatform：生产取值完全一致
  /// （ThemeData.platform 默认就是它），但 Theme 可以被替换，widget 测试因此
  /// 不必去改 foundation 的调试变量。
  static bool _supportsHoverReveal(BuildContext context) =>
      switch (Theme.of(context).platform) {
        TargetPlatform.macOS ||
        TargetPlatform.windows ||
        TargetPlatform.linux =>
          true,
        _ => false,
      };

  double _panelOpacity(BuildContext context) {
    if (!_supportsHoverReveal(context)) return 1.0;
    return _isPointerInside ? 1.0 : _idleOpacity;
  }

  void _setPointerInside(bool inside) {
    if (!mounted || _isPointerInside == inside) return;
    setState(() => _isPointerInside = inside);
  }

  @override
  Widget build(BuildContext context) {
    // MouseRegion 与 AnimatedOpacity 都是单子代理，不改变面板拿到的约束，
    // 也不影响命中测试，所以面板照常可点可滚动。
    return MouseRegion(
      onEnter: (_) => _setPointerInside(true),
      onExit: (_) => _setPointerInside(false),
      child: AnimatedOpacity(
        key: const Key('work-task-panel-opacity'),
        opacity: _panelOpacity(context),
        duration: _hoverTransitionDuration,
        child: Semantics(
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
              constraints: const BoxConstraints(maxHeight: 790),
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
            '本会话还有 ${widget.hiddenTaskCount} 个未结束的任务未在标签栏显示，'
            '可在「历史任务」里查看。',
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
            showSummarySection: widget.showTaskSummarySection,
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
              onConfirmExecutorSwap: widget.onConfirmExecutorSwap,
              onConfirmArtifactDelivery: widget.onConfirmArtifactDelivery,
              characterNameFor: widget.characterNameFor,
              onStop: widget.onStop,
              onContinue: widget.onContinue,
              onReply: widget.onReply,
              onOpenDecision: widget.onOpenDecision,
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
              showSummarySection: widget.showTaskSummarySection,
              characterNameFor: widget.characterNameFor,
              eventStreamFor: widget.eventStreamFor,
              onLatestEvent: (_) {},
              // 历史任务已经结束，用最后更新时间当基准，否则耗时会按
              // 当前时间算成几百上千小时。
              clock: () => detailTask.updatedAt ?? detailTask.createdAt,
            ),
          ),
        // 历史任务不再执行，所以这里不接执行类动作；但"重新放回标签栏"和
        // "删除记录"都不是执行动作，而历史列表正是这两件事的唯一入口。
        if (detailTask != null &&
            (widget.onOpenInTabStrip != null ||
                widget.onDeleteTask != null)) ...<Widget>[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              children: <Widget>[
                if (widget.onOpenInTabStrip != null)
                  OutlinedButton.icon(
                    key: const Key('work-task-history-open-in-tabs'),
                    onPressed: _actionInFlight
                        ? null
                        : () => _openHistoryTaskInTabs(detailTask),
                    icon: const Icon(Icons.tab_unselected_rounded),
                    label: const Text('在标签栏打开'),
                  ),
                if (widget.onDeleteTask != null)
                  TextButton.icon(
                    key: const Key('work-task-history-delete'),
                    onPressed: _actionInFlight
                        ? null
                        : () => _confirmDeleteHistoryTask(detailTask),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('删除任务'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 把历史详情里的任务放回标签栏，并退出历史视图——否则标签恢复了也看不到，
  /// 因为标签栏只画在实时视图里。
  Future<void> _openHistoryTaskInTabs(AgentTask task) async {
    final openInTabs = widget.onOpenInTabStrip;
    if (openInTabs == null) return;
    final opened = await _runAction(openInTabs, task.id);
    if (opened && mounted) {
      setState(() {
        _showHistory = false;
        _historyDetailTaskId = null;
      });
    }
  }

  Future<void> _confirmDeleteHistoryTask(AgentTask task) async {
    final onDelete = widget.onDeleteTask;
    if (onDelete == null) return;
    // 终态任务已经停手、不会再产生文件改动，删除只影响记录本身，直接删；
    // 非终态任务会先被停止，且正在执行的工具可能还在写文件，必须让用户确认。
    if (!task.isTerminal) {
      widget.onModalVisibilityChanged?.call(false);
      bool confirmed;
      try {
        confirmed = await _confirmWorkTaskDeletion(
          context,
          dialogContext: widget.dialogContext,
        );
      } finally {
        widget.onModalVisibilityChanged?.call(true);
      }
      if (!confirmed) return;
    }
    final deleted = await _runAction(onDelete, task.id);
    if (deleted && mounted) {
      // 记录已经不在列表里了，回到列表层，避免停在一个已消失的详情上。
      setState(() => _historyDetailTaskId = null);
    }
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
      if (error is WorkTaskActionNotice) {
        await _showActionNoticeDialog(error);
      }
      return false;
    } finally {
      if (mounted) setState(() => _actionInFlight = false);
    }
  }

  /// 只有当场能修好的问题才打断用户：选了目录但选错时，对话框点名需要授权的
  /// 目录，用户关掉就能直接重选。
  ///
  /// 这里按原样显示绝对路径，不走 `_safePanelText`：面板详情会脱敏本地路径，是
  /// 因为它镜像的是会进入聊天的公开进度；对话框只给机主本人看，设置页也一直这
  /// 样展示授权目录。需要点名的目录若被脱敏成「[本地路径]」就失去了意义。
  Future<void> _showActionNoticeDialog(WorkTaskActionNotice notice) async {
    final requiredDirectory = notice.requiredDirectory?.trim() ?? '';
    if (!mounted || requiredDirectory.isEmpty) return;
    // 面板挂在 App 根 Overlay 上，自身 context 位于路由 Navigator 之上，直接
    // 弹窗会因找不到 Navigator 抛错、变成「点了没反应」。host 传进来的
    // dialogContext 才是路由导航器的 context，与面板其它弹窗保持一致。
    await showDialog<void>(
      context: widget.dialogContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('需要授权另一个目录'),
        content: Text(
          '任务需要授权的目录是：\n$requiredDirectory\n\n'
          '请点击「授权目录」，选择它或它的上级目录。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
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
