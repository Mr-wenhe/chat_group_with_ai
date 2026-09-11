import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/work_context_builder.dart';
import 'package:chat_group/features/work_mode/work_handoff_state.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

class _FakeWorkTaskRunner
    implements
        WorkTaskRunner,
        WorkTaskVisionModelValidator,
        WorkTaskInstallHandler {
  final List<String> startedTaskIds = <String>[];
  final List<String> cancelledTaskIds = <String>[];
  final Set<String> throwTaskIds = <String>{};
  final Map<String, Completer<void>> _completions = <String, Completer<void>>{};
  final Map<String, int> _activeByConversation = <String, int>{};

  int activeCount = 0;
  int maximumActiveCount = 0;
  int maximumActiveForOneConversation = 0;
  bool visionModelAvailable = true;
  int installCalls = 0;

  @override
  bool supportsVisionModel(String characterId) => visionModelAvailable;

  @override
  bool supportsVisionModelForTask(AgentTask task, String characterId) =>
      visionModelAvailable;

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

  @override
  Future<WorkCommandResult> installMissingTool(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    installCalls++;
    throw StateError('测试不应执行工具安装');
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

class _FailureReportingRunner
    implements WorkTaskRunner, WorkTaskFailureReporter {
  final bool persistFailure;

  _FailureReportingRunner({this.persistFailure = true});

  WorkFailure? reportedFailure;
  int reportCount = 0;

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    final failure = WorkFailure.fromToolFailure(
      code: 'documentParseFailed',
      message: 'budget.xlsx 无法解析：文件内容无法读取。',
    );
    task
      ..status = AgentTaskStatus.failed
      ..lastError = failure.reason;
    if (persistFailure) WorkFailure.persistOnTask(task, failure);
  }

  @override
  Future<void> reportFailure(AgentTask task, WorkFailure failure) async {
    reportCount++;
    reportedFailure = failure;
  }
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

AgentTask _task({
  required String id,
  required String conversationId,
  String characterId = 'worker',
}) {
  return AgentTask(
    id: id,
    groupId: conversationId,
    characterId: characterId,
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

Future<void> _waitForTaskState(
  Box<AgentTask> taskBox,
  String taskId,
  bool Function(AgentTask task) predicate,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    final task = taskBox.get(taskId);
    if (task != null && predicate(task)) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('任务未在限定时间内达到预期状态：$taskId');
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

Future<void> _waitForStartedCount(
  _FakeWorkTaskRunner runner,
  int expected,
) async {
  for (var index = 0; index < 200; index++) {
    if (runner.startedTaskIds.length >= expected) return;
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

  test('releases the previous role before starting the next handoff role',
      () async {
    final product = _task(
      id: 'handoff-product',
      conversationId: 'handoff-conversation',
      characterId: 'product',
    );
    final developer = _task(
      id: 'handoff-developer',
      conversationId: 'handoff-conversation',
      characterId: 'developer',
    );

    await coordinator.submit(product);
    await coordinator.submit(developer);

    expect(runner.startedTaskIds, ['handoff-product']);
    expect(runner.maximumActiveForOneConversation, 1);

    runner.complete(product.id);
    await _waitForStartedCount(runner, 2);

    expect(runner.startedTaskIds, ['handoff-product', 'handoff-developer']);
    expect(runner.maximumActiveForOneConversation, 1);
    runner.complete(developer.id);
  });

  test('100 same-conversation role handoffs never overlap active roles',
      () async {
    final tasks = List<AgentTask>.generate(
      100,
      (index) => _task(
        id: 'pressure-$index',
        conversationId: 'pressure-conversation',
        characterId: switch (index % 3) {
          0 => 'product',
          1 => 'developer',
          _ => 'tester',
        },
      ),
    );
    for (final task in tasks) {
      await coordinator.submit(task);
    }

    expect(runner.startedTaskIds, ['pressure-0']);
    for (var index = 0; index < tasks.length; index++) {
      runner.complete(tasks[index].id);
      if (index + 1 < tasks.length) {
        await _waitForStartedCount(runner, index + 2);
      }
    }
    await _settle();

    expect(runner.startedTaskIds.length, 100);
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

  test('keeps attachment-only follow-ups paired with their message IDs',
      () async {
    final task = _task(id: 'attachment-fifo', conversationId: 'group-a');
    await coordinator.submit(task);

    await coordinator.enqueueFollowUp(
      task.id,
      WorkModePolicy.attachmentOnlyRequest,
      attachmentMessageId: 'attachment-a',
    );
    await coordinator.enqueueFollowUp(
      task.id,
      WorkModePolicy.attachmentOnlyRequest,
      attachmentMessageId: 'attachment-b',
    );

    final queued = jsonDecode(taskBox.get(task.id)!.executionStateJson)
        as Map<String, dynamic>;
    expect(
        queued['queuedAttachmentMessageIds'], ['attachment-a', 'attachment-b']);

    runner.complete(task.id);
    await _waitForStartedCount(runner, 2);
    await _waitForTaskState(
      taskBox,
      task.id,
      (value) => value.queuedUserRequests.length == 1,
    );
    final first = jsonDecode(taskBox.get(task.id)!.executionStateJson)
        as Map<String, dynamic>;
    expect(first['attachmentMessageId'], 'attachment-a');
    expect(first['queuedAttachmentMessageIds'], ['attachment-b']);

    runner.complete(task.id);
  });

  test('keeps three running follow-ups FIFO and starts the first on finish',
      () async {
    final task = _task(id: 'fifo-three', conversationId: 'group-fifo');
    await coordinator.submit(task);
    await coordinator.enqueueFollowUp(task.id, '第一条追问');
    await coordinator.enqueueFollowUp(task.id, '第二条追问');
    await coordinator.enqueueFollowUp(task.id, '第三条追问');

    expect(taskBox.get(task.id)?.queuedUserRequests, <String>[
      '第一条追问',
      '第二条追问',
      '第三条追问',
    ]);
    expect(runner.startedTaskIds, ['fifo-three']);

    runner.complete(task.id);
    // The coordinator persists the next request before it crosses the
    // runner boundary. Wait for the runner's observable start rather than
    // treating that intermediate durable state as an active completion gate.
    await _waitForStartedCount(runner, 2);
    await _waitForTaskState(
      taskBox,
      task.id,
      (value) =>
          value.userRequest == '第一条追问' && value.queuedUserRequests.length == 2,
    );
    expect(taskBox.get(task.id)?.userRequest, '第一条追问');
    expect(taskBox.get(task.id)?.queuedUserRequests, <String>[
      '第二条追问',
      '第三条追问',
    ]);
    expect(runner.startedTaskIds, ['fifo-three', 'fifo-three']);

    runner.complete(task.id);
    await _waitForStartedCount(runner, 3);
    await _waitForTaskState(
      taskBox,
      task.id,
      (value) =>
          value.userRequest == '第二条追问' && value.queuedUserRequests.length == 1,
    );
    expect(taskBox.get(task.id)?.userRequest, '第二条追问');
    expect(taskBox.get(task.id)?.queuedUserRequests, ['第三条追问']);
    runner.complete(task.id);
    await _waitForTaskState(
      taskBox,
      task.id,
      (value) =>
          value.userRequest == '第三条追问' && value.queuedUserRequests.isEmpty,
    );
    expect(taskBox.get(task.id)?.userRequest, '第三条追问');
    expect(taskBox.get(task.id)?.queuedUserRequests, isEmpty);
  });

  test('records an explicit revision target without enabling collision rename',
      () async {
    final task =
        _task(id: 'revision-follow-up', conversationId: 'group-revision')
          ..status = AgentTaskStatus.completed
          ..lastArtifactPaths = ['/workspace/report.md'];
    await taskBox.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '请修改当前文件');

    final stored = taskBox.get(task.id)!;
    expect(stored.userRequest, '请修改当前文件');
    expect(stored.executionStateJson, contains('revisionTargetPath'));
    expect(stored.executionStateJson, contains('/workspace/report.md'));
    expect(stored.executionStateJson, contains('"autoRenameIfExists":false'));
    runner.complete(task.id);
  });

  test('clears stale tool results when promoting a terminal follow-up',
      () async {
    final task =
        _task(id: 'fresh-follow-up-context', conversationId: 'group-doc')
          ..status = AgentTaskStatus.completed
          ..resultSummary = '上一轮已完成 README 解析。'
          ..contextSummary = const WorkContextBuilder().build(
            conversationId: 'group-doc',
            target: '解析 README.md',
            completedSummaries: ['上一轮已完成 README 解析。'],
            recentToolResults: [
              {
                'tool': 'workspace.document',
                'path': '/tmp/README.md',
                'summary': '旧解析结果',
              },
            ],
          ).toJsonString();
    await taskBox.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '改为解析 sample.pdf');

    final stored = taskBox.get(task.id)!;
    final context = jsonDecode(stored.contextSummary) as Map<String, dynamic>;
    expect(stored.userRequest, '改为解析 sample.pdf');
    expect(context['recentToolResults'], isEmpty);
    expect(context['completedSummaries'], contains('上一轮已完成 README 解析。'));
    expect(runner.startedTaskIds, [task.id]);
  });

  test('clears the previous plan when promoting a new-artifact follow-up',
      () async {
    final task = _task(id: 'fresh-artifact-plan', conversationId: 'group-doc')
      ..status = AgentTaskStatus.completed
      ..plan = '旧飞行棋计划'
      ..contextSummary = const WorkContextBuilder().build(
        conversationId: 'group-doc',
        target: '继续修改飞行棋页面',
        artifactPaths: ['/workspace/flight-chess.html'],
      ).toJsonString()
      ..lastArtifactPaths = <String>['/workspace/flight-chess.html'];
    await taskBox.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '设计并实现一个 html 教师节贺卡');

    final stored = taskBox.get(task.id)!;
    expect(stored.userRequest, '设计并实现一个 html 教师节贺卡');
    expect(stored.plan, isEmpty);
    expect(stored.lastArtifactPaths, isEmpty);
    final context = jsonDecode(stored.contextSummary) as Map<String, dynamic>;
    expect(context['target'], '设计并实现一个 html 教师节贺卡');
    expect(context['artifactPaths'], isEmpty);
    expect(runner.startedTaskIds, [task.id]);
  });

  test('explicit validation follow-up resumes the paused task checkpoint',
      () async {
    final task = _task(id: 'explicit-validation', conversationId: 'group-test')
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..lastError = '默认不运行测试或构建；请由用户明确要求后再执行。'
      ..executionStateJson = jsonEncode({
        'explicitCommandRequestRequired': true,
        'approvalPlan': {'taskId': 'explicit-validation'},
      });
    await taskBox.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '请运行 flutter test');

    final resumed = taskBox.get(task.id)!;
    expect(resumed.status, AgentTaskStatus.planning);
    expect(resumed.userRequest, contains('请运行 flutter test'));
    expect(resumed.pendingToolRequestJson, isEmpty);
    expect(resumed.executionStateJson,
        isNot(contains('explicitCommandRequestRequired')));
    expect(runner.startedTaskIds, [task.id]);
    runner.complete(task.id);
  });

  test('generic resume remains blocked for an explicit validation checkpoint',
      () async {
    final task = _task(id: 'explicit-generic', conversationId: 'group-test')
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..executionStateJson =
          jsonEncode({'explicitCommandRequestRequired': true});
    await taskBox.put(task.id, task);

    await expectLater(
      coordinator.resumeByUser(task.id),
      throwsStateError,
    );
    expect(runner.startedTaskIds, isEmpty);
  });

  test('generic resume remains blocked until a visual model is selected',
      () async {
    final task = _task(id: 'vision-generic', conversationId: 'group-test')
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..executionStateJson = jsonEncode({'visionModelRequired': true});
    await taskBox.put(task.id, task);

    await expectLater(
      coordinator.resumeByUser(task.id),
      throwsStateError,
    );
    expect(runner.startedTaskIds, isEmpty);
  });

  test('generic resume remains blocked at a missing-tool boundary', () async {
    final task = _task(id: 'missing-tool-generic', conversationId: 'group-test')
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..pendingToolRequestJson = '{"tool":"command.run","args":{}}'
      ..executionStateJson = jsonEncode({'toolMissing': true});
    await taskBox.put(task.id, task);

    await expectLater(
      coordinator.resumeByUser(task.id),
      throwsStateError,
    );
    expect(runner.startedTaskIds, isEmpty);
  });

  test('install action requires a current missing-tool checkpoint', () async {
    final task = _task(id: 'install-gate', conversationId: 'group-test')
      ..status = AgentTaskStatus.paused
      ..pendingToolRequestJson = jsonEncode({
        'tool': 'command.run',
        'args': {'executable': 'pandoc'},
      });
    await taskBox.put(task.id, task);

    await expectLater(
      coordinator.installMissingTool(task.id),
      throwsStateError,
    );
    expect(runner.installCalls, 0);
  });

  test('vision model selection validates the pause state and capability',
      () async {
    final task = _task(id: 'vision-select', conversationId: 'group-test')
      ..status = AgentTaskStatus.paused
      ..executionStateJson = jsonEncode({'visionModelRequired': true});
    await taskBox.put(task.id, task);

    runner.visionModelAvailable = false;
    await expectLater(
      coordinator.selectVisionModel(task.id, 'vision-character'),
      throwsStateError,
    );
    expect(taskBox.get(task.id)?.characterId, 'worker');

    runner.visionModelAvailable = true;
    await coordinator.selectVisionModel(task.id, 'vision-character');
    expect(taskBox.get(task.id)?.characterId, 'vision-character');
    expect(
      taskBox.get(task.id)?.status,
      anyOf(AgentTaskStatus.queued, AgentTaskStatus.planning),
    );
    runner.complete(task.id);
    await _settle();

    final unrelated =
        _task(id: 'vision-unrelated', conversationId: 'group-test')
          ..status = AgentTaskStatus.paused;
    await taskBox.put(unrelated.id, unrelated);
    await expectLater(
      coordinator.selectVisionModel(unrelated.id, 'vision-character'),
      throwsStateError,
    );
  });

  test('handoff keeps the cumulative action budget and start time', () async {
    final startedAt = DateTime.utc(2026, 8, 31, 8);
    final task = _task(
      id: 'handoff-budget',
      conversationId: 'handoff-budget-group',
      characterId: 'product',
    )
      ..actionCount = 37
      ..startedAt = startedAt;
    WorkHandoffState.persistToTask(
      task,
      WorkHandoffState.initial(
        conversationId: task.groupId,
        stages: [
          WorkHandoffStage(id: 'product', label: '产品', roleId: 'product'),
          WorkHandoffStage(id: 'development', label: '开发', roleId: 'developer'),
        ],
      ),
    );

    await coordinator.submit(task);
    final completed = taskBox.get(task.id)!;
    completed
      ..status = AgentTaskStatus.completed
      ..resultSummary = '产品阶段完成';
    await taskBox.put(task.id, completed);
    runner.complete(task.id);
    await _waitForStartedCount(runner, 2);

    final next = taskBox.get(task.id)!;
    expect(next.characterId, 'developer');
    expect(next.actionCount, 37);
    expect(next.startedAt, startedAt);
    runner.complete(task.id);
  });

  test('pauses one ambiguous revision question and keeps it in the FIFO',
      () async {
    final task =
        _task(id: 'ambiguous-follow-up', conversationId: 'group-ambiguous')
          ..status = AgentTaskStatus.completed
          ..lastArtifactPaths = [
            '/workspace/report.md',
            '/workspace/summary.md',
          ];
    await taskBox.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '请修改当前文件');

    final stored = taskBox.get(task.id)!;
    expect(stored.status, AgentTaskStatus.paused);
    expect(stored.queuedUserRequests, ['请修改当前文件']);
    expect(stored.lastError.split('？').length - 1, 1);
    expect(runner.startedTaskIds, isEmpty);
    await expectLater(
      coordinator.resumeByUser(task.id),
      throwsStateError,
    );
  });

  test('rejects a persisted checkpoint from another conversation', () async {
    final task = _task(id: 'foreign-context', conversationId: 'dm:a')
      ..contextSummary = const WorkContextBuilder()
          .build(
            conversationId: 'dm:b',
            target: 'B_ONLY_PRIVATE_CONTENT',
          )
          .toJsonString();

    await coordinator.submit(task);

    final stored = taskBox.get(task.id)!;
    expect(stored.contextSummary, isNot(contains('B_ONLY_PRIVATE_CONTENT')));
    expect(stored.contextSummary, contains('"conversationId":"dm:a"'));
  });

  test('a clarification answer resumes the queued revision without dropping it',
      () async {
    final task =
        _task(id: 'clarification-answer', conversationId: 'group-clarify')
          ..status = AgentTaskStatus.completed
          ..lastArtifactPaths = [
            '/workspace/report.md',
            '/workspace/summary.md',
          ];
    await taskBox.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '请修改当前文件');
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);

    await coordinator.enqueueFollowUp(task.id, 'report.md');

    final resumed = taskBox.get(task.id)!;
    expect(resumed.status, AgentTaskStatus.planning);
    expect(resumed.queuedUserRequests, isEmpty);
    expect(resumed.executionStateJson, contains('/workspace/report.md'));
    expect(runner.startedTaskIds, ['clarification-answer']);
  });

  test('a model clarification answer resumes the paused task', () async {
    final task = _task(
      id: 'model-clarification-answer',
      conversationId: 'group-model-clarify',
    )
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..lastError = '你要生成 PPTX 还是其他格式？'
      ..executionStateJson = jsonEncode({
        'clarificationRequired': true,
        'clarificationQuestion': '你要生成 PPTX 还是其他格式？',
      });
    await taskBox.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '生成 PowerPoint .pptx 文件');

    final resumed = taskBox.get(task.id)!;
    expect(resumed.status, AgentTaskStatus.planning);
    expect(resumed.resumeRequired, isFalse);
    expect(resumed.queuedUserRequests, isEmpty);
    expect(resumed.userRequest, contains('生成 PowerPoint .pptx 文件'));
    expect(runner.startedTaskIds, ['model-clarification-answer']);
  });

  test('a model clarification answer resumes an interrupted task', () async {
    final task = _task(
      id: 'interrupted-model-clarification-answer',
      conversationId: 'group-interrupted-model-clarify',
    )
      ..status = AgentTaskStatus.interrupted
      ..resumeRequired = true
      ..lastError = '你要生成 PPTX 还是其他格式？'
      ..executionStateJson = jsonEncode({
        'clarificationRequired': true,
        'clarificationQuestion': '你要生成 PPTX 还是其他格式？',
      });
    await taskBox.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '生成 PowerPoint .pptx 文件');

    final resumed = taskBox.get(task.id)!;
    expect(resumed.status, AgentTaskStatus.planning);
    expect(resumed.resumeRequired, isFalse);
    expect(resumed.queuedUserRequests, isEmpty);
    expect(resumed.userRequest, contains('生成 PowerPoint .pptx 文件'));
    expect(runner.startedTaskIds, ['interrupted-model-clarification-answer']);
  });

  test('restore reserves a conversation with a pending model clarification',
      () async {
    final task = _task(
      id: 'restored-model-clarification',
      conversationId: 'group-restored-model-clarify',
    )
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..lastError = '你要生成 PPTX 还是其他格式？'
      ..executionStateJson = jsonEncode({
        'clarificationRequired': true,
        'clarificationQuestion': '你要生成 PPTX 还是其他格式？',
      });
    await taskBox.put(task.id, task);

    await coordinator.restore();
    await coordinator.submit(
      _task(
        id: 'blocked-by-restored-model-clarification',
        conversationId: 'group-restored-model-clarify',
      ),
    );

    expect(runner.startedTaskIds, isEmpty);
    expect(
      taskBox.get('blocked-by-restored-model-clarification')?.status,
      AgentTaskStatus.queued,
    );
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

  test('marks the first approval prompt once and survives repeated snapshots',
      () async {
    await coordinator
        .submit(_task(id: 'approval-once', conversationId: 'group-a'));
    await coordinator.pauseForApproval(
      'approval-once',
      pendingToolRequestJson: '{"tool":"workspace.patch"}',
    );

    expect(await coordinator.markApprovalPromptShown('approval-once'), isTrue);
    expect(await coordinator.markApprovalPromptShown('approval-once'), isFalse);
    expect(
      taskBox.get('approval-once')?.executionStateJson,
      contains('"approvalPromptShown":true'),
    );
    await coordinator.approve('approval-once');
    expect(
      taskBox.get('approval-once')?.executionStateJson,
      isNot(contains('"approvalPromptShown":true')),
    );
  });

  test('resets an approval prompt marker after host presentation failure',
      () async {
    await coordinator
        .submit(_task(id: 'approval-reset', conversationId: 'group-a'));
    await coordinator.pauseForApproval(
      'approval-reset',
      pendingToolRequestJson: '{"tool":"workspace.patch"}',
    );

    expect(await coordinator.markApprovalPromptShown('approval-reset'), isTrue);
    await coordinator.resetApprovalPromptShown('approval-reset');

    expect(
      taskBox.get('approval-reset')?.executionStateJson,
      isNot(contains('"approvalPromptShown":true')),
    );
    expect(await coordinator.markApprovalPromptShown('approval-reset'), isTrue);
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

  test(
      'soft-limit continuation releases the conversation for the resumed task and its queued successor',
      () async {
    final first = _task(id: 'soft-limit-first', conversationId: 'dm-character');
    await coordinator.submit(first);
    await _waitForStartedCount(runner, 1);

    // Model the runner's durable soft-limit checkpoint. The runner returns
    // only after publishing the pause, so the coordinator keeps the
    // conversation reservation until an explicit continuation releases it.
    first
      ..status = AgentTaskStatus.paused
      ..softLimitReached = true;
    await taskBox.put(first.id, first);
    runner.complete(first.id);
    await _waitForTaskState(
      taskBox,
      first.id,
      (task) => task.status == AgentTaskStatus.paused,
    );

    final successor = _task(
      id: 'soft-limit-successor',
      conversationId: first.groupId,
    );
    await coordinator.submit(successor);
    expect(runner.startedTaskIds, ['soft-limit-first']);

    await coordinator.continueAfterSoftLimit(first.id);
    await _waitForStartedCount(runner, 2);
    expect(runner.startedTaskIds, ['soft-limit-first', 'soft-limit-first']);

    runner.complete(first.id);
    await _waitForStartedCount(runner, 3);
    expect(
      runner.startedTaskIds,
      ['soft-limit-first', 'soft-limit-first', 'soft-limit-successor'],
    );
    runner.complete(successor.id);
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

  test('reports terminal failures through the runner outcome channel',
      () async {
    final failureRunner = _FailureReportingRunner();
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: failureRunner,
    );
    addTearDown(localCoordinator.dispose);

    await localCoordinator.submit(
      _task(id: 'terminal-failure', conversationId: 'group-a'),
    );
    await _settle();

    expect(failureRunner.reportCount, 1);
    expect(failureRunner.reportedFailure?.reason, contains('budget.xlsx'));
    expect(
      taskBox.get('terminal-failure')?.status,
      AgentTaskStatus.failed,
    );
  });

  test('creates a durable fallback when a runner omits its failure checkpoint',
      () async {
    final failureRunner = _FailureReportingRunner(persistFailure: false);
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: failureRunner,
    );
    addTearDown(localCoordinator.dispose);

    await localCoordinator.submit(
      _task(id: 'uncheckpointed-failure', conversationId: 'group-a'),
    );
    await _settle();

    expect(failureRunner.reportCount, 1);
    expect(failureRunner.reportedFailure?.reason, contains('budget.xlsx'));
    expect(taskBox.get('uncheckpointed-failure')?.workFailure, isNotNull);
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

  test('restarts a user-stopped task only when no mutation was committed',
      () async {
    final task = _task(id: 'restart-from-zero', conversationId: 'group-a')
      ..status = AgentTaskStatus.cancelled
      ..lastError = '用户已停止任务。'
      ..plan = '旧计划'
      ..resultSummary = '旧结果'
      ..currentStep = 4
      ..actionCount = 9
      ..completedOperations = <String>[
        '{"tool":"workspace.list","args":{"path":"."}}',
      ]
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'committedActionKeys': <String>[],
      });
    await taskBox.put(task.id, task);

    await coordinator.retry(task.id);

    final restarted = taskBox.get(task.id)!;
    expect(restarted.status, AgentTaskStatus.planning);
    expect(restarted.actionCount, 0);
    expect(restarted.currentStep, 0);
    expect(restarted.plan, isEmpty);
    expect(restarted.resultSummary, isEmpty);
    expect(restarted.completedOperations, isEmpty);
    expect(restarted.executionStateJson, isEmpty);
    expect(restarted.startedAt, isNotNull);
    expect(runner.startedTaskIds, contains(task.id));
    runner.complete(task.id);

    final committed = _task(id: 'committed-stop', conversationId: 'group-a')
      ..status = AgentTaskStatus.cancelled
      ..lastError = '用户已停止任务。'
      ..lastArtifactPaths = <String>['/workspace/report.md']
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'committedActionKeys': <String>['committed-operation'],
      });
    await taskBox.put(committed.id, committed);

    await expectLater(coordinator.retry(committed.id), throwsStateError);
    expect(taskBox.get(committed.id)?.status, AgentTaskStatus.cancelled);
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

  test('manual restart clears a redacted approval request before re-planning',
      () async {
    final waiting = _task(id: 'restart-approval', conversationId: 'group-a')
      ..status = AgentTaskStatus.waitingForApproval
      ..resumeRequired = true
      ..pendingToolRequestJson =
          '{"tool":"workspace.patch","reason":"写入","args":{"path":"report.md"}}';
    await taskBox.put(waiting.id, waiting);

    await coordinator.restore();
    expect(taskBox.get(waiting.id)?.status, AgentTaskStatus.interrupted);

    await coordinator.resumeByUser(waiting.id);
    final resumed = taskBox.get(waiting.id)!;
    // The coordinator persists planning immediately when it starts the fresh
    // run; the important boundary is that the redacted request is gone.
    expect(resumed.status, AgentTaskStatus.planning);
    expect(resumed.pendingToolRequestJson, isEmpty);
    expect(runner.startedTaskIds, contains(waiting.id));
    runner.complete(waiting.id);
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
    await _waitForTaskState(
        taskBox, first.id, (task) => task.status == AgentTaskStatus.paused);
    await _waitForTaskState(
        taskBox, second.id, (task) => task.status == AgentTaskStatus.paused);

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
    // Completing the native picker only schedules the remaining async grant
    // and task-start chain; observe the runner boundary rather than relying
    // on a fixed 100ms delay under CI load.
    await _waitForStartedCount(runner, 2);
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
