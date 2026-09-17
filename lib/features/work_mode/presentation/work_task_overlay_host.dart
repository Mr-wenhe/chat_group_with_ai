import 'dart:async';

import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:chat_group/features/work_mode/presentation/work_change_approval_dialog.dart';
import 'package:chat_group/features/work_mode/work_task_approval_plan.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/presentation/visible_browser_panel.dart';
import 'package:chat_group/features/work_mode/providers/work_task_providers.dart';
import 'package:chat_group/features/work_mode/visible_browser_service.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/presentation/work_folder_grant_consent_dialog.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_overlay_controller.dart';
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
  final WorkTaskUndoPreview? undoPreviewFor;
  final WorkSnapshotService? snapshotService;
  final String Function(String characterId)? characterNameFor;
  final VisibleBrowserService? browserService;

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
    this.undoPreviewFor,
    this.snapshotService,
    this.characterNameFor,
    this.browserService,
  });

  @override
  ConsumerState<WorkTaskOverlayHost> createState() =>
      _WorkTaskOverlayHostState();
}

class _WorkTaskOverlayHostState extends ConsumerState<WorkTaskOverlayHost> {
  // Keep the global reopen control above the chat composer. The host overlays
  // the whole Navigator and cannot measure a route's variable-height footer.
  // This clearance covers the normal composer row plus a small visual gap;
  // attachment/quote previews remain a known ceiling for this global host.
  static const _reopenButtonBottomClearance = 84.0;

  StreamSubscription<List<AgentTask>>? _tasksSubscription;
  StreamSubscription<List<VisibleBrowserSession>>? _browserSubscription;
  WorkTaskCoordinator? _coordinator;
  WorkTaskEventStore? _eventStore;
  List<AgentTask> _tasks = const <AgentTask>[];
  List<AgentTask> _allTasks = const <AgentTask>[];
  int _hiddenTaskCount = 0;
  String? _selectedTaskId;

  /// 被用户关掉标签的任务 id。只影响标签展示，任务记录仍然完整保留，
  /// 关掉后依旧能在历史任务列表里查到。
  final Set<String> _hiddenWorkTaskIds = <String>{};
  bool _isVisible = true;
  bool _isCollapsed = false;
  WorkSnapshotService? _snapshotService;
  VisibleBrowserService? _browserService;
  List<VisibleBrowserSession> _browserSessions =
      const <VisibleBrowserSession>[];
  String? _selectedBrowserSessionId;
  final Set<String> _approvalPromptInFlight = <String>{};
  late final WorkTaskOverlayController _overlayController;
  late final WorkTaskOverlayOpenTask _overlayOpenCallback;
  String? _pendingOpenTaskId;

  @override
  void initState() {
    super.initState();
    // 必须在订阅任务流之前载入隐藏状态，否则首帧会把已关掉的标签又画出来。
    _loadHiddenWorkTaskIds();
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
    _browserService = widget.browserService;
    if (_browserService == null) {
      try {
        _browserService = ref.read(visibleBrowserServiceProvider);
      } on Object {
        // A lightweight host can omit the app-scoped browser service.
      }
    }
    final browserService = _browserService;
    if (browserService != null) {
      _browserSessions = browserService.sessions;
      _selectedBrowserSessionId =
          _browserSessions.isEmpty ? null : _browserSessions.last.id;
      _browserSubscription = browserService.watchSessions().listen((sessions) {
        if (!mounted) return;
        setState(() {
          _browserSessions = sessions;
          if (_browserSessions
              .every((session) => session.id != _selectedBrowserSessionId)) {
            _selectedBrowserSessionId =
                _browserSessions.isEmpty ? null : _browserSessions.last.id;
          }
        });
      });
    }
    final taskStream = widget.taskStream ??
        _coordinator?.watchAllTasks() ??
        const Stream<List<AgentTask>>.empty();
    _tasksSubscription = taskStream.listen((tasks) {
      if (!mounted) return;
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
    });
  }

