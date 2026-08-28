import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

class _FakeWorkTaskRunner implements WorkTaskRunner {
  final List<String> startedTaskIds = <String>[];
  final List<String> cancelledTaskIds = <String>[];
  final Map<String, Completer<void>> _completions = <String, Completer<void>>{};
  final Map<String, int> _activeByConversation = <String, int>{};

  int activeCount = 0;
  int maximumActiveCount = 0;
  int maximumActiveForOneConversation = 0;

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    final completion = Completer<void>();
    _completions[task.id] = completion;
    startedTaskIds.add(task.id);
    activeCount += 1;
    maximumActiveCount =
        maximumActiveCount < activeCount ? activeCount : maximumActiveCount;
    final conversationActive = (_activeByConversation[task.groupId] ?? 0) + 1;
    _activeByConversation[task.groupId] = conversationActive;
    maximumActiveForOneConversation =
        maximumActiveForOneConversation < conversationActive
            ? conversationActive
            : maximumActiveForOneConversation;

    await Future.any<void>(<Future<void>>[
      completion.future,
      cancellation.whenCancelled.then((_) {
        cancelledTaskIds.add(task.id);
      }),
    ]);

    activeCount -= 1;
    final remaining = _activeByConversation[task.groupId]! - 1;
    if (remaining == 0) {
      _activeByConversation.remove(task.groupId);
    } else {
      _activeByConversation[task.groupId] = remaining;
    }
  }

  void complete(String taskId) {
    final completion = _completions[taskId];
    if (completion == null || completion.isCompleted) {
      throw StateError('任务尚未开始：$taskId');
    }
    completion.complete();
  }

  Future<void> finishAll() async {
    for (final completion in _completions.values) {
      if (!completion.isCompleted) completion.complete();
    }
    await _settle();
  }
}

class _FakeProgressReporter
    implements WorkTaskRunner, WorkTaskProgressReporter {
  void Function(AgentTask task)? sink;
  AgentTask? published;

  @override
  void setTaskUpdateSink(void Function(AgentTask task) value) {
    sink = (task) {
      published = task;
      value(task);
    };
  }

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {}
}

class _GateWorkTaskRunner implements WorkTaskRunner {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int runCount = 0;

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    runCount += 1;
    if (!started.isCompleted) started.complete();
    await Future.any<void>(<Future<void>>[
      release.future,
      cancellation.whenCancelled,
    ]);
  }
}

AgentTask _task({required String id, required String conversationId}) {
  return AgentTask(
    id: id,
    groupId: conversationId,
    characterId: 'worker',
    userRequest: '执行 $id',
    workModeTask: true,
  );
}

