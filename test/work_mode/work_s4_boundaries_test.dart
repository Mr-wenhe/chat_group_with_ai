import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_task_clarification.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _NoopRunner implements WorkTaskRunner {
  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {}
}

class _VersionedDiscussionRunner implements WorkTaskDiscussionRunner {
  final Completer<void> firstStarted = Completer<void>();
  final Completer<void> secondStarted = Completer<void>();
  final Completer<void> releaseFirst = Completer<void>();
  final List<int> revisions = <int>[];

  @override
  Future<void> runDiscussion(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkTaskDiscussionStateSink updateState,
  ) async {
    final current = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    revisions.add(current.requestRevision);
    if (revisions.length == 1) {
      firstStarted.complete();
      await Future.any<void>([
        releaseFirst.future,
        cancellation.whenCancelled,
      ]);
      // Simulate a late model conclusion. The coordinator must reject this
      // stale revision even if the runner ignores the cancellation signal.
      try {
        await updateState(
          current.copyWith(
            phase: WorkDiscussionPhase.ready,
            understandingPercent: 100,
            understandingEvidence: const ['旧版本结论'],
            openQuestions: const [],
            blockers: const [],
          ),
        );
      } on Object {
        // The expected path is a rejected stale revision.
      }
      return;
    }
    secondStarted.complete();
    await cancellation.whenCancelled;
  }
}

class _ImmediateRevisionDiscussionRunner implements WorkTaskDiscussionRunner {
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
    )!;
    if (cancellation.isCancelled) return;
    await updateState(
      current.copyWith(
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        understandingEvidence: const ['修订目标、方案和交付位置已重新确认。'],
        openQuestions: const [],
        blockers: const [],
      ),
    );
  }
}

class _RecordingRunner implements WorkTaskRunner {
  final List<String> requests = <String>[];
  final List<List<String>> artifactPaths = <List<String>>[];
  final List<String> attachmentIds = <String>[];
  final List<Completer<void>> _completions = <Completer<void>>[];
  final List<Completer<void>> _started = <Completer<void>>[];

  Future<void> startedAt(int index) {
    if (_started.length > index) return _started[index].future;
    while (_started.length <= index) {
      _started.add(Completer<void>());
    }
    return _started[index].future;
  }

  void completeAt(int index) {
    final completion = _completions[index];
    if (!completion.isCompleted) completion.complete();
  }

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    final index = requests.length;
    requests.add(task.userRequest);
    artifactPaths.add(List<String>.from(task.lastArtifactPaths));
    final metadata = _decode(task.executionStateJson);
    attachmentIds.add((metadata['attachmentMessageId'] ?? '').toString());
    final completion = Completer<void>();
    _completions.add(completion);
    while (_started.length <= index) {
      _started.add(Completer<void>());
    }
    _started[index].complete();
    await Future.any<void>([completion.future, cancellation.whenCancelled]);
  }

  Map<String, dynamic> _decode(String raw) {
    final value = raw.trim().isEmpty ? null : jsonDecode(raw);
    return value is Map
        ? Map<String, dynamic>.from(value)
        : <String, dynamic>{};
  }
}

class _TerminalCheckpointRunner implements WorkTaskRunner {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    // A production loop can publish a terminal-looking checkpoint before its
    // coordinator finalizer releases the run slot.  Follow-ups must still
    // remain FIFO until that finalizer owns the durable transition.
    task.status = AgentTaskStatus.completed;
    started.complete();
    await Future.any<void>([release.future, cancellation.whenCancelled]);
  }
}

class _HoldingDiscussionRunner implements WorkTaskDiscussionRunner {
  final Completer<String> started = Completer<String>();
  final List<WorkDiscussionState> states = <WorkDiscussionState>[];

  @override
  Future<void> runDiscussion(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkTaskDiscussionStateSink updateState,
  ) async {
    final state = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    );
    if (state != null) states.add(state);
    if (!started.isCompleted) started.complete(task.id);
    await cancellation.whenCancelled;
  }
}

