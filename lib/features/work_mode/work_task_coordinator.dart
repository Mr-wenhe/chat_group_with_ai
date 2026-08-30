import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:hive/hive.dart';

import 'work_task_event.dart';
import 'work_task_event_store.dart';
import 'work_task_error_sanitizer.dart';
import 'work_folder_grant_service.dart';
import 'work_resource_lock_manager.dart';
import 'work_snapshot_manifest.dart';
import 'work_approval_decision.dart';
import 'work_change_plan.dart';

typedef WorkTaskSnapshotStatusUpdater = Future<void> Function(
    String taskId, WorkSnapshotTaskStatus status);

/// A cancellation handle belongs to exactly one active work task.
class WorkTaskCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Runs one task after the coordinator has reserved its global slot.
abstract interface class WorkTaskRunner {
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation);
}

/// Optional capability for runners that persist checkpoints themselves.
///
/// The coordinator remains the owner of the task stream, while a production
/// runner can publish each durable checkpoint immediately instead of waiting
/// for the whole run to finish. Test runners do not need this capability.
abstract interface class WorkTaskProgressReporter {
  void setTaskUpdateSink(void Function(AgentTask task) sink);
}

/// Computes the complete resource plan before a task starts executing.
typedef WorkTaskResourceLockPlan = Iterable<WorkResourceLockRequest> Function(
    AgentTask task);

/// Optional runner capability for a production loop that owns its plan.
abstract interface class WorkTaskResourceLockPlanner {
  Iterable<WorkResourceLockRequest> planResourceLocks(AgentTask task);
}

class _RunningTask {
  final AgentTask task;
  final WorkTaskCancellation cancellation;

  const _RunningTask({required this.task, required this.cancellation});
}

class _WaitingResourceTask {
  final AgentTask task;
  final WorkTaskCancellation cancellation;
  WorkResourceLockLease? lease;

  _WaitingResourceTask({required this.task, required this.cancellation});
}

/// Owns work-task scheduling independently from every chat-room widget.
///
/// State updates are serialized before starting a runner, so two concurrent
/// submissions cannot consume the same slot or run the same conversation.
class WorkTaskCoordinator {
  static const int maximumConcurrentTasks = 2;

  final Box<AgentTask> _taskBox;
  final WorkTaskEventStore _eventStore;
  final WorkTaskRunner _runner;
  final WorkFolderGrantService? _folderGrantService;
  final WorkFolderPicker? _folderPicker;
  WorkFolderGrantConsent? _folderGrantConsent;
  final bool _requireFolderGrant;
  final WorkTaskSnapshotStatusUpdater? _snapshotStatusUpdater;
  final WorkResourceLockManager _resourceLockManager;
  final WorkTaskResourceLockPlan? _resourceLockPlan;
  final DateTime Function() _clock;
  final StreamController<AgentTask> _taskUpdates =
      StreamController<AgentTask>.broadcast(sync: true);
  final Map<String, _RunningTask> _running = <String, _RunningTask>{};
  final Map<String, Queue<String>> _conversationQueues =
      <String, Queue<String>>{};
  final Queue<String> _readyConversations = Queue<String>();
  final Set<String> _readyConversationIds = <String>{};
  final Map<String, Future<void>> _activeRuns = <String, Future<void>>{};
  final Map<String, List<WorkResourceLockRequest>> _taskLockPlans =
      <String, List<WorkResourceLockRequest>>{};
  final Map<String, _WaitingResourceTask> _waitingForResources =
      <String, _WaitingResourceTask>{};
  final Map<String, WorkTaskCancellation> _folderWaiters =
      <String, WorkTaskCancellation>{};
  final Set<String> _conversationReservations = <String>{};
  final Set<String> _startingTaskIds = <String>{};
  final Queue<Completer<void>> _slotWaiters = Queue<Completer<void>>();
  Future<WorkFolderRequestResult>? _folderRequest;

  Future<void> _operations = Future<void>.value();
  Future<void>? _disposeFuture;
  bool _disposed = false;

  WorkTaskCoordinator({
    required Box<AgentTask> taskBox,
    required WorkTaskEventStore eventStore,
    required WorkTaskRunner runner,
    WorkFolderGrantService? folderGrantService,
    WorkFolderPicker? folderPicker,
    WorkFolderGrantConsent? folderGrantConsent,
    bool requireFolderGrant = false,
    WorkTaskSnapshotStatusUpdater? snapshotStatusUpdater,
    WorkResourceLockManager? resourceLockManager,
    WorkTaskResourceLockPlan? resourceLockPlan,
    DateTime Function()? clock,
  })  : _taskBox = taskBox,
        _eventStore = eventStore,
        _runner = runner,
        _folderGrantService = folderGrantService,
        _folderPicker = folderPicker,
        _folderGrantConsent = folderGrantConsent,
        _requireFolderGrant = requireFolderGrant,
        _snapshotStatusUpdater = snapshotStatusUpdater,
        _resourceLockManager = resourceLockManager ?? WorkResourceLockManager(),
        _resourceLockPlan = resourceLockPlan,
        _clock = clock ?? DateTime.now {
    if (runner case final WorkTaskProgressReporter reporter) {
      reporter.setTaskUpdateSink(_publish);
    }
  }

  int get runningTaskCount => _running.length;

  /// Lets the app-level overlay provide the one-time cloud-disclosure dialog
  /// without coupling the scheduler to a particular [BuildContext].
  void setFolderGrantConsent(WorkFolderGrantConsent? consent) {
    _folderGrantConsent = consent;
  }

