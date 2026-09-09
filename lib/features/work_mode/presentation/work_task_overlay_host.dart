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
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/presentation/work_folder_grant_consent_dialog.dart';
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
  int _hiddenTaskCount = 0;
  String? _selectedTaskId;
  bool _isVisible = true;
  bool _isCollapsed = false;
  WorkSnapshotService? _snapshotService;
  VisibleBrowserService? _browserService;
  List<VisibleBrowserSession> _browserSessions =
      const <VisibleBrowserSession>[];
  String? _selectedBrowserSessionId;
  final Set<String> _approvalPromptInFlight = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.taskStream == null ||
        widget.onStopTask == null ||
        widget.onContinueTask == null) {
      _coordinator =
          widget.coordinator ?? ref.read(workTaskCoordinatorProvider);
    } else {
      _coordinator = widget.coordinator;
    }
    _coordinator?.setFolderGrantConsent(_confirmFolderGrant);
    _eventStore = widget.eventStore ??
        (widget.eventStreamFor == null
            ? ref.read(workTaskEventStoreProvider)
            : null);
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
    final taskStream = widget.taskStream ?? _coordinator!.watchAllTasks();
    _tasksSubscription = taskStream.listen((tasks) {
      if (!mounted) return;
      final visibleTasks = _visibleTasks(tasks);
      setState(() {
        _tasks = visibleTasks;
        _hiddenTaskCount = tasks.length - visibleTasks.length;
        if (_tasks.every((task) => task.id != _selectedTaskId)) {
          _selectedTaskId = _tasks.isEmpty ? null : _tasks.first.id;
        }
      });
      // Approval prompts are independent from panel pagination. A waiting
      // task hidden behind the compact list still needs one host-level modal;
      // the panel remains the durable fallback after the prompt is dismissed.
      _scheduleApprovalPrompt(tasks);
    });
  }

  @override
  void dispose() {
    _coordinator?.setFolderGrantConsent(null);
    _tasksSubscription?.cancel();
    _browserSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasTasks = _tasks.isNotEmpty;
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
              selectedTaskId: _selectedTaskId,
              eventStreamFor: widget.eventStreamFor ?? _eventStore!.watch,
              onSelectTask: (taskId) =>
                  setState(() => _selectedTaskId = taskId),
              onStop: _stopTask,
              onContinue: _continueTask,
              onApprove: _approveTask,
              onApproveWithoutUndo: _approveWithoutUndoTask,
              onReject: _rejectTask,
              onRequestFolder: _requestFolder,
              onInstallTool: _installTool,
              onSelectVisionModel: _selectVisionModel,
              onRetry: widget.onRetryTask ??
                  (_coordinator == null ? null : _retryTask),
              onReauthorize: widget.onReauthorizeTask ??
                  (widget.onRequestFolderTask != null || _coordinator != null
                      ? _reauthorizeTask
                      : null),
              onViewConflict: _viewConflictTask,
              onUndo: widget.onUndoTask ??
                  (_snapshotService == null ? null : _undoTask),
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

  List<AgentTask> _visibleTasks(List<AgentTask> allTasks) {
    final sorted = List<AgentTask>.from(allTasks)
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
    if (visibleActive.length >= executionSlotCount) return visibleActive;
    return <AgentTask>[...visibleActive, ...remaining]
        .take(4)
        .toList(growable: false);
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

  Future<void> _retryTask(String taskId) {
    final callback = widget.onRetryTask;
    return callback?.call(taskId) ?? _coordinator!.retry(taskId);
  }

  Future<void> _reauthorizeTask(String taskId) {
    final callback = widget.onReauthorizeTask ?? widget.onRequestFolderTask;
    return callback?.call(taskId) ?? _coordinator!.requestFolderForTask(taskId);
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

  void _scheduleApprovalPrompt(List<AgentTask> tasks) {
    final candidates = tasks
        .where((task) =>
            task.status == AgentTaskStatus.waitingForApproval &&
            task.pendingToolRequestJson.trim().isNotEmpty &&
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
          taskToShow = candidate;
          markerTaskId = candidate.id;
          break;
        }
        final task = taskToShow;
        if (task == null) return;
        if (!mounted) {
          await coordinator.resetApprovalPromptShown(task.id);
          return;
        }
        await _showApprovalPrompt(task);
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

  Future<void> _showApprovalPrompt(AgentTask task) async {
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
    if (decision == WorkChangeApprovalDecision.approved) {
      await _approveTask(task.id);
    } else if (decision == WorkChangeApprovalDecision.approvedWithoutUndo) {
      await _approveWithoutUndoTask(task.id);
    } else {
      await _rejectTask(task.id);
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