AgentTask _task(
  String id,
  String conversationId, {
  String characterId = 'worker',
  AgentTaskStatus status = AgentTaskStatus.planning,
}) {
  return AgentTask(
    id: id,
    groupId: conversationId,
    characterId: characterId,
    userRequest: '执行 $id',
    status: status,
    workModeTask: true,
  );
}

WorkDiscussionState _readyDiscussion({
  required String conversationId,
  required String executorId,
  int requestRevision = 1,
  String format = 'docx',
  String revisionTarget = '',
}) {
  final candidates = <String>[executorId];
  return WorkDiscussionState.initial(
    conversationId: conversationId,
    requestRevision: requestRevision,
    executorId: executorId,
    candidateCharacterIds: candidates,
    participantCharacterIds: candidates,
    deliverableContract: <String, dynamic>{
      'deliverableType': 'document',
      'format': format,
      'location': 'desktop',
      'contentScope': '执行 $conversationId',
      'explicitExecutorId': executorId,
      'revisionTarget': revisionTarget,
      'requestRevision': requestRevision,
    },
  ).copyWith(
    phase: WorkDiscussionPhase.ready,
    understandingPercent: 100,
    understandingEvidence: const ['目标/范围、方案取舍、格式位置和验收已确认。'],
    openQuestions: const [],
    blockers: const [],
  );
}

void _attachDiscussion(AgentTask task, WorkDiscussionState state) {
  task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
    task.executionStateJson,
    state,
  );
}

Future<({Box<AgentTask> box, Directory directory, WorkTaskEventStore events})>
    _openStorage(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  Hive.init(directory.path);
  if (!Hive.isAdapterRegistered(12)) {
    Hive.registerAdapter(AgentTaskStatusAdapter());
  }
  if (!Hive.isAdapterRegistered(13)) {
    Hive.registerAdapter(AgentTaskAdapter());
  }
  final box = await Hive.openBox<AgentTask>('s4-agent-tasks');
  final events = WorkTaskEventStore(
    appSupportDirectory: Directory('${directory.path}/app-support'),
  );
  return (box: box, directory: directory, events: events);
}

Future<void> _closeStorage(
  ({
    Box<AgentTask> box,
    Directory directory,
    WorkTaskEventStore events
  }) storage,
  WorkTaskCoordinator coordinator,
) async {
  await coordinator.dispose();
  await storage.events.close();
  await Hive.close();
  if (await storage.directory.exists()) {
    await storage.directory.delete(recursive: true);
  }
}