  /// Persists and schedules a new V1 work task. The task is queued before a
  /// runner can observe it, which makes state recoverable at every boundary.
  Future<AgentTask> submit(
    AgentTask task, {
    Iterable<WorkResourceLockRequest>? resourceLocks,
  }) {
    return _serialize(() async {
      _ensureOpen();
      if (!task.workModeTask) {
        throw ArgumentError.value(task, 'task', '协调器只接受工作模式任务');
      }
      if (_taskBox.containsKey(task.id)) {
        throw StateError('工作任务已存在：${task.id}');
      }
      if (resourceLocks != null) {
        final normalizedLocks = _resourceLockManager.normalizeLockSet(
          resourceLocks,
        );
        _taskLockPlans[task.id] = normalizedLocks;
        task.executionStateJson = _withResourceLockPlan(
          task.executionStateJson,
          normalizedLocks,
        );
      }
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..updatedAt = _clock();
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '任务已排队'));
      await _schedule();
      return task;
    });
  }

  /// Adds user input to the same durable task instead of replacing its run.
  Future<void> enqueueFollowUp(String taskId, String request) {
    return _serialize(() async {
      _ensureOpen();
      final normalized = request.trim();
      if (normalized.isEmpty) return;
      final task = _requireWorkTask(taskId);
      if (task.status == AgentTaskStatus.cancelled) {
        throw StateError('已停止的任务不能继续追问，请创建新的工作任务。');
      }
      task.queuedUserRequests = <String>[
        ...task.queuedUserRequests,
        normalized,
      ];

      // A completed/failed/partially-completed task is a durable conversation
      // checkpoint. Promote its first follow-up immediately so the same task
      // id, artifacts, completed operations and context summary are reused.
      // Active tasks keep the queue and are promoted only after their current
      // run releases the slot.
      if (task.isTerminal) {
        await _promoteQueuedFollowUp(task, resetRunBudget: true);
        await _schedule();
        return;
      }
      await _save(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '已排队新的追问'));
    });
  }

  /// Persists a tool-approval checkpoint without requiring a chat page to
  /// retain the pending request in memory.
  Future<void> pauseForApproval(
    String taskId, {
    required String pendingToolRequestJson,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.isTerminal) {
        throw StateError('终态任务不能再等待工具审批。');
      }
      task
        ..status = AgentTaskStatus.waitingForApproval
        // Keep only a display-safe checkpoint in Hive. The full request is
        // retained by the in-process runner while the approval dialog is open.
        ..pendingToolRequestJson =
            safeToolRequestCheckpointJson(pendingToolRequestJson)
        ..updatedAt = _clock();
      await _save(task);
      await _markSnapshotStatus(task);
      unawaited(
        _record(task, WorkTaskEventKind.approvalRequired, '等待用户批准操作'),
      );
    });
  }

  /// Approves the pending tool request and queues the same durable task.
  ///
  /// The decision is stored in the task checkpoint so a runner can consume it
  /// after the current process has released its slot, without relying on a
  /// chat-page object or an in-memory dialog callback.
  Future<void> approve(String taskId) => _resolveApproval(
        taskId,
        WorkChangeApprovalDecision.approved.wireName,
      );

  /// Rejects the pending tool request and queues the same durable task. The
  /// runner receives a structured rejection and may continue with safe work.
  Future<void> reject(String taskId) => _resolveApproval(
        taskId,
        WorkChangeApprovalDecision.rejected.wireName,
      );

  /// Approves a mutation after the user has explicitly accepted that this
  /// operation cannot be undone. This decision is durable and is never
  /// inferred from the ordinary-write setting.
  Future<void> approveWithoutUndo(String taskId) => _resolveApproval(
        taskId,
        WorkChangeApprovalDecision.approvedWithoutUndo.wireName,
      );

  /// Explicitly named aliases for UI integrations that prefer task wording.
  Future<void> approveTask(String taskId) => approve(taskId);

  Future<void> rejectTask(String taskId) => reject(taskId);

  Future<void> approveTaskWithoutUndo(String taskId) =>
      approveWithoutUndo(taskId);

  /// Opens the app-level picker from the execution panel and requeues the
  /// waiting task when the selected directory covers its requested path.
  Future<void> requestFolderForTask(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final grantService = _folderGrantService;
      final picker = _folderPicker;
      if (grantService == null || picker == null) {
        throw StateError('当前没有可用的工作目录选择器。');
      }
      final task = _requireWorkTask(taskId);
      final result = await grantService.requestFolder(
        picker: picker,
        requestedPath: _requestedFolderPath(task),
        forcePicker: true,
        requireWritable: _requiresWritableFolder(task),
        consent: _folderGrantConsent,
      );
      if (!result.granted) throw StateError(result.reason);
      _conversationReservations.remove(task.groupId);
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..lastError = ''
        ..executionStateJson = _withoutFolderRequest(task.executionStateJson)
        ..updatedAt = _clock();
      await _save(task);
      _enqueueTask(task);
      await _schedule();
    });
  }

  Future<void> _resolveApproval(String taskId, String decision) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.waitingForApproval ||
          task.pendingToolRequestJson.trim().isEmpty) {
        throw StateError('当前任务没有待处理的工具审批。');
      }
      final parsedDecision = WorkChangeApprovalDecision.fromWire(decision);
      if (parsedDecision == null) {
        throw ArgumentError.value(decision, 'decision', '审批决定无效');
      }
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..executionStateJson = _withApprovalDecision(
          task.executionStateJson,
          decision,
        )
        ..updatedAt = _clock();
      _conversationReservations.remove(task.groupId);
      _folderWaiters.remove(task.id)?.cancel();
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(
        task,
        WorkTaskEventKind.queued,
        parsedDecision.permitsExecution
            ? parsedDecision.permitsWithoutUndo
                ? '用户已批准无撤销执行，继续执行'
                : '用户已批准，继续执行'
            : '用户已拒绝，尝试安全替代路径',
      ));
      await _schedule();
    });
  }

  /// Stops only the requested task. Other conversations keep their slots.
  Future<void> stop(String taskId, {String reason = '用户已停止任务。'}) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.isTerminal) {
        throw StateError('终态任务不能停止。');
      }
      _removeQueuedTask(task);
      // Cancel before mutating the shared Hive object so a late progress
      // callback observes the cancellation and cannot resurrect running state.
      _running[taskId]?.cancellation.cancel();
      _folderWaiters.remove(taskId)?.cancel();
      final waiting = _waitingForResources.remove(taskId);
      waiting?.cancellation.cancel();
      final waitingLease = waiting?.lease;
      if (waitingLease != null) unawaited(waitingLease.release());
      _conversationReservations.remove(task.groupId);
      _makeConversationReady(task.groupId);
      _taskLockPlans.remove(taskId);
      task
        ..status = AgentTaskStatus.cancelled
        ..resumeRequired = false
        ..pendingToolRequestJson = ''
        ..queuedUserRequests = <String>[]
        ..lastError = sanitizeWorkTaskError(reason)
        ..updatedAt = _clock();
      await _save(task);
      await _markSnapshotStatus(task);
      unawaited(
        _record(task, WorkTaskEventKind.failed, '任务已停止', detail: reason),
      );
      await _schedule();
    });
  }

  /// Queues an interrupted or paused task only after an explicit user action.
  Future<void> resumeByUser(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.interrupted &&
          task.status != AgentTaskStatus.paused) {
        throw StateError('当前任务不需要手动继续。');
      }
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..lastError = ''
        // A pending request payload is intentionally not persisted in full.
        // A manual restart must re-plan against the current filesystem and
        // grant state; never reuse a stale path scope.
        ..executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        )
        ..updatedAt = _clock();
      _conversationReservations.remove(task.groupId);
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '用户已继续任务'));
      await _schedule();
    });
  }

  /// Grants a fresh soft-limit budget only after the user chooses to continue.
  Future<void> continueAfterSoftLimit(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (_running.containsKey(taskId)) {
        throw StateError('任务正在收尾，请稍后再点继续。');
      }
      if (!task.softLimitReached ||
          (task.status != AgentTaskStatus.paused &&
              task.status != AgentTaskStatus.interrupted)) {
        throw StateError('当前任务不在等待超限继续的状态。');
      }
      task
        ..status = AgentTaskStatus.queued
        ..actionCount = 0
        ..startedAt = _clock()
        ..softLimitReached = false
        ..resumeRequired = false
        ..lastError = ''
        ..executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        )
        ..updatedAt = _clock();
      await _save(task);
      _enqueueTask(task);
      unawaited(
        _record(task, WorkTaskEventKind.queued, '用户已继续超限任务'),
      );
      await _schedule();
    });
  }

  /// Reloads durable task state without invoking any runner automatically.
  Future<void> restore() {
    return _serialize(() async {
      _ensureOpen();
      for (final task in _allWorkTasks()) {
        // A process restart invalidates every in-memory runner and lock. Only
        // an explicit user continuation may re-plan and reacquire resources.
        if (!_running.containsKey(task.id) &&
            !_waitingForResources.containsKey(task.id) &&
            !task.isTerminal &&
            task.status != AgentTaskStatus.paused &&
            task.status != AgentTaskStatus.interrupted) {
          task.markInterrupted(reason: '应用已关闭，请由用户手动继续任务。');
          await _save(task);
        }
        _publish(task);
      }
    });
  }

  Stream<AgentTask> watchTask(String taskId) async* {
    final initial = _taskBox.get(taskId);
    if (initial != null && initial.workModeTask) yield initial;
    yield* _taskUpdates.stream
        .where((task) => task.id == taskId)
        .map((task) => task);
  }

  Stream<List<AgentTask>> watchAllTasks() async* {
    yield _allWorkTasks();
    yield* _taskUpdates.stream.map((_) => _allWorkTasks());
  }

  /// The app scope can release listeners at shutdown; it deliberately does
  /// not stop active work merely because a chat room disappeared.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    for (final running in _running.values) {
      running.cancellation.cancel();
    }
    for (final waiting in _waitingForResources.values) {
      waiting.cancellation.cancel();
      final lease = waiting.lease;
      if (lease != null) unawaited(lease.release());
    }
    for (final cancellation in _folderWaiters.values) {
      cancellation.cancel();
    }
    _folderWaiters.clear();
    _waitingForResources.clear();
    _conversationReservations.clear();
    _taskLockPlans.clear();
    _notifySlotAvailable();
    _readyConversations.clear();
    _readyConversationIds.clear();
    _conversationQueues.clear();
    final drain = Future.wait<void>(_activeRuns.values, eagerError: false)
        .then<void>((_) async {
      if (!_taskUpdates.isClosed) await _taskUpdates.close();
    });
    _disposeFuture = drain;
    return drain;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final scheduled = _operations.then((_) => operation());
    _operations = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return scheduled;
  }

  Future<void> _schedule() async {
    if (_disposed) return;
    while (!_disposed &&
        _running.length + _startingTaskIds.length < maximumConcurrentTasks) {
      final task = _takeNextTask();
      if (task == null) return;
      // A native directory picker is user-driven and can remain open for an
      // arbitrary time. Do not hold the serialized submit operation while it
      // is open: another conversation must still be able to claim the second
      // global slot and start (or wait for its own grant) independently.
      if (_folderGrantService != null || _requireFolderGrant) {
        _launchStart(task);
      } else {
        await _start(task);
      }
    }
  }

  void _launchStart(AgentTask task) {
    _startingTaskIds.add(task.id);
    final start = _start(task);
    unawaited(
      start.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) async {
          await _handleStartFailure(task, error);
        },
      ).whenComplete(() {
        _startingTaskIds.remove(task.id);
        if (!_disposed) unawaited(_schedule());
      }),
    );
  }

  Future<void> _handleStartFailure(AgentTask task, Object error) async {
    if (_disposed) return;
    try {
      await _serialize(() async {
        _folderWaiters.remove(task.id)?.cancel();
        _conversationReservations.remove(task.groupId);
        final stored = _taskBox.get(task.id);
        if (stored != null && !stored.isTerminal) {
          stored
            ..status = AgentTaskStatus.failed
            ..lastError = sanitizeWorkTaskError(error)
            ..updatedAt = _clock();
          await _save(stored);
          unawaited(
            _record(
              stored,
              WorkTaskEventKind.failed,
              '任务启动失败',
              detail: stored.lastError,
            ),
          );
        }
        _makeConversationReady(task.groupId);
      });
    } on Object {
      // A startup persistence failure must not become an unhandled async
      // error. The durable task state remains authoritative when available.
    }
  }

  AgentTask? _takeNextTask() {
    while (_readyConversations.isNotEmpty) {
      final conversationId = _readyConversations.removeFirst();
      _readyConversationIds.remove(conversationId);
      if (_hasRunningConversation(conversationId)) continue;
      final queue = _conversationQueues[conversationId];
      if (queue == null) continue;
      while (queue.isNotEmpty) {
        final taskId = queue.removeFirst();
        final task = _taskBox.get(taskId);
        if (task == null ||
            !task.workModeTask ||
            task.status != AgentTaskStatus.queued) {
          continue;
        }
        if (queue.isEmpty) _conversationQueues.remove(conversationId);
        return task;
      }
      _conversationQueues.remove(conversationId);
    }
    return null;
  }

  Future<void> _start(AgentTask task) async {
    if (_disposed) return;
    final cancellation = WorkTaskCancellation();
    _conversationReservations.add(task.groupId);
    _folderWaiters[task.id] = cancellation;
    // The first task may be the one that opens the OS folder picker. Resolve
    // that grant before planning locks; otherwise the planner sees an empty
    // grant list, starts without a lease, and only obtains the directory after
    // the runner has already crossed the mutation boundary.
    if ((_folderGrantService != null || _requireFolderGrant) &&
        !await _ensureFolderGrant(task, cancellation)) {
      _folderWaiters.remove(task.id);
      // The picker was resolved before a runner/lease was started. A denied
      // or unavailable grant therefore has no waiter that should hold the
      // conversation reservation; release it so a later manual continuation
      // (or another queued task in the conversation) is not deadlocked.
      _conversationReservations.remove(task.groupId);
      cancellation.cancel();
      _makeConversationReady(task.groupId);
      return;
    }
    _folderWaiters.remove(task.id);
    late final List<WorkResourceLockRequest> locks;
    try {
      locks = _resourceLocksFor(task);
    } on Object catch (error) {
      await _failInvalidResourcePlan(task, error);
      return;
    }

    if (locks.isNotEmpty) {
      WorkResourceLockLease? lease;
      try {
        lease = _resourceLockManager.tryAcquire(task.id, locks);
      } on Object catch (error) {
        await _failInvalidResourcePlan(task, error);
        return;
      }
      if (lease == null) {
        await _waitForResource(task, cancellation, locks);
        return;
      }
      await _startRunning(task, cancellation, lease);
      return;
    }

    await _startRunning(task, cancellation, null);
  }

  Future<void> _failInvalidResourcePlan(AgentTask task, Object error) async {
    _conversationReservations.remove(task.groupId);
    task
      ..status = AgentTaskStatus.failed
      ..lastError = sanitizeWorkTaskError(error)
      ..updatedAt = _clock();
    await _save(task);
    unawaited(_record(task, WorkTaskEventKind.failed, '资源锁计划无效'));
    _makeConversationReady(task.groupId);
    await _schedule();
  }

  Future<void> _startRunning(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkResourceLockLease? lease,
  ) async {
    if (_disposed) {
      cancellation.cancel();
      _conversationReservations.remove(task.groupId);
      if (lease != null) await lease.release();
      return;
    }
    _running[task.id] = _RunningTask(task: task, cancellation: cancellation);
    var runStarted = false;
    try {
      task
        ..status = AgentTaskStatus.planning
        ..startedAt ??= _clock()
        ..updatedAt = _clock();
      await _save(task);
      await _markSnapshotStatus(task);
      if (_disposed) {
        cancellation.cancel();
        return;
      }
      unawaited(_record(task, WorkTaskEventKind.planning, '任务开始执行'));
      final run = _runWithLease(task, cancellation, lease);
      _activeRuns[task.id] = run;
      runStarted = true;
      unawaited(
        run.then<void>(
          (_) => _removeActiveRun(task.id, run),
          onError: (Object _, StackTrace __) => _removeActiveRun(task.id, run),
        ),
      );
    } finally {
      if (!runStarted) {
        _running.remove(task.id);
        _conversationReservations.remove(task.groupId);
        cancellation.cancel();
        if (lease != null) await lease.release();
        _notifySlotAvailable();
      }
    }
  }

  List<WorkResourceLockRequest> _resourceLocksFor(AgentTask task) {
    final explicit = _taskLockPlans[task.id];
    if (explicit != null) return List<WorkResourceLockRequest>.from(explicit);
    final persisted = _persistedResourceLocks(task.executionStateJson);
    if (persisted != null) {
      _taskLockPlans[task.id] = persisted;
      return List<WorkResourceLockRequest>.from(persisted);
    }
    final callback = _resourceLockPlan;
    if (callback != null) {
      return _normalizeAndPersistResourceLocks(task, callback(task));
    }
    if (_runner case final WorkTaskResourceLockPlanner planner) {
      return _normalizeAndPersistResourceLocks(
        task,
        planner.planResourceLocks(task),
      );
    }
    return const <WorkResourceLockRequest>[];
  }

  List<WorkResourceLockRequest> _normalizeAndPersistResourceLocks(
    AgentTask task,
    Iterable<WorkResourceLockRequest> planned,
  ) {
    final normalized = _resourceLockManager.normalizeLockSet(planned);
    if (normalized.isEmpty) return const <WorkResourceLockRequest>[];
    _taskLockPlans[task.id] = normalized;
    // The runner may be created after a process restart, so the first plan
    // computed from the current grant must be persisted before execution can
    // cross the file boundary. _startRunning saves this same task object.
    task.executionStateJson = _withResourceLockPlan(
      task.executionStateJson,
      normalized,
    );
    return List<WorkResourceLockRequest>.from(normalized);
  }

  Future<void> _waitForResource(
    AgentTask task,
    WorkTaskCancellation cancellation,
    List<WorkResourceLockRequest> locks,
  ) async {
    final waiting = _WaitingResourceTask(
      task: task,
      cancellation: cancellation,
    );
    _waitingForResources[task.id] = waiting;
    task
      ..status = AgentTaskStatus.queued
      ..updatedAt = _clock();
    await _save(task);
    final conflict =
        _resourceLockManager.conflictPath(locks) ?? locks.first.path;
    final safePath = _safeLockPath(conflict);
    await _record(
      task,
      WorkTaskEventKind.queued,
      '等待另一个任务释放 $safePath',
      detail: '资源锁等待不会增加 Agent 动作数。',
    );
    unawaited(_awaitResourceLease(waiting, locks));
  }

  Future<void> _awaitResourceLease(
    _WaitingResourceTask waiting,
    List<WorkResourceLockRequest> locks,
  ) async {
    final task = waiting.task;
    try {
      final lease = await _resourceLockManager.acquire(
        task.id,
        locks,
        cancellation: waiting.cancellation.whenCancelled,
        isCancelled: () => waiting.cancellation.isCancelled,
      );
      if (!_isWaiting(waiting) ||
          _disposed ||
          waiting.cancellation.isCancelled ||
          _taskBox.get(task.id)?.status != AgentTaskStatus.queued) {
        await lease.release();
        return;
      }
      waiting.lease = lease;
      while (!_disposed &&
          _running.length >= maximumConcurrentTasks &&
          !waiting.cancellation.isCancelled) {
        await Future.any<void>([
          _waitForSlot(),
          waiting.cancellation.whenCancelled,
        ]);
      }
      if (!_isWaiting(waiting) ||
          _disposed ||
          waiting.cancellation.isCancelled ||
          _taskBox.get(task.id)?.status != AgentTaskStatus.queued) {
        await lease.release();
        return;
      }
      _waitingForResources.remove(task.id);
      _startingTaskIds.add(task.id);
      try {
        await _startRunning(task, waiting.cancellation, lease);
      } finally {
        _startingTaskIds.remove(task.id);
      }
    } on WorkResourceLockCancelled {
      _dropWaiting(waiting);
    } on Object catch (error) {
      await _failResourceWait(waiting, error);
    }
  }

  Future<void> _failResourceWait(
    _WaitingResourceTask waiting,
    Object error,
  ) async {
    await _serialize(() async {
      if (!_isWaiting(waiting) || _disposed) return;
      _dropWaiting(waiting);
      final stored = _taskBox.get(waiting.task.id);
      if (stored == null || stored.isTerminal) return;
      stored
        ..status = AgentTaskStatus.failed
        ..lastError = sanitizeWorkTaskError(error)
        ..updatedAt = _clock();
      await _save(stored);
      unawaited(
        _record(stored, WorkTaskEventKind.failed, '资源锁等待失败'),
      );
      _makeConversationReady(stored.groupId);
      await _schedule();
    });
  }

  bool _isWaiting(_WaitingResourceTask waiting) =>
      identical(_waitingForResources[waiting.task.id], waiting);

  void _dropWaiting(_WaitingResourceTask waiting) {
    if (!_isWaiting(waiting)) return;
    _waitingForResources.remove(waiting.task.id);
    _conversationReservations.remove(waiting.task.groupId);
    _makeConversationReady(waiting.task.groupId);
  }

  Future<void> _runWithLease(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkResourceLockLease? lease,
  ) async {
    try {
      await _run(task, cancellation);
    } finally {
      if (lease != null) await lease.release();
    }
  }

  Future<void> _run(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    Object? error;
    StackTrace? stackTrace;
    try {
      if ((_folderGrantService != null || _requireFolderGrant) &&
          !await _ensureFolderGrant(task, cancellation)) {
        await _serialize(() async {
          _running.remove(task.id);
          final stored = _taskBox.get(task.id);
          if (!_disposed &&
              !cancellation.isCancelled &&
              stored != null &&
              !stored.isTerminal) {
            _folderWaiters[task.id] = cancellation;
          } else {
            _folderWaiters.remove(task.id);
          }
          // A failed revalidation is a paused boundary, not an active run.
          // Release the conversation reservation so a later manual resume or
          // another queued task cannot be permanently starved by a stale
          // folder picker/authorization state.
          _conversationReservations.remove(task.groupId);
          _makeConversationReady(task.groupId);
          _notifySlotAvailable();
        });
        return;
      }
      await _runner.run(task, cancellation);
    } on Object catch (caught, trace) {
      error = caught;
      stackTrace = trace;
    }
    // Disposal is cooperative, but the runner may finish one microtask after
    // cancellation. Never touch Hive or the event store after shutdown starts.
    if (_disposed) return;
    await _serialize(() async {
      if (_disposed) return;
      final running = _running[task.id];
      if (running == null || !identical(running.cancellation, cancellation)) {
        return;
      }
      _running.remove(task.id);
      _notifySlotAvailable();
      final stored = _taskBox.get(task.id);
      if (stored == null) {
        _conversationReservations.remove(task.groupId);
        await _schedule();
        return;
      }

      if (error != null &&
          !stored.isTerminal &&
          stored.status != AgentTaskStatus.queued) {
        stored
          ..status = AgentTaskStatus.failed
          ..lastError = sanitizeWorkTaskError(error)
          ..updatedAt = _clock();
        await _save(stored);
        unawaited(_record(
          stored,
          WorkTaskEventKind.failed,
          '任务执行失败',
          detail: sanitizeWorkTaskError(error),
        ));
      } else if (!stored.isTerminal &&
          stored.status != AgentTaskStatus.queued &&
          stored.status != AgentTaskStatus.paused &&
          stored.status != AgentTaskStatus.interrupted &&
          stored.status != AgentTaskStatus.waitingForApproval) {
        stored
          ..status = AgentTaskStatus.completed
          ..updatedAt = _clock();
        await _save(stored);
        unawaited(
          _record(stored, WorkTaskEventKind.completed, '任务已完成'),
        );
      }

      await _promoteQueuedFollowUp(stored);
      await _markSnapshotStatus(stored);

      final holdConversation = !stored.isTerminal &&
          (stored.status == AgentTaskStatus.waitingForApproval ||
              stored.status == AgentTaskStatus.paused ||
              stored.status == AgentTaskStatus.interrupted);
      if (!holdConversation) {
        _conversationReservations.remove(task.groupId);
      }
      _folderWaiters.remove(task.id);

      if (stackTrace != null) {
        // The public event only contains the error message; stack traces stay
        // out of persisted task output and can be surfaced by a future logger.
      }
      _makeConversationReady(task.groupId);
      await _schedule();
    });
  }

  Future<bool> _ensureFolderGrant(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    final grantService = _folderGrantService;
    if (grantService == null) {
      if (!_requireFolderGrant) return true;
      task
        ..status = AgentTaskStatus.paused
        ..resumeRequired = true
        ..lastError = '工作目录授权服务不可用，请检查应用设置后重试。'
        ..updatedAt = _clock();
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.paused,
        '工作目录授权不可用',
        detail: task.lastError,
      );
      return false;
    }
    try {
      await grantService.load();
    } on Object catch (error) {
      task
        ..status = AgentTaskStatus.paused
        ..resumeRequired = true
        ..lastError = '工作目录授权校验失败，请重试。'
        ..updatedAt = _clock();
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.paused,
        '工作目录授权校验失败',
        detail: sanitizeWorkTaskError(error),
      );
      return false;
    }
    if (_disposed || cancellation.isCancelled) return false;
    final requestedPath = _requestedFolderPath(task);
    final requiresWritable = _requiresWritableFolder(task);
    if (requestedPath == null &&
        (requiresWritable
            ? grantService.hasConfirmedWritableGrant()
            : grantService.hasConfirmedAvailableGrant())) {
      return true;
    }
    if (requestedPath != null &&
        (requiresWritable
            ? await grantService.isPathWritableResolved(requestedPath)
            : await grantService.isPathAuthorizedResolved(requestedPath))) {
      task.executionStateJson = _withoutFolderRequest(task.executionStateJson);
      await _save(task);
      return true;
    }

    task
      ..status = AgentTaskStatus.waitingForApproval
      ..resumeRequired = false
      ..updatedAt = _clock();
    await _save(task);
    await _record(
      task,
      WorkTaskEventKind.approvalRequired,
      '需要授权工作目录',
      detail: requestedPath == null
          ? '首次执行工作模式前，需要选择一个 App 级工作目录。'
          : '请求路径未被现有授权覆盖，需要选择其所在目录。',
    );
    if (_disposed || cancellation.isCancelled) return false;

    final requestResult = await _requestFolder(
      grantService,
      task: task,
      requestedPath: requestedPath,
    );
    if (_disposed || cancellation.isCancelled) return false;
    if (requestResult.granted) {
      task
        ..status = AgentTaskStatus.planning
        ..resumeRequired = false
        ..lastError = ''
        ..executionStateJson = _withoutFolderRequest(task.executionStateJson)
        ..updatedAt = _clock();
      await _save(task);
      return true;
    }

    final reason =
        requestResult.reason.isEmpty ? '未完成工作目录授权。' : requestResult.reason;
    task
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..lastError = reason
      ..updatedAt = _clock();
    await _save(task);
    await _record(task, WorkTaskEventKind.paused, '等待工作目录授权', detail: reason);
    return false;
  }

  Future<WorkFolderRequestResult> _requestFolder(
    WorkFolderGrantService grantService, {
    required AgentTask task,
    String? requestedPath,
  }) async {
    final existing = _folderRequest;
    if (existing != null) return existing;
    final request = _folderPicker == null
        ? Future<WorkFolderRequestResult>.value(
            const WorkFolderRequestResult(
              status: WorkFolderRequestStatus.unavailable,
              reason: '当前没有可用的目录选择器。',
            ),
          )
        : grantService.requestFolder(
            picker: _folderPicker,
            requestedPath: requestedPath,
            forcePicker: requestedPath != null,
            requireWritable: _requiresWritableFolder(task),
            consent: _folderGrantConsent,
          );
    _folderRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_folderRequest, request)) _folderRequest = null;
    }
  }

  void _enqueueTask(AgentTask task) {
    final queue = _conversationQueues.putIfAbsent(task.groupId, Queue.new);
    if (!queue.contains(task.id)) queue.addLast(task.id);
    if (!_hasRunningConversation(task.groupId)) {
      _makeConversationReady(task.groupId);
    }
  }

  void _removeQueuedTask(AgentTask task) {
    final queue = _conversationQueues[task.groupId];
    if (queue == null) return;
    queue.remove(task.id);
    if (queue.isEmpty) _conversationQueues.remove(task.groupId);
  }

  void _makeConversationReady(String conversationId) {
    final queue = _conversationQueues[conversationId];
    if (queue == null ||
        queue.isEmpty ||
        _hasRunningConversation(conversationId)) {
      return;
    }
    if (_readyConversationIds.add(conversationId)) {
      _readyConversations.addLast(conversationId);
    }
  }

  bool _hasRunningConversation(String conversationId) =>
      _conversationReservations.contains(conversationId) ||
      _running.values.any((running) => running.task.groupId == conversationId);

  Future<void> _waitForSlot() {
    if (_disposed || _running.length < maximumConcurrentTasks) {
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _slotWaiters.addLast(waiter);
    return waiter.future;
  }

  void _notifySlotAvailable() {
    if (!_disposed && _running.length >= maximumConcurrentTasks) return;
    while (_slotWaiters.isNotEmpty) {
      final waiter = _slotWaiters.removeFirst();
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  String _safeLockPath(String path) => WorkFolderGrantService.displayNameFor(
        path,
        isWindows: _resourceLockManager.isWindows,
      );

  AgentTask _requireWorkTask(String taskId) {
    final task = _taskBox.get(taskId);
    if (task == null || !task.workModeTask) {
      throw StateError('未找到工作模式任务：$taskId');
    }
    return task;
  }

  Future<void> _save(AgentTask task) async {
    await _taskBox.put(task.id, task);
    _publish(task);
  }

  void _publish(AgentTask task) {
    if (!_disposed) _taskUpdates.add(task);
  }

  List<AgentTask> _allWorkTasks() {
    final tasks = _taskBox.values.where((task) => task.workModeTask).toList();
    tasks.sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return List<AgentTask>.unmodifiable(tasks);
  }

  Future<void> _record(
    AgentTask task,
    WorkTaskEventKind kind,
    String title, {
    String detail = '',
  }) async {
    if (_disposed) return;
    try {
      await _eventStore.append(
        taskId: task.id,
        kind: kind,
        title: title,
        detail: detail,
      );
    } on Object catch (error) {
      // Event persistence is diagnostic only; never replace a valid task
      // outcome with a logging exception. The durable flag tells the panel
      // that the timeline may have gaps.
      if (_disposed || task.eventLogIncomplete) return;
      task.eventLogIncomplete = true;
      if (task.lastError.isEmpty) {
        task.lastError = '任务日志保存不完整：${sanitizeWorkTaskError(error)}';
      }
      try {
        await _taskBox.put(task.id, task);
        _publish(task);
      } on Object {
        // The database may already be closing. The task outcome must remain
        // authoritative even when there is no storage left for this flag.
      }
    }
  }

  Future<void> _markSnapshotStatus(AgentTask task) async {
    final updater = _snapshotStatusUpdater;
    if (updater == null) return;
    final status = switch (task.status) {
      AgentTaskStatus.completed => WorkSnapshotTaskStatus.completed,
      AgentTaskStatus.failed => WorkSnapshotTaskStatus.failed,
      AgentTaskStatus.cancelled => WorkSnapshotTaskStatus.cancelled,
      AgentTaskStatus.partiallyCompleted =>
        WorkSnapshotTaskStatus.partiallyCompleted,
      _ => WorkSnapshotTaskStatus.active,
    };
    try {
      await updater(task.id, status);
    } on Object {
      // Snapshot bookkeeping must not turn a valid task checkpoint into a
      // failed run. The next cleanup pass can retry this metadata update.
    }
  }

  Future<void> _promoteQueuedFollowUp(
    AgentTask task, {
    bool resetRunBudget = false,
  }) async {
    if (!task.isTerminal ||
        task.status == AgentTaskStatus.cancelled ||
        task.queuedUserRequests.isEmpty ||
        _disposed) {
      return;
    }
    final nextRequest = task.queuedUserRequests.first.trim();
    task.queuedUserRequests = task.queuedUserRequests.skip(1).toList();
    if (nextRequest.isEmpty) {
      await _promoteQueuedFollowUp(task);
      return;
    }
    // A follow-up is a new execution run under the same conversation/task
    // identity.  Do not reuse the previous run's in-memory lock plan: the
    // new request may target a different file, and a stale plan could either
    // block unrelated work or fail to serialize the new target.
    _taskLockPlans.remove(task.id);
    task
      ..userRequest = nextRequest
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false
      ..softLimitReached = false
      ..pendingToolRequestJson = ''
      ..executionStateJson = ''
      ..lastError = ''
      ..resultSummary = ''
      ..actionCount = resetRunBudget ? 0 : task.actionCount
      ..startedAt = resetRunBudget ? _clock() : task.startedAt
      ..updatedAt = _clock();
    await _save(task);
    _enqueueTask(task);
    unawaited(
      _record(task, WorkTaskEventKind.queued, '开始处理已排队的追问'),
    );
  }

  void _removeActiveRun(String taskId, Future<void> run) {
    if (identical(_activeRuns[taskId], run)) _activeRuns.remove(taskId);
  }

  String _withApprovalDecision(String raw, String decision) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..['approvalDecision'] = decision;
        final parsedDecision = WorkChangeApprovalDecision.fromWire(decision);
        final rawPlan = copy['approvalPlan'];
        if (parsedDecision?.permitsExecution == true && rawPlan is Map) {
          try {
            final plan = WorkChangePlan.fromJson(
              Map<String, dynamic>.from(rawPlan),
            );
            copy['approvalScope'] = WorkApprovalScope.fromPlan(plan).toJson();
          } on Object {
            // The runner will fail closed when a tampered plan cannot produce
            // an exact scope; never synthesize a wildcard approval.
            copy.remove('approvalScope');
          }
        } else {
          // A rejection is not a capability grant. Remove the descriptive
          // scope before the runner continues with the safe skip path, so a
          // later tool cannot inherit the declined mutation's paths.
          copy.remove('approvalScope');
        }
        return jsonEncode(copy);
      }
    } on Object {
      // Replace malformed/non-object execution metadata with a minimal safe
      // checkpoint rather than persisting arbitrary model text.
    }
    return jsonEncode(<String, String>{'approvalDecision': decision});
  }

  String _withoutApprovalCheckpoint(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..remove('approvalDecision')
          ..remove('approvalScope')
          ..remove('approvalPlan');
        return copy.isEmpty ? '' : jsonEncode(copy);
      }
    } on Object {
      // A malformed checkpoint is not safe to reuse after a restart.
    }
    return '';
  }

  String? _requestedFolderPath(AgentTask task) {
    try {
      final decoded = jsonDecode(task.executionStateJson);
      if (decoded is! Map) return null;
      final direct = decoded['folderRequestPath'];
      if (direct is String && direct.trim().isNotEmpty) return direct.trim();
      final plan = decoded['approvalPlan'];
      if (plan is Map) {
        final paths = plan['exactPaths'];
        if (paths is List) {
          for (final path in paths) {
            if (path is String && path.trim().isNotEmpty) return path.trim();
          }
        }
      }
    } on Object {
      // Malformed execution metadata cannot safely identify a requested path.
    }
    return null;
  }

  bool _requiresWritableFolder(AgentTask task) {
    final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
    if (pending == null) {
      // The runner creates a conversation workspace before the first model
      // read, so an initial grant must be able to create that directory.
      return true;
    }
    return pending.tool == AgentToolName.workspacePatch ||
        pending.tool == AgentToolName.workspaceRename ||
        pending.tool == AgentToolName.workspaceDelete;
  }

  String _withoutFolderRequest(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..remove('folderRequestPath');
        return copy.isEmpty ? '' : jsonEncode(copy);
      }
    } on Object {
      return '';
    }
    return raw;
  }

  String _withResourceLockPlan(
    String raw,
    List<WorkResourceLockRequest> locks,
  ) {
    final resourceLocks = locks
        .map((lock) => <String, String>{
              'path': lock.path,
              'mode': lock.mode.name,
            })
        .toList(growable: false);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return jsonEncode({...decoded, 'resourceLocks': resourceLocks});
      }
    } on Object {
      // Replace malformed/non-object metadata with the durable lock plan.
    }
    return jsonEncode(<String, dynamic>{'resourceLocks': resourceLocks});
  }

  List<WorkResourceLockRequest>? _persistedResourceLocks(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final rawLocks = decoded['resourceLocks'];
      if (rawLocks is List) {
        final parsed = <WorkResourceLockRequest>[];
        for (final item in rawLocks) {
          if (item is! Map || item['path'] is! String) {
            throw const FormatException('资源锁计划格式无效');
          }
          final mode = switch (item['mode']) {
            'read' => WorkResourceLockMode.read,
            'write' => WorkResourceLockMode.write,
            'treeWrite' => WorkResourceLockMode.treeWrite,
            _ => throw const FormatException('资源锁模式无效'),
          };
          parsed.add(
            WorkResourceLockRequest(path: item['path'] as String, mode: mode),
          );
        }
        return _resourceLockManager.normalizeLockSet(parsed);
      }
      final legacyPaths = decoded['resourceLockPaths'];
      if (legacyPaths is List) {
        return _resourceLockManager.normalizeLockSet(
          legacyPaths.whereType<String>().map(WorkResourceLockRequest.write),
        );
      }
    } on Object {
      rethrow;
    }
    return null;
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('工作任务调度器已关闭。');
  }
}
