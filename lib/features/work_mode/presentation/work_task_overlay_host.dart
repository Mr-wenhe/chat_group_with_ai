import 'dart:async';

import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:chat_group/features/work_mode/providers/work_task_providers.dart';
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
  final Future<void> Function(String taskId)? onUndoTask;
  final WorkTaskUndoPreview? undoPreviewFor;
  final WorkSnapshotService? snapshotService;
  final String Function(String characterId)? characterNameFor;

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
    this.onUndoTask,
    this.undoPreviewFor,
    this.snapshotService,
    this.characterNameFor,
  });

  @override
  ConsumerState<WorkTaskOverlayHost> createState() =>
      _WorkTaskOverlayHostState();
}

class _WorkTaskOverlayHostState extends ConsumerState<WorkTaskOverlayHost> {
  StreamSubscription<List<AgentTask>>? _tasksSubscription;
  WorkTaskCoordinator? _coordinator;
  WorkTaskEventStore? _eventStore;
  List<AgentTask> _tasks = const <AgentTask>[];
  int _hiddenTaskCount = 0;
  String? _selectedTaskId;
  bool _isVisible = true;
  bool _isCollapsed = false;
  WorkSnapshotService? _snapshotService;

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
    });
  }

  @override
  void dispose() {
    _coordinator?.setFolderGrantConsent(null);
    _tasksSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasTasks = _tasks.isNotEmpty;
    final isWide = MediaQuery.sizeOf(context).width >= 800;
    return Stack(
      children: <Widget>[
        Positioned.fill(child: widget.child),
        if (hasTasks && _isVisible && !_isCollapsed)
          _positionedPanel(
            isWide: isWide,
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
              onUndo: widget.onUndoTask ??
                  (_snapshotService == null ? null : _undoTask),
              undoPreviewFor: widget.undoPreviewFor ??
                  (_snapshotService == null ? null : _undoPreview),
              onOpenConversation: _openConversation,
              characterNameFor: widget.characterNameFor ?? _characterName,
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
            bottom: 16,
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

  Widget _positionedPanel({required bool isWide, required Widget child}) {
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
      height: 470,
      child: child,
    );
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

  Future<void> _approveTask(String taskId) {
    final callback = widget.onApproveTask;
    return callback?.call(taskId) ?? _coordinator!.approve(taskId);
  }

  Future<void> _requestFolder(String taskId) {
    return widget.onRequestFolderTask?.call(taskId) ??
        _coordinator!.requestFolderForTask(taskId);
  }

  Future<bool> _confirmFolderGrant(WorkFolderGrant grant) {
    if (!mounted) return Future.value(false);
    final navigatorContext = widget.navigatorKey?.currentContext ?? context;
    return showWorkFolderGrantConsent(navigatorContext, grant);
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
