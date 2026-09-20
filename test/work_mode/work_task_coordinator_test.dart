import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/work_context_builder.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_handoff_state.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_follow_up_policy.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_budget_wait.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
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
  final Set<String> failOnCompletion = <String>{};

  /// 每次运行实际看到的当前附件 id，按任务分组，用于验证追问是否切换了附件。
  final Map<String, List<String>> _attachments = <String, List<String>>{};

  List<String> attachmentsFor(String taskId) =>
      List<String>.unmodifiable(_attachments[taskId] ?? const <String>[]);
  final Map<String, Completer<void>> _completions = <String, Completer<void>>{};
  final Map<String, int> _activeByConversation = <String, int>{};

  int activeCount = 0;
  int maximumActiveCount = 0;
  int maximumActiveForOneConversation = 0;
  bool visionModelAvailable = true;
  int installCalls = 0;
  WorkTaskCancellation? installCancellation;
  WorkCommandResult? installResult;
  Completer<WorkCommandResult>? installGate;

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
    (_attachments[task.id] ??= <String>[]).add(_attachmentIdOf(task));
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
    if (failOnCompletion.remove(task.id)) throw StateError('completion failed');
  }

  Map<String, dynamic> _decode(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final value = jsonDecode(raw);
    return value is Map
        ? Map<String, dynamic>.from(value)
        : <String, dynamic>{};
  }

  String _attachmentIdOf(AgentTask task) =>
      (_decode(task.executionStateJson)['attachmentMessageId'] ?? '')
          .toString();

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
    installCancellation = cancellation;
    final gate = installGate;
    if (gate != null) return gate.future;
    final result = installResult;
    if (result != null) return result;
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

class _LateCheckpointRunner
    implements WorkTaskRunner, WorkTaskCheckpointReporter {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  Future<void> Function(AgentTask task)? checkpoint;

  @override
  void setTaskCheckpointSink(Future<void> Function(AgentTask task) sink) {
    checkpoint = sink;
  }

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    if (!started.isCompleted) started.complete();
    await Future.any<void>([release.future, cancellation.whenCancelled]);
  }
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

class _DelayedDiscussionRunner
    implements WorkTaskRunner, WorkTaskDiscussionExecutorValidator {
  final Completer<void> validationStarted = Completer<void>();
  final Completer<void> releaseValidation = Completer<void>();
  int runCount = 0;
  int validationCount = 0;

  @override
  Future<String?> validateDiscussionExecutor(
    AgentTask task,
    WorkDiscussionState state,
  ) async {
    validationCount++;
    if (!validationStarted.isCompleted) validationStarted.complete();
    await releaseValidation.future;
    return null;
  }

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    runCount += 1;
  }
}

class _FakeDiscussionRunner implements WorkTaskDiscussionRunner {
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> release = Completer<void>();
  int runCount = 0;

  @override
  Future<void> runDiscussion(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkTaskDiscussionStateSink updateState,
  ) async {
    runCount++;
    if (runCount == 1 && !firstStarted.isCompleted) {
      firstStarted.complete();
    }
    await Future.any<void>([
      release.future,
      cancellation.whenCancelled,
    ]);
  }
}

class _CompletingBlockedDiscussionRunner implements WorkTaskDiscussionRunner {
  int runCount = 0;

  @override
  Future<void> runDiscussion(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkTaskDiscussionStateSink updateState,
  ) async {
    runCount++;
    final current = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    );
    if (current == null || cancellation.isCancelled) return;
    await updateState(
      current.copyWith(
        phase: WorkDiscussionPhase.blocked,
        blockers: const ['discussionNotConverged'],
      ),
    );
  }
}

AgentTask _task({
  required String id,
  required String conversationId,
  String characterId = 'worker',
}) {
  final task = AgentTask(
    id: id,
    groupId: conversationId,
    characterId: characterId,
    userRequest: '执行 $id',
    workModeTask: true,
  );
  return task;
}

WorkDiscussionState _discussionState({
  required String conversationId,
  String? executorId = 'worker',
  int requestRevision = 1,
  String phase = WorkDiscussionPhase.awaitingDiscussion,
  int understandingPercent = 0,
  List<String> openQuestions = const [],
  List<String> blockers = const [],
}) {
  final candidates =
      executorId == null ? const <String>[] : <String>[executorId];
  final pending = WorkDiscussionState.initial(
    conversationId: conversationId,
    requestRevision: requestRevision,
    executorId: executorId,
    candidateCharacterIds: candidates,
    participantCharacterIds: candidates,
    deliverableContract: <String, dynamic>{
      'deliverableType': 'document',
      'format': 'docx',
      'location': 'desktop',
      'contentScope': '执行 $conversationId',
      'explicitExecutorId': executorId,
      'revisionTarget': '',
      'requestRevision': requestRevision,
    },
    openQuestions: openQuestions,
    blockers: blockers,
  );
  return pending.copyWith(
    phase: phase,
    understandingPercent: understandingPercent,
    understandingEvidence: const ['执行人已确认需求与交付合同。'],
    openQuestions: openQuestions,
    blockers: blockers,
  );
}

AgentTask _taskWithDiscussion(
  AgentTask task,
  WorkDiscussionState state,
) {
  task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
    task.executionStateJson,
    state,
  );
  return task;
}