Future<void> _settle() async {
  // Hive writes are asynchronous file operations. A fixed wall-clock fence
  // makes this behavioral test observe the same completion that production
  // listeners receive instead of relying on a scheduler-specific microtask
  // count (which flakes when the full suite is under load).
  for (var index = 0; index < 10; index++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory directory;
  late Box<AgentTask> taskBox;
  late WorkTaskEventStore eventStore;
  late _FakeWorkTaskRunner runner;
  late WorkTaskCoordinator coordinator;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('work-task-coordinator-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(12)) {
      Hive.registerAdapter(AgentTaskStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(13)) {
      Hive.registerAdapter(AgentTaskAdapter());
    }
    taskBox = await Hive.openBox<AgentTask>(DatabaseService.agentTaskBoxName);
    eventStore = WorkTaskEventStore(
      appSupportDirectory: Directory('${directory.path}/app-support'),
    );
    runner = _FakeWorkTaskRunner();
    coordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
    );
  });

  tearDown(() async {
    await runner.finishAll();
    await coordinator.dispose();
    await eventStore.close();
    await Hive.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('runs at most two tasks globally and starts the next queued task',
      () async {
    await coordinator.submit(_task(id: 'task-a', conversationId: 'group-a'));
    await coordinator.submit(_task(id: 'task-b', conversationId: 'group-b'));
    await coordinator.submit(_task(id: 'task-c', conversationId: 'group-c'));

    expect(runner.startedTaskIds, <String>['task-a', 'task-b']);
    expect(taskBox.get('task-c')?.status, AgentTaskStatus.queued);
    expect(runner.maximumActiveCount, 2);

    runner.complete('task-a');
    await _settle();

    expect(runner.startedTaskIds, <String>['task-a', 'task-b', 'task-c']);
    expect(runner.maximumActiveCount, 2);
  });

  test('serializes tasks from the same conversation in FIFO order', () async {
    await coordinator.submit(_task(id: 'first', conversationId: 'group-a'));
    await coordinator.submit(_task(id: 'second', conversationId: 'group-a'));
    await coordinator.submit(_task(id: 'other', conversationId: 'group-b'));

    expect(runner.startedTaskIds, <String>['first', 'other']);
    expect(taskBox.get('second')?.status, AgentTaskStatus.queued);

    runner.complete('first');
    await _settle();

    expect(runner.startedTaskIds, <String>['first', 'other', 'second']);
    expect(runner.maximumActiveForOneConversation, 1);
  });

  test('queues follow-up text on its task without cancelling the run',
      () async {
    await coordinator.submit(_task(id: 'active', conversationId: 'group-a'));

    await coordinator.enqueueFollowUp('active', '请把结论改成表格');
    await coordinator.enqueueFollowUp('active', '再检查一次错误');

    final stored = taskBox.get('active')!;
    expect(stored.queuedUserRequests, <String>['请把结论改成表格', '再检查一次错误']);
    expect(runner.cancelledTaskIds, isEmpty);
    expect(runner.startedTaskIds, <String>['active']);
  });

  test('keeps an approval checkpoint after its runner releases the slot',
      () async {
    await coordinator.submit(_task(id: 'approval', conversationId: 'group-a'));

    await coordinator.pauseForApproval(
      'approval',
      pendingToolRequestJson: '{"tool":"workspace.patch"}',
    );
    runner.complete('approval');
    await _settle();

    final task = taskBox.get('approval');
    expect(task?.status, AgentTaskStatus.waitingForApproval);
    expect(
      task?.pendingToolRequestJson,
      '{"tool":"workspace.patch","reason":"需要批准 workspace.patch","args":{}}',
    );
  });

  test('approval decision queues the same task and is durable', () async {
    await coordinator.submit(_task(id: 'approval', conversationId: 'group-a'));
    await coordinator.pauseForApproval(
      'approval',
      pendingToolRequestJson:
          '{"tool":"workspace.patch","reason":"写入报告","args":{"path":"report.md"}}',
    );
    await coordinator.approve('approval');

    final queued = taskBox.get('approval')!;
    expect(queued.status, AgentTaskStatus.queued);
    expect(
        queued.executionStateJson, contains('"approvalDecision":"approved"'));
    expect(runner.startedTaskIds, <String>['approval']);

    runner.complete('approval');
    await _settle();
    expect(runner.startedTaskIds, <String>['approval', 'approval']);
    runner.complete('approval');
    await _settle();
    expect(taskBox.get('approval')?.status, AgentTaskStatus.completed);
  });

  test('reject decision is durable and does not revive a cancelled task',
      () async {
    await coordinator.submit(_task(id: 'approval', conversationId: 'group-a'));
    await coordinator.pauseForApproval(
      'approval',
      pendingToolRequestJson:
          '{"tool":"workspace.patch","reason":"写入报告","args":{"path":"report.md"}}',
    );
    await coordinator.reject('approval');

    expect(taskBox.get('approval')?.executionStateJson,
        contains('"approvalDecision":"rejected"'));
    await coordinator.stop('approval');
    expect(taskBox.get('approval')?.status, AgentTaskStatus.cancelled);
    expect(taskBox.get('approval')?.queuedUserRequests, isEmpty);
  });

  test(
      'completed tasks accept same-task follow-up but reject stop/continuation',
      () async {
    final completed = _task(id: 'done', conversationId: 'group-a')
      ..status = AgentTaskStatus.completed
      ..softLimitReached = true
      ..contextSummary = '{"goal":"保留上下文"}'
      ..completedOperations = const ['{"tool":"workspace.read","args":{}}'];
    await taskBox.put(completed.id, completed);

    await expectLater(
      coordinator.stop(completed.id),
      throwsStateError,
    );
    await coordinator.enqueueFollowUp(completed.id, '重新生成');
    final resumed = taskBox.get(completed.id)!;
    expect(resumed.status, AgentTaskStatus.planning);
    expect(resumed.userRequest, '重新生成');
    expect(resumed.contextSummary, '{"goal":"保留上下文"}');
    expect(resumed.completedOperations, isNotEmpty);
    expect(runner.startedTaskIds, <String>['done']);

    runner.complete('done');
    await _settle();
    await expectLater(
      coordinator.continueAfterSoftLimit('done'),
      throwsStateError,
    );
    expect(taskBox.get(completed.id)?.status, AgentTaskStatus.completed);
  });

  test('soft-limit continuation cannot race a still-running runner', () async {
    final gate = _GateWorkTaskRunner();
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: gate,
    );
    addTearDown(localCoordinator.dispose);

    final task = _task(id: 'soft-limit-race', conversationId: 'group-a');
    await localCoordinator.submit(task);
    await gate.started.future;
    task
      ..status = AgentTaskStatus.paused
      ..softLimitReached = true;
    await taskBox.put(task.id, task);

    await expectLater(
      localCoordinator.continueAfterSoftLimit(task.id),
      throwsStateError,
    );
    gate.release.complete();
    await _settle();
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
  });

  test('follow-up queued at terminal boundary starts after old run releases',
      () async {
    final gate = _GateWorkTaskRunner();
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: gate,
    );
    addTearDown(localCoordinator.dispose);

    final task = _task(id: 'terminal-boundary', conversationId: 'group-a');
    await localCoordinator.submit(task);
    await gate.started.future;
    task.status = AgentTaskStatus.completed;
    await taskBox.put(task.id, task);

    await localCoordinator.enqueueFollowUp(task.id, '修改刚才的结果');
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.queued);
    gate.release.complete();
    await _settle();

    expect(gate.runCount, 2);
    expect(taskBox.get(task.id)?.userRequest, '修改刚才的结果');
  });

  test('dispose drains cancellation before the task database can close',
      () async {
    await coordinator.submit(_task(id: 'in-flight', conversationId: 'group-a'));

    await coordinator.dispose();

    expect(runner.cancelledTaskIds, contains('in-flight'));
    expect(runner.activeCount, 0);
  });

  test('event persistence failures mark the task timeline incomplete',
      () async {
    await eventStore.close();
    await coordinator
        .submit(_task(id: 'event-failure', conversationId: 'group-a'));
    await _settle();

    expect(taskBox.get('event-failure')?.eventLogIncomplete, isTrue);
    runner.complete('event-failure');
  });

  test('runner progress reporter is connected to the coordinator stream', () {
    final reporter = _FakeProgressReporter();
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: reporter,
    );
    addTearDown(localCoordinator.dispose);

    expect(reporter.sink, isNotNull);
    final task = _task(id: 'published', conversationId: 'group-a');
    reporter.sink!(task);
    expect(reporter.published, same(task));
  });

  test('stopping one task does not cancel a task in another conversation',
      () async {
    await coordinator.submit(_task(id: 'target', conversationId: 'group-a'));
    await coordinator
        .submit(_task(id: 'unaffected', conversationId: 'group-b'));

    await coordinator.stop('target');
    await _settle();

    expect(runner.cancelledTaskIds, contains('target'));
    expect(runner.cancelledTaskIds, isNot(contains('unaffected')));
    expect(taskBox.get('target')?.status, AgentTaskStatus.cancelled);
    expect(taskBox.get('unaffected')?.status, isNot(AgentTaskStatus.cancelled));
  });

  test('restore publishes interrupted tasks without running them', () async {
    final interrupted = _task(id: 'interrupted', conversationId: 'group-a')
      ..status = AgentTaskStatus.interrupted
      ..resumeRequired = true;
    await taskBox.put(interrupted.id, interrupted);

    await coordinator.restore();

    final tasks = await coordinator.watchAllTasks().first;
    expect(tasks.map((task) => task.id), contains('interrupted'));
    expect(runner.startedTaskIds, isEmpty);
  });

  test('root provider keeps one coordinator backed by database and event store',
      () async {
    final container = ProviderContainer(
      overrides: <Override>[
        databaseServiceProvider.overrideWithValue(DatabaseService()),
        workTaskEventStoreProvider.overrideWithValue(eventStore),
        workTaskRunnerProvider.overrideWithValue(runner),
      ],
    );
    addTearDown(container.dispose);

    final first = container.read(workTaskCoordinatorProvider);
    final second = container.read(workTaskCoordinatorProvider);

    expect(identical(first, second), isTrue);
    await first.submit(_task(id: 'provided', conversationId: 'group-provider'));
    expect(taskBox.containsKey('provided'), isTrue);

    final productionContainer = ProviderContainer(
      overrides: <Override>[
        databaseServiceProvider.overrideWithValue(DatabaseService()),
        workTaskEventStoreProvider.overrideWithValue(eventStore),
      ],
    );
    addTearDown(productionContainer.dispose);
    expect(
      productionContainer.read(workTaskRunnerProvider),
      isA<DefaultWorkTaskRunner>(),
    );
  });
}
