import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:hive/hive.dart';

import 'work_task_event.dart';
import 'work_task_event_store.dart';
import 'work_task_error_sanitizer.dart';

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

class _RunningTask {
  final AgentTask task;
  final WorkTaskCancellation cancellation;

  const _RunningTask({required this.task, required this.cancellation});
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
  final DateTime Function() _clock;
  final StreamController<AgentTask> _taskUpdates =
      StreamController<AgentTask>.broadcast(sync: true);
  final Map<String, _RunningTask> _running = <String, _RunningTask>{};
  final Map<String, Queue<String>> _conversationQueues =
      <String, Queue<String>>{};
  final Queue<String> _readyConversations = Queue<String>();
  final Set<String> _readyConversationIds = <String>{};
  final Map<String, Future<void>> _activeRuns = <String, Future<void>>{};

  Future<void> _operations = Future<void>.value();
  Future<void>? _disposeFuture;
  bool _disposed = false;

  WorkTaskCoordinator({
    required Box<AgentTask> taskBox,
    required WorkTaskEventStore eventStore,
    required WorkTaskRunner runner,
    DateTime Function()? clock,
  })  : _taskBox = taskBox,
        _eventStore = eventStore,
        _runner = runner,
        _clock = clock ?? DateTime.now {
    if (runner case final WorkTaskProgressReporter reporter) {
      reporter.setTaskUpdateSink(_publish);
    }
  }

  int get runningTaskCount => _running.length;

  /// Persists and schedules a new V1 work task. The task is queued before a
  /// runner can observe it, which makes state recoverable at every boundary.
  Future<AgentTask> submit(AgentTask task) {
    return _serialize(() async {
      _ensureOpen();
      if (!task.workModeTask) {
        throw ArgumentError.value(task, 'task', '协调器只接受工作模式任务');
      }
      if (_taskBox.containsKey(task.id)) {
        throw StateError('工作任务已存在：${task.id}');
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
  Future<void> approve(String taskId) => _resolveApproval(taskId, 'approved');

  /// Rejects the pending tool request and queues the same durable task. The
  /// runner receives a structured rejection and may continue with safe work.
  Future<void> reject(String taskId) => _resolveApproval(taskId, 'rejected');

  /// Explicitly named aliases for UI integrations that prefer task wording.
  Future<void> approveTask(String taskId) => approve(taskId);

  Future<void> rejectTask(String taskId) => reject(taskId);

  Future<void> _resolveApproval(String taskId, String decision) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.waitingForApproval ||
          task.pendingToolRequestJson.trim().isEmpty) {
        throw StateError('当前任务没有待处理的工具审批。');
      }
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..executionStateJson = _withApprovalDecision(
          task.executionStateJson,
          decision,
        )
        ..updatedAt = _clock();
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(
        task,
        WorkTaskEventKind.queued,
        decision == 'approved' ? '用户已批准，继续执行' : '用户已拒绝，尝试安全替代路径',
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
      task
        ..status = AgentTaskStatus.cancelled
        ..resumeRequired = false
        ..pendingToolRequestJson = ''
        ..queuedUserRequests = <String>[]
        ..lastError = sanitizeWorkTaskError(reason)
        ..updatedAt = _clock();
      await _save(task);
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
        ..updatedAt = _clock();
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
    while (!_disposed && _running.length < maximumConcurrentTasks) {
      final task = _takeNextTask();
      if (task == null) return;
      await _start(task);
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
    _running[task.id] = _RunningTask(task: task, cancellation: cancellation);
    task
      ..status = AgentTaskStatus.planning
      ..startedAt ??= _clock()
      ..updatedAt = _clock();
    await _save(task);
    if (_disposed) {
      _running.remove(task.id);
      cancellation.cancel();
      return;
    }
    unawaited(_record(task, WorkTaskEventKind.planning, '任务开始执行'));
    final run = _run(task, cancellation);
    _activeRuns[task.id] = run;
    unawaited(
      run.then<void>(
        (_) => _removeActiveRun(task.id, run),
        onError: (Object _, StackTrace __) => _removeActiveRun(task.id, run),
      ),
    );
  }

  Future<void> _run(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    Object? error;
    StackTrace? stackTrace;
    try {
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
      final stored = _taskBox.get(task.id);
      if (stored == null) {
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

      if (stackTrace != null) {
        // The public event only contains the error message; stack traces stay
        // out of persisted task output and can be surfaced by a future logger.
      }
      _makeConversationReady(task.groupId);
      await _schedule();
    });
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
      _running.values.any((running) => running.task.groupId == conversationId);

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
        return jsonEncode({...decoded, 'approvalDecision': decision});
      }
    } on Object {
      // Replace malformed/non-object execution metadata with a minimal safe
      // checkpoint rather than persisting arbitrary model text.
    }
    return jsonEncode(<String, String>{'approvalDecision': decision});
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('工作任务调度器已关闭。');
  }
}
