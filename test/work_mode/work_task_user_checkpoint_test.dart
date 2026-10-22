import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_overlay_host.dart';
import 'package:flutter/material.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_task_completion_choice.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_task_requirements_confirmation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';
import 'work_candidate_test_support.dart';

class _Runner
    implements
        WorkTaskRunner,
        WorkTaskCheckpointReporter,
        WorkTaskCollaborationExecutor,
        WorkTaskUserCandidateDelivery {
  late Future<void> Function(AgentTask) checkpoint;
  final started = Completer<void>();
  final finishAction = Completer<void>();
  int actions = 0;
  int deliveries = 0;
  @override
  void setTaskCheckpointSink(Future<void> Function(AgentTask) sink) =>
      checkpoint = sink;
  @override
  Future<bool> prepareCollaborationWork(AgentTask task) async => true;
  @override
  Future<void> commitCollaborationDelivery(AgentTask task,
      {bool Function()? hasArrivingInput}) async {}
  @override
  Future<bool> deliverUserConfirmedCandidate(AgentTask task,
      {bool Function()? hasArrivingInput}) async {
    deliveries++;
    return true;
  }

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    started.complete();
    await finishAction.future;
    actions++;
    await checkpoint(task); // One atomic action is durable before pausing.
    if (cancellation.isCancelled) return;
    actions++;
  }
}