void _markDiscussionReady(AgentTask task) {
  final current = WorkDiscussionState.fromExecutionState(
    task.executionStateJson,
  );
  if (current == null) return;
  final contract = current.deliverableContract == null
      ? null
      : <String, dynamic>{
          ...current.deliverableContract!,
          // Legacy recovery fixtures do not carry an artifact contract. The
          // helper represents a completed discussion, so it must provide the
          // same concrete chat-delivery facts that the real discussion would.
          if (current.deliverableContract!['format'] == 'unspecified')
            'format': 'text',
          if (current.deliverableContract!['location'] == 'unspecified')
            'location': 'conversation',
          if (current.executorId != null)
            'explicitExecutorId': current.executorId,
        };
  task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
    task.executionStateJson,
    current.copyWith(
      phase: WorkDiscussionPhase.ready,
      understandingPercent: 100,
      understandingEvidence: const ['测试已确认旧任务的执行目标与交付边界。'],
      openQuestions: const [],
      blockers: const [],
      deliverableContract: contract,
    ),
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

Future<void> _waitForInstallCall(_FakeWorkTaskRunner runner) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (runner.installCalls > 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('安装器未在限定时间内启动');
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
    if (!Hive.isAdapterRegistered(10)) {
      Hive.registerAdapter(ToolPermissionAdapter());
    }
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
      installerIsMacOS: true,
    );
  });

  tearDown(() async {
    await runner.finishAll();
    await coordinator.dispose();
    await eventStore.close();
    await Hive.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('direct revisions remain FIFO and keep attachments and time budget',
      () async {
    var now = DateTime.utc(2026, 9, 17, 9);
    final originalStart = now;
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      clock: () => now,
    );
    addTearDown(localCoordinator.dispose);
    final task = _task(id: 'revision-fifo', conversationId: 'dm:worker')
      ..userRequest = '生成报告'
      ..lastArtifactPaths = ['/workspace/report.md'];
    await localCoordinator.submit(task);
    await localCoordinator.enqueueFollowUp(
      task.id,
      '修改同一文件的标题',
      attachmentMessageId: 'attachment-first',
    );
    await localCoordinator.enqueueFollowUp(task.id, '内容再详细些');
    expect(task.userRequest, '生成报告');
    expect(task.queuedUserRequests, ['修改同一文件的标题', '内容再详细些']);
    expect(runner.cancelledTaskIds, isEmpty);
    expect(runner.startedTaskIds, [task.id]);

    now = now.add(const Duration(minutes: 10));
    runner.complete(task.id);
    await _waitForStartedCount(runner, 2);
    expect(task.userRequest, '修改同一文件的标题');
    expect(task.queuedUserRequests, ['内容再详细些']);
    expect(task.lastArtifactPaths, ['/workspace/report.md']);
    expect(runner.attachmentsFor(task.id), ['', 'attachment-first']);
    expect(task.startedAt, originalStart);
    expect(task.attemptStartedAt, now);

    now = now.add(const Duration(minutes: 10));
    runner.complete(task.id);
    await _waitForStartedCount(runner, 3);
    expect(task.userRequest, '内容再详细些');
    expect(task.queuedUserRequests, isEmpty);
    expect(task.lastArtifactPaths, ['/workspace/report.md']);
    expect(runner.attachmentsFor(task.id), ['', 'attachment-first', '']);
    expect(task.startedAt, originalStart);
    expect(task.attemptStartedAt, now);
    expect(runner.maximumActiveForOneConversation, 1);
    expect(runner.cancelledTaskIds, isEmpty);
    runner.complete(task.id);
    await _waitForTaskState(taskBox, task.id, (task) => task.isTerminal);
  });

  test('a late execution failure preserves queued direct revisions', () async {
    final task = _task(id: 'revision-failure', conversationId: 'dm:worker')
      ..userRequest = '生成报告'
      ..lastArtifactPaths = ['/workspace/report.md'];
    await coordinator.submit(task);
    await coordinator.enqueueFollowUp(task.id, '内容再详细些',
        attachmentMessageId: 'revision-attachment');
    runner.failOnCompletion.add(task.id);
    runner.complete(task.id);
    await _waitForTaskState(
        taskBox, task.id, (task) => task.status == AgentTaskStatus.failed);
    expect(task.lastError, contains('completion failed'));
    expect(task.userRequest, '生成报告');
    expect(task.queuedUserRequests, ['内容再详细些']);
    expect(
        (jsonDecode(task.executionStateJson)
            as Map)['queuedAttachmentMessageIds'],
        ['revision-attachment']);
    expect(runner.startedTaskIds, [task.id]);
    expect(runner.cancelledTaskIds, isEmpty);
  });

  test('regression: visual recovery keeps discussion executor consistent',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'audit-vision', conversationId: 'audit-group'),
      _discussionState(
          conversationId: 'audit-group',
          phase: WorkDiscussionPhase.ready,
          understandingPercent: 100),
    )..status = AgentTaskStatus.paused;
    final execution =
        jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    execution['visionModelRequired'] = true;
    task.executionStateJson = jsonEncode(execution);
    await taskBox.put(task.id, task);
    await coordinator.selectVisionModel(task.id, 'vision-character');
    await _settle();
    expect(task.lastError, isNot(contains('最终执行人不一致')));
  });

  test('regression: restart typed discussion actually launches discussion',
      () async {
    await coordinator.dispose();
    final discussionRunner = _FakeDiscussionRunner();
    coordinator = WorkTaskCoordinator(
        taskBox: taskBox,
        eventStore: eventStore,
        runner: runner,
        discussionRunner: discussionRunner);
    final task = _taskWithDiscussion(
        _task(id: 'audit-restart', conversationId: 'audit-group'),
        _discussionState(conversationId: 'audit-group'))
      ..status = AgentTaskStatus.cancelled
      ..lastError = '用户已停止任务。';
    await taskBox.put(task.id, task);
    await coordinator.retry(task.id);
    await _settle();
    expect(discussionRunner.runCount, greaterThan(0));
  });

  test('regression: ready discussion preserves missing tool request', () async {
    final task = _taskWithDiscussion(
        _task(id: 'audit-tool', conversationId: 'audit-group'),
        _discussionState(conversationId: 'audit-group'));
    final execution =
        jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    execution['toolMissing'] = true;
    task.executionStateJson = jsonEncode(execution);
    task.pendingToolRequestJson =
        '{"tool":"command.run","args":{"executable":"pandoc"}}';
    await coordinator.submit(task);
    await coordinator.updateDiscussionState(
        task.id,
        _discussionState(
            conversationId: 'audit-group',
            phase: WorkDiscussionPhase.ready,
            understandingPercent: 100));
    expect(task.pendingToolRequestJson, isNotEmpty);
  });

  test('invalid nested discussion can be rebuilt by explicit continue',
      () async {
    await coordinator.dispose();
    final discussionRunner = _FakeDiscussionRunner();
    coordinator = WorkTaskCoordinator(
        taskBox: taskBox,
        eventStore: eventStore,
        runner: runner,
        discussionRunner: discussionRunner);
    final task = _task(id: 'invalid-nested', conversationId: 'invalid-group')
      ..status = AgentTaskStatus.paused
      ..executionStateJson = '{"discussionState":{"schemaVersion":99}}';
    await taskBox.put(task.id, task);
    await coordinator.resumeByUser(task.id);
    await _settle();
    expect(WorkDiscussionState.fromExecutionState(task.executionStateJson),
        isNotNull);
    expect(discussionRunner.runCount, 1);
    expect(task.status, AgentTaskStatus.paused);
  });

  test('persists discussion wait and only runs after a ready transition',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-ready', conversationId: 'group-discussion'),
      _discussionState(
        conversationId: 'group-discussion',
        executorId: 'worker',
      ),
    );
    await coordinator.submit(task);

    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
    expect(taskBox.get(task.id)?.characterId, 'worker');
    expect(runner.startedTaskIds, isEmpty);
    final pending = WorkDiscussionState.fromExecutionState(
      taskBox.get(task.id)!.executionStateJson,
    )!;
    await coordinator.updateDiscussionState(
      task.id,
      pending.copyWith(
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        openQuestions: const [],
        blockers: const [],
      ),
    );
    expect(runner.startedTaskIds, [task.id]);
    runner.complete(task.id);
  });

  test('attachment-only delivery retry skips a fresh model credential gate',
      () async {
    final retryRunner = _DelayedDiscussionRunner();
    final localCoordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: retryRunner,
    );
    addTearDown(localCoordinator.dispose);

    final task = _taskWithDiscussion(
      _task(id: 'artifact-retry-gate', conversationId: 'group-artifact'),
      _discussionState(
        conversationId: 'group-artifact',
        executorId: 'worker',
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
      ),
    );
    task.executionStateJson = jsonEncode(<String, dynamic>{
      ...jsonDecode(task.executionStateJson) as Map<String, dynamic>,
      'artifactDeliveryNoticePublished': true,
      'artifactDeliveryRetryOnly': true,
      'artifactDeliveryMessageId': 'message-artifact-retry',
    });

    await localCoordinator.submit(task);
    await _waitForTaskState(
      taskBox,
      task.id,
      (value) => value.status == AgentTaskStatus.completed,
    );

    expect(retryRunner.validationCount, 0);
    expect(retryRunner.runCount, 1);
  });

  test('rejects external discussion overwrite and restarts a renewed revision',
      () async {
    final discussionRunner = _FakeDiscussionRunner();
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      discussionRunner: discussionRunner,
    );
    addTearDown(() async {
      if (!discussionRunner.release.isCompleted) {
        discussionRunner.release.complete();
      }
      await guarded.dispose();
    });
    final task = _taskWithDiscussion(
      _task(id: 'discussion-renew', conversationId: 'group-renew'),
      _discussionState(conversationId: 'group-renew'),
    );
    await guarded.submit(task);
    await discussionRunner.firstStarted.future;

    await expectLater(
      guarded.updateDiscussionState(
        task.id,
        _discussionState(conversationId: task.groupId),
      ),
      throwsStateError,
    );
    await guarded.enqueueFollowUp(task.id, '补充移动端验收边界');
    for (var attempt = 0; attempt < 100; attempt++) {
      if (discussionRunner.runCount >= 2) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(discussionRunner.runCount, 2);
    expect(
      WorkDiscussionState.fromExecutionState(
        taskBox.get(task.id)!.executionStateJson,
      )!
          .requestRevision,
      2,
    );
  });

  test('starts a renewed discussion when the old run already completed',
      () async {
    final discussionRunner = _CompletingBlockedDiscussionRunner();
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      discussionRunner: discussionRunner,
    );
    addTearDown(() => guarded.dispose());
    final task = _taskWithDiscussion(
      _task(
          id: 'discussion-renew-after-complete',
          conversationId: 'group-renew-after-complete'),
      _discussionState(conversationId: 'group-renew-after-complete'),
    );
    await guarded.submit(task);
    for (var attempt = 0; attempt < 100; attempt++) {
      if (discussionRunner.runCount >= 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(discussionRunner.runCount, 1);
    await guarded.enqueueFollowUp(task.id, '补充最终验收条件');
    for (var attempt = 0; attempt < 100; attempt++) {
      if (discussionRunner.runCount >= 2) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(discussionRunner.runCount, 2);
    expect(
      WorkDiscussionState.fromExecutionState(
        taskBox.get(task.id)!.executionStateJson,
      )!
          .requestRevision,
      2,
    );
  });

  test('discussion readiness never clears an independent tool approval gate',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-approval', conversationId: 'group-approval'),
      _discussionState(conversationId: 'group-approval'),
    );
    await coordinator.submit(task);
    final stored = taskBox.get(task.id)!;
    stored
      ..status = AgentTaskStatus.waitingForApproval
      ..pendingToolRequestJson =
          '{"tool":"workspace.patch","reason":"写入 Word 文档","args":{"path":"report.docx"}}';
    await taskBox.put(task.id, stored);

    final pending = WorkDiscussionState.fromExecutionState(
      stored.executionStateJson,
    )!;
    await coordinator.updateDiscussionState(
      task.id,
      pending.copyWith(
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        openQuestions: const [],
        blockers: const [],
      ),
    );

    final after = taskBox.get(task.id)!;
    expect(after.status, AgentTaskStatus.waitingForApproval);
    expect(after.pendingToolRequestJson, contains('workspace.patch'));
    expect(
      WorkDiscussionState.fromExecutionState(after.executionStateJson)!
          .isExecutionReady,
      isTrue,
    );
    expect(runner.startedTaskIds, isEmpty);
  });

  test('rejects 99 percent understanding before any runner/tool call',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-99', conversationId: 'group-99'),
      _discussionState(
        conversationId: 'group-99',
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 99,
      ),
    );
    await coordinator.submit(task);
    expect(runner.startedTaskIds, isEmpty);
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
  });

  test('rejects a nominally complete discussion with an open question',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-open', conversationId: 'group-open'),
      _discussionState(
        conversationId: 'group-open',
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        openQuestions: const ['Word 输出位置未确认'],
      ),
    );
    await coordinator.submit(task);
    expect(runner.startedTaskIds, isEmpty);
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
  });

  test('rejects an expired discussion revision and keeps the current state',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-stale', conversationId: 'group-stale'),
      _discussionState(
        conversationId: 'group-stale',
        requestRevision: 2,
      ),
    );
    await coordinator.submit(task);
    final before = WorkDiscussionState.fromExecutionState(
      taskBox.get(task.id)!.executionStateJson,
    )!;
    await expectLater(
      coordinator.updateDiscussionState(
        task.id,
        _discussionState(
          conversationId: 'group-stale',
          requestRevision: 1,
          phase: WorkDiscussionPhase.ready,
          understandingPercent: 100,
          blockers: const [],
        ),
      ),
      throwsStateError,
    );
    final after = WorkDiscussionState.fromExecutionState(
      taskBox.get(task.id)!.executionStateJson,
    )!;
    expect(after.requestRevision, before.requestRevision);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('rejects a discussion revision that skips an intermediate version',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-jump', conversationId: 'group-jump'),
      _discussionState(conversationId: 'group-jump'),
    );
    await coordinator.submit(task);
    final before = WorkDiscussionState.fromExecutionState(
      taskBox.get(task.id)!.executionStateJson,
    )!;
    await expectLater(
      coordinator.updateDiscussionState(
        task.id,
        before.copyWith(requestRevision: before.requestRevision + 2),
      ),
      throwsStateError,
    );
    final after = WorkDiscussionState.fromExecutionState(
      taskBox.get(task.id)!.executionStateJson,
    )!;
    expect(after.requestRevision, before.requestRevision);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('rejects an out-of-range in-memory discussion transition', () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-bounds', conversationId: 'group-bounds'),
      _discussionState(conversationId: 'group-bounds'),
    );
    await coordinator.submit(task);
    final current = WorkDiscussionState.fromExecutionState(
      taskBox.get(task.id)!.executionStateJson,
    )!;
    final invalid = WorkDiscussionState(
      conversationId: current.conversationId,
      phase: WorkDiscussionPhase.ready,
      requestRevision: current.requestRevision,
      executorId: current.executorId,
      candidateCharacterIds: current.candidateCharacterIds,
      participants: current.participants,
      understandingPercent: 101,
      understandingEvidence: const ['已确认需求'],
      deliverableContract: current.deliverableContract,
    );

    await expectLater(
      coordinator.updateDiscussionState(task.id, invalid),
      throwsStateError,
    );
    expect(runner.startedTaskIds, isEmpty);
    expect(
      WorkDiscussionState.fromExecutionState(
        taskBox.get(task.id)!.executionStateJson,
      )!
          .understandingPercent,
      current.understandingPercent,
    );
  });

  test('merges a follow-up into a pending discussion before execution',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-follow-up', conversationId: 'group-follow-up'),
      _discussionState(conversationId: 'group-follow-up'),
    );
    await coordinator.submit(task);
    await coordinator.enqueueFollowUp(task.id, '补充验收标准并保留 Word 格式');

    final stored = taskBox.get(task.id)!;
    final pending = WorkDiscussionState.fromExecutionState(
      stored.executionStateJson,
    )!;
    expect(stored.userRequest, contains('补充验收标准并保留 Word 格式'));
    expect(stored.queuedUserRequests, isEmpty);
    expect(pending.requestRevision, 2);
    expect(pending.phase, WorkDiscussionPhase.awaitingDiscussion);
    expect(runner.startedTaskIds, isEmpty);

    await coordinator.updateDiscussionState(
      task.id,
      pending.copyWith(
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        understandingEvidence: const ['执行人已纳入补充验收标准。'],
        openQuestions: const [],
        blockers: const [],
      ),
    );
    expect(runner.startedTaskIds, [task.id]);
    runner.complete(task.id);
  });

  test('does not apply a group discussion marker to private chat execution',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'dm-discussion-marker', conversationId: 'dm:worker'),
      _discussionState(conversationId: 'dm:worker'),
    );
    await coordinator.submit(task);
    expect(runner.startedTaskIds, [task.id]);
    runner.complete(task.id);
  });

  test('does not accept discussion state updates for private chats', () async {
    final task = _task(
      id: 'dm-discussion-update',
      conversationId: 'dm:worker',
    );
    await coordinator.submit(task);
    await expectLater(
      coordinator.updateDiscussionState(
        task.id,
        _discussionState(conversationId: task.groupId),
      ),
      throwsStateError,
    );
    runner.complete(task.id);
  });

  test('waits with an empty executor and never promotes a coordinator',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-no-executor', conversationId: 'group-election')
        ..characterId = '',
      _discussionState(
        conversationId: 'group-election',
        executorId: null,
      ),
    );
    await coordinator.submit(task);
    expect(taskBox.get(task.id)?.characterId, isEmpty);
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('a discussion wait survives coordinator restart without running',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-restart', conversationId: 'group-restart'),
      _discussionState(conversationId: 'group-restart'),
    );
    await coordinator.submit(task);
    await coordinator.dispose();

    final restarted = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
    );
    addTearDown(restarted.dispose);
    await restarted.restore();
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
    expect(runner.startedTaskIds, isEmpty);
    final pending = WorkDiscussionState.fromExecutionState(
      taskBox.get(task.id)!.executionStateJson,
    )!;
    await restarted.updateDiscussionState(
      task.id,
      pending.copyWith(
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        blockers: const [],
        openQuestions: const [],
      ),
    );
    expect(runner.startedTaskIds, [task.id]);
    runner.complete(task.id);
  });

  test('unknown execution checkpoint is paused before locks or runner start',
      () async {
    final task = _taskWithDiscussion(
      _task(
          id: 'unknown-execution-coordinator', conversationId: 'group-future'),
      _discussionState(
        conversationId: 'group-future',
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
      ),
    );
    final state = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    state['schemaVersion'] = 99;
    state['folderGrantPending'] = true;
    state['approvalDecision'] = 'approved';
    task.executionStateJson = jsonEncode(state);

    final locks = WorkResourceLockManager(isWindows: false);
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      resourceLockManager: locks,
    );
    addTearDown(guarded.dispose);
    await guarded.submit(
      task,
      resourceLocks: [
        const WorkResourceLockRequest(
          path: '/workspace/project',
          mode: WorkResourceLockMode.treeWrite,
        ),
      ],
    );

    final restored = taskBox.get(task.id)!;
    final execution = jsonDecode(restored.executionStateJson) as Map;
    expect(restored.status, AgentTaskStatus.paused);
    expect(restored.resumeRequired, isTrue);
    expect(runner.startedTaskIds, isEmpty);
    expect(locks.activeLockCount, 0);
    expect(execution['checkpointSchemaUnsupported'], isTrue);
    expect(execution['folderGrantPending'], isTrue);
    expect(execution, isNot(contains('approvalDecision')));
  });

  test('malformed execution checkpoint is paused before runner start',
      () async {
    final task = _task(
      id: 'malformed-execution-coordinator',
      conversationId: 'group-malformed-execution',
    )..executionStateJson = '{malformed execution checkpoint';

    await coordinator.submit(task);

    final restored = taskBox.get(task.id)!;
    final execution = jsonDecode(restored.executionStateJson) as Map;
    expect(restored.status, AgentTaskStatus.paused);
    expect(restored.resumeRequired, isTrue);
    expect(runner.startedTaskIds, isEmpty);
    expect(execution['schemaVersion'], 1);
    expect(execution['checkpointSchemaUnsupported'], isTrue);
  });

  test('resuming malformed group checkpoint reopens discussion before runner',
      () async {
    final task = _task(
      id: 'malformed-execution-resume-discussion',
      conversationId: 'group-malformed-resume',
    )..executionStateJson = '{malformed execution checkpoint';

    await coordinator.submit(task);
    await coordinator.resumeByUser(task.id);

    final restored = taskBox.get(task.id)!;
    final state = WorkDiscussionState.fromExecutionState(
      restored.executionStateJson,
    );
    expect(restored.status, AgentTaskStatus.paused);
    expect(restored.resumeRequired, isFalse);
    expect(state?.phase, WorkDiscussionPhase.awaitingDiscussion);
    expect(state?.isExecutionReady, isFalse);
    expect(
      jsonDecode(restored.executionStateJson),
      isNot(contains('checkpointSchemaUnsupported')),
    );
    expect(runner.startedTaskIds, isEmpty);
  });

  test('resuming an unsupported checkpoint drops an invalid discussion marker',
      () async {
    final task = _task(
      id: 'invalid-discussion-review-resume',
      conversationId: 'group-invalid-discussion-resume',
    )
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'schemaVersion': 99,
        'checkpointSchemaUnsupported': true,
        'discussionState': <String, dynamic>{'schemaVersion': 99},
      });
    await taskBox.put(task.id, task);

    await coordinator.resumeByUser(task.id);

    final restored = taskBox.get(task.id)!;
    final state = WorkDiscussionState.fromExecutionState(
      restored.executionStateJson,
    );
    expect(restored.status, AgentTaskStatus.paused);
    expect(state?.phase, WorkDiscussionPhase.awaitingDiscussion);
    expect(state?.isExecutionReady, isFalse);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('soft-limit continuation cannot bypass a missing group discussion',
      () async {
    final task = _task(
      id: 'malformed-soft-limit-discussion',
      conversationId: 'group-malformed-soft-limit',
    )
      ..status = AgentTaskStatus.paused
      ..softLimitReached = true
      ..resumeRequired = true
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'checkpointSchemaUnsupported': true,
      });
    await taskBox.put(task.id, task);

    await coordinator.continueAfterSoftLimit(task.id);

    final restored = taskBox.get(task.id)!;
    final state = WorkDiscussionState.fromExecutionState(
      restored.executionStateJson,
    );
    expect(restored.status, AgentTaskStatus.paused);
    expect(restored.softLimitReached, isFalse);
    expect(state?.phase, WorkDiscussionPhase.awaitingDiscussion);
    expect(state?.isExecutionReady, isFalse);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('restored approval wait keeps the conversation reserved', () async {
    final waiting = _taskWithDiscussion(
      _task(id: 'approval-restart', conversationId: 'group-approval-restart')
        ..status = AgentTaskStatus.waitingForApproval
        ..pendingToolRequestJson = jsonEncode({
          'tool': 'workspace.patch',
          'reason': '等待用户审批',
          'args': <String, dynamic>{},
        }),
      _discussionState(
        conversationId: 'group-approval-restart',
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        blockers: const [],
      ),
    );
    await taskBox.put(waiting.id, waiting);
    await coordinator.restore();

    final successor = _taskWithDiscussion(
      _task(id: 'approval-successor', conversationId: waiting.groupId),
      _discussionState(
        conversationId: waiting.groupId,
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        blockers: const [],
      ),
    );
    await coordinator.submit(successor);
    expect(runner.startedTaskIds, isEmpty);

    await coordinator.stop(waiting.id);
    await _waitForStartedCount(runner, 1);
    expect(runner.startedTaskIds, ['approval-successor']);
    runner.complete(successor.id);
  });

  test('cancelled discussion ignores a late ready transition', () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-cancel', conversationId: 'group-cancel')
        ..characterId = '',
      _discussionState(
        conversationId: 'group-cancel',
        executorId: null,
      ),
    );
    await coordinator.submit(task);
    await coordinator.stop(task.id);
    await expectLater(
      coordinator.updateDiscussionState(
        task.id,
        _discussionState(
          conversationId: 'group-cancel',
          phase: WorkDiscussionPhase.ready,
          understandingPercent: 100,
          blockers: const [],
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(runner.startedTaskIds, isEmpty);
  });

  test('stopping during an async discussion gate cannot resurrect the task',
      () async {
    final delayedRunner = _DelayedDiscussionRunner();
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: delayedRunner,
      requireFolderGrant: true,
    );
    addTearDown(() async {
      if (!delayedRunner.releaseValidation.isCompleted) {
        delayedRunner.releaseValidation.complete();
      }
      await guarded.dispose();
    });

    final task = _taskWithDiscussion(
      _task(id: 'discussion-stop-race', conversationId: 'group-stop-race'),
      _discussionState(
        conversationId: 'group-stop-race',
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
      ),
    );
    await guarded.submit(task);
    await delayedRunner.validationStarted.future;

    await guarded.stop(task.id);
    delayedRunner.releaseValidation.complete();
    await _settle();

    expect(taskBox.get(task.id)?.status, AgentTaskStatus.cancelled);
    expect(delayedRunner.runCount, 0);
  });

  test('cross-group discussion state is paused and cannot execute', () async {
    final task = _taskWithDiscussion(
      _task(id: 'discussion-cross-group', conversationId: 'group-a'),
      _discussionState(
        conversationId: 'group-b',
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        blockers: const [],
      ),
    );
    await coordinator.submit(task);
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('cannot replace a persisted cross-group discussion marker', () async {
    final task = _task(
      id: 'discussion-cross-group-update',
      conversationId: 'group-update-a',
    )..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        _discussionState(
          conversationId: 'group-update-b',
          executorId: 'worker',
        ),
      );
    await taskBox.put(task.id, task);
    await coordinator.restore();

    final before = taskBox.get(task.id)!.executionStateJson;
    await expectLater(
      coordinator.updateDiscussionState(
        task.id,
        _discussionState(
          conversationId: task.groupId,
          requestRevision: 2,
          phase: WorkDiscussionPhase.ready,
          understandingPercent: 100,
        ),
      ),
      throwsStateError,
    );
    expect(taskBox.get(task.id)?.executionStateJson, before);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('malformed discussion state cannot be replaced by a follow-up',
      () async {
    final task = _task(
      id: 'discussion-malformed-follow-up',
      conversationId: 'group-malformed',
    )..executionStateJson = jsonEncode({
        'discussionState': <String, dynamic>{'schemaVersion': 99},
      });
    await coordinator.submit(task);
    await coordinator.enqueueFollowUp(task.id, '补充要求');
    final stored = taskBox.get(task.id)!;
    expect(stored.status, AgentTaskStatus.paused);
    expect(stored.userRequest, '执行 discussion-malformed-follow-up');
    expect(
      WorkDiscussionState.decodeExecutionState(stored.executionStateJson)
          .isValid,
      isFalse,
    );
    expect(runner.startedTaskIds, isEmpty);
  });

  test('restore supplements an old unfinished task without claiming discussion',
      () async {
    final task = _task(id: 'legacy-discussion', conversationId: 'group-legacy')
      ..status = AgentTaskStatus.runningTool
      ..completedOperations = <String>['已完成的旧读取']
      ..executionStateJson = '';
    await taskBox.put(task.id, task);
    await coordinator.restore();
    final restored = taskBox.get(task.id)!;
    final state = WorkDiscussionState.fromExecutionState(
      restored.executionStateJson,
    );
    expect(state, isNotNull);
    expect(state!.phase, WorkDiscussionPhase.awaitingDiscussion);
    expect(state.isExecutionReady, isFalse);
    expect(restored.status, AgentTaskStatus.paused);
    expect(restored.lastError, contains('补充群讨论'));
    expect(restored.completedOperations, ['已完成的旧读取']);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('restore gates old failed work without rewriting completed outcomes',
      () async {
    final failed = _task(id: 'legacy-failed', conversationId: 'group-legacy')
      ..status = AgentTaskStatus.failed
      ..completedOperations = <String>['旧任务已完成的读取']
      ..pendingToolRequestJson =
          '{"tool":"workspace.patch","args":{"path":"report.docx"}}'
      ..lastError = '旧目录授权已失效';
    final partial =
        _task(id: 'legacy-partial', conversationId: 'group-legacy-partial')
          ..status = AgentTaskStatus.partiallyCompleted
          ..completedOperations = <String>['旧任务已完成的转换']
          ..resultSummary = '已生成旧的中间产物';
    final completed =
        _task(id: 'legacy-completed', conversationId: 'group-completed')
          ..status = AgentTaskStatus.completed
          ..resultSummary = '历史任务已完成';

    await taskBox.put(failed.id, failed);
    await taskBox.put(partial.id, partial);
    await taskBox.put(completed.id, completed);
    await coordinator.restore();

    for (final task in [failed, partial]) {
      final restored = taskBox.get(task.id)!;
      final state = WorkDiscussionState.fromExecutionState(
        restored.executionStateJson,
      );
      expect(restored.status, AgentTaskStatus.paused);
      expect(state?.phase, WorkDiscussionPhase.awaitingDiscussion);
      expect(state?.isExecutionReady, isFalse);
      expect(restored.completedOperations, isNotEmpty);
    }
    expect(taskBox.get(failed.id)!.lastError, '旧目录授权已失效');
    expect(taskBox.get(partial.id)!.lastError, '旧任务需要补充群讨论后才能继续。');
    final restoredCompleted = taskBox.get(completed.id)!;
    expect(restoredCompleted.status, AgentTaskStatus.completed);
    expect(restoredCompleted.executionStateJson, isEmpty);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('restored discussion gate hides and then restores a stale approval',
      () async {
    final task = _taskWithDiscussion(
      _task(id: 'legacy-approval-discussion', conversationId: 'group-approval'),
      _discussionState(conversationId: 'group-approval'),
    )
      ..status = AgentTaskStatus.waitingForApproval
      ..pendingToolRequestJson =
          '{"tool":"workspace.patch","args":{"path":"report.docx"}}';
    await taskBox.put(task.id, task);

    await coordinator.restore();
    final restored = taskBox.get(task.id)!;
    expect(restored.status, AgentTaskStatus.paused);
    expect(
      WorkTaskUserAction.forTask(restored).where(
          (action) => action.kind == WorkTaskUserActionKind.approveCommand),
      isEmpty,
    );
    await expectLater(coordinator.approve(task.id), throwsStateError);

    final pending = WorkDiscussionState.fromExecutionState(
      restored.executionStateJson,
    )!;
    await coordinator.updateDiscussionState(
      task.id,
      pending.copyWith(
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        openQuestions: const [],
        blockers: const [],
      ),
    );
    final ready = taskBox.get(task.id)!;
    expect(ready.status, AgentTaskStatus.waitingForApproval);
    expect(
      WorkTaskUserAction.forTask(ready).where(
          (action) => action.kind == WorkTaskUserActionKind.approveCommand),
      hasLength(1),
    );
    await coordinator.approve(task.id);
    await _waitForStartedCount(runner, 1);
    expect(runner.startedTaskIds, [task.id]);
    runner.complete(task.id);
  });

  test('unversioned folder action cannot target an unrelated approval',
      () async {
    final settingsBox =
        await Hive.openBox<dynamic>('app_settings-folder-unversioned');
    var pickerCalls = 0;
    final grants = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
    );
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      folderGrantService: grants,
      folderPicker: () async {
        pickerCalls++;
        return directory.path;
      },
      folderGrantConsent: (_) async => true,
    );
    addTearDown(() async {
      await guarded.dispose();
      await settingsBox.deleteFromDisk();
    });
    final task = _task(
      id: 'folder-unversioned-approval',
      conversationId: 'group-folder-unversioned',
    )
      ..status = AgentTaskStatus.waitingForApproval
      ..pendingToolRequestJson =
          '{"tool":"workspace.patch","args":{"path":"report.docx"}}';
    await taskBox.put(task.id, task);

    await expectLater(
      guarded.requestFolderForTask(task.id),
      throwsStateError,
    );
    expect(pickerCalls, 0);
    expect(taskBox.get(task.id)!.status, AgentTaskStatus.waitingForApproval);
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

  test('repairs the script named by a prior command failure without pausing',
      () async {
    final task = _task(id: 'failed-ppt-conversion', conversationId: 'group-ppt')
      ..status = AgentTaskStatus.failed
      ..lastArtifactPaths = [
        '/workspace/催眠心理学报告.md',
        '/workspace/create_lucid_dream_ppt.py',
      ];
    WorkFailure.persistOnTask(
      task,
      WorkFailure.fromToolResult(
        const WorkToolResult.failed(
          message: '命令退出码为 1。',
          data: <String, dynamic>{
            'commandDisplay': 'python3 create_lucid_dream_ppt.py',
            'artifactPaths': <String>[
              '/workspace/催眠心理学报告.md',
              '/workspace/create_lucid_dream_ppt.py',
            ],
            'stderr': 'SyntaxError: invalid syntax',
          },
          failureCode: 'commandFailed',
        ),
      ),
    );
    await taskBox.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '请修复之前的 PPT 转换问题');

    final resumed = taskBox.get(task.id)!;
    expect(resumed.status, AgentTaskStatus.planning);
    expect(resumed.queuedUserRequests, isEmpty);
    expect(resumed.executionStateJson,
        contains('/workspace/create_lucid_dream_ppt.py'));
    expect(resumed.executionStateJson, contains('"autoRenameIfExists":false'));
    expect(runner.startedTaskIds, [task.id]);
  });

  test('recovers an already-paused repair clarification from its checkpoint',
      () async {
    final task = _task(
      id: 'paused-failed-ppt-conversion',
      conversationId: 'group-paused-ppt',
    )
      ..status = AgentTaskStatus.paused
      ..lastError = '请明确要修改的文件路径。'
      ..queuedUserRequests = ['请修复之前的 PPT 转换问题']
      ..lastArtifactPaths = [
        '/workspace/催眠心理学报告.md',
        '/workspace/create_lucid_dream_ppt.py',
      ];
    WorkFailure.persistOnTask(
      task,
      const WorkFailure(
        type: WorkFailureType.commandFailed,
        title: '命令执行未完成',
        reason: '命令退出码为 1。',
        technicalDetail:
            '命令：python3 create_lucid_dream_ppt.py；退出码：1；stderr：SyntaxError',
        completedContent: <String>[],
        retryable: false,
        suggestedAction: '请检查命令和工作目录后重新规划。',
      ),
    );
    task.executionStateJson = jsonEncode({
      ...jsonDecode(task.executionStateJson) as Map<String, dynamic>,
      'followUpKind': WorkFollowUpKind.clarification.name,
      'clarificationQuestion': '请明确要修改的文件路径。',
    });
    await taskBox.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '请修复之前的 PPT 转换问题');

    final resumed = taskBox.get(task.id)!;
    expect(resumed.status, AgentTaskStatus.planning);
    expect(resumed.queuedUserRequests, isEmpty);
    expect(resumed.executionStateJson,
        contains('/workspace/create_lucid_dream_ppt.py'));
    expect(runner.startedTaskIds, [task.id]);
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

  test('creates a fresh discussion task for a new-artifact follow-up',
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

    final source = taskBox.get(task.id)!;
    expect(source.status, AgentTaskStatus.completed);
    expect(source.userRequest, '执行 fresh-artifact-plan');
    expect(source.plan, '旧飞行棋计划');
    expect(source.lastArtifactPaths, ['/workspace/flight-chess.html']);
    final fresh = taskBox.values
        .where((item) =>
            item.id != task.id &&
            item.groupId == 'group-doc' &&
            item.workModeTask)
        .single;
    expect(fresh.userRequest, '设计并实现一个 html 教师节贺卡');
    expect(fresh.characterId, isEmpty);
    expect(fresh.plan, isEmpty);
    expect(fresh.lastArtifactPaths, isEmpty);
    expect(fresh.status, AgentTaskStatus.paused);
    final context = jsonDecode(fresh.contextSummary) as Map<String, dynamic>;
    expect(context['target'], '设计并实现一个 html 教师节贺卡');
    expect(context['artifactPaths'], isEmpty);
    expect(runner.startedTaskIds, isEmpty);
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

  test('manual resume refreshes the role capability snapshot', () async {
    final task = _task(
      id: 'refresh-role-capabilities',
      conversationId: 'dm:worker',
    )
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..requestedPermissions = <ToolPermission>[
        ToolPermission.skillCreate,
      ];
    await taskBox.put(task.id, task);

    await coordinator.resumeByUser(task.id);
    await _waitForStartedCount(runner, 1);

    expect(taskBox.get(task.id)!.requestedPermissions, isEmpty);
    runner.complete(task.id);
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

  test('two concurrent install actions share one trusted installer run',
      () async {
    final command = WorkCommand(
      executable: 'pandoc',
      workingDirectory: '/tmp',
      declaredImpact: const [],
    );
    runner.installResult = WorkCommandResult(
      command: command,
      status: WorkCommandRunStatus.completed,
      message: 'pandoc 已安装',
      stdout: '',
      stderr: '',
      exitCode: 0,
      elapsed: Duration.zero,
      outputTruncated: false,
      policy: WorkCommandPolicyResult(
        command: command,
        impact: WorkCommandImpact.readOnly,
        allowed: true,
        requiresApproval: false,
        requiresSeparateConfirmation: false,
        requiresExplicitRequest: false,
        reason: '测试安装结果',
      ),
    );
    final task = _task(id: 'install-idempotent', conversationId: 'group-test')
      ..status = AgentTaskStatus.paused
      ..pendingToolRequestJson = jsonEncode({
        'tool': 'command.run',
        'args': {'executable': 'pandoc'},
      })
      ..executionStateJson = jsonEncode({'toolMissing': true});
    await taskBox.put(task.id, task);

    final first = coordinator.installMissingTool(task.id);
    final second = coordinator.installMissingTool(task.id);
    await _waitForStartedCount(runner, 1);
    expect(runner.installCalls, 1);
    runner.complete(task.id);
    await Future.wait<void>([first, second]);
    expect(runner.installCalls, 1);
  });

  test('does not apply a late install result to a revised checkpoint',
      () async {
    final command = WorkCommand(
      executable: 'pandoc',
      workingDirectory: '/tmp',
      declaredImpact: const [],
    );
    final installGate = Completer<WorkCommandResult>();
    runner.installGate = installGate;
    final task = _task(id: 'install-stale', conversationId: 'group-test')
      ..status = AgentTaskStatus.paused
      ..pendingToolRequestJson = jsonEncode({
        'tool': 'command.run',
        'args': {'executable': 'pandoc'},
      })
      ..executionStateJson = jsonEncode({'toolMissing': true});
    await taskBox.put(task.id, task);
    final action = WorkTaskUserAction.forTask(task, isMacOS: true).single;

    final install = coordinator.installMissingTool(
      task.id,
      expectedActionVersion: action.version,
    );
    await _waitForInstallCall(runner);

    // A new command request replaces the durable checkpoint while the
    // package manager is still running. The old result must become inert.
    final revised = taskBox.get(task.id)!;
    revised.pendingToolRequestJson = jsonEncode({
      'tool': 'command.run',
      'args': {'executable': 'tectonic'},
    });
    await taskBox.put(revised.id, revised);

    installGate.complete(
      WorkCommandResult(
        command: command,
        status: WorkCommandRunStatus.completed,
        message: 'pandoc 已安装',
        stdout: '',
        stderr: '',
        exitCode: 0,
        elapsed: Duration.zero,
        outputTruncated: false,
        policy: WorkCommandPolicyResult(
          command: command,
          impact: WorkCommandImpact.readOnly,
          allowed: true,
          requiresApproval: false,
          requiresSeparateConfirmation: false,
          requiresExplicitRequest: false,
          reason: '测试安装结果',
        ),
      ),
    );
    await install;
    await _settle();

    final after = taskBox.get(task.id)!;
    expect(after.status, AgentTaskStatus.paused);
    expect(after.executionStateJson, contains('toolMissing'));
    expect(after.pendingToolRequestJson, contains('tectonic'));
    expect(runner.startedTaskIds, isEmpty);
  });

  test('stopping a task cancels an in-flight tool installation', () async {
    final command = WorkCommand(
      executable: 'pandoc',
      workingDirectory: '/tmp',
      declaredImpact: const [],
    );
    final installGate = Completer<WorkCommandResult>();
    runner.installGate = installGate;
    final task = _task(id: 'install-stop', conversationId: 'group-test')
      ..status = AgentTaskStatus.paused
      ..pendingToolRequestJson = jsonEncode({
        'tool': 'command.run',
        'args': {'executable': 'pandoc'},
      })
      ..executionStateJson = jsonEncode({'toolMissing': true});
    await taskBox.put(task.id, task);
    final action = WorkTaskUserAction.forTask(task, isMacOS: true).single;
    final install = coordinator.installMissingTool(
      task.id,
      expectedActionVersion: action.version,
    );
    await _waitForInstallCall(runner);

    await coordinator.stop(task.id);
    expect(runner.installCancellation?.isCancelled, isTrue);
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.cancelled);

    installGate.complete(
      WorkCommandResult(
        command: command,
        status: WorkCommandRunStatus.completed,
        message: 'pandoc 已安装',
        stdout: '',
        stderr: '',
        exitCode: 0,
        elapsed: Duration.zero,
        outputTruncated: false,
        policy: WorkCommandPolicyResult(
          command: command,
          impact: WorkCommandImpact.readOnly,
          allowed: true,
          requiresApproval: false,
          requiresSeparateConfirmation: false,
          requiresExplicitRequest: false,
          reason: '测试安装结果',
        ),
      ),
    );
    await install;
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.cancelled);
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
    expect(taskBox.get(task.id)?.characterId, 'worker');
    expect(jsonDecode(task.executionStateJson)['visionModelCharacterId'],
        'vision-character');
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

  test('approval checkpoint opens a wait window for the time budget', () async {
    await coordinator
        .submit(_task(id: 'approval-wait', conversationId: 'group-a'));

    await coordinator.pauseForApproval(
      'approval-wait',
      pendingToolRequestJson: '{"tool":"workspace.patch"}',
    );

    final execution = Map<String, dynamic>.from(
      jsonDecode(taskBox.get('approval-wait')!.executionStateJson) as Map,
    );
    expect(WorkTaskBudgetWait.startedAtOf(execution), isNotNull);
    expect(
      execution[WorkTaskBudgetWait.totalKey],
      isNull,
      reason: '等待尚未结束，还没有可抵扣的时长。',
    );
  });

  test('stopping records the queued follow-ups it discards', () async {
    await coordinator
        .submit(_task(id: 'stop-drops', conversationId: 'group-a'));
    await coordinator.enqueueFollowUp('stop-drops', '改成第二版');
    await coordinator.enqueueFollowUp('stop-drops', '再补一个附录');
    expect(
      taskBox.get('stop-drops')?.queuedUserRequests,
      ['改成第二版', '再补一个附录'],
    );

    await coordinator.stop('stop-drops');
    await _settle();

    final stored = taskBox.get('stop-drops');
    expect(stored?.status, AgentTaskStatus.cancelled);
    expect(stored?.queuedUserRequests, isEmpty);
    final events = (await eventStore.read('stop-drops')).events;
    final dropped =
        events.where((event) => event.title.contains('未执行')).toList();
    expect(dropped, hasLength(1), reason: '丢弃的追问必须留下可追溯的记录。');
    expect(dropped.single.detail, contains('改成第二版'));
    expect(dropped.single.detail, contains('再补一个附录'));
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

  test('approval action rejects a stale chat reminder version', () async {
    final task = _task(id: 'approval-stale-action', conversationId: 'group-a')
      ..status = AgentTaskStatus.waitingForApproval
      ..pendingToolRequestJson = jsonEncode({
        'tool': 'workspace.patch',
        'args': {'path': 'old.docx'},
      });
    await taskBox.put(task.id, task);
    final action = WorkTaskUserAction.forTask(task).single;

    task.pendingToolRequestJson = jsonEncode({
      'tool': 'workspace.patch',
      'args': {'path': 'new.docx'},
    });
    await taskBox.put(task.id, task);

    await expectLater(
      coordinator.approve(
        task.id,
        expectedActionVersion: action.version,
      ),
      throwsStateError,
    );
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.waitingForApproval);
  });

  test('two concurrent approval entrances share one checkpoint decision',
      () async {
    final task = _task(id: 'approval-idempotent', conversationId: 'group-a');
    await taskBox.put(task.id, task);
    await coordinator.pauseForApproval(
      'approval-idempotent',
      pendingToolRequestJson:
          '{"tool":"workspace.patch","args":{"path":"report.md"}}',
    );
    final action =
        WorkTaskUserAction.forTask(taskBox.get('approval-idempotent')!).single;

    final first = coordinator.approve(
      'approval-idempotent',
      expectedActionVersion: action.version,
    );
    final second = coordinator.approve(
      'approval-idempotent',
      expectedActionVersion: action.version,
    );
    await Future.wait<void>([first, second]);
    await _waitForStartedCount(runner, 1);
    await _waitForTaskState(
      taskBox,
      task.id,
      (current) => current.status == AgentTaskStatus.planning,
    );

    expect(
        taskBox.get('approval-idempotent')?.status, AgentTaskStatus.planning);
    expect(runner.startedTaskIds, ['approval-idempotent']);
    runner.complete('approval-idempotent');
  });

  test('two concurrent folder entrances share one native picker', () async {
    final settingsBox =
        await Hive.openBox<dynamic>('app_settings-folder-action');
    var pickerCalls = 0;
    final grants = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
    );
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      folderGrantService: grants,
      folderPicker: () async {
        pickerCalls++;
        return directory.path;
      },
      folderGrantConsent: (_) async => true,
    );
    addTearDown(() => guarded.dispose());
    final task = _task(id: 'folder-idempotent', conversationId: 'group-folder')
      ..status = AgentTaskStatus.paused
      ..executionStateJson = jsonEncode({'folderGrantPending': true});
    await taskBox.put(task.id, task);
    final action = WorkTaskUserAction.forTask(task).single;

    final first = guarded.requestFolderForTask(
      task.id,
      expectedActionVersion: action.version,
    );
    final second = guarded.requestFolderForTask(
      task.id,
      expectedActionVersion: action.version,
    );
    await Future.wait<void>([first, second]);
    await _waitForStartedCount(runner, 1);
    await _waitForTaskState(
      taskBox,
      task.id,
      (current) => current.status == AgentTaskStatus.planning,
    );

    expect(pickerCalls, 1);
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.planning);
    expect(runner.startedTaskIds, [task.id]);
    runner.complete(task.id);
  });

  test('stopping a folder picker leaves a late grant unable to revive the task',
      () async {
    final settingsBox =
        await Hive.openBox<dynamic>('app_settings-folder-stop-race');
    final pickerGate = Completer<String?>();
    var pickerCalls = 0;
    final grants = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
    );
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      folderGrantService: grants,
      folderPicker: () {
        pickerCalls++;
        return pickerGate.future;
      },
      folderGrantConsent: (_) async => true,
    );
    addTearDown(() async {
      if (!pickerGate.isCompleted) pickerGate.complete(null);
      await guarded.dispose();
      await settingsBox.deleteFromDisk();
    });

    final task = _task(id: 'folder-stop-race', conversationId: 'group-folder')
      ..status = AgentTaskStatus.paused
      ..executionStateJson = jsonEncode({'folderGrantPending': true});
    await taskBox.put(task.id, task);
    final action = WorkTaskUserAction.forTask(task).single;
    final request = guarded.requestFolderForTask(
      task.id,
      expectedActionVersion: action.version,
    );
    for (var attempt = 0; attempt < 200 && pickerCalls == 0; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(pickerCalls, 1);

    await guarded.stop(task.id).timeout(const Duration(seconds: 1));
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.cancelled);

    pickerGate.complete(directory.path);
    await request;
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.cancelled);
    expect(runner.startedTaskIds, isEmpty);
  });

  test('a shared folder result requeues a different waiting task', () async {
    final settingsBox =
        await Hive.openBox<dynamic>('app_settings-folder-cross-task');
    final pickerGate = Completer<String?>();
    var pickerCalls = 0;
    final grants = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
    );
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      folderGrantService: grants,
      folderPicker: () {
        pickerCalls++;
        return pickerGate.future;
      },
      folderGrantConsent: (_) async => true,
    );
    addTearDown(() async {
      if (!pickerGate.isCompleted) pickerGate.complete(null);
      await guarded.dispose();
    });

    await guarded.submit(
      _task(id: 'folder-owner', conversationId: 'folder-owner-group'),
    );
    for (var attempt = 0; attempt < 200; attempt++) {
      if (pickerCalls == 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(pickerCalls, 1);

    final waiting =
        _task(id: 'folder-consumer', conversationId: 'folder-consumer-group')
          ..status = AgentTaskStatus.waitingForApproval
          ..executionStateJson = jsonEncode({'folderGrantPending': true});
    await taskBox.put(waiting.id, waiting);
    final action = WorkTaskUserAction.forTask(waiting).single;
    final request = guarded.requestFolderForTask(
      waiting.id,
      expectedActionVersion: action.version,
    );

    pickerGate.complete(directory.path);
    await request;
    await _waitForStartedCount(runner, 2);

    expect(pickerCalls, 1);
    expect(
      taskBox.get(waiting.id)?.status,
      anyOf(AgentTaskStatus.queued, AgentTaskStatus.planning),
    );
    expect(runner.startedTaskIds, contains(waiting.id));
    runner.complete('folder-owner');
    runner.complete(waiting.id);
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
    // The runner has published a terminal-looking checkpoint, but the
    // coordinator still owns the execution slot. Keep the follow-up durable
    // and untouched until the old run has actually released that slot.
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.completed);
    expect(taskBox.get(task.id)?.queuedUserRequests, ['修改刚才的结果']);
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

  test('a late checkpoint after stop cannot rewrite or complete the task',
      () async {
    final lateRunner = _LateCheckpointRunner();
    final guarded = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: lateRunner,
    );
    addTearDown(() async {
      if (!lateRunner.release.isCompleted) lateRunner.release.complete();
      await guarded.dispose();
    });

    final task = _task(id: 'late-checkpoint', conversationId: 'group-late');
    await guarded.submit(task);
    await lateRunner.started.future;
    await guarded.stop(task.id);

    final stale = AgentTask(
      id: task.id,
      groupId: task.groupId,
      characterId: task.characterId,
      userRequest: task.userRequest,
      workModeTask: true,
      status: AgentTaskStatus.runningTool,
      contextSummary: 'stale runner context',
    );
    await lateRunner.checkpoint!(stale);
    if (!lateRunner.release.isCompleted) lateRunner.release.complete();
    await _settle();

    final stored = taskBox.get(task.id)!;
    expect(stored.status, AgentTaskStatus.cancelled);
    expect(stored.contextSummary, isNot('stale runner context'));
    expect(stored.contextSummary, isNot(contains('已完成，可继续追问')));
    final events = await eventStore.read(task.id);
    expect(
      events.events.where((event) => event.kind == WorkTaskEventKind.completed),
      isEmpty,
    );
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

  test('reauthorize rebuilds a terminal missing-scope task from its checkpoint',
      () async {
    final oldStart = DateTime.utc(2026, 7, 15, 12);
    final task = _task(
      id: 'missing-scope-recovery',
      conversationId: 'dm:worker',
    )
      ..status = AgentTaskStatus.failed
      ..startedAt = oldStart
      ..completedOperations = <String>[
        '{"tool":"skill.download","args":{"templateId":"frontend.interactive-artifact"}}',
      ]
      ..lastArtifactPaths = <String>['/Users/fengye/Desktop/已有产物.html']
      ..contextSummary = const WorkContextBuilder().build(
        conversationId: 'dm:worker',
        target: '生成新的交付文件',
        approvalScope: <String, dynamic>{
          'taskId': 'missing-scope-recovery',
          'entries': <Map<String, dynamic>>[
            <String, dynamic>{'path': '/Users/fengye/Desktop/旧范围.html'},
          ],
        },
      ).toJsonString()
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'approvalDecision': 'approvedWithoutUndo',
        'approvalCapability': 'mutation',
        'approvalConsumed': true,
      });
    WorkFailure.persistOnTask(
      task,
      WorkFailure.fromToolFailure(
        code: 'notApproved',
        message: '审批范围缺失，已要求任务重新生成变更计划。',
      ),
    );
    await taskBox.put(task.id, task);

    await coordinator.reauthorizeTask(task.id);
    await _waitForStartedCount(runner, 1);

    final recovered = taskBox.get(task.id)!;
    expect(recovered.status, AgentTaskStatus.planning);
    expect(recovered.startedAt, isNot(oldStart));
    expect(recovered.completedOperations, hasLength(1));
    expect(recovered.lastArtifactPaths, ['/Users/fengye/Desktop/已有产物.html']);
    expect(recovered.pendingToolRequestJson, isEmpty);
    expect(recovered.executionStateJson, isNot(contains('approvalDecision')));
    expect(
      (jsonDecode(recovered.contextSummary) as Map)['approvalScope'],
      isNull,
    );
    runner.complete(task.id);
  });

  test('reauthorize removes stale approval scope from a legacy summary',
      () async {
    final task = _task(
      id: 'legacy-missing-scope-recovery',
      conversationId: 'dm:legacy-worker',
    )
      ..status = AgentTaskStatus.failed
      ..contextSummary = jsonEncode(<String, dynamic>{
        'goal': '旧任务目标',
        'approvalScope': <String, dynamic>{
          'taskId': 'legacy-missing-scope-recovery',
          'entries': const <Map<String, dynamic>>[],
        },
      });
    WorkFailure.persistOnTask(
      task,
      WorkFailure.fromToolFailure(
        code: 'notApproved',
        message: '审批范围缺失，已要求任务重新生成变更计划。',
      ),
    );
    await taskBox.put(task.id, task);

    await coordinator.reauthorizeTask(task.id);
    await _waitForStartedCount(runner, 1);

    final recovered = taskBox.get(task.id)!;
    expect(recovered.contextSummary, isNot(contains('approvalScope')));
    runner.complete(task.id);
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
    expect(taskBox.get(waiting.id)?.status, AgentTaskStatus.paused);
    _markDiscussionReady(taskBox.get(waiting.id)!);
    await taskBox.put(waiting.id, taskBox.get(waiting.id)!);

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
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
    _markDiscussionReady(taskBox.get(task.id)!);
    await taskBox.put(task.id, taskBox.get(task.id)!);
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

    expect(taskBox.get(orphaned.id)?.status, AgentTaskStatus.paused);
    expect(taskBox.get(orphaned.id)?.resumeRequired, isFalse);
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
