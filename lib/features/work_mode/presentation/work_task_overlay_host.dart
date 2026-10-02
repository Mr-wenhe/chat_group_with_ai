import 'dart:async';

import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_decision_dialog.dart';
import 'package:chat_group/features/work_mode/presentation/work_change_approval_dialog.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_generic_approval_dialog.dart';
import 'package:chat_group/features/work_mode/work_task_approval_plan.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/providers/work_task_providers.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
import 'package:chat_group/features/work_mode/work_task_decision.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/presentation/work_folder_grant_consent_dialog.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_overlay_controller.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_pill_position.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_tab_visibility.dart';
import 'package:chat_group/services/conversation_presence_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hosts the non-modal work-task panel above every application route.
///
/// The host listens to the app-scoped coordinator but never owns it, so hiding
/// or navigating cannot cancel a running task.
class WorkTaskOverlayHost extends ConsumerStatefulWidget {
  final Widget child;
  final WorkTaskCoordinator? coordinator;
  final WorkTaskEventStore? eventStore;
  final GlobalKey<NavigatorState>? navigatorKey;
  final Stream<List<AgentTask>>? taskStream;
  final WorkTaskEventStream? eventStreamFor;
  final Future<void> Function(String taskId)? onStopTask;
  final Future<void> Function(String taskId)? onContinueTask;
  final Future<void> Function(String taskId, String reply)? onReplyTask;
  final Future<void> Function(String taskId)? onApproveTask;
  final Future<void> Function(String taskId)? onApproveWithoutUndoTask;
  final Future<void> Function(String taskId)? onRejectTask;
  final Future<void> Function(String taskId)? onRequestFolderTask;
  final Future<void> Function(String taskId)? onInstallToolTask;
  final Future<void> Function(String taskId)? onSelectVisionModelTask;
  final Future<void> Function(String taskId)? onRetryTask;
  final Future<void> Function(String taskId)? onReauthorizeTask;
  final Future<void> Function(String taskId)? onViewConflictTask;
  final Future<void> Function(String taskId)? onUndoTask;

  /// 真删除任务记录（不可逆）。为 null 时退回协调器实现。
  final Future<void> Function(String taskId)? onDeleteTask;

  /// 把历史任务放回标签栏并选中。为 null 时用宿主自己的实现。
  final Future<void> Function(String taskId)? onOpenInTabStrip;
  final WorkTaskUndoPreview? undoPreviewFor;
  final WorkSnapshotService? snapshotService;
  final String Function(String characterId)? characterNameFor;

  /// 是否渲染面板上半区（「任务详情」开关、任务需求 / 运行状态 / 执行细节三张卡、
  /// 失败提示与「异常与日志」卡）。
  ///
  /// 默认 false：面板自上而下只剩任务标签、执行动态与底部操作按钮，高度全给
  /// 执行动态。透传给 [WorkTaskPanel.showTaskSummarySection]，置 true 即可整块恢复。
  final bool showTaskSummarySection;

  const WorkTaskOverlayHost({
    super.key,
    required this.child,
    this.coordinator,
    this.eventStore,
    this.navigatorKey,
    this.taskStream,
    this.eventStreamFor,
    this.onStopTask,
    this.onContinueTask,
    this.onReplyTask,
    this.onApproveTask,
    this.onApproveWithoutUndoTask,
    this.onRejectTask,
    this.onRequestFolderTask,
    this.onInstallToolTask,
    this.onSelectVisionModelTask,
    this.onRetryTask,
    this.onReauthorizeTask,
    this.onViewConflictTask,
    this.onUndoTask,
    this.onDeleteTask,
    this.onOpenInTabStrip,
    this.undoPreviewFor,
    this.snapshotService,
    this.characterNameFor,
    this.showTaskSummarySection = false,
  });

  @override
  ConsumerState<WorkTaskOverlayHost> createState() =>
      _WorkTaskOverlayHostState();
}

class _WorkTaskOverlayHostState extends ConsumerState<WorkTaskOverlayHost> {
  /// 底部留给聊天输入区的净空。
  ///
  /// 宿主覆盖在整个 Navigator 之上，量不到具体路由的输入行高度（附件/引用预览
  /// 会把它顶得更高），只能取一个覆盖常见形态的高度。面板下边界与隐藏态圆钮都
  /// 靠它让开输入框和发送按钮：贴到窗口底边时，落点正是「发送」所在的位置。
  static const _composerClearance = 84.0;

  /// 顶部锚点与 AppBar 之间留出的空隙。
  static const _topAnchorGap = 16.0;

  /// 会话页在 AppBar 之下自己画的那条会话控件行（自动发言 / 语音播报 / 圆桌会议 /
  /// 工作模式）的高度。
  ///
  /// 全局宿主读不到具体路由的布局，只能照抄 CompactConversationControls 的常量：
  /// 外框上下内边距 6 + 2，内层 3 + 36 的按钮 + 3。折叠胶囊与宽屏面板若落在
  /// AppBar 正下方，压住的正是这条行右端的「工作模式」开关——被盖住就点不到。
  ///
  /// 它**不含**会话页顶部的横幅（未配置 Key / 群公告 / 联机状态 / 搜索状态）：
  /// 那些横幅高度随文案换行变化，数量也不定，一个常量兜不住，所以这里只让开会
  /// 话控件行本身。有横幅时控件行会被顶下去：胶囊可以拖走，面板则仍会压住它。
  static const double _conversationControlsBand = 50.0;

  /// 折叠胶囊、隐藏态圆钮与宽屏面板的顶边偏移：落在 AppBar 之下，会话页还要再
  /// 让开会话控件行。
  ///
  /// 全局宿主读不到具体路由的 AppBar 与布局，按状态栏 + 标准工具栏高度推算。
  /// 桌面端状态栏为 0，非会话页落点 72，收起与展开停在同一个角落，而顶部那一
  /// 行留给 AppBar 自己的按钮。会话页之外的页面（角色列表、设置页等）没有这条
  /// 控件行，所以只有会话内才需要让位。
  double _topAnchor(BuildContext context) =>
      _panelTopAnchor(context) + _topAnchorGap;

  /// 宽屏面板的顶边：紧贴会话控件行的下沿。
  ///
  /// 「填满聊天窗口高度」要的就是不浪费 [_topAnchorGap] 那一段——胶囊是浮在控件
  /// 行外面的小球，留空隙才不会显得贴脸；面板是一整块矩形，贴上去既多出十几像素
  /// 可读高度，也不会盖住任何东西。底边仍停在输入区之上（见 [_composerClearance]）。
  double _panelTopAnchor(BuildContext context) =>
      MediaQuery.paddingOf(context).top +
      kToolbarHeight +
      (_activeConversationId == null ? 0.0 : _conversationControlsBand);

