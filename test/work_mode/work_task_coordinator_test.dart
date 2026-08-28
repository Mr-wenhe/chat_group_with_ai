import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
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
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
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
    coordinator.dispose();
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
  });
}