class _FreezingRunner extends _Runner {
  _FreezingRunner(this.frozenCheckpoint);
  final String frozenCheckpoint;
  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    task.executionStateJson = frozenCheckpoint;
    task.status = AgentTaskStatus.paused;
    await checkpoint(task);
    started.complete();
    await finishAction.future;
  }
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('安全停点未及时到达');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory dir;
  late DatabaseService db;
  late WorkTaskEventStore events;
  late WorkTaskCoordinator coordinator;
  late _Runner runner;
  setUp(() async {
    dir = await openLifecycleHive();
    db = DatabaseService();
    events = WorkTaskEventStore(
        appSupportDirectory: Directory('${dir.path}/support'));
    runner = _Runner();
    coordinator = WorkTaskCoordinator(
        taskBox: db.agentTaskBox, eventStore: events, runner: runner);
  });
  tearDown(() async {
    if (!runner.finishAction.isCompleted) runner.finishAction.complete();
    await coordinator.dispose();
    await events.close();
    await closeLifecycleHive(dir, db);
  });

  AgentTask frozen() {
    final state = candidateTestState();
    final raw = state.toJson()
      ..['phase'] = 'verifying'
      ..['iterations'] = [
        {
          'id': 'r001',
          'artifactDigest': 'digest-a',
          'requestRevision': 1,
          'teamRevision': 1,
          'manifestRef': 'candidate:r001',
          'reviewRef': '',
          'status': 'candidate',
        }
      ];
    return candidateTestTask(WorkCollaborationState.tryParse(raw)!)
      ..status = AgentTaskStatus.paused;
  }

  test(
      'a confirmation with attachments is a supplement rather than authorization',
      () {
    final task = frozen();
    WorkTaskRequirementsConfirmation.requireForCurrentRequest(task);
    expect(
        WorkTaskRequirementsConfirmation.acceptsMessage(task, '确认需求'), isTrue);
    for (final text in ['确认', '同意', '接受', '我确认当前需求', '确认！']) {
      expect(
          WorkTaskRequirementsConfirmation.acceptsMessage(task, text), isTrue,
          reason: text);
    }
    for (final text in ['不确认', '确认需', '确认但增加按钮', '是否同意需求']) {
      expect(
          WorkTaskRequirementsConfirmation.acceptsMessage(task, text), isFalse,
          reason: text);
    }
    expect(
        WorkTaskRequirementsConfirmation.acceptsMessage(task, '确认需求',
            hasAttachments: true),
        isFalse);
  });

  test('暂停等当前动作落盘，不执行下一动作；补充原文及附件保留且不自启', () async {
    final task = candidateTestTask(candidateTestState());
    await coordinator.submit(task);
    await runner.started.future.timeout(const Duration(seconds: 3));
    await coordinator.pauseForSupplement(task.id);
    expect(runner.actions, 0);
    await coordinator.enqueueFollowUp(task.id, '增加导出按钮',
        sourceMessageId: 'supplement-message',
        attachmentMessageId: 'supplement-message');
    runner.finishAction.complete();
    await _until(() => !coordinator.isTaskInFlight(task.id));
    expect(runner.actions, 1);
    expect(task.status, AgentTaskStatus.paused);
    expect(WorkTaskCompletionChoice.paused(task), isTrue);
    expect(WorkTaskRequirementsConfirmation.isCurrent(task), isTrue);
    expect(task.userRequest, contains('增加导出按钮'));
    expect(task.executionStateJson, contains('supplement-message'));
  });

  for (final phase in ['forming', 'producing']) {
    testWidgets('补充暂停后可从$phase阶段继续', (tester) async {
      final raw = candidateTestState().toJson()..['phase'] = phase;
      if (phase == 'forming') raw['plan'] = '';
      final task = candidateTestTask(WorkCollaborationState.tryParse(raw)!)
        ..status = AgentTaskStatus.paused
        ..resumeRequired = false;
      WorkTaskCompletionChoice.setPaused(task, true);
      var continued = false;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: WorkTaskPanel(
        tasks: [task],
        eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
        onSelectTask: (_) {},
        onStop: (_) {},
        onContinue: (_) => continued = true,
        onOpenConversation: (_) {},
        onCollapse: () {},
        onClose: () {},
      ))));
      final button = find.byKey(const Key('work-task-continue'));
      expect(button, findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(find.textContaining('需要你操作：点击继续'), findsOneWidget);
      expect(find.textContaining('疑似停滞'), findsNothing);
      await tester.tap(button);
      await tester.pump();
      expect(continued, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('冻结后的面板提供确认入口，普通继续不能绕过选择', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkTaskPanel(
      tasks: [frozen()],
      eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
      onSelectTask: (_) {},
      onStop: (_) {},
      onContinue: (_) {},
      onOpenConversation: (_) {},
      onCollapse: () {},
      onClose: () {},
      onCompletionChoice: (_) {},
      onSupplement: (_) {},
    ))));
    await tester.pump();
    expect(
        find.byKey(const Key('work-task-completion-choice')), findsOneWidget);
    final continueButton = find.byKey(const Key('work-task-continue'));
    if (continueButton.evaluate().isNotEmpty) {
      expect(tester.widget<FilledButton>(continueButton).onPressed, isNull);
    }
    expect(find.byKey(const Key('work-task-supplement')), findsOneWidget);
  });

  testWidgets('completion prompt waits for runner cleanup then opens once',
      (tester) async {
    await coordinator.dispose();
    await tester.runAsync(() async {
      runner = _FreezingRunner(frozen().executionStateJson);
      coordinator = WorkTaskCoordinator(
          taskBox: db.agentTaskBox, eventStore: events, runner: runner);
    });
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseServiceProvider.overrideWithValue(db)],
      child: MaterialApp(
          navigatorKey: navigator,
          home: WorkTaskOverlayHost(
            coordinator: coordinator,
            eventStore: events,
            navigatorKey: navigator,
            child: const Scaffold(body: Text('chat')),
          )),
    ));
    final task = candidateTestTask(candidateTestState());
    await tester.runAsync(() async {
      await coordinator.submit(task);
      await runner.started.future.timeout(const Duration(seconds: 3));
    });
    await tester.pump();
    expect(coordinator.isTaskInFlight(task.id), isTrue);
    expect(WorkTaskCompletionChoice.pending(task), isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('work-task-completion-dialog')), findsNothing);
    await tester.runAsync(() async {
      runner.finishAction.complete();
      await _until(() => !coordinator.isTaskInFlight(task.id));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
        find.byKey(const Key('work-task-completion-dialog')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('直接交付通过协调器完结，过期弹窗不能提交', () async {
    final task = frozen();
    await db.agentTaskBox.put(task.id, task);
    final identity = WorkTaskCompletionChoice.identity(task)!;
    await expectLater(
        coordinator.chooseCandidateCompletion(task.id, 'stale', test: false),
        throwsStateError);
    expect(runner.deliveries, 0);
    await coordinator.chooseCandidateCompletion(task.id, identity, test: false);
    expect(runner.deliveries, 1);
    expect(task.status, AgentTaskStatus.completed);
    expect(task.resultSummary, contains('未经过本轮测试'));
    expect(runner.started.isCompleted, isFalse);
  });

  test('关闭补充窗口后仍保持暂停；显式选择测试才排队', () async {
    final task = frozen();
    await db.agentTaskBox.put(task.id, task);
    await coordinator.pauseForSupplement(task.id);
    expect(task.status, AgentTaskStatus.paused);
    expect(runner.started.isCompleted, isFalse);
    await coordinator.chooseCandidateCompletion(
        task.id, WorkTaskCompletionChoice.identity(task)!,
        test: true);
    expect(WorkTaskCompletionChoice.choice(task), 'test');
    expect(WorkTaskCompletionChoice.paused(task), isFalse);
    await runner.started.future.timeout(const Duration(seconds: 3));
  });
}