  /// 面板走右侧宽布局而不是底部窄布局的窗口宽度下限。
  static const double _wideLayoutMinWidth = 800.0;

  /// 折叠态下面板的目标高度上限。
  ///
  /// 面板折起来时要能一眼看全：上半区（任务需求 + 运行状态 + 执行细节）优先拿到
  /// 足够高度，剩下的才分给「执行动态」。这个上限只是给窄屏一个参考值 ——
  /// 宽屏面板由顶锚点到 `_composerClearance` 撑满视口，此处会被视口高度覆盖。
  static const double _collapsedPanelMaxHeight = 790.0;

  /// 面板顶部至少留出的空隙，避免矮窗口下 Positioned 超出 Stack 被裁掉面板头。
  static const double _panelTopClearance = 96.0;

  StreamSubscription<List<AgentTask>>? _tasksSubscription;
  StreamSubscription<String?>? _conversationSubscription;
  WorkTaskCoordinator? _coordinator;
  WorkTaskEventStore? _eventStore;
  List<AgentTask> _tasks = const <AgentTask>[];
  List<AgentTask> _allTasks = const <AgentTask>[];
  int _hiddenTaskCount = 0;
  String? _selectedTaskId;

  /// 被用户关掉标签的任务 id。只影响标签展示，任务记录仍然完整保留，
  /// 关掉后依旧能在历史任务列表里查到。
  final Set<String> _hiddenWorkTaskIds = <String>{};
  Future<void> _hiddenMarkerWrites = Future<void>.value();

  /// 折叠入口被拖到的左上角（窗口逻辑坐标）。null = 没拖过，停在默认锚点。
  ///
  /// 用户 2026-09-30 拍板让它可拖动：右上角那个位置同时住着任务入口、会话控件
  /// 行和各类横幅，任何固定常量都只是把冲突挪个地方；交给用户自己摆，冲突就此
  /// 结束。
  Offset? _pillPosition;

  /// 量折叠入口尺寸的锚点：拖动与窗口缩放后都要按真实尺寸夹取。
  ///
  /// 键挂在折叠入口的外层而不是胶囊上，隐藏态那颗圆钮也走同一条布局路径——量
  /// 的是当前实际渲染的那一块。挂在胶囊上时圆钮按零尺寸夹取，约束退化成"左上角
  /// 留在窗口内"，窗口变窄后它能整块落到屏幕外，而那时胶囊没在树上，读不到尺寸
  /// 也就永远修不回来。读不到时仍退回零尺寸（重启后第一帧），够把胶囊抓回来。
  final GlobalKey _pillEntryKey = GlobalKey();
  bool _isVisible = true;
  bool _isCollapsed = false;
  WorkSnapshotService? _snapshotService;
  final Set<String> _approvalPromptInFlight = <String>{};
  final Set<String> _decisionPromptInFlight = <String>{};
  late final WorkTaskOverlayController _overlayController;
  late final WorkTaskOverlayOpenTask _overlayOpenCallback;
  String? _pendingOpenTaskId;

  @override
  void initState() {
    super.initState();
    // 必须在订阅任务流之前载入隐藏状态，否则首帧会把已关掉的标签又画出来。
    _loadHiddenWorkTaskIds();
    _loadPillPosition();
    try {
      _overlayController = ref.read(workTaskOverlayControllerProvider);
    } on Object {
      // Lightweight widget hosts may be mounted without ProviderScope; the
      // app-scoped singleton keeps the chat bridge usable in that harness.
      _overlayController = WorkTaskOverlayController.shared;
    }
    _overlayOpenCallback = _openTask;
    _overlayController.attach(_overlayOpenCallback);
    if (widget.taskStream == null ||
        widget.onStopTask == null ||
        widget.onContinueTask == null) {
      try {
        _coordinator =
            widget.coordinator ?? ref.read(workTaskCoordinatorProvider);
      } on Object {
        // A display-only host may be mounted without the app coordinator.
        // Keep the child usable and let the explicit task stream/callbacks
        // drive any tasks that the embedding can actually control.
        _coordinator = widget.coordinator;
      }
    } else {
      _coordinator = widget.coordinator;
    }
    _coordinator?.setFolderGrantConsent(_confirmFolderGrant);
    _eventStore = widget.eventStore;
    if (_eventStore == null && widget.eventStreamFor == null) {
      try {
        _eventStore = ref.read(workTaskEventStoreProvider);
      } on Object {
        // A callback-driven/lightweight host may not have the app event-store
        // provider. The panel still remains usable; its timeline uses the
        // explicit empty stream fallback in build().
      }
    }
    _snapshotService = widget.snapshotService;
    if (_snapshotService == null &&
        widget.onUndoTask == null &&
        widget.undoPreviewFor == null) {
      try {
        _snapshotService = ref.read(workSnapshotServiceProvider);
      } on Object {
        // Lightweight widget tests may not initialize DatabaseService; the
        // undo control remains disabled until a production service is wired.
      }
    }
    final taskStream = widget.taskStream ??
        _coordinator?.watchAllTasks() ??
        const Stream<List<AgentTask>>.empty();
    _tasksSubscription = taskStream.listen((tasks) {
      if (!mounted) return;
      _releaseHiddenMarkersForResumedTasks(tasks);
      final selectedId = _selectedTaskId;
      final visibleTasks = _visibleTasks(
        tasks,
        preferredTaskId:
            selectedId != null && tasks.any((task) => task.id == selectedId)
                ? selectedId
                : null,
      );
      setState(() {
        _allTasks = List<AgentTask>.unmodifiable(tasks);
        _tasks = visibleTasks;
        _hiddenTaskCount = _hiddenTaskCountFor(tasks, visibleTasks);
        if (_tasks.every((task) => task.id != _selectedTaskId)) {
          _selectedTaskId = _tasks.isEmpty ? null : _tasks.first.id;
        }
      });
      final pendingTaskId = _pendingOpenTaskId;
      if (pendingTaskId != null &&
          tasks.any((task) => task.id == pendingTaskId)) {
        _pendingOpenTaskId = null;
        _openTask(pendingTaskId);
      }
      // Approval prompts are independent from panel pagination. A waiting
      // task hidden behind the compact list still needs one host-level modal;
      // the panel remains the durable fallback after the prompt is dismissed.
      _scheduleApprovalPrompt(tasks);
      _scheduleDecisionPrompt(tasks);
    });
    // 标签栏与队列计数按当前会话收敛，所以会话切换必须主动重算：只跟着任务流
    // 更新重算的话，切到另一个已有历史任务的会话时，标签栏仍旧是上一个会话的，
    // 而且可能一直不刷新（那个会话没有新任务事件）。
    _conversationSubscription = ConversationPresenceService
        .instance.activeConversationStream
        .listen((_) {
      if (!mounted) return;
      // 不带 preferredTaskId：上个会话选中的任务不能跟着带到新会话。
      final visibleTasks = _visibleTasks(_allTasks);
      setState(() {
        _tasks = visibleTasks;
        _hiddenTaskCount = _hiddenTaskCountFor(_allTasks, visibleTasks);
        if (_tasks.every((task) => task.id != _selectedTaskId)) {
          _selectedTaskId = _tasks.isEmpty ? null : _tasks.first.id;
        }
      });
      _scheduleDecisionPrompt(_allTasks);
    });
  }