void main() {
  test('A10 merges an in-flight discussion supplement and rejects stale finish',
      () async {
    final storage = await _openStorage('work-s4-a10-');
    final discussion = _VersionedDiscussionRunner();
    final coordinator = WorkTaskCoordinator(
      taskBox: storage.box,
      eventStore: storage.events,
      runner: _NoopRunner(),
      discussionRunner: discussion,
    );
    addTearDown(() => _closeStorage(storage, coordinator));

    final task = _task('a10', 'group-a10', characterId: '')
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'attachmentMessageId': 'attachment-initial',
      });
    _attachDiscussion(
      task,
      _readyDiscussion(
        conversationId: 'group-a10',
        executorId: 'worker',
      ).copyWith(
        phase: WorkDiscussionPhase.awaitingDiscussion,
        understandingPercent: 40,
        understandingEvidence: const ['初步范围'],
        blockers: const ['discussionRequired'],
      ),
    );
    await coordinator.submit(task);
    await discussion.firstStarted.future;

    await coordinator.enqueueFollowUp(
      task.id,
      '补充移动端验收边界',
      attachmentMessageId: 'attachment-a10',
    );
    final renewed = storage.box.get(task.id)!;
    final renewedState = WorkDiscussionState.fromExecutionState(
      renewed.executionStateJson,
    )!;
    expect(renewedState.requestRevision, 2);
    expect(renewed.userRequest, contains('补充移动端验收边界'));
    expect(renewed.executionStateJson, contains('attachment-a10'));
    expect(renewed.executionStateJson, contains('attachment-initial'));
    expect(renewedState.isExecutionReady, isFalse);

    discussion.releaseFirst.complete();
    await discussion.secondStarted.future;
    expect(discussion.revisions, [1, 2]);
  });

  test('A13 keeps same-file revisions and attachments in FIFO order', () async {
    final storage = await _openStorage('work-s4-a13-');
    final runner = _RecordingRunner();
    final discussion = _ImmediateRevisionDiscussionRunner();
    final coordinator = WorkTaskCoordinator(
      taskBox: storage.box,
      eventStore: storage.events,
      runner: runner,
      discussionRunner: discussion,
    );
    addTearDown(() => _closeStorage(storage, coordinator));

    final task = _task('a13', 'group-a13');
    task.userRequest = '生成报告';
    task.lastArtifactPaths = ['/workspace/report.docx'];
    _attachDiscussion(
      task,
      _readyDiscussion(
        conversationId: 'group-a13',
        executorId: 'worker',
        revisionTarget: '/workspace/report.docx',
      ),
    );
    await coordinator.submit(task);
    await runner.startedAt(0);

    await coordinator.enqueueFollowUp(
      task.id,
      '请修改 /workspace/report.docx 的中文标题',
      attachmentMessageId: 'attachment-cn',
    );
    await coordinator.enqueueFollowUp(
      task.id,
      'Please revise /workspace/report.docx with the English title',
      attachmentMessageId: 'attachment-en',
    );
    expect(storage.box.get(task.id)!.queuedUserRequests, hasLength(2));
    expect(storage.box.get(task.id)!.executionStateJson,
        contains('attachment-cn'));
    expect(storage.box.get(task.id)!.executionStateJson,
        contains('attachment-en'));

    runner.completeAt(0);
    await runner.startedAt(1);
    expect(runner.artifactPaths[1], ['/workspace/report.docx']);
    expect(runner.attachmentIds[1], 'attachment-cn');
    runner.completeAt(1);
    await runner.startedAt(2);
    expect(runner.artifactPaths[2], ['/workspace/report.docx']);
    expect(runner.attachmentIds[2], 'attachment-en');
    expect(runner.requests[1], contains('中文标题'));
    expect(runner.requests[2], contains('English title'));
    runner.completeAt(2);
  });

  test('terminal-looking in-flight checkpoint keeps follow-up queued',
      () async {
    final storage = await _openStorage('work-s4-terminal-checkpoint-');
    final runner = _TerminalCheckpointRunner();
    final coordinator = WorkTaskCoordinator(
      taskBox: storage.box,
      eventStore: storage.events,
      runner: runner,
    );
    addTearDown(() => _closeStorage(storage, coordinator));

    final task = _task('terminal-checkpoint-s4', 'group-terminal-checkpoint');
    await coordinator.submit(task);
    await runner.started.future;
    expect(storage.box.get(task.id)!.status, AgentTaskStatus.completed);

    await coordinator.enqueueFollowUp(task.id, '继续完善刚才的文档');
    final queued = storage.box.get(task.id)!;
    expect(queued.status, AgentTaskStatus.completed);
    expect(queued.queuedUserRequests, ['继续完善刚才的文档']);

    runner.release.complete();
  });

  test('A20 splits a completed explicit new task and reopens role discussion',
      () async {
    final storage = await _openStorage('work-s4-a20-');
    final discussion = _HoldingDiscussionRunner();
    final coordinator = WorkTaskCoordinator(
      taskBox: storage.box,
      eventStore: storage.events,
      runner: _NoopRunner(),
      discussionRunner: discussion,
    );
    addTearDown(() => _closeStorage(storage, coordinator));

    final source = _task(
      'a20-source',
      'group-a20',
      characterId: 'old-owner',
      status: AgentTaskStatus.completed,
    )
      ..plan = '旧计划'
      ..lastArtifactPaths = ['/workspace/old.html'];
    await storage.box.put(source.id, source);

    await coordinator.enqueueFollowUp(source.id, '新建一个 html 教师节页面');
    final fresh = storage.box.values
        .where((task) => task.groupId == source.groupId && task.id != source.id)
        .single;
    expect(source.status, AgentTaskStatus.completed);
    expect(source.characterId, 'old-owner');
    expect(fresh.id, isNot(source.id));
    expect(fresh.characterId, isEmpty);
    expect(fresh.assignedCharacterIds, isEmpty);
    expect(fresh.lastArtifactPaths, isEmpty);
    expect(fresh.plan, isEmpty);
    final state = WorkDiscussionState.fromExecutionState(
      fresh.executionStateJson,
    )!;
    expect(state.executorId, isNull);
    expect(state.requestRevision, 1);
    expect(state.deliverableContract?['format'], 'html');
    expect(coordinator.taskForConversation(source.groupId)?.id, fresh.id);
    expect(await discussion.started.future, fresh.id);
  });

  test('a group-elected owner is re-elected after a revision', () async {
    final storage = await _openStorage('work-s4-re-election-');
    final discussion = _HoldingDiscussionRunner();
    final coordinator = WorkTaskCoordinator(
      taskBox: storage.box,
      eventStore: storage.events,
      runner: _NoopRunner(),
      discussionRunner: discussion,
    );
    addTearDown(() => _closeStorage(storage, coordinator));

    final task = _task(
      're-election-s4',
      'group-re-election-s4',
      characterId: 'old-owner',
      status: AgentTaskStatus.completed,
    )
      ..lastArtifactPaths = ['/workspace/old.docx']
      ..assignedCharacterIds = <String>['old-owner'];
    final groupElected = _readyDiscussion(
      conversationId: task.groupId,
      executorId: 'old-owner',
      format: 'docx',
      revisionTarget: '/workspace/old.docx',
    ).copyWith(
      deliverableContract: <String, dynamic>{
        ..._readyDiscussion(
          conversationId: task.groupId,
          executorId: 'old-owner',
          format: 'docx',
          revisionTarget: '/workspace/old.docx',
        ).deliverableContract!,
        'explicitExecutorId': null,
      },
    );
    _attachDiscussion(task, groupElected);
    await storage.box.put(task.id, task);

    await coordinator.enqueueFollowUp(
      task.id,
      '请修改 /workspace/old.docx 的标题',
    );
    await discussion.started.future;

    final stored = storage.box.get(task.id)!;
    expect(stored.characterId, isEmpty);
    expect(stored.assignedCharacterIds, isEmpty);
    expect(discussion.states, hasLength(1));
    expect(discussion.states.single.executorId, isNull);
    expect(discussion.states.single.requestRevision, 2);
  });

  test(
      'model clarification answer resumes a ready group task without a new task',
      () async {
    final storage = await _openStorage('work-s4-model-clarify-');
    final runner = _RecordingRunner();
    final coordinator = WorkTaskCoordinator(
      taskBox: storage.box,
      eventStore: storage.events,
      runner: runner,
    );
    addTearDown(() => _closeStorage(storage, coordinator));

    final task = _task(
      'model-clarify-s4',
      'group-model-clarify-s4',
      characterId: 'worker',
      status: AgentTaskStatus.paused,
    )
      ..resumeRequired = true
      ..lastError = '请选择要保留的章节？';
    _attachDiscussion(
      task,
      _readyDiscussion(
        conversationId: task.groupId,
        executorId: 'worker',
      ),
    );
    WorkTaskClarification.markPending(task, '请选择要保留的章节？');
    await storage.box.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '保留摘要和验收章节');
    await runner.startedAt(0);
    final stored = storage.box.get(task.id)!;
    expect(stored.id, task.id);
    expect(stored.status, AgentTaskStatus.planning);
    expect(stored.executionStateJson, contains('discussionState'));
    expect(stored.executionStateJson, isNot(contains('clarificationRequired')));
    expect(runner.requests.single, contains('保留摘要和验收章节'));
  });

  test('model clarification answer preserves later FIFO inputs and attachments',
      () async {
    final storage = await _openStorage('work-s4-model-clarify-fifo-');
    final runner = _RecordingRunner();
    final coordinator = WorkTaskCoordinator(
      taskBox: storage.box,
      eventStore: storage.events,
      runner: runner,
    );
    addTearDown(() => _closeStorage(storage, coordinator));

    final task = _task(
      'model-clarify-fifo-s4',
      'group-model-clarify-fifo-s4',
      characterId: 'worker',
      status: AgentTaskStatus.paused,
    )
      ..resumeRequired = true
      ..lastError = '请选择要保留的章节？'
      ..queuedUserRequests = <String>['后续追问保留']
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'clarificationRequired': true,
        'clarificationQuestion': '请选择要保留的章节？',
        'queuedAttachmentMessageIds': ['attachment-later'],
      });
    _attachDiscussion(
      task,
      _readyDiscussion(
        conversationId: task.groupId,
        executorId: 'worker',
      ),
    );
    WorkTaskClarification.markPending(task, '请选择要保留的章节？');
    await storage.box.put(task.id, task);

    await coordinator.enqueueFollowUp(
      task.id,
      '保留摘要和验收章节',
      attachmentMessageId: 'attachment-answer',
    );
    await runner.startedAt(0);

    final stored = storage.box.get(task.id)!;
    expect(stored.queuedUserRequests, ['后续追问保留']);
    expect(runner.requests.single, contains('保留摘要和验收章节'));
    final metadata = jsonDecode(stored.executionStateJson) as Map;
    expect(metadata['attachmentMessageId'], 'attachment-answer');
    expect(metadata['queuedAttachmentMessageIds'], ['attachment-later']);
    runner.completeAt(0);
  });

  test('approval scope changes invalidate the old operation checkpoint',
      () async {
    final storage = await _openStorage('work-s4-approval-');
    final coordinator = WorkTaskCoordinator(
      taskBox: storage.box,
      eventStore: storage.events,
      runner: _NoopRunner(),
    );
    addTearDown(() => _closeStorage(storage, coordinator));

    final task = _task('approval-s4', 'group-approval-s4')
      ..status = AgentTaskStatus.waitingForApproval
      ..pendingToolRequestJson = '{"tool":"workspace.patch"}'
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'approvalDecision': 'approved',
        'approvalPromptShown': true,
        'approvalPlan': <String, dynamic>{
          'exactPaths': ['/workspace/old.md']
        },
        'approvalScope': <String, dynamic>{
          'exactPaths': ['/workspace/old.md']
        },
      });
    _attachDiscussion(
      task,
      _readyDiscussion(
        conversationId: task.groupId,
        executorId: 'worker',
        revisionTarget: '/workspace/old.md',
      ),
    );
    await storage.box.put(task.id, task);

    await coordinator.enqueueFollowUp(task.id, '请修改 /workspace/old.md');
    final stored = storage.box.get(task.id)!;
    expect(stored.pendingToolRequestJson, isEmpty);
    expect(stored.executionStateJson, isNot(contains('approvalDecision')));
    expect(stored.executionStateJson, isNot(contains('approvalPromptShown')));
    expect(stored.executionStateJson, isNot(contains('approvalScope')));
    expect(
      WorkDiscussionState.fromExecutionState(stored.executionStateJson)!
          .requestRevision,
      2,
    );
  });

  test(
      'conversation task lookup prefers a non-terminal owner over a newer result',
      () async {
    final storage = await _openStorage('work-s4-lookup-');
    final coordinator = WorkTaskCoordinator(
      taskBox: storage.box,
      eventStore: storage.events,
      runner: _NoopRunner(),
    );
    addTearDown(() => _closeStorage(storage, coordinator));
    final active =
        _task('active', 'group-lookup', status: AgentTaskStatus.paused)
          ..updatedAt = DateTime(2026, 1, 1);
    final completed = _task(
      'completed',
      'group-lookup',
      status: AgentTaskStatus.completed,
    )..updatedAt = DateTime(2030, 1, 1);
    await storage.box.put(active.id, active);
    await storage.box.put(completed.id, completed);

    expect(coordinator.taskForConversation('group-lookup')?.id, active.id);
  });
}
