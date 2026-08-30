import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

class _FakeWorkTaskRunner implements WorkTaskRunner {
  final List<String> startedTaskIds = <String>[];
  final List<String> cancelledTaskIds = <String>[];
  final Set<String> throwTaskIds = <String>{};
  final Map<String, Completer<void>> _completions = <String, Completer<void>>{};
  final Map<String, int> _activeByConversation = <String, int>{};

  int activeCount = 0;
  int maximumActiveCount = 0;
  int maximumActiveForOneConversation = 0;

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    if (throwTaskIds.contains(task.id)) {
      startedTaskIds.add(task.id);
      throw StateError('runner failed');
    }
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

Future<void> _waitForLockCount(
  WorkResourceLockManager manager,
  int expected,
) async {
  for (var index = 0; index < 200; index++) {
    if (manager.activeLockCount == expected) return;
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

  test('follow-up recalculates resource locks for its new request', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      resourceLockManager: manager,
      resourceLockPlan: (task) => [
        WorkResourceLockRequest.write(
          task.userRequest.contains('新目标')
              ? '/workspace/new-target.txt'
              : '/workspace/old-target.txt',
        ),
      ],
    );
    addTearDown(localCoordinator.dispose);

    final task = _task(id: 'lock-follow-up', conversationId: 'group-lock');
    await localCoordinator.submit(task);
    expect(
      taskBox.get(task.id)?.executionStateJson,
      contains('/workspace/old-target.txt'),
    );
    runner.complete(task.id);
    await _settle();

    await localCoordinator.enqueueFollowUp(task.id, '改写到新目标');
    expect(
      taskBox.get(task.id)?.executionStateJson,
      contains('/workspace/new-target.txt'),
    );
    expect(
      taskBox.get(task.id)?.executionStateJson,
      isNot(contains('/workspace/old-target.txt')),
    );
    runner.complete(task.id);
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

  test('persists explicit resource lock plans for a later coordinator',
      () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final first = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      resourceLockManager: manager,
    );
    final task = _task(id: 'persisted-lock', conversationId: 'group-lock');
    await first.submit(
      task,
      resourceLocks: const [
        WorkResourceLockRequest.treeWrite('/workspace/project'),
      ],
    );
    expect(taskBox.get(task.id)?.executionStateJson, contains('resourceLocks'));
    await first.dispose();

    final second = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      resourceLockManager: manager,
    );
    addTearDown(second.dispose);
    await second.restore();
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.interrupted);
    await second.resumeByUser(task.id);
    expect(runner.startedTaskIds, contains(task.id));
    runner.complete(task.id);
  });

  test('persists a runner-derived resource lock plan before execution',
      () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final local = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      resourceLockManager: manager,
      resourceLockPlan: (_) => [
        const WorkResourceLockRequest.treeWrite('/workspace/conversation'),
      ],
    );
    addTearDown(local.dispose);

    final task = _task(id: 'derived-lock', conversationId: 'group-derived');
    await local.submit(task);

    final stored = taskBox.get(task.id)!;
    expect(stored.executionStateJson, contains('resourceLocks'));
    expect(stored.executionStateJson, contains('/workspace/conversation'));
    expect(runner.startedTaskIds, contains(task.id));

    runner.complete(task.id);
    await _settle();
  });

  test('fails closed when a required folder grant service is unavailable',
      () async {
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      requireFolderGrant: true,
    );
    addTearDown(guarded.dispose);
    final task = _task(id: 'missing-grant', conversationId: 'group-grant');
    await guarded.submit(task);
    await _settle();

    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
    expect(taskBox.get(task.id)?.resumeRequired, isTrue);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('releases the conversation reservation after initial folder denial',
      () async {
    final settingsBox = await Hive.openBox<dynamic>('app_settings');
    final grants = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => false,
    );
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      folderGrantService: grants,
      folderPicker: () async => null,
    );
    addTearDown(guarded.dispose);

    final first =
        _task(id: 'folder-denied-first', conversationId: 'folder-group');
    final second =
        _task(id: 'folder-denied-second', conversationId: 'folder-group');
    await guarded.submit(first);
    await guarded.submit(second);
    await _settle();

    expect(taskBox.get(first.id)?.status, AgentTaskStatus.paused);
    expect(taskBox.get(second.id)?.status, AgentTaskStatus.paused);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('a native folder picker does not block another conversation submission',
      () async {
    final settingsBox = await Hive.openBox<dynamic>('app_settings-picker');
    final grants = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
    );
    final pickerGate = Completer<String?>();
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      folderGrantService: grants,
      folderPicker: () => pickerGate.future,
      folderGrantConsent: (_) async => true,
    );
    addTearDown(() async {
      if (!pickerGate.isCompleted) pickerGate.complete(null);
      await guarded.dispose();
    });

    final first = await guarded.submit(
      _task(id: 'picker-first', conversationId: 'picker-a'),
    );
    final second = await guarded.submit(
      _task(id: 'picker-second', conversationId: 'picker-b'),
    );

    expect(first.status, AgentTaskStatus.waitingForApproval);
    expect(second.status, AgentTaskStatus.waitingForApproval);
    expect(runner.startedTaskIds, isEmpty);

    pickerGate.complete(directory.path);
    await _settle();
    expect(
        runner.startedTaskIds,
        containsAll(<String>[
          'picker-first',
          'picker-second',
        ]));
  });

  test('queues a conflicting resource and starts it after release', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      resourceLockManager: manager,
      resourceLockPlan: (_) => [
        const WorkResourceLockRequest.write('/workspace/shared.txt'),
      ],
    );
    addTearDown(localCoordinator.dispose);

    await localCoordinator.submit(_task(id: 'lock-first', conversationId: 'a'));
    await localCoordinator
        .submit(_task(id: 'lock-second', conversationId: 'b'));
    expect(taskBox.get('lock-second')?.status, AgentTaskStatus.queued);
    expect(taskBox.get('lock-second')?.actionCount, 0);

    final waitingEvents = await eventStore.read('lock-second');
    expect(
      waitingEvents.events.any(
        (event) =>
            event.title.contains('shared.txt') ||
            event.detail.contains('shared.txt'),
      ),
      isTrue,
    );

    runner.complete('lock-first');
    await _settle();
    expect(runner.startedTaskIds, ['lock-first', 'lock-second']);
    runner.complete('lock-second');
  });

  test('a lock waiter does not consume the second global execution slot',
      () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      resourceLockManager: manager,
      resourceLockPlan: (task) => [
        if (task.id != 'unrelated')
          const WorkResourceLockRequest.write('/workspace/shared.txt'),
      ],
    );
    addTearDown(localCoordinator.dispose);

    await localCoordinator
        .submit(_task(id: 'lock-holder', conversationId: 'a'));
    await localCoordinator
        .submit(_task(id: 'lock-waiter', conversationId: 'b'));
    await localCoordinator.submit(_task(id: 'unrelated', conversationId: 'c'));

    expect(runner.startedTaskIds, ['lock-holder', 'unrelated']);
    expect(taskBox.get('lock-waiter')?.status, AgentTaskStatus.queued);
    expect(localCoordinator.runningTaskCount, 2);

    runner.complete('lock-holder');
    runner.complete('unrelated');
    await _settle();
    expect(runner.startedTaskIds, ['lock-holder', 'unrelated', 'lock-waiter']);
    runner.complete('lock-waiter');
  });

  test('runner failure releases its resource lease for the next task',
      () async {
    final manager = WorkResourceLockManager(isWindows: false);
    runner.throwTaskIds.add('lock-error');
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      resourceLockManager: manager,
      resourceLockPlan: (_) => [
        const WorkResourceLockRequest.write('/workspace/shared.txt'),
      ],
    );
    addTearDown(localCoordinator.dispose);

    await localCoordinator.submit(_task(id: 'lock-error', conversationId: 'a'));
    await localCoordinator
        .submit(_task(id: 'after-error', conversationId: 'b'));
    await _settle();

    expect(taskBox.get('lock-error')?.status, AgentTaskStatus.failed);
    expect(runner.startedTaskIds, ['lock-error', 'after-error']);
    runner.complete('after-error');
    await _settle();
    await _waitForLockCount(manager, 0);
    expect(manager.activeLockCount, 0);
  });

  test('stopping a lock waiter removes it without starting the runner',
      () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      resourceLockManager: manager,
      resourceLockPlan: (_) => [
        const WorkResourceLockRequest.write('/workspace/shared.txt'),
      ],
    );
    addTearDown(localCoordinator.dispose);

    await localCoordinator.submit(_task(id: 'holder', conversationId: 'a'));
    await localCoordinator
        .submit(_task(id: 'cancel-waiter', conversationId: 'b'));
    await localCoordinator.stop('cancel-waiter');
    expect(taskBox.get('cancel-waiter')?.status, AgentTaskStatus.cancelled);
    expect(manager.waitingOwnerIds, isNot(contains('cancel-waiter')));

    runner.complete('holder');
    await _settle();
    expect(runner.startedTaskIds, ['holder']);
  });

  test('restore marks an orphaned running task interrupted', () async {
    final orphaned = _task(id: 'orphaned', conversationId: 'group-a')
      ..status = AgentTaskStatus.runningTool;
    await taskBox.put(orphaned.id, orphaned);

    await coordinator.restore();

    expect(taskBox.get(orphaned.id)?.status, AgentTaskStatus.interrupted);
    expect(taskBox.get(orphaned.id)?.resumeRequired, isTrue);
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