  @override
  void dispose() {
    _overlayController.detach(_overlayOpenCallback);
    _coordinator?.setFolderGrantConsent(null);
    _tasksSubscription?.cancel();
    _conversationSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 标签全被关掉时面板也必须留着：历史任务入口在面板里，一旦整体消失，
    // 用户就再也看不到那些被关掉的任务。
    final hasTasks = _panelHasContent;
    final viewport = MediaQuery.sizeOf(context);
    final isWide = viewport.width >= _wideLayoutMinWidth;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: widget.child),
        if (hasTasks && _isVisible && !_isCollapsed)
          _positionedPanel(
            isWide: isWide,
            viewportHeight: viewport.height,
            child: WorkTaskPanel(
              showTaskSummarySection: widget.showTaskSummarySection,
              tasks: _tasks,
              hiddenTaskCount: _hiddenTaskCount,
              historyTasks: _historyTasksForActiveConversation(),
              hiddenTaskIds: _hiddenWorkTaskIds,
              onHideTask: _hideTask,
              selectedTaskId: _selectedTaskId,
              eventStreamFor: widget.eventStreamFor ??
                  _eventStore?.watch ??
                  ((_) => const Stream<WorkTaskEvent>.empty()),
              onSelectTask: (taskId) =>
                  setState(() => _selectedTaskId = taskId),
              onStop: _stopTask,
              onContinue: _continueTask,
              onReply: _canReplyToTask ? _replyTask : null,
              onOpenDecision: _coordinator == null ? null : _openDecision,
              onApprove: widget.onApproveTask ??
                  (_coordinator == null ? null : _approveTask),
              onApproveVersioned:
                  widget.onApproveTask == null && _coordinator != null
                      ? _approveTaskVersioned
                      : null,
              onApproveWithoutUndo: widget.onApproveWithoutUndoTask ??
                  (_coordinator == null ? null : _approveWithoutUndoTask),
              onApproveWithoutUndoVersioned:
                  widget.onApproveWithoutUndoTask == null &&
                          _coordinator != null
                      ? _approveWithoutUndoTaskVersioned
                      : null,
              onReject: widget.onRejectTask ??
                  (_coordinator == null ? null : _rejectTask),
              onRejectVersioned:
                  widget.onRejectTask == null && _coordinator != null
                      ? _rejectTaskVersioned
                      : null,
              onRequestFolder: widget.onRequestFolderTask ??
                  (_coordinator == null ? null : _requestFolder),
              onRequestFolderVersioned:
                  widget.onRequestFolderTask == null && _coordinator != null
                      ? _requestFolderVersioned
                      : null,
              onInstallTool: widget.onInstallToolTask ??
                  (_coordinator == null ? null : _installTool),
              onInstallToolVersioned:
                  widget.onInstallToolTask == null && _coordinator != null
                      ? _installToolVersioned
                      : null,
              onSelectVisionModel: widget.onSelectVisionModelTask ??
                  (_coordinator == null ? null : _selectVisionModel),
              onConfirmExecutorSwap:
                  _coordinator == null ? null : _confirmExecutorSwap,
              onConfirmArtifactDelivery:
                  _coordinator == null ? null : _confirmArtifactDelivery,
              onRetry: widget.onRetryTask ??
                  (_coordinator == null ? null : _retryTask),
              onReauthorize: widget.onReauthorizeTask ??
                  (widget.onRequestFolderTask != null || _coordinator != null
                      ? _reauthorizeTask
                      : null),
              onViewConflict: _viewConflictTask,
              onUndo: widget.onUndoTask ??
                  (_snapshotService == null ? null : _undoTask),
              onLater: _coordinator == null ? null : _laterTask,
              onLaterVersioned:
                  _coordinator == null ? null : _laterTaskVersioned,
              undoPreviewFor: widget.undoPreviewFor ??
                  (_snapshotService == null ? null : _undoPreview),
              onDeleteTask: widget.onDeleteTask ??
                  (_coordinator == null ? null : _deleteTask),
              // 把历史里的任务放回标签栏是纯展示动作，不依赖协调器。
              onOpenInTabStrip: widget.onOpenInTabStrip ?? _openTask,
              onOpenConversation: _openConversation,
              characterNameFor: widget.characterNameFor ?? _characterName,
              onModalVisibilityChanged: _setPanelModalVisibility,
              dialogContext: widget.navigatorKey?.currentContext,
              onCollapse: () => setState(() => _isCollapsed = true),
              onClose: () => setState(() => _isVisible = false),
            ),
          ),
        if (hasTasks && _isVisible && _isCollapsed)
          _positionedPillEntry(
            isWide: isWide,
            child: _WorkTaskMiniBar(
              taskCount: _tasks.length + _hiddenTaskCount,
              onExpand: () => setState(() => _isCollapsed = false),
              onDragUpdate: _dragMiniBar,
              onDragEnd: _endMiniBarDrag,
            ),
          ),
        if (hasTasks && !_isVisible)
          _positionedPillEntry(
            isWide: isWide,
            child: FloatingActionButton.small(
              key: const Key('work-task-reopen'),
              tooltip: '显示执行面板（任务仍在继续）',
              onPressed: () => setState(() {
                _isVisible = true;
                _isCollapsed = false;
              }),
              child: const Icon(Icons.auto_awesome_rounded),
            ),
          ),
      ],
    );
  }

  Widget _positionedPanel({
    required bool isWide,
    required double viewportHeight,
    required Widget child,
  }) {
    if (isWide) {
      return Positioned(
        key: const Key('work-task-panel-wide'),
        right: 16,
        // 与折叠胶囊同一个角落，但贴着控件行下沿而不是落在胶囊那一行（见
        // [_panelTopAnchor]）：面板展开那一下不该跳回 AppBar 正下方，也不该
        // 白白空出一段高度。
        top: _panelTopAnchor(context),
        // 面板打开时用户照样要能在会话里发言：下边界必须停在输入区之上，
        // 否则它盖住的正是输入框右端的发送按钮。
        bottom: _composerClearance,
        width: 420,
        child: child,
      );
    }
    // 底部面板不再钉死 470：折叠态内容（含两条单行动态）在 470 下放不下，
    // 执行细节必须拨滚轮才能看到。改为"视口给足 + 上限保护"。
    //
    // 顶部净空同样要让开会话控件行：窄布局下面板头原本落在 96，而控件行下沿在
    // 106，正好盖住「工作模式」开关的最后十来个像素——和宽屏面板、折叠胶囊是同一
    // 个冲突，只是这条路径漏了。窗口太矮时 400 的下限仍会把它顶回去，那是既有
    // 取舍（面板头一旦被 Stack 裁掉就什么都没了）。
    final panelTopClearance = _panelTopClearance +
        (_activeConversationId == null ? 0.0 : _conversationControlsBand);
    final panelHeight =
        (viewportHeight - panelTopClearance - _composerClearance)
            .clamp(400.0, _collapsedPanelMaxHeight)
            .toDouble();
    return Positioned(
      key: const Key('work-task-panel-bottom'),
      left: 12,
      right: 12,
      bottom: _composerClearance,
      height: panelHeight,
      child: child,
    );
  }

  /// 折叠入口（胶囊与关闭后的圆钮）落在哪儿。
  ///
  /// 拖过就停在用户放下的位置，并按窗口边界夹取——留着半个在屏幕外，用户就再也
  /// 抓不回来了；没拖过则钉在右上角默认锚点，与过去完全一致。
  Widget _positionedPillEntry({
    required bool isWide,
    required Widget child,
  }) {
    // 量的是当前实际渲染的那一块（见 [_pillEntryKey]）：隐藏态下也是它。
    final entry = KeyedSubtree(key: _pillEntryKey, child: child);
    final stored = _pillPosition;
    if (stored == null) {
      return Positioned(
        right: isWide ? 16 : 12,
        top: _topAnchor(context),
        child: entry,
      );
    }
    final position = clampWorkTaskPillPosition(
      position: stored,
      pillSize: _pillEntrySize(),
      viewport: MediaQuery.sizeOf(context),
    );
    return Positioned(left: position.dx, top: position.dy, child: entry);
  }

  /// Selects an exact task from a chat action and makes the panel visible.
  /// Hidden-task pagination is only a presentation concern; it must never
  /// change the task id addressed by the message.
  void _openTask(String taskId) {
    if (!mounted) return;
    final target = _allTasks.where((task) => task.id == taskId).firstOrNull;
    if (target == null) {
      _pendingOpenTaskId = taskId;
      return;
    }
    // 从聊天卡片点任务比「关掉标签」更新，这里顺带取消隐藏，
    // 否则面板会打开却找不到对应的标签。
    if (_hiddenWorkTaskIds.contains(taskId)) {
      unawaited(_setTaskHidden(taskId, false));
    }
    final visible = _visibleTasks(_allTasks, preferredTaskId: taskId);
    setState(() {
      _tasks = visible;
      _hiddenTaskCount = _hiddenTaskCountFor(_allTasks, visible);
      _selectedTaskId = taskId;
      _isVisible = true;
      _isCollapsed = false;
    });
  }

  void _loadHiddenWorkTaskIds() {
    try {
      _hiddenWorkTaskIds.addAll(
        ref.read(databaseServiceProvider).hiddenWorkTaskIds(),
      );
    } on Object {
      // 轻量宿主（widget 测试）可能没有 ProviderScope / 数据库，
      // 此时隐藏状态只在本次会话内生效。
    }
  }

  /// 读回用户拖到的胶囊位置。
  void _loadPillPosition() {
    try {
      _pillPosition = WorkTaskPillPosition.read(
        ref.read(databaseServiceProvider).appSettingsBox,
      );
    } on Object {
      // 见 [_loadHiddenWorkTaskIds]：轻量宿主里位置只在本次会话内生效。
    }
  }

  /// 折叠入口最近一次布局的尺寸；还没布局过时返回零尺寸。
  Size _pillEntrySize() {
    final renderObject = _pillEntryKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      return renderObject.size;
    }
    return Size.zero;
  }

  /// 拖动中：把位移累加到当前位置上。
  ///
  /// 第一次拖动从默认锚点起步，之后就在用户放下的地方继续走；夹取用胶囊的真实
  /// 尺寸，拖到哪儿都不会只剩半个在窗口里。
  void _dragMiniBar(Offset delta) {
    final viewport = MediaQuery.sizeOf(context);
    final current = _pillPosition ?? _defaultPillTopLeft(viewport);
    final moved = clampWorkTaskPillPosition(
      position: current + delta,
      pillSize: _pillEntrySize(),
      viewport: viewport,
    );
    if (moved == _pillPosition) return;
    setState(() => _pillPosition = moved);
  }

  /// 松手才落盘：拖动过程每帧都是一次写，没必要。
  void _endMiniBarDrag() {
    final position = _pillPosition;
    if (position == null) return;
    unawaited(_persistPillPosition(position));
  }

  Future<void> _persistPillPosition(Offset position) async {
    try {
      await WorkTaskPillPosition.write(
        ref.read(databaseServiceProvider).appSettingsBox,
        position,
      );
    } on Object {
      // 界面已经更新，位置最差只在本次会话生效。
    }
  }

  /// 没拖过时胶囊该待的左上角：右上角默认锚点。
  Offset _defaultPillTopLeft(Size viewport) {
    final isWide = viewport.width >= _wideLayoutMinWidth;
    return Offset(
      viewport.width - _pillEntrySize().width - (isWide ? 16 : 12),
      _topAnchor(context),
    );
  }

  /// 当前会话的历史任务（含被用户关掉标签的任务），按创建时间倒序。
  ///
  /// 面板标签只展示有限的执行快照，历史列表要能回溯整条记录，
  /// 所以这里从全局任务流里筛出属于当前会话的部分。
  List<AgentTask> _historyTasksForActiveConversation() {
    final conversationId =
        ConversationPresenceService.instance.activeConversationId;
    if (conversationId == null) return const <AgentTask>[];
    final tasks = _allTasks
        .where((task) => task.groupId == conversationId)
        .toList()
      ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return List<AgentTask>.unmodifiable(tasks);
  }

  Future<void> _hideTask(String taskId) => _setTaskHidden(taskId, true);

  /// 撤销已被续跑任务的隐藏标记。
  ///
  /// 标签栏只给终态任务提供关闭入口，正因如此「被关掉的标签」不会一直关着：
  /// 追问续跑、重试或恢复会把同一个任务 id 从终态拉回执行中。若不在这里撤销
  /// 标记，运行中的任务会被隐藏过滤挡在标签栏之外，而 X 入口又只对终态任务
  /// 开放，用户就再也无法把它找回来。
  void _releaseHiddenMarkersForResumedTasks(List<AgentTask> tasks) {
    if (_hiddenWorkTaskIds.isEmpty) return;
    final resumedTaskIds = tasks
        .where(
            (task) => !task.isTerminal && _hiddenWorkTaskIds.contains(task.id))
        .map((task) => task.id)
        .toList(growable: false);
    if (resumedTaskIds.isEmpty) return;
    _hiddenWorkTaskIds.removeAll(resumedTaskIds);
    unawaited(_persistTasksHidden(resumedTaskIds, false));
  }

  /// 切换某个任务标签的显示状态。
  ///
  /// 只改标签可见性，不动 `agent_tasks` 记录；关掉的任务仍然能在
  /// 「历史任务」里查到。持久化失败也不回滚界面，避免轻量宿主里
  /// 面板状态和数据库状态来回打架。
  Future<void> _setTaskHidden(String taskId, bool hidden) async {
    if (!mounted) return;
    if (hidden == _hiddenWorkTaskIds.contains(taskId)) return;
    final pool = <AgentTask>[..._allTasks];
    if (hidden) {
      _hiddenWorkTaskIds.add(taskId);
    } else {
      _hiddenWorkTaskIds.remove(taskId);
    }
    final visibleTasks = _visibleTasks(pool);
    setState(() {
      _tasks = visibleTasks;
      _hiddenTaskCount = _hiddenTaskCountFor(pool, visibleTasks);
      if (_tasks.every((task) => task.id != _selectedTaskId)) {
        _selectedTaskId = _tasks.isEmpty ? null : _tasks.first.id;
      }
    });
    await _persistTaskHidden(taskId, hidden);
  }

  Future<void> _persistTaskHidden(String taskId, bool hidden) async {
    await _persistTasksHidden(<String>[taskId], hidden);
  }

  Future<void> _persistTasksHidden(
    Iterable<String> taskIds,
    bool hidden,
  ) async {
    final ids = List<String>.unmodifiable(taskIds);
    _hiddenMarkerWrites = _hiddenMarkerWrites.then((_) async {
      try {
        await ref.read(databaseServiceProvider).setWorkTasksHidden(ids, hidden);
      } on Object {
        // 见 [_setTaskHidden] 注释：界面已经更新，隐藏状态最差只在本次会话生效。
      }
    });
    await _hiddenMarkerWrites;
  }

  // 标签栏与队列计数的判据集中在 [WorkTaskTabVisibility]：宿主只负责把当前的
  // 隐藏标记和所在会话递进去。规则本身与 widget 生命周期无关，单独成文件既让
  // 它们可以被独立测试，也不再往这个已经很长的宿主里加东西。
  String? get _activeConversationId =>
      ConversationPresenceService.instance.activeConversationId;

  /// 队列里被折叠的任务数，不含用户手动关掉的标签。
  int _hiddenTaskCountFor(List<AgentTask> allTasks, List<AgentTask> visible) =>
      WorkTaskTabVisibility.foldedUnfinishedCount(
        allTasks,
        visible,
        hiddenTaskIds: _hiddenWorkTaskIds,
        activeConversationId: _activeConversationId,
      );

  List<AgentTask> _visibleTasks(
    List<AgentTask> allTasks, {
    String? preferredTaskId,
  }) =>
      WorkTaskTabVisibility.visibleTasks(
        allTasks,
        hiddenTaskIds: _hiddenWorkTaskIds,
        activeConversationId: _activeConversationId,
        preferredTaskId: preferredTaskId,
      );

  /// 面板是否还有理由出现。
  bool get _panelHasContent => WorkTaskTabVisibility.hasContent(
        _allTasks,
        _tasks,
        hiddenTaskIds: _hiddenWorkTaskIds,
        activeConversationId: _activeConversationId,
      );

  Future<void> _stopTask(String taskId) {
    return widget.onStopTask?.call(taskId) ?? _coordinator!.stop(taskId);
  }

  Future<void> _continueTask(String taskId) {
    final callback = widget.onContinueTask;
    if (callback != null) return callback(taskId);
    AgentTask? task;
    for (final item in _tasks) {
      if (item.id == taskId) {
        task = item;
        break;
      }
    }
    if (task == null) return Future<void>.value();
    if (task.softLimitReached) {
      return _coordinator!.continueAfterSoftLimit(taskId);
    }
    return _coordinator!.resumeByUser(taskId);
  }

  bool get _canReplyToTask =>
      widget.onReplyTask != null || _coordinator != null;

  Future<void> _replyTask(String taskId, String reply) {
    final callback = widget.onReplyTask;
    if (callback != null) return callback(taskId, reply);
    final coordinator = _coordinator;
    if (coordinator == null) {
      throw StateError('工作任务调度器不可用，请稍后重试。');
    }
    return coordinator.enqueueFollowUp(taskId, reply);
  }

  Future<void> _retryTask(String taskId) {
    final callback = widget.onRetryTask;
    return callback?.call(taskId) ?? _coordinator!.retry(taskId);
  }

  Future<void> _reauthorizeTask(String taskId) {
    final callback = widget.onReauthorizeTask ?? widget.onRequestFolderTask;
    return callback?.call(taskId) ?? _coordinator!.reauthorizeTask(taskId);
  }

  Future<void> _viewConflictTask(String taskId) async {
    final callback = widget.onViewConflictTask;
    if (callback != null) {
      await callback(taskId);
      return;
    }
    // The default host has no conflict viewer of its own. Returning to the
    // task conversation still exposes the preserved checkpoint and lets the
    // user request a re-plan without inventing a destructive merge action.
    final task = _tasks.where((item) => item.id == taskId).firstOrNull;
    if (task != null) _openConversation(task.groupId);
  }

  Future<void> _approveTask(String taskId) {
    final callback = widget.onApproveTask;
    return callback?.call(taskId) ?? _coordinator!.approve(taskId);
  }

  Future<void> _laterTask(String taskId) {
    final coordinator = _coordinator;
    if (coordinator == null) return Future<void>.value();
    return coordinator.deferUserAction(taskId);
  }

  Future<void> _laterTaskVersioned(String taskId, int version) {
    final coordinator = _coordinator;
    if (coordinator == null) return Future<void>.value();
    final task = coordinator.taskById(taskId);
    if (task == null) {
      return Future<void>.error(StateError('该任务已不存在。'));
    }
    final blocker = WorkTaskUserAction.forTask(task)
        .where((action) => action.version == version)
        .firstOrNull;
    final discussionCheckpoint =
        WorkTaskUserAction.discussionCheckpointVersion(task) == version;
    if (blocker == null && !discussionCheckpoint) {
      return Future<void>.error(StateError('该任务提醒已失效。'));
    }
    return coordinator.deferUserAction(
      taskId,
      blockerId: blocker?.blockerId ?? 'discussionRequired',
      version: version,
    );
  }

  Future<void> _approveTaskVersioned(String taskId, int version) {
    final coordinator = _coordinator;
    return coordinator?.approve(
          taskId,
          expectedActionVersion: version,
        ) ??
        Future<void>.value();
  }

  Future<void> _approveWithoutUndoTaskVersioned(
    String taskId,
    int version,
  ) {
    final coordinator = _coordinator;
    return coordinator?.approveWithoutUndo(
          taskId,
          expectedActionVersion: version,
        ) ??
        Future<void>.value();
  }

  Future<void> _rejectTaskVersioned(String taskId, int version) {
    final coordinator = _coordinator;
    return coordinator?.reject(
          taskId,
          expectedActionVersion: version,
        ) ??
        Future<void>.value();
  }

  Future<void> _requestFolderVersioned(String taskId, int version) {
    final coordinator = _coordinator;
    return coordinator?.requestFolderForTask(
          taskId,
          expectedActionVersion: version,
        ) ??
        Future<void>.value();
  }

  Future<void> _installToolVersioned(String taskId, int version) {
    final coordinator = _coordinator;
    return coordinator?.installMissingTool(
          taskId,
          expectedActionVersion: version,
        ) ??
        Future<void>.value();
  }

  Future<void> _confirmExecutorSwap(
    String taskId,
    int version,
    bool swap,
  ) {
    final coordinator = _coordinator;
    return coordinator?.confirmExecutorSwap(
          taskId,
          version: version,
          swap: swap,
        ) ??
        Future<void>.value();
  }

  /// Accepts the files a paused task offered, answering the delivery question.
  ///
  /// This route deliberately does not go through the reply box: an accepted
  /// delivery is a decision about a known set of files, not free text, and the
  /// coordinator is the only place that may record it.
  Future<void> _confirmArtifactDelivery(String taskId) {
    final coordinator = _coordinator;
    return coordinator?.confirmArtifactDelivery(taskId) ?? Future<void>.value();
  }

  void _scheduleDecisionPrompt(List<AgentTask> tasks) {
    final coordinator = _coordinator;
    final conversationId = _activeConversationId;
    if (coordinator == null ||
        conversationId == null ||
        _decisionPromptInFlight.isNotEmpty) {
      return;
    }
    final candidate = tasks.where((task) {
      final current = coordinator.taskById(task.id);
      return current != null &&
          current.groupId == conversationId &&
          WorkTaskDecision.forTask(current).any((item) =>
              item.reminderKind != null &&
              item.promptedReminder != item.reminderKind);
    }).firstOrNull;
    if (candidate == null) return;
    _decisionPromptInFlight.add(candidate.id);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (!mounted || _activeConversationId != candidate.groupId) return;
        await _presentDecisionDialog(candidate.id, automatic: true);
      } finally {
        _decisionPromptInFlight.remove(candidate.id);
        if (mounted) _scheduleDecisionPrompt(_allTasks);
      }
    });
  }

  Future<void> _openDecision(String taskId) async {
    if (_decisionPromptInFlight.isNotEmpty) return;
    if (!_decisionPromptInFlight.add(taskId)) return;
    try {
      await _presentDecisionDialog(taskId, automatic: false);
    } finally {
      _decisionPromptInFlight.remove(taskId);
      if (mounted) _scheduleDecisionPrompt(_allTasks);
    }
  }

  Future<void> _presentDecisionDialog(String taskId,
      {required bool automatic}) async {
    final coordinator = _coordinator;
    final task = coordinator?.taskById(taskId);
    if (coordinator == null ||
        task == null ||
        !mounted ||
        task.groupId != _activeConversationId) {
      return;
    }
    final decisions =
        WorkTaskDecision.forTask(task).where((item) => item.isOpen).toList();
    if (decisions.isEmpty ||
        automatic &&
            !decisions.any((item) =>
                item.reminderKind != null &&
                item.promptedReminder != item.reminderKind)) {
      return;
    }
    final wasVisible = _isVisible;
    if (wasVisible) setState(() => _isVisible = false);
    try {
      await showDialog<void>(
        context: widget.navigatorKey?.currentContext ?? context,
        builder: (_) => WorkTaskDecisionDialog(
          decisions: decisions,
          onReply: (decision, answer, {choiceId, disposition = 'answer'}) =>
              coordinator.respondToDecision(
            taskId,
            decisionId: decision.id,
            revision: decision.revision,
            answer: answer,
            choiceId: choiceId,
            disposition: disposition,
          ),
        ),
      );
      // Claim only after the route was actually shown and dismissed. A crash
      // before presentation must still allow the reminder after restart.
      // 快照只用来确定"这次弹过哪几条"：用户在弹窗里作答/暂缓后，那条决策的修订与
      // 提醒种类都变了，按快照去标记会落空，于是同一个弹窗立刻重开。
      final current = coordinator.taskById(taskId);
      if (current != null) {
        for (final decision
            in WorkTaskDecision.remindersToClaim(decisions, current)) {
          await coordinator.markDecisionPromptShown(taskId,
              decisionId: decision.id,
              revision: decision.revision,
              reminderKind: decision.reminderKind!);
        }
      }
    } finally {
      if (mounted && wasVisible) setState(() => _isVisible = true);
    }
  }

  void _scheduleApprovalPrompt(List<AgentTask> tasks) {
    final candidates = tasks
        .where((task) =>
            task.status == AgentTaskStatus.waitingForApproval &&
            task.pendingToolRequestJson.trim().isNotEmpty &&
            WorkTaskUserAction.forTask(task).any(
              (action) => action.blockerId == 'commandApproval',
            ) &&
            !_approvalPromptInFlight.contains(task.id))
        .toList(growable: false);
    if (candidates.isEmpty) return;
    final coordinator = _coordinator;
    if (coordinator == null) return;
    final candidateIds = candidates.map((task) => task.id).toSet();
    _approvalPromptInFlight.addAll(candidateIds);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      AgentTask? taskToShow;
      String? markerTaskId;
      int? markerVersion;
      try {
        // A task may already have been presented (or dismissed) while
        // another task was waiting. Walk the snapshot until the coordinator
        // grants one fresh marker instead of letting the first task suppress
        // every later approval checkpoint.
        for (final candidate in candidates) {
          if (!mounted) return;
          final shouldShow = await coordinator.markApprovalPromptShown(
            candidate.id,
          );
          if (!shouldShow) continue;
          // Read the task again after the marker write. The stream snapshot
          // may be one update behind, and the approval dialog must describe
          // the exact pending request whose version it will resolve.
          final current = coordinator.taskById(candidate.id);
          final action = current == null
              ? null
              : WorkTaskUserAction.forTask(current)
                  .where(
                    (item) => item.blockerId == 'commandApproval',
                  )
                  .firstOrNull;
          if (current == null || action == null) {
            await coordinator.resetApprovalPromptShown(candidate.id);
            continue;
          }
          taskToShow = current;
          markerTaskId = candidate.id;
          markerVersion = action.version;
          break;
        }
        final task = taskToShow;
        final version = markerVersion;
        if (task == null || version == null) return;
        if (!mounted) {
          await coordinator.resetApprovalPromptShown(task.id);
          return;
        }
        await _showApprovalPrompt(task, expectedActionVersion: version);
      } on Object {
        // The task panel remains the durable fallback when a navigator or a
        // lightweight test host cannot present a modal prompt.
        final markerId = markerTaskId;
        if (markerId != null) {
          try {
            await coordinator.resetApprovalPromptShown(markerId);
          } on Object {
            // Keep the original presentation failure as the visible outcome.
          }
        }
      } finally {
        _approvalPromptInFlight.removeAll(candidateIds);
      }
    });
  }

  Future<void> _showApprovalPrompt(
    AgentTask task, {
    required int expectedActionVersion,
  }) async {
    final plan = approvalPlanForTask(task);
    final navigatorContext = widget.navigatorKey?.currentContext ?? context;
    final wasVisible = _isVisible;
    final wasCollapsed = _isCollapsed;
    if (wasVisible) setState(() => _isVisible = false);
    WorkChangeApprovalDecision? decision;
    try {
      if (plan != null) {
        decision = await WorkChangeApprovalDialog.show(
          navigatorContext,
          plan: plan,
        );
      } else {
        final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
        final requiresNoUndo = taskRequiresNoUndoApproval(task, plan);
        decision = await WorkTaskGenericApprovalDialog.show(
          navigatorContext,
          pending: pending,
          requiresNoUndo: requiresNoUndo,
        );
      }
    } finally {
      if (mounted && wasVisible) {
        setState(() {
          _isVisible = true;
          _isCollapsed = wasCollapsed;
        });
      }
    }
    if (decision == null) {
      // Dismissing the modal is not a decision, but the checkpoint is still
      // waiting and the host presents at most one prompt per checkpoint. Without
      // this hint the task blocks forever on a dialog the user just closed.
      _showApprovalStillPendingHint(task.id);
      return;
    }
    if (!mounted) return;
    await _resolveApprovalPromptDecision(
      task.id,
      expectedActionVersion,
      decision,
    );
  }

  /// Points a user who dismissed the approval modal at the durable fallback
  /// instead of leaving the task silently blocked.
  void _showApprovalStillPendingHint(String taskId) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: const Text('已关闭审批弹窗，任务仍在等待审批。'),
        action: SnackBarAction(
          label: '查看任务',
          onPressed: () => _openTask(taskId),
        ),
      ),
    );
  }

  Future<void> _resolveApprovalPromptDecision(
    String taskId,
    int expectedActionVersion,
    WorkChangeApprovalDecision decision,
  ) async {
    final coordinator = _coordinator;
    if (coordinator != null) {
      // The modal may remain open while another route receives a new request.
      // Re-check the exact command-approval marker before invoking the
      // coordinator; its versioned API is the final durable guard.
      final current = coordinator.taskById(taskId);
      if (current == null ||
          !WorkTaskUserAction.isCurrent(
            current,
            blockerId: 'commandApproval',
            version: expectedActionVersion,
          )) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('审批提醒已失效，请打开任务面板查看最新状态。')),
          );
        }
        return;
      }
      switch (decision) {
        case WorkChangeApprovalDecision.approved:
          await coordinator.approve(
            taskId,
            expectedActionVersion: expectedActionVersion,
          );
        case WorkChangeApprovalDecision.approvedWithoutUndo:
          await coordinator.approveWithoutUndo(
            taskId,
            expectedActionVersion: expectedActionVersion,
          );
        case WorkChangeApprovalDecision.rejected:
          await coordinator.reject(
            taskId,
            expectedActionVersion: expectedActionVersion,
          );
      }
      return;
    }
    // A lightweight embedding can provide callbacks without an app-scoped
    // coordinator. Such callbacks remain responsible for their own durable
    // validation, as they were before the coordinator bridge existed.
    if (decision == WorkChangeApprovalDecision.approved) {
      await _approveTask(taskId);
    } else if (decision == WorkChangeApprovalDecision.approvedWithoutUndo) {
      await _approveWithoutUndoTask(taskId);
    } else {
      await _rejectTask(taskId);
    }
  }

  Future<void> _requestFolder(String taskId) {
    return widget.onRequestFolderTask?.call(taskId) ??
        _coordinator!.requestFolderForTask(taskId);
  }

  Future<void> _installTool(String taskId) {
    return widget.onInstallToolTask?.call(taskId) ??
        _coordinator!.installMissingTool(taskId);
  }

  Future<void> _selectVisionModel(String taskId) async {
    final custom = widget.onSelectVisionModelTask;
    if (custom != null) {
      await custom(taskId);
      return;
    }
    final coordinator = _coordinator;
    if (coordinator == null) return;
    final task = _tasks.where((item) => item.id == taskId).firstOrNull;
    if (task == null) return;
    final candidates = _visionCandidates(task);
    if (candidates.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有找到已配置且支持图片的视觉模型。')),
        );
      }
      return;
    }
    // ponytail: the global task panel otherwise covers this Navigator modal;
    // temporarily remove it so the model list and cancel action are usable.
    final wasVisible = _isVisible;
    final wasCollapsed = _isCollapsed;
    if (wasVisible) setState(() => _isVisible = false);
    String? selected;
    try {
      selected = await showDialog<String>(
        context: widget.navigatorKey?.currentContext ?? context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('work-task-vision-model-dialog'),
          title: const Text('选择视觉模型'),
          content: SizedBox(
            width: 420,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: candidates.length,
              itemBuilder: (context, index) {
                final candidate = candidates[index];
                return ListTile(
                  key: Key('work-task-vision-model-${candidate.character.id}'),
                  title: Text(candidate.character.name),
                  subtitle: Text(
                    '${candidate.config.provider} / ${candidate.config.modelName}',
                  ),
                  onTap: () => Navigator.of(dialogContext).pop(
                    candidate.character.id,
                  ),
                );
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              key: const Key('work-task-vision-model-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted && wasVisible) {
        setState(() {
          _isVisible = true;
          _isCollapsed = wasCollapsed;
        });
      }
    }
    if (selected == null || selected == task.characterId) return;
    await coordinator.selectVisionModel(taskId, selected);
  }

  List<_VisionCandidate> _visionCandidates(AgentTask task) {
    try {
      final database = ref.read(databaseServiceProvider);
      final governance = AiGovernanceStore.forDatabase(database);
      final allowedCharacterIds = _visionCharacterIdsForTask(database, task);
      final candidates = <_VisionCandidate>[];
      for (final character in database.aiCharacterBox.values) {
        if (!allowedCharacterIds.contains(character.id)) continue;
        if (!character.isActive || !character.agenticEnabled) continue;
        final config = database.apiConfigBox.get(character.apiConfigId);
        if (config == null || (!config.hasCredential && !config.hasApiKey)) {
          continue;
        }
        final provider = ApiProvider.values.where(
          (item) => item.name == config.provider,
        );
        if (provider.isEmpty) continue;
        final capability = governance.guard.capability(
          provider.single,
          config.modelName,
        );
        if (capability.supportsVision) {
          candidates
              .add(_VisionCandidate(character: character, config: config));
        }
      }
      return candidates;
    } on Object {
      return const <_VisionCandidate>[];
    }
  }

  Set<String> _visionCharacterIdsForTask(
    DatabaseService database,
    AgentTask task,
  ) {
    if (task.groupId.startsWith('dm:')) {
      return {task.groupId.substring(3)};
    }
    final group = database.chatGroupBox.get(task.groupId);
    return group == null ? const <String>{} : group.aiCharacterIds.toSet();
  }

  Future<bool> _confirmFolderGrant(WorkFolderGrant grant) {
    if (!mounted) return Future.value(false);
    final navigatorContext = widget.navigatorKey?.currentContext ?? context;
    // ponytail: the app-scoped panel sits above the route Navigator; hide it
    // for the modal consent so its action buttons cannot be covered by the
    // very panel that triggered the authorization request.
    final wasVisible = _isVisible;
    final wasCollapsed = _isCollapsed;
    if (wasVisible) {
      setState(() => _isVisible = false);
    }
    return showWorkFolderGrantConsent(navigatorContext, grant).whenComplete(() {
      if (mounted && wasVisible) {
        setState(() {
          _isVisible = true;
          _isCollapsed = wasCollapsed;
        });
      }
    });
  }

  void _setPanelModalVisibility(bool visible) {
    if (!mounted) return;
    setState(() {
      _isVisible = visible;
      if (visible) _isCollapsed = false;
    });
  }

  Future<void> _rejectTask(String taskId) {
    final callback = widget.onRejectTask;
    return callback?.call(taskId) ?? _coordinator!.reject(taskId);
  }

  Future<void> _approveWithoutUndoTask(String taskId) {
    final callback = widget.onApproveWithoutUndoTask;
    return callback?.call(taskId) ?? _coordinator!.approveWithoutUndo(taskId);
  }

  /// 删除一条任务记录。
  ///
  /// 标签隐藏标记是"展示层"状态，与记录分开存放：记录没了却留下标记，会让这
  /// 个 id 永远占着设置项。协调器只负责记录与日志，标记由宿主自己清。
  Future<void> _deleteTask(String taskId) async {
    final coordinator = _coordinator;
    if (coordinator == null) {
      throw StateError('工作任务调度器不可用，请稍后重试。');
    }
    if (_hiddenWorkTaskIds.remove(taskId)) {
      unawaited(_persistTaskHidden(taskId, false));
    }
    await coordinator.deleteTask(taskId);
  }

  Future<void> _undoTask(String taskId) async {
    final service = _snapshotService;
    if (service == null) throw StateError('当前没有可用的任务快照。');
    final result = await service.undo(taskId);
    if (!result.succeeded) {
      final conflicts = result.conflicts
          .map(
            (conflict) =>
                '${_shortConflictPath(conflict.path)}：${sanitizeWorkTaskError(conflict.reason)}',
          )
          .join('；');
      final suffix = conflicts.isEmpty ? '' : ' 具体冲突：$conflicts';
      throw StateError('${sanitizeWorkTaskError(result.reason)}$suffix');
    }
  }

  Future<List<WorkSnapshotUndoItem>> _undoPreview(String taskId) {
    final service = _snapshotService;
    if (service == null) return Future.value(const []);
    return service.previewUndo(taskId);
  }

  String _shortConflictPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  String _characterName(String characterId) {
    try {
      final database = ref.read(databaseServiceProvider);
      return database.aiCharacterBox.get(characterId)?.name ?? characterId;
    } on Object {
      // Embedded/widget tests may provide a task stream without opening Hive.
      return characterId;
    }
  }

  void _openConversation(String conversationId) {
    final route = conversationId.startsWith('dm:')
        ? '/dm/${conversationId.substring(3)}'
        : '/chat/$conversationId';
    final navigator = widget.navigatorKey?.currentState;
    if (navigator != null) {
      navigator.pushNamed(route);
      return;
    }
    Navigator.of(context).pushNamed(route);
  }
}

/// 折叠后的常驻入口。
///
/// 只留图标、任务数与展开箭头：它默认浮在聊天页右上角，可以拖到任意位置。
///
/// 文字越长占掉的横向空间越大，越容易压住下面的内容，所以完整含义放进 tooltip，
/// 需要时仍可读到。
///
/// 任务数为 0 时不画数字：那不代表「还有 0 个任务」，而是本会话没有可盯的标签
/// （记录都收在「历史任务」里，或者被用户自己关掉了标签），写一个 0 出来只会让
/// 人以为出了问题。面板自己那条队列提示用的也是同一个口径（只在计数大于 0 时
/// 出现），隐藏态的圆钮本来就没有数字，三者由此对齐。
class _WorkTaskMiniBar extends StatelessWidget {
  final int taskCount;
  final VoidCallback onExpand;

  /// 拖动回调：`onDragUpdate` 收位移增量，`onDragEnd` 在松手时落盘。
  ///
  /// 手势与点击共存：没挪动的话由内层 InkWell 的 tap 拿走（展开面板），越过触摸
  /// slop 才归 pan 识别器——拖动不会被误判成展开。
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragEnd;

  const _WorkTaskMiniBar({
    required this.taskCount,
    required this.onExpand,
    this.onDragUpdate,
    this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final showsCount = taskCount > 0;
    final bar = Tooltip(
      message: showsCount ? '工作任务 $taskCount 项 · 点击展开' : '打开任务面板',
      child: Material(
        key: const Key('work-task-mini-bar'),
        elevation: 8,
        borderRadius: BorderRadius.circular(18),
        color: Theme.of(context).colorScheme.surface,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onExpand,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.auto_awesome_rounded, size: 16),
                const SizedBox(width: 6),
                if (showsCount) ...<Widget>[
                  Text('$taskCount'),
                  const SizedBox(width: 2),
                ],
                const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
    if (onDragUpdate == null && onDragEnd == null) return bar;
    return GestureDetector(
      // 只给工具提示留的默认行为不受影响：桌面端 Tooltip 走悬停，触屏端长按
      // （没有位移）仍由长按识别器拿走。
      behavior: HitTestBehavior.deferToChild,
      onPanUpdate: (details) => onDragUpdate?.call(details.delta),
      onPanEnd: onDragEnd == null ? null : (_) => onDragEnd!(),
      child: bar,
    );
  }
}

class _VisionCandidate {
  final AICharacter character;
  final ApiConfig config;

  const _VisionCandidate({required this.character, required this.config});
}
