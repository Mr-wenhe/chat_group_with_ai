import 'dart:async';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_overlay_host.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTask _task({
  required String id,
  required String conversationId,
  required String characterId,
  String request = '整理发布说明',
  int currentStep = 3,
  int actionLimit = 8,
  DateTime? startedAt,
  String plan = '先读取项目结构，再整理发布说明。',
  String resultSummary = '',
}) {
  return AgentTask(
    id: id,
    groupId: conversationId,
    characterId: characterId,
    userRequest: request,
    currentStep: currentStep,
    actionLimit: actionLimit,
    startedAt: startedAt ?? DateTime.utc(2026, 8, 28, 10),
    plan: plan,
    resultSummary: resultSummary,
    workModeTask: true,
  );
}

void main() {
  group('WorkTaskPanel', () {
    testWidgets('shows public task details and streamed events in sequence',
        (tester) async {
      final events = StreamController<WorkTaskEvent>.broadcast();
      addTearDown(events.close);
      final task = _task(
        id: 'task-one',
        conversationId: 'group-one',
        characterId: 'product-owner',
        resultSummary: '发布说明已整理完成。',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => events.stream,
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
            clock: () => DateTime.utc(2026, 8, 28, 10, 2),
          ),
        ),
      ));

      expect(find.text('整理发布说明'), findsOneWidget);
      expect(find.text('执行角色：product-owner'), findsOneWidget);
      expect(find.text('步骤 3 / 8'), findsOneWidget);
      expect(find.text('已执行 2 分钟'), findsOneWidget);
      expect(find.text('先读取项目结构，再整理发布说明。'), findsOneWidget);
      expect(find.text('发布说明已整理完成。'), findsOneWidget);

      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 1,
        timestamp: DateTime.utc(2026, 8, 28, 10, 1),
        kind: WorkTaskEventKind.stepStarted,
        title: '正在读取项目配置',
        safeMetadata: const <String, Object?>{'tool': 'read_text'},
      ));
      await tester.pump();
      await tester.pump();
      expect(find.text('当前动作：正在读取项目配置'), findsOneWidget);
      expect(find.text('工具：read_text'), findsOneWidget);

      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 2,
        timestamp: DateTime.utc(2026, 8, 28, 10, 2),
        kind: WorkTaskEventKind.toolOutput,
        title: '已读取 pubspec.yaml',
        detail: '发现 3 个待确认配置。',
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('当前动作：正在读取项目配置'), findsOneWidget);
      expect(find.text('工具：read_text'), findsOneWidget);
      expect(find.text('已读取 pubspec.yaml'), findsOneWidget);
      expect(find.text('发现 3 个待确认配置。'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('正在读取项目配置')).dy,
        lessThan(tester.getTopLeft(find.text('已读取 pubspec.yaml')).dy),
      );
    });

    testWidgets('switches between two tasks and keeps task details isolated',
        (tester) async {
      final taskOne = _task(
        id: 'task-one',
        conversationId: 'group-one',
        characterId: 'product-owner',
        request: '整理需求',
      );
      final taskTwo = _task(
        id: 'task-two',
        conversationId: 'group-two',
        characterId: 'developer',
        request: '实现面板',
      );
      var selectedTaskId = taskOne.id;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => WorkTaskPanel(
              tasks: <AgentTask>[taskOne, taskTwo],
              selectedTaskId: selectedTaskId,
              eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
              onSelectTask: (taskId) => setState(() => selectedTaskId = taskId),
              onStop: (_) {},
              onContinue: (_) {},
              onOpenConversation: (_) {},
              onCollapse: () {},
              onClose: () {},
            ),
          ),
        ),
      ));

      expect(find.text('整理需求'), findsOneWidget);
      expect(find.text('实现面板'), findsNothing);

      await tester.tap(find.byKey(const Key('work-task-tab-task-two')));
      await tester.pump();

      expect(find.text('实现面板'), findsOneWidget);
      expect(find.text('执行角色：developer'), findsOneWidget);
      expect(find.text('整理需求'), findsNothing);
    });

    testWidgets('shows approval controls, role names, and safe public text',
        (tester) async {
      final task = _task(
        id: 'approval-task',
        conversationId: 'group-one',
        characterId: 'worker-id',
        plan: '读取 /Users/alice/project.md；https://private.example/token',
        resultSummary: 'https://private.example/result?token=secret',
      )..status = AgentTaskStatus.waitingForApproval;
      var approved = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onApprove: (_) async {
              approved = true;
              throw StateError('https://private.example/api?token=secret');
            },
            onReject: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
            characterNameFor: (_) => '产品经理',
          ),
        ),
      ));

      expect(find.text('执行角色：产品经理'), findsOneWidget);
      expect(find.text('执行角色：worker-id'), findsNothing);
      expect(find.byKey(const Key('work-task-approve')), findsOneWidget);
      expect(find.byKey(const Key('work-task-reject')), findsOneWidget);
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('secret'), findsNothing);

      await tester.tap(find.byKey(const Key('work-task-approve')));
      await tester.pump();
      await tester.pump();

      expect(approved, isTrue);
      expect(find.text('操作失败'), findsOneWidget);
      expect(find.textContaining('https://'), findsNothing);
      expect(find.textContaining('secret'), findsNothing);
    });

    testWidgets('shows a retryable error when the event stream fails',
        (tester) async {
      final task = _task(
        id: 'stream-error-task',
        conversationId: 'group-one',
        characterId: 'developer',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => Stream<WorkTaskEvent>.error(
              StateError('读取 https://private.example/log 失败'),
            ),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('执行动态读取失败'), findsOneWidget);
      expect(find.byKey(const Key('work-task-event-retry')), findsOneWidget);
      expect(find.textContaining('https://'), findsNothing);
    });
  });

  group('WorkTaskOverlayHost', () {
    testWidgets('collapse and hide do not stop the running task',
        (tester) async {
      final task = _task(
        id: 'running-task',
        conversationId: 'group-one',
        characterId: 'developer',
      );
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      final taskEvents = StreamController<WorkTaskEvent>.broadcast();
      final stoppedTaskIds = <String>[];
      addTearDown(taskUpdates.close);
      addTearDown(taskEvents.close);
      var childTapCount = 0;

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => taskEvents.stream,
          onStopTask: (taskId) async => stoppedTaskIds.add(taskId),
          onContinueTask: (_) async {},
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => childTapCount += 1,
              child: const Text('设置页内容仍可点击'),
            ),
          ),
        ),
      ));
      taskUpdates.add(<AgentTask>[task]);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('work-task-panel')), findsOneWidget);
      await tester.tap(find.text('设置页内容仍可点击'));
      expect(childTapCount, 1);
      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();
      expect(find.byKey(const Key('work-task-mini-bar')), findsOneWidget);
      expect(stoppedTaskIds, isEmpty);

      await tester.tap(find.byKey(const Key('work-task-mini-bar')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('work-task-close')));
      await tester.pump();

      expect(find.byKey(const Key('work-task-reopen')), findsOneWidget);
      expect(stoppedTaskIds, isEmpty);
      expect(find.text('设置页内容仍可点击'), findsOneWidget);

      await tester.tap(find.byKey(const Key('work-task-reopen')));
      await tester.pump();
      expect(find.byKey(const Key('work-task-panel')), findsOneWidget);
      expect(stoppedTaskIds, isEmpty);
    });

    testWidgets(
        'stop is separate from hiding and cancels only the selected task',
        (tester) async {
      final task = _task(
        id: 'stop-task',
        conversationId: 'group-one',
        characterId: 'developer',
      );
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      final taskEvents = StreamController<WorkTaskEvent>.broadcast();
      final stoppedTaskIds = <String>[];
      addTearDown(taskUpdates.close);
      addTearDown(taskEvents.close);

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => taskEvents.stream,
          onStopTask: (taskId) async => stoppedTaskIds.add(taskId),
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[task]);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('work-task-stop')));
      await tester.pump();

      expect(stoppedTaskIds, <String>[task.id]);
    });

    testWidgets('uses a bottom non-modal panel in a narrow window',
        (tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      final taskEvents = StreamController<WorkTaskEvent>.broadcast();
      addTearDown(taskUpdates.close);
      addTearDown(taskEvents.close);

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => taskEvents.stream,
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[
        _task(
          id: 'narrow-task',
          conversationId: 'group-one',
          characterId: 'developer',
        ),
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('work-task-panel-bottom')), findsOneWidget);
      expect(find.byKey(const Key('work-task-panel-wide')), findsNothing);
    });

    testWidgets('keeps both active execution slots visible', (tester) async {
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      final first = _task(
        id: 'active-one',
        conversationId: 'group-one',
        characterId: 'developer',
      )..status = AgentTaskStatus.runningTool;
      final second = _task(
        id: 'active-two',
        conversationId: 'group-two',
        characterId: 'tester',
      )..status = AgentTaskStatus.planning;
      final newerQueued = _task(
        id: 'newer-queued',
        conversationId: 'group-three',
        characterId: 'product',
      )..status = AgentTaskStatus.queued;

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[newerQueued, first, second]);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('work-task-tab-active-one')), findsOneWidget);
      expect(find.byKey(const Key('work-task-tab-active-two')), findsOneWidget);
      expect(find.byKey(const Key('work-task-tab-newer-queued')), findsNothing);
    });
  });
}
