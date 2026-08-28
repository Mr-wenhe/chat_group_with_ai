import 'dart:async';
import 'dart:collection';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:hive/hive.dart';

import 'work_task_event.dart';
import 'work_task_event_store.dart';

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

  Future<void> _operations = Future<void>.value();
  bool _disposed = false;

  WorkTaskCoordinator({
    required Box<AgentTask> taskBox,
    required WorkTaskEventStore eventStore,
    required WorkTaskRunner runner,
    DateTime Function()? clock,
  })  : _taskBox = taskBox,
        _eventStore = eventStore,
        _runner = runner,
        _clock = clock ?? DateTime.now;

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
      _record(task, WorkTaskEventKind.queued, '任务已排队');
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
      task.queuedUserRequests = <String>[
        ...task.queuedUserRequests,
        normalized,
      ];
      await _save(task);
      _record(task, WorkTaskEventKind.queued, '已排队新的追问');

      if (task.isTerminal) {
        task
          ..status = AgentTaskStatus.queued
          ..resumeRequired = false
          ..updatedAt = _clock();
        await _save(task);
        _enqueueTask(task);
        await _schedule();
      }
    });
  }

  /// Stops only the requested task. Other conversations keep their slots.
  Future<void> stop(String taskId, {String reason = '用户已停止任务。'}) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      _removeQueuedTask(task);
      task
        ..status = AgentTaskStatus.cancelled
        ..resumeRequired = false
        ..lastError = reason
        ..updatedAt = _clock();
      await _save(task);
      _running[taskId]?.cancellation.cancel();
      _record(task, WorkTaskEventKind.failed, '任务已停止', detail: reason);
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
      _record(task, WorkTaskEventKind.queued, '用户已继续任务');
      await _schedule();
    });
  }

  /// Grants a fresh soft-limit budget only after the user chooses to continue.
  Future<void> continueAfterSoftLimit(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (!task.softLimitReached) {
        throw StateError('当前任务尚未达到执行上限。');
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
      _record(task, WorkTaskEventKind.queued, '用户已继续超限任务');
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
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_taskUpdates.close());
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
    while (_running.length < maximumConcurrentTasks) {
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
    final cancellation = WorkTaskCancellation();
    _running[task.id] = _RunningTask(task: task, cancellation: cancellation);
    task
      ..status = AgentTaskStatus.planning
      ..startedAt ??= _clock()
      ..updatedAt = _clock();
    await _save(task);
    _record(task, WorkTaskEventKind.planning, '任务开始执行');
    unawaited(_run(task, cancellation));
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
    await _serialize(() async {
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

      if (error != null && !stored.isTerminal) {
        stored
          ..status = AgentTaskStatus.failed
          ..lastError = '$error'
          ..updatedAt = _clock();
        await _save(stored);
        _record(stored, WorkTaskEventKind.failed, '任务执行失败', detail: '$error');
      } else if (!stored.isTerminal &&
          stored.status != AgentTaskStatus.paused &&
          stored.status != AgentTaskStatus.interrupted) {
        stored
          ..status = AgentTaskStatus.completed
          ..updatedAt = _clock();
        await _save(stored);
        _record(stored, WorkTaskEventKind.completed, '任务已完成');
      }

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

  void _record(
    AgentTask task,
    WorkTaskEventKind kind,
    String title, {
    String detail = '',
  }) {
    unawaited(
      _eventStore
          .append(
            taskId: task.id,
            kind: kind,
            title: title,
            detail: detail,
          )
          .then<void>(
            (_) {},
            onError: (Object _, StackTrace __) {},
          ),
    );
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('工作任务调度器已关闭。');
  }
}