  @override
  void dispose() {
    _overlayController.detach(_overlayOpenCallback);
    _coordinator?.setFolderGrantConsent(null);
    _tasksSubscription?.cancel();
    _browserSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 标签全被关掉时面板也必须留着：历史任务入口在面板里，一旦整体消失，
    // 用户就再也看不到那些被关掉的任务。
    final hasTasks = _tasks.isNotEmpty || _hasHiddenWorkTasks;
    final viewport = MediaQuery.sizeOf(context);
    final isWide = viewport.width >= 800;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: widget.child),
        if (_browserSessions.isNotEmpty)
          _positionedBrowserPanel(
            isWide: isWide,
            availableWidth: viewport.width,
            availableHeight: viewport.height,
            child: VisibleBrowserPanel(
              sessions: _browserSessions,
              selectedSessionId: _selectedBrowserSessionId,
              onSelectSession: (sessionId) =>
                  setState(() => _selectedBrowserSessionId = sessionId),
              onContinue: _continueBrowser,
              onClose: _closeBrowser,
              onBringToForeground: _focusBrowser,
              onInstallRuntime: _installBrowserRuntime,
            ),
          ),
        if (hasTasks && _isVisible && !_isCollapsed)
          _positionedPanel(
            isWide: isWide,
            availableHeight: viewport.height,
            splitForBrowser: _browserSessions.isNotEmpty,
            child: WorkTaskPanel(
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
              onOpenConversation: _openConversation,
              characterNameFor: widget.characterNameFor ?? _characterName,
              onModalVisibilityChanged: _setPanelModalVisibility,
              dialogContext: widget.navigatorKey?.currentContext,
              onCollapse: () => setState(() => _isCollapsed = true),
              onClose: () => setState(() => _isVisible = false),
            ),
          ),
        if (hasTasks && _isVisible && _isCollapsed)
          _positionedMiniBar(
            isWide: isWide,
            child: _WorkTaskMiniBar(
              taskCount: _tasks.length + _hiddenTaskCount,
              onExpand: () => setState(() => _isCollapsed = false),
            ),
          ),
        if (hasTasks && !_isVisible)
          Positioned(
            right: 16,
            bottom: _reopenButtonBottomClearance,
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
    required double availableHeight,
    required bool splitForBrowser,
    required Widget child,
  }) {
    if (isWide) {
      return Positioned(
        key: const Key('work-task-panel-wide'),
        right: 16,
        top: 72,
        bottom: 16,
        width: 420,
        child: child,
      );
    }
    return Positioned(
      key: const Key('work-task-panel-bottom'),
      left: 12,
      right: 12,
      bottom: 12,
      height: splitForBrowser ? _splitPanelHeight(availableHeight) : 470,
      child: child,
    );
  }

  Widget _positionedBrowserPanel({
    required bool isWide,
    required double availableWidth,
    required double availableHeight,
    required Widget child,
  }) {
    if (isWide) {
      // Keep the two non-modal panels side by side even at the default
      // 800px widget-test/desktop width; neither panel may absorb the other.
      final width = (availableWidth - 468).clamp(300.0, 420.0);
      return Positioned(
        key: const Key('visible-browser-panel-wide'),
        left: 16,
        top: 72,
        bottom: 16,
        width: width,
        child: child,
      );
    }
    return Positioned(
      key: const Key('visible-browser-panel-top'),
      left: 12,
      right: 12,
      top: 12,
      height: _splitPanelHeight(availableHeight),
      child: child,
    );
  }

  double _splitPanelHeight(double availableHeight) {
    return ((availableHeight - 36) / 2).clamp(180.0, 470.0);
  }

  Widget _positionedMiniBar({required bool isWide, required Widget child}) {
    return Positioned(
      right: isWide ? 16 : 12,
      left: isWide ? null : 12,
      bottom: 16,
      child: child,
    );
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

  /// 是否存在被用户关掉标签的任务。只要有一个，面板就不能整体消失。
  bool get _hasHiddenWorkTasks =>
      _allTasks.any((task) => _hiddenWorkTaskIds.contains(task.id));

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
    try {
      await ref.read(databaseServiceProvider).setWorkTaskHidden(taskId, hidden);
    } on Object {
      // 见方法注释：界面已经更新，隐藏状态最差只在本次会话生效。
    }
  }

  /// 队列里被折叠的任务数，不含用户手动关掉的标签。
  int _hiddenTaskCountFor(List<AgentTask> allTasks, List<AgentTask> visible) {
    final offScreen =
        allTasks.where((task) => !_hiddenWorkTaskIds.contains(task.id)).length;
    final count = offScreen - visible.length;
    return count < 0 ? 0 : count;
  }

  List<AgentTask> _visibleTasks(
    List<AgentTask> allTasks, {
    String? preferredTaskId,
  }) {
    // 被用户关掉标签的任务不参与标签挑选，但仍然留在 _allTasks 里，
    // 供历史任务列表回查。
    final candidates = allTasks
        .where((task) => !_hiddenWorkTaskIds.contains(task.id))
        .toList(growable: false);
    final sorted = List<AgentTask>.from(candidates)
      ..sort(
        (left, right) => (right.updatedAt ?? right.createdAt).compareTo(
          left.updatedAt ?? left.createdAt,
        ),
      );
    // A newer queued task must not hide an older task that is actively
    // executing. Keep both global execution slots visible, then fill the
    // remaining panel slot with the newest other checkpoint.
    final active = sorted
        .where((task) => _isVisibleActiveStatus(task.status))
        .toList(growable: false);
    final remaining = sorted
        .where((task) => !active.any((item) => item.id == task.id))
        .toList(growable: false);
    // The coordinator has two global execution slots. Keep both active tasks
    // visible; only show queued/history tabs when an execution slot is free.
    const executionSlotCount = 2;
    final visibleActive =
        active.take(executionSlotCount).toList(growable: false);
    final visible = visibleActive.length >= executionSlotCount
        ? visibleActive
        : <AgentTask>[...visibleActive, ...remaining]
            .take(4)
            .toList(growable: false);
    if (preferredTaskId == null ||
        visible.any((task) => task.id == preferredTaskId)) {
      return visible;
    }
    final preferred =
        sorted.where((task) => task.id == preferredTaskId).firstOrNull;
    return preferred == null ? visible : <AgentTask>[...visible, preferred];
  }

  bool _isVisibleActiveStatus(AgentTaskStatus status) {
    return status == AgentTaskStatus.planning ||
        status == AgentTaskStatus.waitingForApproval ||
        status == AgentTaskStatus.runningTool;
  }

  Future<void> _stopTask(String taskId) {
    return widget.onStopTask?.call(taskId) ?? _coordinator!.stop(taskId);
  }

  Future<void> _continueBrowser(String sessionId) async {
    await _browserService?.continueSession(sessionId);
  }

  Future<void> _closeBrowser(String sessionId) async {
    await _browserService?.closeSession(sessionId);
  }

  Future<void> _focusBrowser(String sessionId) async {
    await _browserService?.bringToForeground(sessionId);
  }

  Future<void> _installBrowserRuntime() async {
    final installed = await _browserService?.openRuntimeInstallFlow() ?? false;
    if (!installed && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开官方 WebView 运行时安装流程。')),
      );
    }
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
        decision = await showDialog<WorkChangeApprovalDecision>(
          context: navigatorContext,
          barrierDismissible: true,
          builder: (dialogContext) => AlertDialog(
            key: const Key('work-generic-approval-dialog'),
            title: const Text('工作任务需要审批'),
            content: Text(
              pending == null
                  ? '任务准备执行一项需要确认的操作。'
                  : WorkModePolicy.approvalSummary(pending),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext)
                    .pop(WorkChangeApprovalDecision.rejected),
                child: const Text('拒绝并暂停'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext)
                    .pop(WorkChangeApprovalDecision.approved),
                child: const Text('允许本次操作'),
              ),
            ],
          ),
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
    if (decision == null || !mounted) return;
    await _resolveApprovalPromptDecision(
      task.id,
      expectedActionVersion,
      decision,
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

class _WorkTaskMiniBar extends StatelessWidget {
  final int taskCount;
  final VoidCallback onExpand;

  const _WorkTaskMiniBar({required this.taskCount, required this.onExpand});

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('work-task-mini-bar'),
      elevation: 8,
      borderRadius: BorderRadius.circular(18),
      color: Theme.of(context).colorScheme.surface,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onExpand,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.auto_awesome_rounded, size: 18),
              const SizedBox(width: 8),
              Text('工作任务 $taskCount 项 · 点击展开'),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_up_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _VisionCandidate {
  final AICharacter character;
  final ApiConfig config;

  const _VisionCandidate({required this.character, required this.config});
}
