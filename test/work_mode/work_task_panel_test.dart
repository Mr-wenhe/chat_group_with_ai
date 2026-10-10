import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/message.dart';
// 任务胶囊与聊天页共用右上角，几何断言要量会话控件行的真实高度。
import 'package:chat_group/features/chat_group/widgets/compact_conversation_controls.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_bubble.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_overlay_host.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_decision_dialog.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_pill_position.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_change_policy.dart';
import 'package:chat_group/features/work_mode/work_task_action_notice.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_decision.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_task_run_boundary.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_overlay_controller.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/conversation_presence_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import '../helpers/lifecycle_hive.dart';

/// Keeps a submitted task in flight so a test can drive its own checkpoints.
class _HoldingWorkTaskRunner implements WorkTaskRunner {
  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) =>
      cancellation.whenCancelled;
}

/// Pumps frames until [finder] matches, allowing Hive I/O between frames.
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) =>
    _pumpUntil(
      tester,
      () => finder.evaluate().isNotEmpty,
      maxFrames: maxFrames,
      // 保留"命中即返回"的旧语义：用 finder 等待的可能是瞬态 widget，
      // 多等一轮会让它消失后才返回。
      requireStable: false,
      reason: '$finder 未在 $maxFrames 帧内出现',
    );

/// 有界轮询：等到 [condition] 成立（超时后让 expect 给出失败原因）。
///
/// 不用固定 sleep：全量套件并行时 50ms 常常不够，会变成与改动无关的假失败。
/// 条件成立后**再多排空一轮真实异步**——Hive 的写入在值可见之后才 resolve，
/// 触发它的动作要等它返回才会解除忙碌状态，立刻返回会让后续点击落在禁用按钮上。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxFrames = 120,
  String? reason,
  bool requireStable = true,
}) async {
  var satisfied = false;
  for (var frame = 0; frame < maxFrames; frame++) {
    if (condition()) {
      if (satisfied || !requireStable) return;
      satisfied = true;
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(condition(), isTrue, reason: reason);
}

AgentTask _task({
  required String id,
  required String conversationId,
  required String characterId,
  String request = '整理发布说明',
  int currentStep = 3,
  int actionCount = 3,
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
    actionCount: actionCount,
    actionLimit: actionLimit,
    startedAt: startedAt ?? DateTime.utc(2026, 8, 28, 10),
    plan: plan,
    resultSummary: resultSummary,
    workModeTask: true,
  );
}

AgentTask _decisionTask(String id, String conversationId) {
  final task =
      _task(id: id, conversationId: conversationId, characterId: 'worker')
        ..status = AgentTaskStatus.paused;
  final raw = WorkCollaborationState.fromLegacy(
    taskId: id,
    conversationId: conversationId,
    projectScopeId: 'scope-$id',
    requestRevision: 1,
    requestMessageId: 'request-$id',
    scope: task.userRequest,
    artifactContract: {
      'type': 'document',
      'format': 'txt',
      'location': 'out.txt',
      'revisionTarget': ''
    },
  ).toJson();
  raw
    ..['coordinatorId'] = 'worker'
    ..['team'] = [
      {
        'memberId': 'worker',
        'role': 'writer',
        'qualificationRef': 'skill',
        'qualified': true,
        'available': true
      }
    ]
    ..['decisions'] = [
      {
        'id': 'format',
        'revision': 1,
        'status': 'pending',
        'reason': '交付格式选哪一种？',
        'answer': '',
        'impact': '影响打开方式',
        'responseRef': '',
        'kind': 'choice',
        'targetId': 'format',
        'missingCondition': '需要明确格式',
        'options': [
          {'id': 'txt', 'label': '纯文本', 'impact': '可直接打开'},
          {'id': 'md', 'label': 'Markdown', 'impact': '可保留标题'},
        ]
      }
    ];
  final collaboration = WorkCollaborationState.tryParse(raw)!;
  task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      WorkDiscussionState(
        schemaVersion: 2,
        conversationId: conversationId,
        phase: WorkDiscussionPhase.blocked,
        requestRevision: 1,
        collaboration: collaboration,
      ));
  return task;
}

/// 旧 v1 检查点（没有协作记录）+ 一个未完成的讨论阶段。
///
/// 「讨论门禁前移」只在 v2 上放开：v1 没有"重开讨论"这条重入路径。
AgentTask _taskWithLegacyDiscussion(
    String id, String conversationId, String phase) {
  final task = _task(
    id: id,
    conversationId: conversationId,
    characterId: 'worker',
  );
  task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
    '',
    WorkDiscussionState.initial(
      conversationId: conversationId,
      executorId: 'worker',
      candidateCharacterIds: const ['worker'],
      participantCharacterIds: const ['worker'],
      deliverableContract: const <String, dynamic>{
        'deliverableType': 'document',
        'format': 'docx',
        'location': 'desktop',
        'contentScope': '输出 Word 文档',
        'explicitExecutorId': 'worker',
        'revisionTarget': '',
        'requestRevision': 1,
      },
    ).copyWith(phase: phase),
  );
  return task;
}

/// 在指定视口里挂一个带单条任务的全局宿主，供几何断言测算面板/折叠条位置。
Future<void> _pumpOverlayHostWithTask(
    WidgetTester tester, Size viewport) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final taskUpdates = StreamController<List<AgentTask>>.broadcast();
  addTearDown(taskUpdates.close);
  await tester.pumpWidget(MaterialApp(
    home: WorkTaskOverlayHost(
      taskStream: taskUpdates.stream,
      eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
      onStopTask: (_) async {},
      onContinueTask: (_) async {},
      child: const SizedBox.expand(),
    ),
  ));
  taskUpdates.add(<AgentTask>[
    _task(
      id: 'geometry-task',
      conversationId: 'group-one',
      characterId: 'developer',
    ),
  ]);
  await tester.pump();
  await tester.pump();
}

/// 拖动折叠胶囊。
///
/// 先用一段大于触摸 slop 的移动把识别器喂饱——`DragStartBehavior.start` 下这段
/// 会被折进起手位置、不产生位移，所以只有 [delta] 会真的落在胶囊上，断言才能
/// 按精确位移写。
Future<void> _dragMiniBar(WidgetTester tester, Offset delta) async {
  final bar = find.byKey(const Key('work-task-mini-bar'));
  final gesture = await tester.startGesture(tester.getCenter(bar));
  await tester.pump();
  await gesture.moveBy(const Offset(0, kTouchSlop * 2));
  await tester.pump();
  await gesture.moveBy(delta);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('decision dialog reports only pages actually displayed',
      (tester) async {
    final task = _decisionTask('shown-pages', 'qa-pages');
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    final raw = state.collaboration!.toJson();
    raw['decisions'] = [
      ...raw['decisions'] as List,
      {
        ...state.collaboration!.decisions.single,
        'id': 'second',
        'targetId': 'second',
        'reason': 'Second question'
      }
    ];
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState('',
        state.copyWith(collaboration: WorkCollaborationState.tryParse(raw)!));
    final decisions = WorkTaskDecision.forTask(task);
    final seen = <WorkTaskDecision>[];
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => WorkTaskDecisionDialog(
                            decisions: decisions,
                            onDecisionShown: seen.add,
                            onReply: (_, __,
                                    {choiceId, disposition = 'answer'}) async =>
                                true)),
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('work-task-decision-close')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(seen.map((d) => d.id), ['format']);
    expect(WorkTaskDecision.remindersToClaim(seen, task).map((d) => d.id),
        ['format']);
    seen.clear();
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('work-task-decision-option-md')));
    await tester.pump();
    expect(find.text('Second question'), findsOneWidget);
    expect(seen.map((d) => d.id), ['format', 'second']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('v2 discussion details preserve timeline space in a short panel',
      (tester) async {
    final task = _decisionTask('short-discussion', 'qa-short');
    final original =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    final raw = original.collaboration!.toJson()
      ..['plan'] =
          List.filled(30, 'Long requirement and independent review.').join(' ');
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        original.copyWith(
            collaboration: WorkCollaborationState.tryParse(raw)!));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 420,
                    height: 500,
                    child: WorkTaskPanel(
                      tasks: [task],
                      eventStreamFor: (_) =>
                          const Stream<WorkTaskEvent>.empty(),
                      onSelectTask: (_) {},
                      onStop: (_) {},
                      onContinue: (_) {},
                      onOpenConversation: (_) {},
                      onCollapse: () {},
                      onClose: () {},
                    ))))));
    await tester.tap(find.byKey(const Key('work-v2-discussion-details')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('收起问题与方案'), findsOneWidget);
    expect(find.text('执行动态 · 实时公开输出'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('P3 chat reminder button opens its exact decision task',
      (tester) async {
    final task = _decisionTask('p3-chat-button', 'p3-chat');
    final action = WorkTaskUserAction.forTask(task).single;
    WorkTaskUserAction? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatMessageBubble(
          message: Message(
            id: action.messageId,
            groupId: task.groupId,
            senderId: 'system',
            senderType: Message.senderTypeSystem,
            content: '请选择交付格式',
          ),
          characters: const [],
          cs: const ColorScheme.light(),
          senderColor: (_) => Colors.blue,
          ownerName: '我',
          onTaskAction: (item) => opened = item,
        ),
      ),
    ));
    await tester.tap(find.byKey(ValueKey(action.messageId)));
    expect(opened?.taskId, task.id);
    expect(opened?.blockerId, action.blockerId);
    expect(opened?.version, action.version);
  });

  group('WorkTaskPanel', () {
    testWidgets('hides the task summary section by default', (tester) async {
      final task = _task(
        id: 'summary-hidden-task',
        conversationId: 'group-one',
        characterId: 'developer',
        request: '整理需求',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      // 默认布局只留任务标签、执行动态与底部操作按钮：上半区整块（「任务详情」
      // 开关、任务需求 / 运行状态 / 执行细节三卡、失败提示与「异常与日志」卡）
      // 都不挂载。代码保留在 `_showSummarySection` 后面，显式传
      // `showTaskSummarySection: true` 才恢复（见下方依赖上半区的用例）。
      expect(find.byKey(const Key('work-task-details-toggle')), findsNothing);
      expect(find.byKey(const Key('work-task-request')), findsNothing);
      expect(
        find.byKey(const Key('work-task-details-scrollbar')),
        findsNothing,
      );
      expect(find.text('任务需求'), findsNothing);
      expect(find.text('运行状态'), findsNothing);
      expect(find.text('执行细节'), findsNothing);
      expect(find.text('异常与日志'), findsNothing);
      expect(
        find.byKey(const Key('work-task-event-timeline')),
        findsOneWidget,
      );
    });

    testWidgets('shows elapsed time for the current attempt', (tester) async {
      final task = _task(
        id: 'attempt-duration',
        conversationId: 'dm:worker',
        characterId: 'worker',
        startedAt: DateTime.utc(2026, 8, 28, 9),
      )..attemptStartedAt = DateTime.utc(2026, 8, 28, 10);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            showTaskSummarySection: true,
            tasks: [task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
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
      // 上半区默认收起，耗时属于「运行状态」卡的内容，要先展开「任务详情」。
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('已执行 2 分钟'), findsOneWidget);
      expect(find.textContaining('1 小时'), findsNothing);
    });

    testWidgets('freezes elapsed time once the task stops', (tester) async {
      final task = _task(
        id: 'stopped-duration',
        conversationId: 'dm:worker',
        characterId: 'worker',
        startedAt: DateTime.utc(2026, 8, 28, 9),
      )
        ..attemptStartedAt = DateTime.utc(2026, 8, 28, 10)
        ..status = AgentTaskStatus.completed
        ..updatedAt = DateTime.utc(2026, 8, 28, 10, 2);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            showTaskSummarySection: true,
            tasks: [task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
            // 任务已结束 2 小时，耗时仍应停在收工那一刻，而不是跟着当前时间涨。
            clock: () => DateTime.utc(2026, 8, 28, 12),
          ),
        ),
      ));
      // 上半区默认收起，耗时属于「运行状态」卡的内容，要先展开「任务详情」。
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('已执行 2 分钟'), findsOneWidget);
    });

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
            showTaskSummarySection: true,
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

      // 上半区默认收起：三张卡各只占一行，内容要点「详情」才补出来。
      expect(find.byKey(const Key('work-task-request')), findsNothing);
      expect(find.text('执行角色：product-owner'), findsNothing);
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('执行角色：product-owner'), findsOneWidget);
      expect(find.text('步骤 3 / 8'), findsOneWidget);
      expect(find.text('已执行 2 分钟'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('work-task-request'))).data,
        '整理发布说明',
      );
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
      // 执行动态默认展开：每条动态完整显示标题与详情。
      expect(find.text('发现 3 个待确认配置。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-task-timeline-toggle')));
      await tester.pump();
      // 收起后每条只占一行：标题还在，详情整行不渲染。
      expect(find.text('发现 3 个待确认配置。'), findsNothing);
      expect(
        tester.getTopLeft(find.text('正在读取项目配置')).dy,
        lessThan(tester.getTopLeft(find.text('已读取 pubspec.yaml')).dy),
      );
    });

    testWidgets('hides the previous request progress behind a toggle',
        (tester) async {
      // 现场：私聊里新请求被并入旧记录，标签写着新请求，执行动态却还是 9/11 那次
      // 江苏攻略的运行。默认只显示当前这一段，旧历史要点开才铺出来。
      final events = StreamController<WorkTaskEvent>.broadcast();
      addTearDown(events.close);
      final task = _task(
        id: 'joined-lineage',
        conversationId: 'dm-character-one',
        characterId: 'character-one',
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
            clock: () => DateTime.utc(2026, 9, 30, 17, 50),
          ),
        ),
      ));

      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 1,
        timestamp: DateTime.utc(2026, 9, 11, 19, 20),
        kind: WorkTaskEventKind.toolOutput,
        title: '文件交付进度',
        detail: '已处理 1/1 个文件，4603/4603 字节。',
      ));
      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 2,
        timestamp: DateTime.utc(2026, 9, 30, 17, 47),
        kind: WorkTaskEventKind.queued,
        title: '开始处理已排队的追问',
        safeMetadata: const <String, Object?>{
          WorkTaskRunBoundary.metadataKey:
              WorkTaskRunBoundary.followUpPromotion,
        },
      ));
      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 3,
        timestamp: DateTime.utc(2026, 9, 30, 17, 48),
        kind: WorkTaskEventKind.toolOutput,
        title: '正在读取已生成的 Markdown 攻略文件',
      ));
      await tester.pump();
      await tester.pump();

      expect(find.text('正在读取已生成的 Markdown 攻略文件'), findsOneWidget);
      // 旧请求那一段默认不渲染，只留一行入口。
      expect(find.text('文件交付进度'), findsNothing);
      expect(find.text('之前的 1 条动态'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('work-task-timeline-earlier-toggle')),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('文件交付进度'), findsOneWidget);
      expect(find.text('收起之前的 1 条动态'), findsOneWidget);
      // 顺序仍是时间序：旧的一段在前面。
      expect(
        tester.getTopLeft(find.text('文件交付进度')).dy,
        lessThan(
          tester.getTopLeft(find.text('正在读取已生成的 Markdown 攻略文件')).dy,
        ),
      );
    });

    testWidgets('shows how long the model has been silent', (tester) async {
      // 现场：上游停滞时面板连续几分钟只有一行静态占位，看不出是在等还是卡死。
      final events = StreamController<WorkTaskEvent>.broadcast();
      addTearDown(events.close);
      final task = _task(
        id: 'waiting-task',
        conversationId: 'group-one',
        characterId: 'developer',
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
            clock: () => DateTime.utc(2026, 9, 30, 10, 50),
          ),
        ),
      ));

      WorkTaskEvent pendingSince(DateTime timestamp, int sequence) =>
          WorkTaskEvent(
            taskId: task.id,
            sequence: sequence,
            timestamp: timestamp,
            kind: WorkTaskEventKind.toolOutput,
            title: 'AI 正在生成公开进度',
            detail: '已连接模型，正在等待第一段公开进度…',
            safeMetadata: const <String, Object?>{
              'stream': 'model',
              'pending': true,
              'pendingText': '已连接模型，正在等待第一段公开进度…',
            },
          );

      // 刚发出请求的半分钟内不该跳出"已等待 0 分钟"这种噪音。
      events.add(pendingSince(DateTime.utc(2026, 9, 30, 10, 49, 30), 1));
      await tester.pump();
      await tester.pump();
      expect(find.text('已连接模型，正在等待第一段公开进度…'), findsOneWidget);
      expect(find.textContaining('已等待'), findsNothing);

      // 等待起点取事件自己的时间戳，而不是"面板看到它的时刻"。
      events.add(pendingSince(DateTime.utc(2026, 9, 30, 10, 47), 2));
      await tester.pump();
      await tester.pump();
      expect(find.text('已等待 3 分钟'), findsOneWidget);
    });

    testWidgets('shows terminal status instead of a stale last action',
        (tester) async {
      final events = StreamController<WorkTaskEvent>.broadcast();
      addTearDown(events.close);
      final task = _task(
        id: 'completed-task',
        conversationId: 'group-one',
        characterId: 'developer',
        resultSummary: '项目分析结论已整理完成。',
      )..status = AgentTaskStatus.completed;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            showTaskSummarySection: true,
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => events.stream,
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 1,
        timestamp: DateTime.utc(2026, 8, 28, 10, 1),
        kind: WorkTaskEventKind.stepStarted,
        title: '已读取项目关键文件',
        safeMetadata: const <String, Object?>{'tool': 'workspace.read'},
      ));
      await tester.pump();
      await tester.pump();

      // 上半区默认收起，连「当前动作」都不渲染；展开「详情」后才补齐。
      expect(find.text('当前动作：任务已完成。'), findsNothing);
      expect(find.text('当前动作：已读取项目关键文件'), findsNothing);
      expect(find.text('工具：workspace.read'), findsNothing);
      // 结论是展开态内容，折叠时不应出现在面板上。
      expect(find.text('项目分析结论已整理完成。'), findsNothing);
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('当前动作：任务已完成。'), findsOneWidget);
      expect(find.text('项目分析结论已整理完成。'), findsOneWidget);
      expect(find.text('工具：workspace.read'), findsNothing);
    });

    testWidgets(
        'migrates a legacy invalid-command pause without showing continue',
        (tester) async {
      final task = _task(
        id: 'legacy-invalid-command-panel-task',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..resumeRequired = true
        ..lastError = '命令包含控制字符。';
      WorkFailure.persistOnTask(
        task,
        WorkFailure.defaults(WorkFailureType.userActionRequired),
      );
      var retried = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onRetry: (_) async => retried = true,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-continue')), findsNothing);
      expect(find.byKey(const Key('work-task-retry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-task-retry')));
      expect(retried, isTrue);
    });

    testWidgets('blocks generic continue while group discussion is pending',
        (tester) async {
      final pending = WorkDiscussionState.initial(
        conversationId: 'group-discussion-panel',
        executorId: 'worker',
        candidateCharacterIds: const ['worker'],
        participantCharacterIds: const ['worker'],
        deliverableContract: const <String, dynamic>{
          'deliverableType': 'document',
          'format': 'docx',
          'location': 'desktop',
          'contentScope': '输出 Word 文档',
          'explicitExecutorId': 'worker',
          'revisionTarget': '',
          'requestRevision': 1,
        },
      );
      final task = _task(
        id: 'discussion-panel-task',
        conversationId: 'group-discussion-panel',
        characterId: 'worker',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          '',
          pending,
        );
      var continued = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) => continued = true,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      final continueButton = tester.widget<FilledButton>(
        find.byKey(const Key('work-task-continue')),
      );
      expect(continueButton.onPressed, isNull);
      expect(continued, isFalse);
    });

    testWidgets('offers the executor confirmation for a pinned conflict',
        (tester) async {
      final conflict = WorkDiscussionState.initial(
        conversationId: 'group-pin-panel',
        executorId: 'elected',
        candidateCharacterIds: const ['elected', 'pinned'],
        participantCharacterIds: const ['elected', 'pinned'],
        deliverableContract: const <String, dynamic>{
          'deliverableType': 'document',
          'format': 'docx',
          'location': 'desktop',
          'contentScope': '输出 Word 文档',
          'explicitExecutorId': 'pinned',
          'revisionTarget': '',
          'requestRevision': 1,
        },
      ).copyWith(
        phase: WorkDiscussionPhase.blocked,
        understandingPercent: 99,
        blockers: const ['executorPinConflict'],
      );
      final task = _task(
        id: 'pin-panel-task',
        conversationId: 'group-pin-panel',
        characterId: 'elected',
      )
        ..status = AgentTaskStatus.paused
        ..lastError = '等待群讨论解决：executorPinConflict。'
        ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          '',
          conflict,
        );
      final choices = <String>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            characterNameFor: (characterId) =>
                characterId == 'elected' ? '乙' : '甲',
            onConfirmExecutorSwap: (taskId, version, swap) async {
              choices.add('$taskId:$swap');
            },
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('work-task-confirm-executor')));
      await tester.pumpAndSettle();
      expect(find.textContaining('乙'), findsWidgets);
      expect(find.textContaining('甲'), findsWidgets);

      await tester.tap(
        find.byKey(const Key('work-task-confirm-executor-swap')),
      );
      await tester.pumpAndSettle();
      expect(choices, ['pin-panel-task:true']);
    });

    testWidgets('offers explicit rebuild for an invalid nested discussion',
        (tester) async {
      final task = _task(
          id: 'invalid-discussion-panel',
          conversationId: 'group-invalid-panel',
          characterId: 'worker')
        ..status = AgentTaskStatus.paused
        ..executionStateJson = '{"discussionState":{"schemaVersion":99}}';
      var continued = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) => continued = true,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      final continueButton = tester.widget<FilledButton>(
        find.byKey(const Key('work-task-continue')),
      );
      expect(continueButton.onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('work-task-continue')));
      expect(continued, isTrue);
    });

    testWidgets('later action keeps the exact discussion checkpoint waiting',
        (tester) async {
      final pending = WorkDiscussionState.initial(
        conversationId: 'discussion-later-panel',
        executorId: null,
        candidateCharacterIds: const [],
        participantCharacterIds: const [],
        deliverableContract: const <String, dynamic>{
          'deliverableType': 'document',
          'format': 'docx',
          'location': 'desktop',
          'contentScope': '输出 Word 文档',
          'explicitExecutorId': null,
          'revisionTarget': '',
          'requestRevision': 1,
        },
      );
      final task = _task(
        id: 'discussion-later-task',
        conversationId: 'discussion-later-panel',
        characterId: '',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          '',
          pending,
        );
      var laterTaskId = '';

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onLater: (taskId) async => laterTaskId = taskId,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      final later = find.byKey(const Key('work-task-later'));
      expect(later, findsOneWidget);
      await tester.tap(later);
      await tester.pumpAndSettle();
      expect(laterTaskId, task.id);
    });

    testWidgets('shows discussion understanding progress and open questions',
        (tester) async {
      final pending = WorkDiscussionState.initial(
        conversationId: 'discussion-progress-panel',
        executorId: 'worker',
        candidateCharacterIds: const ['worker'],
        participantCharacterIds: const ['worker'],
        deliverableContract: const <String, dynamic>{
          'deliverableType': 'document',
          'format': 'docx',
          'location': 'desktop',
          'contentScope': '输出 Word 文档',
          'explicitExecutorId': 'worker',
          'revisionTarget': '',
          'requestRevision': 1,
        },
      ).copyWith(
        round: 2,
        understandingPercent: 65,
        understandingEvidence: const ['范围已确认'],
        openQuestions: const ['请确认最终桌面目录'],
      );
      final task = _task(
        id: 'discussion-progress-panel-task',
        conversationId: 'discussion-progress-panel',
        characterId: 'worker',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          '',
          pending,
        );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            showTaskSummarySection: true,
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      // 上半区默认收起，「讨论理解进度 / 待解决」都在「运行状态」卡内容里。
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('讨论理解进度：65% · 第2轮'), findsOneWidget);
      expect(find.text('待解决：请确认最终桌面目录'), findsOneWidget);
    });

    testWidgets('submits a discussion question from the panel', (tester) async {
      final pending = WorkDiscussionState.initial(
        conversationId: 'discussion-question-panel',
        executorId: 'worker',
        candidateCharacterIds: const ['worker'],
        participantCharacterIds: const ['worker'],
        deliverableContract: const <String, dynamic>{
          'deliverableType': 'document',
          'format': 'docx',
          'location': 'desktop',
          'contentScope': '输出 Word 文档',
          'explicitExecutorId': 'worker',
          'revisionTarget': '',
          'requestRevision': 1,
        },
      ).copyWith(
        phase: WorkDiscussionPhase.blocked,
        understandingPercent: 72,
        understandingEvidence: const ['输出格式已确认'],
        openQuestions: const ['请确认最终输出目录'],
        blockers: const ['missingUserInformation'],
      );
      final task = _task(
        id: 'discussion-question-panel-task',
        conversationId: 'discussion-question-panel',
        characterId: 'worker',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          '',
          pending,
        );
      String? submittedReply;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onReply: (_, reply) async => submittedReply = reply,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.text('请回答群讨论的问题'), findsOneWidget);
      expect(find.text('请确认最终输出目录'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('work-task-reply-input')),
        '/Users/me/Desktop/exports',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('work-task-reply-send')));
      await tester.tap(find.byKey(const Key('work-task-reply-send')));
      await tester.pumpAndSettle();

      expect(submittedReply, '/Users/me/Desktop/exports');
    });

    testWidgets('shows the budgeted action count rather than a tool index',
        (tester) async {
      final task = _task(
        id: 'count-task',
        conversationId: 'group-one',
        characterId: 'developer',
        currentStep: 99,
        actionCount: 2,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            showTaskSummarySection: true,
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      // 上半区默认收起，步骤数在「运行状态」卡内容里。
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('步骤 2 / 8'), findsOneWidget);
      expect(find.text('步骤 99 / 8'), findsNothing);
    });

    testWidgets(
        'shows public model content instead of transport character counts',
        (tester) async {
      final events = StreamController<WorkTaskEvent>.broadcast();
      addTearDown(events.close);
      final task = _task(
        id: 'public-output-task',
        conversationId: 'group-one',
        characterId: 'developer',
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
          ),
        ),
      ));

      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 1,
        timestamp: DateTime.utc(2026, 8, 28, 10, 1),
        kind: WorkTaskEventKind.modelOutput,
        title: 'AI 正在输出公开进度',
        detail: '正在检查授权目录并准备写入文件。',
        safeMetadata: const <String, Object?>{
          'stream': 'public_update',
          'publicDraft': '正在检查授权目录并准备写入文件。',
        },
      ));
      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 2,
        timestamp: DateTime.utc(2026, 8, 28, 10, 1, 1),
        kind: WorkTaskEventKind.toolOutput,
        title: '模型仍在生成工作决策',
        detail: '已接收约 128 个字符（协议内容不会直接展示）。',
        safeMetadata: const <String, Object?>{
          'stream': 'model',
          'characters': 128,
        },
      ));
      await tester.pump();

      // 时间线默认展开，完整展示公开草稿正文；
      // 而第二个事件（纯传输进度）会把上一张 live 卡片交接成历史卡片，正文随之
      // 保持可见。本条用例要验的是"面板展示的是模型公开正文，不是传输字符数"。
      expect(find.text('正在检查授权目录并准备写入文件。'), findsOneWidget);
      expect(find.textContaining('已接收约'), findsNothing);
      expect(find.text('AI 正在整理公开进度…'), findsNothing);

      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 3,
        timestamp: DateTime.utc(2026, 8, 28, 10, 1, 2),
        kind: WorkTaskEventKind.stepStarted,
        title: '正在执行文件写入',
      ));
      await tester.pump();

      expect(find.byKey(const Key('work-task-live-output')), findsNothing);
      expect(find.text('正在检查授权目录并准备写入文件。'), findsOneWidget);
      expect(find.text('正在执行文件写入'), findsOneWidget);

      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 4,
        timestamp: DateTime.utc(2026, 8, 28, 10, 1, 3),
        kind: WorkTaskEventKind.toolOutput,
        title: '模型仍在生成工作决策',
        detail: '已接收约 256 个字符。',
        safeMetadata: const <String, Object?>{
          'stream': 'model',
          'characters': 256,
          'publicDraft': '正在复核文件内容。',
        },
      ));
      await tester.pump();

      expect(find.text('正在复核文件内容。'), findsOneWidget);
      expect(find.textContaining('已接收约'), findsNothing);
    });

    testWidgets('keeps task and event scrollbars independently draggable',
        (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<WorkTaskEvent>.broadcast();
      addTearDown(events.close);
      final task = _task(
        id: 'scrollable-task',
        conversationId: 'group-one',
        characterId: 'developer',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            showTaskSummarySection: true,
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => events.stream,
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      for (var sequence = 1; sequence <= 24; sequence++) {
        events.add(WorkTaskEvent(
          taskId: task.id,
          sequence: sequence,
          timestamp: DateTime.utc(2026, 8, 28, 10, 1, sequence),
          kind: WorkTaskEventKind.toolOutput,
          title: '执行动态 $sequence',
          detail: '已完成第 $sequence 个公开检查。',
        ));
      }
      await tester.pump();

      // 执行动态默认展开：一开始就只渲染事件区滚动条，上半区仍收起无滚动条。
      expect(
        find.byKey(const Key('work-task-event-scrollbar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('work-task-details-scrollbar')),
        findsNothing,
      );
      expect(find.byType(Scrollbar), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('work-task-details-toggle')),
      );
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();

      final detailsScrollbar = tester.widget<Scrollbar>(
        find.byKey(const Key('work-task-details-scrollbar')),
      );
      final eventScrollbar = tester.widget<Scrollbar>(
        find.byKey(const Key('work-task-event-scrollbar')),
      );
      expect(detailsScrollbar.interactive, isTrue);
      expect(detailsScrollbar.thumbVisibility, isTrue);
      expect(eventScrollbar.interactive, isTrue);
      expect(eventScrollbar.thumbVisibility, isTrue);
      expect(find.byType(Scrollbar), findsNWidgets(2));

      final timeline = find.byKey(const Key('work-task-event-timeline'));
      final innerScrollable = find.descendant(
        of: timeline,
        matching: find.byType(Scrollable),
      );
      expect(innerScrollable, findsOneWidget);
      // 默认展开且自动跟随到最新一条：视口已贴在列表底部，
      // 向上能翻回更早的动态说明这个列表是可拖动的。
      final position = tester.state<ScrollableState>(innerScrollable).position;
      final before = position.pixels;
      expect(before, greaterThan(0.0));
      await tester.drag(timeline, const Offset(0, 180));
      await tester.pump();
      final after =
          tester.state<ScrollableState>(innerScrollable).position.pixels;
      expect(after, lessThan(before));
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
              showTaskSummarySection: true,
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

      // 默认收起时任务需求不可见，展开「详情」后才校验当前任务的内容。
      expect(find.byKey(const Key('work-task-request')), findsNothing);
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('work-task-request'))).data,
        '整理需求',
      );

      await tester.tap(find.byKey(const Key('work-task-tab-task-two')));
      await tester.pump();

      // 切任务后回到收起态，「详情」需要重新展开。
      expect(find.byKey(const Key('work-task-request')), findsNothing);
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(
        tester.widget<Text>(find.byKey(const Key('work-task-request'))).data,
        '实现面板',
      );
      expect(find.text('执行角色：developer'), findsOneWidget);
    });

    testWidgets('shows approval controls, role names, and safe public text',
        (tester) async {
      final task = _task(
        id: 'approval-task',
        conversationId: 'group-one',
        characterId: 'worker-id',
        plan: '读取 /Users/alice/project.md；https://private.example/token',
        resultSummary: 'https://private.example/result?token=secret',
      )
        ..status = AgentTaskStatus.waitingForApproval
        ..pendingToolRequestJson = '{"tool":"command.run","args":{}}';
      var approved = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            showTaskSummarySection: true,
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

      // 上半区默认收起，「执行角色」在「运行状态」卡内容里。
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
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

    testWidgets(
        'does not fall back to a legacy approval callback for a stale button',
        (tester) async {
      final task = _task(
        id: 'stale-approval-button',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.waitingForApproval
        ..pendingToolRequestJson = '{"tool":"command.run","args":{}}';
      var legacyCalls = 0;
      var versionedCalls = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onApprove: (_) async => legacyCalls++,
            onApproveVersioned: (_, __) async => versionedCalls++,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      // The already-rendered button represents the old waiting checkpoint.
      // Its task object now reflects a terminal transition before the tap;
      // neither callback may be used as a compatibility escape hatch.
      task.status = AgentTaskStatus.completed;
      await tester.tap(find.byKey(const Key('work-task-approve')));
      await tester.pump();

      expect(legacyCalls, 0);
      expect(versionedCalls, 0);
      expect(find.textContaining('该任务提醒已失效'), findsOneWidget);
    });

    testWidgets(
        'keeps the rendered approval version when the task mutates in place',
        (tester) async {
      final task = _task(
        id: 'in-place-approval-version',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.waitingForApproval
        ..pendingToolRequestJson = jsonEncode(<String, dynamic>{
          'tool': 'command.run',
          'args': <String, dynamic>{
            'executable': 'echo',
            'arguments': ['old']
          },
        });
      var versionedCalls = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onApproveVersioned: (_, __) async => versionedCalls++,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      task.pendingToolRequestJson = jsonEncode(<String, dynamic>{
        'tool': 'command.run',
        'args': <String, dynamic>{
          'executable': 'echo',
          'arguments': ['new']
        },
      });
      await tester.tap(find.byKey(const Key('work-task-approve')));
      await tester.pump();

      expect(versionedCalls, 0);
      expect(find.textContaining('该任务提醒已失效'), findsOneWidget);
    });

    testWidgets('supports a versioned later action without a legacy callback',
        (tester) async {
      final task = _task(
        id: 'versioned-later-discussion',
        conversationId: 'group-one',
        characterId: '',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          '',
          WorkDiscussionState.initial(
            conversationId: 'group-one',
            deliverableContract: const <String, dynamic>{
              'deliverableType': 'document',
              'format': 'docx',
              'location': 'desktop',
              'contentScope': '整理发布说明',
              'revisionTarget': '',
              'requestRevision': 1,
            },
          ),
        );
      var versionedCalls = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
            onLaterVersioned: (_, version) async {
              expect(version, greaterThan(0));
              versionedCalls++;
            },
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('work-task-later')));
      await tester.pump();

      expect(versionedCalls, 1);
    });

    testWidgets('shows only folder authorization while a grant is pending',
        (tester) async {
      final task = _task(
        id: 'folder-pending-task',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.waitingForApproval
        ..pendingToolRequestJson = '{"tool":"command.run","args":{}}'
        ..executionStateJson = jsonEncode({
          'folderGrantPending': true,
          'folderRequestPath': '/tmp/project',
        });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
            onApprove: (_) async {},
            onReject: (_) {},
            onRequestFolder: (_) async {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-add-folder')), findsOneWidget);
      expect(find.byKey(const Key('work-task-approve')), findsNothing);
      expect(find.byKey(const Key('work-task-reject')), findsNothing);
    });

    testWidgets(
        'names the required directory when the folder choice is refused',
        (tester) async {
      final task = _task(
        id: 'folder-refused-task',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = jsonEncode(<String, dynamic>{
          'folderGrantPending': true,
          'folderRequestPath': '/tmp/project',
        });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
            onApprove: (_) async {},
            onReject: (_) {},
            // 选择了别的目录时协调器会用带 requiredDirectory 的提示回传，
            // 面板必须当场弹窗点名需要授权的目录，而不是只留一行详情。
            onRequestFolder: (_) async {
              throw const WorkTaskActionNotice(
                '未获得目录授权：所选目录未覆盖原请求路径，请选择其所在目录。',
                requiredDirectory: '/tmp/project',
              );
            },
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('work-task-add-folder')));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('需要授权另一个目录'), findsOneWidget);
      expect(find.textContaining('/tmp/project'), findsWidgets);
    });

    testWidgets('opens the folder notice through the navigator context',
        (tester) async {
      // 面板在 App 里挂在 MaterialApp.builder 的 Overlay 上（见 main.dart），
      // 位于路由 Navigator 之上：它自己的 context 里既没有 Navigator 也没有
      // 路由的私有 Overlay，所以弹窗只能走 host 传进来的 dialogContext。
      // 这里复刻那棵树，否则用例会在「面板位于 Navigator 之下」的测试环境里
      // 假通过；缺 Overlay 时面板头部会直接构建失败。
      final navigatorKey = GlobalKey<NavigatorState>();
      late StateSetter rebuildHost;
      final task = _task(
        id: 'folder-refused-above-navigator',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = jsonEncode(<String, dynamic>{
          'folderGrantPending': true,
          'folderRequestPath': '/tmp/project',
        });

      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) => Overlay(
          initialEntries: <OverlayEntry>[
            OverlayEntry(
              builder: (_) => StatefulBuilder(
                builder: (context, setState) {
                  rebuildHost = setState;
                  return Stack(
                    alignment: Alignment.topRight,
                    children: <Widget>[
                      Positioned.fill(
                        child: child ?? const SizedBox.shrink(),
                      ),
                      SizedBox(
                        width: 420,
                        child: WorkTaskPanel(
                          tasks: <AgentTask>[task],
                          eventStreamFor: (_) =>
                              const Stream<WorkTaskEvent>.empty(),
                          onSelectTask: (_) {},
                          onStop: (_) {},
                          onContinue: (_) {},
                          onOpenConversation: (_) {},
                          onCollapse: () {},
                          onClose: () {},
                          onApprove: (_) async {},
                          onReject: (_) {},
                          dialogContext: navigatorKey.currentContext,
                          onRequestFolder: (_) async {
                            throw const WorkTaskActionNotice(
                              '未获得目录授权：所选目录未覆盖原请求路径，请选择其所在目录。',
                              requiredDirectory: '/tmp/project',
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        home: const Scaffold(body: SizedBox()),
      ));
      // 首帧时路由导航器尚未挂载，dialogContext 还是 null（host 同样如此，
      // 它是靠后续重建拿到 navigatorKey.currentContext 的）。
      rebuildHost(() {});
      await tester.pump();

      await tester.tap(find.byKey(const Key('work-task-add-folder')));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('需要授权另一个目录'), findsOneWidget);
      expect(find.textContaining('/tmp/project'), findsWidgets);
    });

    testWidgets('offers install consent for a legacy pandoc checkpoint',
        (tester) async {
      final task = _task(
        id: 'legacy-pandoc-panel-task',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..lastError = '缺少工具：pandoc。'
        ..pendingToolRequestJson = jsonEncode(<String, dynamic>{
          'tool': 'command.run',
          'args': <String, dynamic>{'executable': 'pandoc'},
        })
        ..executionStateJson = jsonEncode(<String, dynamic>{
          'toolMissing': true,
        })
        ..contextSummary = jsonEncode(<String, dynamic>{
          'recentToolResults': <Map<String, dynamic>>[
            <String, dynamic>{
              'data': <String, dynamic>{
                'installSuggestion': <String, dynamic>{
                  'executable': 'pandoc',
                },
              },
            },
          ],
        });
      var installRequested = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
            onInstallTool: (_) async => installRequested = true,
          ),
        ),
      ));

      if (!Platform.isMacOS && !Platform.isWindows) {
        expect(find.byKey(const Key('work-task-install-tool')), findsNothing);
        return;
      }

      expect(find.byKey(const Key('work-task-install-tool')), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-task-install-tool')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('work-task-install-tool-dialog')),
          findsOneWidget);

      await tester.tap(find.byKey(const Key('work-task-install-tool-confirm')));
      await tester.pumpAndSettle();
      expect(installRequested, isTrue);
    });

    testWidgets('requires a visual model choice before generic continue',
        (tester) async {
      final task = _task(
        id: 'vision-model-task',
        conversationId: 'group-one',
        characterId: 'text-only',
      )
        ..status = AgentTaskStatus.paused
        ..resumeRequired = true
        ..executionStateJson = jsonEncode({'visionModelRequired': true})
        ..lastError = '当前模型不支持图片输入，请选择视觉模型。';
      var selected = false;
      var continued = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) => continued = true,
            onSelectVisionModel: (_) => selected = true,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-select-vision-model')),
          findsOneWidget);
      final continueButton = tester.widget<FilledButton>(
        find.byKey(const Key('work-task-continue')),
      );
      expect(continueButton.onPressed, isNull);
      await tester.tap(find.byKey(const Key('work-task-select-vision-model')));
      expect(selected, isTrue);
      expect(continued, isFalse);
    });

    testWidgets('shows a reply editor for a model clarification pause',
        (tester) async {
      final task = _task(
        id: 'model-clarification-panel',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..resumeRequired = true
        ..lastError = '你要生成 PPTX 还是其他格式？'
        ..executionStateJson = jsonEncode({
          'clarificationRequired': true,
          'clarificationQuestion': '你要生成 PPTX 还是其他格式？',
        });
      var shouldFail = false;
      String? submittedReply;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onReply: (_, reply) async {
              if (shouldFail) throw StateError('network timeout');
              submittedReply = reply;
            },
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-reply-box')), findsOneWidget);
      expect(find.byKey(const Key('work-task-reply-input')), findsOneWidget);
      expect(find.byKey(const Key('work-task-reply-send')), findsOneWidget);
      expect(find.text('请回答模型的问题'), findsOneWidget);

      final continueButton = tester.widget<FilledButton>(
        find.byKey(const Key('work-task-continue')),
      );
      expect(continueButton.onPressed, isNull);

      await tester.enterText(
        find.byKey(const Key('work-task-reply-input')),
        '生成 PowerPoint .pptx 文件',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('work-task-reply-send')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(find.byKey(const Key('work-task-reply-send')));
      await tester.tap(find.byKey(const Key('work-task-reply-send')));
      await tester.pumpAndSettle();
      expect(submittedReply, '生成 PowerPoint .pptx 文件');
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('work-task-reply-input')),
            )
            .controller!
            .text,
        isEmpty,
      );

      shouldFail = true;
      await tester.enterText(
        find.byKey(const Key('work-task-reply-input')),
        '再次发送',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('work-task-reply-send')));
      await tester.tap(find.byKey(const Key('work-task-reply-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('work-task-reply-error')), findsOneWidget);
      expect(find.textContaining('发送失败：任务执行超时'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('work-task-reply-input')),
            )
            .controller!
            .text,
        '再次发送',
      );
    });

    testWidgets('shows a reply editor for an unresolved revision clarification',
        (tester) async {
      // 追问澄清（无法确定要改哪个既有产物）过去只写 clarificationQuestion，
      // 不写 clarificationRequired，于是 isPending 为 false：面板不给回复框，
      // 而"继续"又按另一个判据拒绝 —— 用户既答不了也退不出。
      final task = _task(
        id: 'follow-up-clarification-panel',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..lastError = '请明确要修改的文件路径（report.md、summary.md）？'
        ..executionStateJson = jsonEncode({
          'followUpKind': 'clarification',
          'clarificationQuestion': '请明确要修改的文件路径（report.md、summary.md）？',
        });
      String? submittedReply;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onReply: (_, reply) async => submittedReply = reply,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-reply-box')), findsOneWidget);
      expect(find.text('请明确修订目标'), findsOneWidget);
      expect(
        find.textContaining('请明确要修改的文件路径（report.md、summary.md）？'),
        findsOneWidget,
      );
      // 首次提问时不能出现"上次答复没被采纳"的措辞：那时用户还没答过任何东西，
      // 凭空虚指一句会让用户怀疑自己根本没发出去。
      expect(
        find.byKey(const Key('work-task-reply-rejected')),
        findsNothing,
      );
      // 澄清期间"继续"必须可见地不可用：既不能答、也不能继续才是原来的死角。
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('work-task-continue')))
            .onPressed,
        isNull,
      );

      await tester.enterText(
        find.byKey(const Key('work-task-reply-input')),
        '桌面',
      );
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('work-task-reply-send')));
      await tester.tap(find.byKey(const Key('work-task-reply-send')));
      await tester.pumpAndSettle();
      expect(submittedReply, '桌面');
    });

    testWidgets('a revision clarification offers its candidates as buttons',
        (tester) async {
      // 候选本来就摆在问题文案里，但用户只能照着抄一遍。按钮把"清单第几条"
      // 和"点哪个"对上，并且提交的是完整路径 —— 同名文件手打文件名必错。
      final task = _task(
        id: 'follow-up-clarification-options-panel',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..lastError = '请明确要修改的文件路径（点击选项，或回复序号／文件名）？\n'
            '1. report.md\n2. summary.md'
        ..executionStateJson = jsonEncode({
          'followUpKind': 'clarification',
          'clarificationQuestion': '请明确要修改的文件路径（点击选项，或回复序号／文件名）？\n'
              '1. report.md\n2. summary.md',
          'clarificationOptions': [
            {'index': 1, 'path': '/workspace/report.md'},
            {'index': 2, 'path': '/workspace/summary.md'},
          ],
        });
      String? submittedReply;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onReply: (_, reply) async => submittedReply = reply,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-reply-option-1')), findsOneWidget);
      expect(find.byKey(const Key('work-task-reply-option-2')), findsOneWidget);
      expect(find.text('report.md'), findsOneWidget);
      expect(find.text('summary.md'), findsOneWidget);

      await tester
          .ensureVisible(find.byKey(const Key('work-task-reply-option-2')));
      await tester.tap(find.byKey(const Key('work-task-reply-option-2')));
      await tester.pumpAndSettle();

      expect(submittedReply, '/workspace/summary.md');
    });

    testWidgets('same-named candidates are labelled with their full paths',
        (tester) async {
      // 文件名撞车正是这次澄清要解决的场景（不同目录下的同名脚本）。两个长得
      // 一模一样的按钮等于没给出选择，所以这类候选必须显示完整路径。
      final task = _task(
        id: 'follow-up-clarification-same-name',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = jsonEncode({
          'followUpKind': 'clarification',
          'clarificationQuestion': '请明确要修改的文件路径（点击选项，或回复序号／文件名）？\n'
              '1. create_ppt.py\n2. create_ppt.py',
          'clarificationOptions': [
            {'index': 1, 'path': '/workspace/first/create_ppt.py'},
            {'index': 2, 'path': '/workspace/second/create_ppt.py'},
          ],
        });
      String? submittedReply;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onReply: (_, reply) async => submittedReply = reply,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.text('create_ppt.py'), findsNothing);
      expect(find.text('/workspace/first/create_ppt.py'), findsOneWidget);
      expect(find.text('/workspace/second/create_ppt.py'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('work-task-reply-option-2')),
      );
      await tester.tap(find.byKey(const Key('work-task-reply-option-2')));
      await tester.pumpAndSettle();

      expect(submittedReply, '/workspace/second/create_ppt.py');
    });

    testWidgets('a model question offers no candidate buttons', (tester) async {
      // 模型提问没有结构化候选。这里不给按钮，是因为没有可点的目标 ——
      // 凭空造一排"是/否"会把用户的选择权换成我们的猜测。
      final task = _task(
        id: 'model-clarification-no-options',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..resumeRequired = true
        ..lastError = '你要生成 PPTX 还是其他格式？'
        ..executionStateJson = jsonEncode({
          'clarificationRequired': true,
          'clarificationQuestion': '你要生成 PPTX 还是其他格式？',
        });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onReply: (_, __) async {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-reply-box')), findsOneWidget);
      expect(
        find.byKey(const Key('work-task-reply-option-1')),
        findsNothing,
      );
    });

    testWidgets('a re-asked clarification says the last answer was not taken',
        (tester) async {
      // 问题原样再问一遍时，用户分不清系统是没收到答复，还是收到了但读不懂。
      final task = _task(
        id: 'clarification-answer-rejected',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = jsonEncode({
          'followUpKind': 'clarification',
          'clarificationQuestion': '请明确要修改的文件路径（点击选项，或回复序号／文件名）？\n1. report.md',
          'clarificationOptions': [
            {'index': 1, 'path': '/workspace/report.md'},
          ],
          'clarificationAnswerRejected': true,
        });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onReply: (_, __) async {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(
        find.byKey(const Key('work-task-reply-rejected')),
        findsOneWidget,
      );
      expect(find.textContaining('没能从上次回复里认出'), findsOneWidget);
    });

    testWidgets(
        'a path-only re-ask does not point at buttons that are not there',
        (tester) async {
      // 没有候选的澄清（任务里一个产物路径都没有）若仍写"请点选下面的选项"，
      // 用户会去找一排不存在的按钮。
      final task = _task(
        id: 'clarification-rejected-no-options',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = jsonEncode({
          'followUpKind': 'clarification',
          'clarificationQuestion': '请明确要修改的文件路径（例如：/workspace/report.md）？',
          'clarificationAnswerRejected': true,
        });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onReply: (_, __) async {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-reply-rejected')), findsOneWidget);
      expect(find.textContaining('没能从上次回复里认出'), findsOneWidget);
      expect(find.textContaining('点选'), findsNothing);
    });

    testWidgets('the clarification question can be selected and copied',
        (tester) async {
      // 问题里带着文件路径，用户经常要把它贴到别处去；纯 Text 连选都选不中。
      final task = _task(
        id: 'clarification-copyable',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..resumeRequired = true
        ..lastError = '你要生成 PPTX 还是其他格式？'
        ..executionStateJson = jsonEncode({
          'clarificationRequired': true,
          'clarificationQuestion': '你要生成 PPTX 还是其他格式？',
        });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onReply: (_, __) async {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      final question = tester.widget<SelectableText>(
        find.byKey(const Key('work-task-reply-question')),
      );
      expect(question.data, '你要生成 PPTX 还是其他格式？');
    });

    testWidgets(
        'shows continue for a soft-limit pause despite stale retry data',
        (tester) async {
      final task = _task(
        id: 'soft-limit-stale-failure',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.paused
        ..softLimitReached = true
        ..resumeRequired = true;
      WorkFailure.persistOnTask(
        task,
        WorkFailure.defaults(WorkFailureType.modelProtocol),
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) async {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-continue')), findsOneWidget);
      expect(find.byKey(const Key('work-task-retry')), findsNothing);
    });

    testWidgets('offers a fresh restart for a stopped task without writes',
        (tester) async {
      var restarted = false;
      final task = _task(
        id: 'stopped-without-write',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.cancelled
        ..lastError = '用户已停止任务。'
        ..executionStateJson = '{"committedActionKeys":[]}';

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onRetry: (_) async => restarted = true,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-retry')), findsOneWidget);
      expect(find.text('从头开始'), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-task-retry')));
      expect(restarted, isTrue);
    });

    testWidgets('offers continue for a task the user stopped', (tester) async {
      var continued = false;
      final task = _task(
        id: 'stopped-continue',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.cancelled
        ..lastError = AgentTask.userStopReason;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) async => continued = true,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-continue')), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-task-continue')));
      await tester.pump();
      expect(continued, isTrue);
    });

    testWidgets('offers continue instead of a dead retry after a user stop',
        (tester) async {
      // 停止后记录上仍可能带着可重试的失败标记（`_implStop` 不清它）。面板过去
      // 建议"请先点击重试"，而停止的任务走重试会被状态守卫直接拒绝（只允许"从头
      // 开始"那条路），于是既没有继续入口、又摆着一个点下去必然报错的重试。
      final task = _task(
        id: 'stopped-retryable-failure',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.cancelled
        ..lastError = AgentTask.userStopReason
        // 已经写出产物：不能"从头开始"，所以重试对这条记录是无效动作。
        ..lastArtifactPaths = <String>['/workspace/report.md'];
      WorkFailure.persistOnTask(
        task,
        WorkFailure.defaults(WorkFailureType.retryableNetwork),
      );
      var continued = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) async => continued = true,
            onRetry: (_) async {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-continue')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('work-task-continue')))
            .onPressed,
        isNotNull,
        reason: '停止后的任务只能靠「继续」接着跑',
      );
      expect(find.byKey(const Key('work-task-retry')), findsNothing,
          reason: '这条记录既不能从头开始，重试按钮就只会抛错');
      await tester.tap(find.byKey(const Key('work-task-continue')));
      await tester.pump();
      expect(continued, isTrue);
    });

    testWidgets('offers continue for a stopped v2 task whose discussion never finished',
        (tester) async {
      // 停止已经把讨论取消掉，v2 又不允许「从头开始」清空协作记录：这时「继续」
      // 是重新进入讨论的唯一入口。按"请先完成群讨论"挡掉它，任务既答不了也退不出。
      final task = _decisionTask('stopped-unfinished', 'group-one')
        ..status = AgentTaskStatus.cancelled
        ..lastError = AgentTask.userStopReason;
      var continued = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) async => continued = true,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-continue')), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-task-continue')));
      await tester.pump();
      expect(continued, isTrue);
    });

    testWidgets('keeps the discussion gate in front of a stopped legacy task',
        (tester) async {
      // 旧 v1 检查点没有"重开讨论"这条重入路径：继续会直接抛"请先完成群讨论"。
      // 这里必须与 v2 相反——不摆一个点下去只会报错的入口，出路是「从头开始」。
      final task = _taskWithLegacyDiscussion(
        'stopped-legacy-unfinished',
        'group-one',
        WorkDiscussionPhase.blocked,
      )
        ..status = AgentTaskStatus.cancelled
        ..lastError = AgentTask.userStopReason;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) async {},
            onRetry: (_) async {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-continue')), findsNothing);
      expect(find.text('从头开始'), findsOneWidget);
    });

    testWidgets('asks what to do with follow-ups a stop interrupted',
        (tester) async {
      var continued = false;
      var continuedWithoutFollowUps = false;
      final task = _task(
        id: 'stopped-with-follow-ups',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.cancelled
        ..lastError = AgentTask.userStopReason
        ..queuedUserRequests = <String>['改成第二版', '再补一个附录'];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) async => continued = true,
            onContinueWithoutFollowUps: (_) async =>
                continuedWithoutFollowUps = true,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('work-task-continue')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('work-task-continue-dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('2 条'), findsOneWidget);

      await tester
          .tap(find.byKey(const Key('work-task-continue-keep-follow-ups')));
      await tester.pumpAndSettle();
      expect(continued, isTrue);
      expect(continuedWithoutFollowUps, isFalse);
    });

    testWidgets('lets the user drop the interrupted follow-ups', (tester) async {
      var continued = false;
      var continuedWithoutFollowUps = false;
      final task = _task(
        id: 'stopped-drop-follow-ups',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.cancelled
        ..lastError = AgentTask.userStopReason
        ..queuedUserRequests = <String>['改成第二版'];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) async => continued = true,
            onContinueWithoutFollowUps: (_) async =>
                continuedWithoutFollowUps = true,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('work-task-continue')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const Key('work-task-continue-drop-follow-ups')));
      await tester.pumpAndSettle();
      expect(continuedWithoutFollowUps, isTrue);
      expect(continued, isFalse);
    });

    testWidgets('hides the fresh restart for a v2 collaboration task',
        (tester) async {
      // 「从头开始」对 v2 任务会清空整块协作记录，协调器因此拒绝执行。
      // 按钮不该先展示、再让用户撞上一次报错。
      final task = _decisionTask('stopped-v2', 'group-one')
        ..status = AgentTaskStatus.cancelled
        ..lastError = AgentTask.userStopReason;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onRetry: (_) async {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-retry')), findsNothing);
      expect(find.text('从头开始'), findsNothing);
    });

    testWidgets('hides stale pause details while a resumed task is running',
        (tester) async {
      final events = StreamController<WorkTaskEvent>.broadcast();
      addTearDown(events.close);
      final task = _task(
        id: 'resuming-task',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )..status = AgentTaskStatus.planning;
      WorkFailure.persistOnTask(
        task,
        WorkFailure.defaults(WorkFailureType.userActionRequired),
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            showTaskSummarySection: true,
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => events.stream,
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) async {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));
      events.add(WorkTaskEvent(
        taskId: task.id,
        sequence: 1,
        timestamp: DateTime.utc(2026, 9, 9, 10),
        kind: WorkTaskEventKind.paused,
        title: '已暂停：达到执行软上限。',
      ));
      await tester.pump();
      await tester.pump();

      // 默认收起时三张卡都只占一行，「当前动作」要展开「任务详情」才可见。
      expect(find.text('当前动作：正在规划下一步。'), findsNothing);
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('当前动作：正在规划下一步。'), findsOneWidget);
      expect(find.byKey(const Key('work-task-failure')), findsNothing);
      expect(find.byKey(const Key('work-task-continue')), findsNothing);
      expect(find.byKey(const Key('work-task-stop')), findsOneWidget);
    });

    testWidgets('shows the folder picker for an initial grant without a path',
        (tester) async {
      final task = _task(
        id: 'initial-folder-pending-task',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.waitingForApproval
        ..executionStateJson = jsonEncode({'folderGrantPending': true});

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
            onRequestFolder: (_) async {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-add-folder')), findsOneWidget);
      expect(find.byKey(const Key('work-task-approve')), findsNothing);
    });

    testWidgets('shows the durable change plan before approving a mutation',
        (tester) async {
      final plan = WorkChangePlan(
        taskId: 'planned-approval-task',
        actionType: WorkChangeActionType.modify,
        exactPaths: const ['/workspace/report.md'],
        knownAffectedDirectories: const ['/workspace'],
        estimatedBytes: 128,
        snapshotAvailable: true,
        reversible: true,
        riskReason: '需要更新周报并保留可撤销快照。',
      );
      final task = _task(
        id: plan.taskId,
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.waitingForApproval
        ..pendingToolRequestJson =
            '{"tool":"workspace.patch","args":{"path":"report.md"}}'
        ..executionStateJson = jsonEncode({
          'approvalPlan': plan.toJson(),
          'approvalScope': WorkApprovalScope.fromPlan(plan).toJson(),
        });
      var approved = false;
      var rejected = false;
      final modalVisibility = <bool>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onApprove: (_) async => approved = true,
            onReject: (_) async => rejected = true,
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
            onModalVisibilityChanged: modalVisibility.add,
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('work-task-approve')));
      await tester.pumpAndSettle();

      expect(find.text('任务变更需要审批'), findsOneWidget);
      expect(find.text('/workspace/report.md'), findsOneWidget);
      expect(find.text('需要更新周报并保留可撤销快照。'), findsOneWidget);
      expect(approved, isFalse);
      expect(modalVisibility, <bool>[false]);

      await tester.tap(find.text('允许本次范围'));
      await tester.pumpAndSettle();

      expect(approved, isTrue);
      expect(rejected, isFalse);
      expect(modalVisibility, <bool>[false, true]);
    });

    testWidgets('fails closed when a file approval plan cannot be read',
        (tester) async {
      final task = _task(
        id: 'missing-approval-plan',
        conversationId: 'group-one',
        characterId: 'worker-id',
      )
        ..status = AgentTaskStatus.waitingForApproval
        ..pendingToolRequestJson =
            '{"tool":"workspace.patch","args":{"path":"report.md"}}';
      var approved = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onApprove: (_) async => approved = true,
            onReject: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      final approve = find.byKey(const Key('work-task-approve'));
      expect(approve, findsOneWidget);
      final button = tester.widget<FilledButton>(approve);
      expect(button.onPressed, isNull);
      expect(find.byKey(const Key('work-task-approve-without-undo')),
          findsNothing);
      expect(approved, isFalse);
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

    testWidgets('offers a confirmed undo action for a completed task',
        (tester) async {
      final task = _task(
        id: 'undo-task',
        conversationId: 'group-one',
        characterId: 'developer',
      )..status = AgentTaskStatus.completed;
      var undone = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onUndo: (_) async => undone = true,
            undoPreviewFor: (_) => const <WorkSnapshotUndoItem>[
              WorkSnapshotUndoItem(
                sequence: 1,
                operation: '恢复',
                path: '/Volumes/project/report.md',
              ),
              WorkSnapshotUndoItem(
                sequence: 2,
                operation: '删除',
                path: '/Volumes/project/new.md',
              ),
            ],
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      final undoButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('work-task-undo')),
      );
      expect(undoButton.onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('work-task-undo')));
      await tester.pumpAndSettle();
      expect(find.text('撤销本任务改动'), findsOneWidget);
      expect(find.text('恢复：/Volumes/project/report.md'), findsOneWidget);
      expect(find.text('删除：/Volumes/project/new.md'), findsOneWidget);

      await tester.tap(find.byKey(const Key('work-task-undo-confirm')));
      await tester.pumpAndSettle();
      expect(undone, isTrue);
    });

    testWidgets('confirms before deleting a task that is still running',
        (tester) async {
      // 历史任务不再执行，所以详情不接执行类动作；真删除（不可逆）在界面上只剩
      // 这一个入口——操作区已不再放"删除任务"，避免与标签旁的 ✕ 混淆。
      // 任务还没结束时要先确认：删除会顺手停止它，正在跑的工具可能还在改文件。
      final task = _task(
        id: 'history-delete-task',
        conversationId: 'group-history-delete',
        characterId: 'developer',
      )..status = AgentTaskStatus.runningTool;
      final deletedTaskIds = <String>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            historyTasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onDeleteTask: (taskId) async => deletedTaskIds.add(taskId),
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      expect(find.byKey(const Key('work-task-delete')), findsNothing);
      await tester.tap(find.byKey(const Key('work-task-history-open')));
      await tester.pump();
      await tester.tap(find.byKey(Key('work-task-history-item-${task.id}')));
      await tester.pump();

      // 取消不得触发任何删除。
      await tester.tap(find.byKey(const Key('work-task-history-delete')));
      await tester.pumpAndSettle();
      expect(find.text('删除这条任务？'), findsOneWidget);
      expect(find.textContaining('已经生成的文件不会被删除'), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-task-delete-cancel')));
      await tester.pumpAndSettle();
      expect(deletedTaskIds, isEmpty);

      await tester.tap(find.byKey(const Key('work-task-history-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('work-task-delete-confirm')));
      await tester.pumpAndSettle();
      expect(deletedTaskIds, ['history-delete-task']);
    });

    testWidgets('deletes a finished task without asking', (tester) async {
      // 终态任务已经停手、不会再产生文件改动，删除只影响记录本身，不再弹窗。
      final task = _task(
        id: 'history-delete-terminal-task',
        conversationId: 'group-history-delete-terminal',
        characterId: 'developer',
      )..status = AgentTaskStatus.cancelled;
      final deletedTaskIds = <String>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            historyTasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onDeleteTask: (taskId) async => deletedTaskIds.add(taskId),
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('work-task-history-open')));
      await tester.pump();
      await tester.tap(find.byKey(Key('work-task-history-item-${task.id}')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('work-task-history-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('work-task-delete-dialog')), findsNothing);
      expect(deletedTaskIds, ['history-delete-terminal-task']);
    });

    testWidgets('opens a historical task back into the tab strip',
        (tester) async {
      // 历史详情不接执行动作，所以"这条旧任务我要接着处理"必须先回到标签栏，
      // 否则用户看着一条旧任务却无处下手。
      final task = _task(
        id: 'history-open-task',
        conversationId: 'group-history-open',
        characterId: 'developer',
      )..status = AgentTaskStatus.paused;
      final openedTaskIds = <String>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            historyTasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenInTabStrip: (taskId) async => openedTaskIds.add(taskId),
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('work-task-history-open')));
      await tester.pump();
      await tester.tap(find.byKey(Key('work-task-history-item-${task.id}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('work-task-history-open-in-tabs')));
      await tester.pumpAndSettle();

      expect(openedTaskIds, ['history-open-task']);
      // 退出历史视图后标签栏才画出来，任务才算真的能操作。
      expect(find.byKey(const Key('work-task-history-list')), findsNothing);
      expect(find.byKey(Key('work-task-tab-${task.id}')), findsOneWidget);
    });
  });

  group('WorkTaskOverlayHost', () {
    testWidgets('collapse does not stop the running task', (tester) async {
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

      // 面板头只保留「收起」，不再有独立的「隐藏 ✕」按钮。
      expect(find.byKey(const Key('work-task-close')), findsNothing);
      expect(find.byKey(const Key('work-task-collapse')), findsOneWidget);
      expect(find.byKey(const Key('work-task-panel')), findsOneWidget);
      expect(find.byKey(const Key('work-task-mini-bar')), findsNothing);
      expect(stoppedTaskIds, isEmpty);
      expect(find.text('设置页内容仍可点击'), findsOneWidget);
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

    testWidgets(
        'lightweight host hides optional controls without handlers and uses an empty event stream',
        (tester) async {
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      final task = _task(
        id: 'lightweight-approval-task',
        conversationId: 'group-lightweight',
        characterId: 'worker',
      )
        ..status = AgentTaskStatus.waitingForApproval
        ..pendingToolRequestJson = jsonEncode(<String, dynamic>{
          'tool': 'command.run',
          'args': <String, dynamic>{
            'executable': 'echo',
            'arguments': <String>['ok'],
          },
        });

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[task]);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('work-task-panel')), findsOneWidget);
      expect(find.byKey(const Key('work-task-approve')), findsNothing);
      expect(find.byKey(const Key('work-task-reject')), findsNothing);
      expect(find.byKey(const Key('work-task-install-tool')), findsNothing);
      expect(find.byKey(const Key('work-task-add-folder')), findsNothing);
    });

    testWidgets('display-only host works without app-scoped providers',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: WorkTaskOverlayHost(
          child: SizedBox.expand(),
        ),
      ));
      await tester.pump();

      expect(find.byType(SizedBox), findsWidgets);
      expect(find.byKey(const Key('work-task-panel')), findsNothing);
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

    testWidgets(
        'collapsed bar parks in the top-right corner, clear of the composer',
        (tester) async {
      const viewport = Size(800, 800);
      await _pumpOverlayHostWithTask(tester, viewport);

      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();

      final bar = tester.getRect(find.byKey(const Key('work-task-mini-bar')));
      // 折叠条曾经钉在 bottom:16 —— 正是输入框右端「发送」所在的位置。
      expect(bar.top, greaterThanOrEqualTo(kToolbarHeight));
      expect(bar.bottom, lessThan(viewport.height - 84));
      expect(bar.left, greaterThan(viewport.width / 2));
      expect(bar.right, lessThanOrEqualTo(viewport.width));
    });

    testWidgets('collapsed bar parks below the conversation controls band',
        (tester) async {
      // 会话页在 AppBar 之下还有一行会话控件（自动发言 / 语音播报 / 圆桌会议 /
      // 工作模式）。胶囊曾经停在 kToolbarHeight + 16，正好压住这行的右端——
      // 「工作模式」开关被盖住就点不到，所以这里必须让开。
      const viewport = Size(800, 800);
      final bandKey = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('群聊')),
          body: CompactConversationControls(
            key: bandKey,
            showAutoChat: true,
            autoChatEnabled: true,
            autoChatAvailable: true,
            autoChatTooltip: '',
            workModeEnabled: true,
            workModeTooltip: '',
            onAutoChatChanged: (_) {},
            onWorkModeChanged: (_) {},
            showRoundtableMode: true,
            onRoundtableModeChanged: (_) {},
            showVoiceBroadcast: true,
            voiceBroadcastAvailable: true,
            voiceBroadcastTooltip: '',
            onVoiceBroadcastChanged: (_) {},
          ),
        ),
      ));
      // 下边界取真实控件的布局结果：控件行改高（图标或内边距调整）时，宿主里
      // 那个常量会跟着失真，这条断言必须一起失败，否则胶囊会重新压上去。
      final bandBottom = tester.getRect(find.byKey(bandKey)).bottom;
      ConversationPresenceService.instance.enter('group-one');
      addTearDown(
          () => ConversationPresenceService.instance.leave('group-one'));
      await _pumpOverlayHostWithTask(tester, viewport);

      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();

      final bar = tester.getRect(find.byKey(const Key('work-task-mini-bar')));
      expect(bar.top, greaterThanOrEqualTo(bandBottom));
      expect(bar.left, greaterThan(viewport.width / 2));

      // 展开后的宽屏面板与胶囊共用同一个顶锚点：只挪胶囊的话，展开那一下面板
      // 会跳回原处，再把「工作模式」开关压住。
      await tester.tap(find.byKey(const Key('work-task-mini-bar')));
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const Key('work-task-panel-wide'))).top,
        greaterThanOrEqualTo(bandBottom),
      );
    });

    testWidgets('collapsed bar keeps the AppBar anchor outside a conversation',
        (tester) async {
      // 角色列表、设置页没有那条控件行，胶囊不该为它空出一段距离。
      const viewport = Size(800, 800);
      await _pumpOverlayHostWithTask(tester, viewport);

      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();

      final bar = tester.getRect(find.byKey(const Key('work-task-mini-bar')));
      expect(bar.top, kToolbarHeight + 16);
    });

    testWidgets('collapsed bar still shows a non-zero count', (tester) async {
      const viewport = Size(800, 800);
      await _pumpOverlayHostWithTask(tester, viewport);

      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();

      final bar = find.byKey(const Key('work-task-mini-bar'));
      expect(
        find.descendant(of: bar, matching: find.text('1')),
        findsOneWidget,
      );
      expect(find.byTooltip('工作任务 1 项 · 点击展开'), findsOneWidget);
    });

    testWidgets('collapsed bar drops a meaningless zero count', (tester) async {
      // 「0」不代表还有零个任务，而是本会话没有可盯的标签：记录收在历史里，
      // 或者标签被用户自己关掉了。这时胶囊只当入口用，不该报一个 0 出来。
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      final task = _task(
        id: 'hidden-only-task',
        conversationId: 'group-one',
        characterId: 'developer',
      )..status = AgentTaskStatus.completed;
      ConversationPresenceService.instance.enter('group-one');
      addTearDown(
          () => ConversationPresenceService.instance.leave('group-one'));

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[task]);
      await tester.pump();
      await tester.pump();

      // 关掉唯一的标签后本会话再没有可展示的标签，但记录仍在历史里，
      // 所以面板（连带胶囊）必须留着，只是不该再报数。
      await tester.tap(find.descendant(
        of: find.byKey(const Key('work-task-tab-hidden-only-task')),
        matching: find.byIcon(Icons.close_rounded),
      ));
      await tester.pump();
      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();

      final bar = find.byKey(const Key('work-task-mini-bar'));
      expect(bar, findsOneWidget);
      expect(find.descendant(of: bar, matching: find.text('0')), findsNothing);
      expect(find.byTooltip('打开任务面板'), findsOneWidget);
      expect(find.byTooltip('工作任务 0 项 · 点击展开'), findsNothing);
    });

    testWidgets('wide panel starts at the conversation controls band',
        (tester) async {
      // 「填满聊天窗口高度」：面板顶边紧贴控件行下沿，不再空出 _topAnchorGap 那
      // 16px；底边仍停在输入区之上，发送按钮照样点得到。
      const viewport = Size(1000, 800);
      final bandKey = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('群聊')),
          body: CompactConversationControls(
            key: bandKey,
            showAutoChat: true,
            autoChatEnabled: true,
            autoChatAvailable: true,
            autoChatTooltip: '',
            workModeEnabled: true,
            workModeTooltip: '',
            onAutoChatChanged: (_) {},
            onWorkModeChanged: (_) {},
            showRoundtableMode: true,
            onRoundtableModeChanged: (_) {},
            showVoiceBroadcast: true,
            voiceBroadcastAvailable: true,
            voiceBroadcastTooltip: '',
            onVoiceBroadcastChanged: (_) {},
          ),
        ),
      ));
      final bandBottom = tester.getRect(find.byKey(bandKey)).bottom;
      ConversationPresenceService.instance.enter('group-one');
      addTearDown(
          () => ConversationPresenceService.instance.leave('group-one'));
      await _pumpOverlayHostWithTask(tester, viewport);

      final panel =
          tester.getRect(find.byKey(const Key('work-task-panel-wide')));
      expect(panel.top, closeTo(bandBottom, 0.5));
      expect(panel.bottom, lessThanOrEqualTo(viewport.height - 84));
    });

    testWidgets('narrow panel also clears the conversation controls band',
        (tester) async {
      // 窄布局的面板不比宽屏面板特殊：它的顶边原本落在 96，而控件行下沿在 106，
      // 面板头正压着「工作模式」开关的最后十来个像素——两个宽布局入口都让开了，
      // 这条路径漏了。
      const viewport = Size(600, 844);
      final bandKey = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('群聊')),
          body: CompactConversationControls(
            key: bandKey,
            showAutoChat: true,
            autoChatEnabled: true,
            autoChatAvailable: true,
            autoChatTooltip: '',
            workModeEnabled: true,
            workModeTooltip: '',
            onAutoChatChanged: (_) {},
            onWorkModeChanged: (_) {},
            showRoundtableMode: true,
            onRoundtableModeChanged: (_) {},
            showVoiceBroadcast: true,
            voiceBroadcastAvailable: true,
            voiceBroadcastTooltip: '',
            onVoiceBroadcastChanged: (_) {},
          ),
        ),
      ));
      final bandBottom = tester.getRect(find.byKey(bandKey)).bottom;
      ConversationPresenceService.instance.enter('group-one');
      addTearDown(
          () => ConversationPresenceService.instance.leave('group-one'));
      await _pumpOverlayHostWithTask(tester, viewport);

      final panel =
          tester.getRect(find.byKey(const Key('work-task-panel-bottom')));
      expect(panel.top, greaterThanOrEqualTo(bandBottom));
      expect(panel.bottom, lessThanOrEqualTo(viewport.height - 84));
    });

    testWidgets('collapsed bar follows a drag', (tester) async {
      const viewport = Size(800, 800);
      await _pumpOverlayHostWithTask(tester, viewport);

      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();

      final bar = find.byKey(const Key('work-task-mini-bar'));
      final before = tester.getRect(bar);
      await _dragMiniBar(tester, const Offset(-200, 120));

      final after = tester.getRect(bar);
      expect(after.left, closeTo(before.left - 200, 1));
      expect(after.top, closeTo(before.top + 120, 1));
    });

    testWidgets('dragging the collapsed bar keeps it inside the window',
        (tester) async {
      const viewport = Size(800, 800);
      await _pumpOverlayHostWithTask(tester, viewport);

      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();

      await _dragMiniBar(tester, const Offset(4000, 4000));
      final pushed =
          tester.getRect(find.byKey(const Key('work-task-mini-bar')));
      expect(pushed.right, lessThanOrEqualTo(viewport.width));
      expect(pushed.bottom, lessThanOrEqualTo(viewport.height));

      await _dragMiniBar(tester, const Offset(-4000, -4000));
      final pulled =
          tester.getRect(find.byKey(const Key('work-task-mini-bar')));
      expect(pulled.left, greaterThanOrEqualTo(0));
      expect(pulled.top, greaterThanOrEqualTo(0));
    });

    testWidgets('dragging the collapsed bar does not expand the panel',
        (tester) async {
      const viewport = Size(800, 800);
      await _pumpOverlayHostWithTask(tester, viewport);

      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();

      await _dragMiniBar(tester, const Offset(-120, 90));

      expect(find.byKey(const Key('work-task-mini-bar')), findsOneWidget);
      expect(find.byKey(const Key('work-task-panel-wide')), findsNothing);
    });

    testWidgets('a dragged bar does not move the wide panel', (tester) async {
      // 面板不跟随胶囊：拖到哪儿，展开后的面板都还在右侧默认锚点铺满。
      const viewport = Size(1000, 800);
      await _pumpOverlayHostWithTask(tester, viewport);

      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();
      await _dragMiniBar(tester, const Offset(-400, 300));

      final barBefore =
          tester.getRect(find.byKey(const Key('work-task-mini-bar')));
      await tester.tap(find.byKey(const Key('work-task-mini-bar')));
      await tester.pump();

      final panel =
          tester.getRect(find.byKey(const Key('work-task-panel-wide')));
      expect(panel.right, closeTo(viewport.width - 16, 0.5));
      expect(panel.top, lessThan(barBefore.top));
    });

    testWidgets('wide panel stops above the composer row', (tester) async {
      const viewport = Size(1000, 800);
      await _pumpOverlayHostWithTask(tester, viewport);

      final panel =
          tester.getRect(find.byKey(const Key('work-task-panel-wide')));
      // 面板曾一路铺到 bottom:16，右下角压住发送按钮。
      expect(panel.bottom, lessThanOrEqualTo(viewport.height - 84));
    });

    testWidgets('narrow panel stops above the composer row', (tester) async {
      const viewport = Size(600, 1000);
      await _pumpOverlayHostWithTask(tester, viewport);

      final panel =
          tester.getRect(find.byKey(const Key('work-task-panel-bottom')));
      expect(panel.bottom, lessThanOrEqualTo(viewport.height - 84));
      // 让出底部净空后不得为了塞满而往顶部溢出，否则面板头会被 Stack 裁掉。
      expect(panel.top, greaterThan(0));
    });

    testWidgets('keeps discussion reply actions visible in a short window',
        (tester) async {
      tester.view.physicalSize = const Size(800, 630);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      final pending = WorkDiscussionState.initial(
        conversationId: 'short-panel-group',
        executorId: 'worker',
        candidateCharacterIds: const ['worker'],
        participantCharacterIds: const ['worker'],
        deliverableContract: const <String, dynamic>{
          'deliverableType': 'document',
          'format': 'docx',
          'location': 'desktop',
          'contentScope': '输出 Word 文档',
          'explicitExecutorId': 'worker',
          'revisionTarget': '',
          'requestRevision': 1,
        },
      ).copyWith(
        phase: WorkDiscussionPhase.blocked,
        openQuestions: const [
          '请确认本轮冒烟测试的具体验收项是否仅覆盖基础功能，还是包含性能、兼容性项；'
              '冒烟测试的兼容性覆盖范围（浏览器版本、设备类型）待确认；'
              '400错误、半格延迟问题的质检判定标准待明早对齐确认；'
              '暗色模式可识别度的测试用例阈值待确认',
        ],
        blockers: const ['missingUserInformation'],
      );
      final task = _task(
        id: 'short-panel-task',
        conversationId: 'short-panel-group',
        characterId: 'worker',
      )
        ..status = AgentTaskStatus.paused
        ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          '',
          pending,
        );

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          onReplyTask: (_, __) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[task]);
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('work-task-reply-send')), findsOneWidget);
      expect(find.byKey(const Key('work-task-stop')), findsOneWidget);
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

    testWidgets('labels task tabs with the user request instead of an index',
        (tester) async {
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      final task = _task(
        id: 'labeled-task',
        conversationId: 'group-labeled',
        characterId: 'developer',
        request: '在桌面生成隆中对对策 PDF 文档',
      )..status = AgentTaskStatus.planning;

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[task]);
      await tester.pump();
      await tester.pump();

      // 「任务 1」既说不清在干什么，也会在列表变化时改号。标签必须能直接
      // 认出是哪条需求。
      final tab = find.byKey(const Key('work-task-tab-labeled-task'));
      expect(
          find.descendant(of: tab, matching: find.text(workTaskTabLabel(task))),
          findsOneWidget);
      expect(find.text('任务 1'), findsNothing);
    });

    testWidgets('marks a task hidden from the tab strip in the history list',
        (tester) async {
      final task = _task(
        id: 'hidden-history-task',
        conversationId: 'group-history',
        characterId: 'developer',
        request: '在桌面生成隆中对对策 PDF',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            showTaskSummarySection: true,
            tasks: [task],
            historyTasks: [task],
            hiddenTaskIds: {task.id},
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ));
      await tester.tap(find.byKey(const Key('work-task-history-open')));
      await tester.pump();
      expect(find.textContaining('已从标签栏隐藏'), findsOneWidget);
      await tester.tap(find.byKey(Key('work-task-history-item-${task.id}')));
      await tester.pump();
      // 历史详情同样默认收起，展开「详情」后才看得到任务需求卡。
      expect(find.byKey(const Key('work-task-request')), findsNothing);
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.byKey(const Key('work-task-request')), findsOneWidget);
    });

    testWidgets('opens the exact older task from a hidden chat reminder',
        (tester) async {
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      final hidden = _task(
        id: 'hidden-old-task',
        conversationId: 'group-old',
        characterId: 'developer',
      )
        ..status = AgentTaskStatus.paused
        ..updatedAt = DateTime.utc(2026, 1, 1);
      final visibleTasks = [
        for (var index = 0; index < 4; index++)
          _task(
            id: 'newer-task-$index',
            conversationId: 'group-$index',
            characterId: 'developer',
          )
            ..status = AgentTaskStatus.queued
            ..updatedAt = DateTime.utc(2026, 2, index + 1),
      ];

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          showTaskSummarySection: true,
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[...visibleTasks, hidden]);
      await tester.pump();
      await tester.pump();

      expect(
          find.byKey(const Key('work-task-tab-hidden-old-task')), findsNothing);
      WorkTaskOverlayController.shared.openTask(hidden.id);
      await tester.pump();

      expect(find.byKey(const Key('work-task-tab-hidden-old-task')),
          findsOneWidget);
      // 上半区默认收起，「执行角色」在「运行状态」卡内容里，需要先展开。
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('执行角色：developer'), findsOneWidget);

      // A later task-stream delta must not replace the exact task selected
      // from the old reminder with the newest queued row.
      taskUpdates.add(<AgentTask>[
        ...visibleTasks,
        hidden,
        _task(
          id: 'newest-task',
          conversationId: 'group-newest',
          characterId: 'developer',
        )..status = AgentTaskStatus.queued,
      ]);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('work-task-tab-hidden-old-task')),
          findsOneWidget);
      expect(find.text('执行角色：developer'), findsOneWidget);
    });

    testWidgets('restores the tab of a hidden task that is resumed',
        (tester) async {
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      final task = _task(
        id: 'resumed-hidden-task',
        conversationId: 'group-resumed',
        characterId: 'developer',
      )..status = AgentTaskStatus.failed;

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[task]);
      await tester.pump();
      await tester.pump();

      const tabKey = Key('work-task-tab-resumed-hidden-task');
      final tab = find.byKey(tabKey);
      expect(tab, findsOneWidget);
      await tester.tap(
        find.descendant(of: tab, matching: find.byIcon(Icons.close_rounded)),
      );
      await tester.pump();
      expect(tab, findsNothing);

      // 追问续跑会把同一个任务从终态拉回执行中。此时标签必须自己回来，
      // 否则运行中的任务在面板上既看不见、也没有任何恢复入口。
      taskUpdates.add(<AgentTask>[task..status = AgentTaskStatus.planning]);
      await tester.pump();
      await tester.pump();

      expect(tab, findsOneWidget);
    });

    testWidgets('keeps a closed tab hidden while its task stays terminal',
        (tester) async {
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      final task = _task(
        id: 'still-terminal-task',
        conversationId: 'group-terminal',
        characterId: 'developer',
      )..status = AgentTaskStatus.completed;

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[task]);
      await tester.pump();
      await tester.pump();

      const tabKey = Key('work-task-tab-still-terminal-task');
      final tab = find.byKey(tabKey);
      await tester.tap(
        find.descendant(of: tab, matching: find.byIcon(Icons.close_rounded)),
      );
      await tester.pump();
      expect(tab, findsNothing);

      // 终态任务仍然终止：不能因为“这条被关过”就在下一次流更新里把它放回来。
      taskUpdates.add(<AgentTask>[
        task..updatedAt = DateTime.utc(2026, 3, 1),
      ]);
      await tester.pump();
      await tester.pump();

      expect(tab, findsNothing);
    });

    testWidgets('scopes the tab strip to the active conversation',
        (tester) async {
      // 面板是全 App 覆盖层，但标签栏只该回答"当前会话我该盯哪几条任务"。
      // 曾经它按全局更新时间取前 4 条：用户私聊里刚提交的任务会被别的会话里
      // 早已结束的旧任务挤出标签栏，面板上只剩别人的历史。
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      const conversation = 'dm:active-conversation';
      ConversationPresenceService.instance.enter(conversation);
      addTearDown(
          () => ConversationPresenceService.instance.leave(conversation));
      final mine = _task(
        id: 'mine-task',
        conversationId: conversation,
        characterId: 'developer',
      )
        ..status = AgentTaskStatus.paused
        ..updatedAt = DateTime.utc(2026, 9, 1);
      final others = <AgentTask>[
        for (var index = 0; index < 3; index++)
          _task(
            id: 'other-task-$index',
            conversationId: 'group-old-$index',
            characterId: 'developer',
          )
            ..status = AgentTaskStatus.failed
            ..updatedAt = DateTime.utc(2026, 9, 20 + index),
      ];

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[mine, ...others]);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('work-task-tab-mine-task')), findsOneWidget);
      expect(find.byKey(const Key('work-task-tab-other-task-0')), findsNothing);
      expect(find.byKey(const Key('work-task-tab-other-task-2')), findsNothing);
    });

    testWidgets('counts only the current conversation unfinished tasks',
        (tester) async {
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      const conversation = 'dm:folded-count';
      ConversationPresenceService.instance.enter(conversation);
      addTearDown(
          () => ConversationPresenceService.instance.leave(conversation));
      AgentTask inConversation(String id, AgentTaskStatus status, int day) =>
          _task(
            id: id,
            conversationId: conversation,
            characterId: 'developer',
          )
            ..status = status
            ..updatedAt = DateTime.utc(2026, 5, day);
      final tasks = <AgentTask>[
        for (var index = 0; index < 4; index++)
          inConversation(
              'count-task-$index', AgentTaskStatus.queued, 1 + index),
        // 第 5 条未结束的任务排不进标签栏，才是这行提示真正要说的那一条。
        inConversation('folded-paused-task', AgentTaskStatus.paused, 1),
        // 本会话已结束的任务和别的会话的失败任务都不算队列。
        inConversation(
            'terminal-in-conversation', AgentTaskStatus.completed, 1),
        _task(
          id: 'terminal-elsewhere',
          conversationId: 'group-elsewhere',
          characterId: 'developer',
        )
          ..status = AgentTaskStatus.failed
          ..updatedAt = DateTime.utc(2026, 6, 1),
      ];

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(tasks);
      await tester.pump();
      await tester.pump();

      expect(
        find.text('本会话还有 1 个未结束的任务未在标签栏显示，可在「历史任务」里查看。'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('work-task-tab-terminal-elsewhere')),
          findsNothing);
    });

    testWidgets('refreshes the tab strip when the active conversation changes',
        (tester) async {
      // 标签栏按当前会话收敛，所以切换会话必须主动重算：过去只在任务流更新时
      // 重算，切到另一个已有历史任务的会话时标签栏还是上一个会话的，而且可能
      // 一直不刷新（那个会话没有新任务事件）。
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      final first = _task(
        id: 'switch-one-task',
        conversationId: 'dm:switch-one',
        characterId: 'developer',
      )..status = AgentTaskStatus.paused;
      final second = _task(
        id: 'switch-two-task',
        conversationId: 'dm:switch-two',
        characterId: 'tester',
      )..status = AgentTaskStatus.paused;
      ConversationPresenceService.instance.enter('dm:switch-one');
      addTearDown(() {
        ConversationPresenceService.instance.leave('dm:switch-one');
        ConversationPresenceService.instance.leave('dm:switch-two');
      });

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          showTaskSummarySection: true,
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[first, second]);
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('work-task-tab-switch-one-task')),
          findsOneWidget);
      expect(
          find.byKey(const Key('work-task-tab-switch-two-task')), findsNothing);
      // 上半区默认收起，「执行角色」在「运行状态」卡内容里，需要先展开。
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('执行角色：developer'), findsOneWidget);

      ConversationPresenceService.instance.enter('dm:switch-two');
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('work-task-tab-switch-two-task')),
          findsOneWidget);
      expect(
          find.byKey(const Key('work-task-tab-switch-one-task')), findsNothing);
      // 选中项也必须跟着走：上个会话选过的任务不能继续占着详情。
      // 换任务会回到收起态，所以这里要重新展开「任务详情」。
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('执行角色：tester'), findsOneWidget);
    });

    testWidgets('opens a hidden historical task back into the tab strip',
        (tester) async {
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      final task = _task(
        id: 'history-restore-task',
        conversationId: 'group-restore',
        characterId: 'developer',
      )..status = AgentTaskStatus.completed;
      ConversationPresenceService.instance.enter('group-restore');
      addTearDown(
          () => ConversationPresenceService.instance.leave('group-restore'));

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          showTaskSummarySection: true,
          taskStream: taskUpdates.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          child: const SizedBox.expand(),
        ),
      ));
      taskUpdates.add(<AgentTask>[task]);
      await tester.pump();
      await tester.pump();

      const tabKey = Key('work-task-tab-history-restore-task');
      await tester.tap(
        find.descendant(
            of: find.byKey(tabKey), matching: find.byIcon(Icons.close_rounded)),
      );
      await tester.pump();
      expect(find.byKey(tabKey), findsNothing);

      await tester.tap(find.byKey(const Key('work-task-history-open')));
      await tester.pump();
      await tester.tap(find.byKey(Key('work-task-history-item-${task.id}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('work-task-history-open-in-tabs')));
      await tester.pump();
      await tester.pump();

      // 关掉的标签必须自己回来，用户才能接着操作这条旧任务。
      expect(find.byKey(tabKey), findsOneWidget);
      // 上半区默认收起，「执行角色」在「运行状态」卡内容里，需要先展开。
      await tester.tap(find.byKey(const Key('work-task-details-toggle')));
      await tester.pump();
      expect(find.text('执行角色：developer'), findsOneWidget);
    });
  });

  group('WorkTaskOverlayHost approval prompt', () {
    // Hive and the event store need real file I/O, which the widget-test
    // fake-async zone never pumps. Following the repository convention, the
    // fixture is opened outside the test bodies and only the writes are wrapped
    // in `tester.runAsync`.
    late Directory hiveDirectory;
    late WorkTaskEventStore eventStore;
    late WorkTaskCoordinator coordinator;
    late Box<AgentTask> taskBox;

    setUpAll(() async {
      hiveDirectory = await openLifecycleHive();
      taskBox = Hive.box<AgentTask>(DatabaseService.agentTaskBoxName);
      eventStore = WorkTaskEventStore(appSupportDirectory: hiveDirectory);
      coordinator = WorkTaskCoordinator(
        taskBox: taskBox,
        eventStore: eventStore,
        runner: _HoldingWorkTaskRunner(),
      );
    });

    tearDownAll(() async {
      // A frame can leave a Hive write chain pending in the widget-test
      // fake-async zone, which would make `Hive.close()` wait forever. The
      // fixture only backs this group, so a bounded wait is enough to release
      // the temporary directory without hanging the suite.
      await closeLifecycleHive(hiveDirectory).timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    });

    setUp(() async {
      await taskBox.clear();
    });

    testWidgets(
        'dismissing the approval modal points the user back at the task panel',
        (tester) async {
      // The host presents at most one modal per checkpoint, so a dismissed
      // prompt must still leave a visible route back to the durable approval.
      final task = _task(
        id: 'overlay-dismiss',
        conversationId: 'group-dismiss',
        characterId: 'developer',
      )..status = AgentTaskStatus.queued;
      await tester.runAsync(() => taskBox.put(task.id, task));

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          coordinator: coordinator,
          eventStore: eventStore,
          onStopTask: (_) async {},
          onContinueTask: (_) async {},
          // ScaffoldMessenger only renders a SnackBar once a Scaffold is
          // registered; the production host always sits above one.
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ));
      await tester.pump();

      await tester.runAsync(() async {
        await coordinator.pauseForApproval(
          task.id,
          pendingToolRequestJson: jsonEncode(<String, dynamic>{
            'tool': 'command.run',
            'args': <String, dynamic>{
              'executable': 'echo',
              'arguments': <String>['ok'],
            },
          }),
        );
      });
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('work-generic-approval-dialog')),
      );

      try {
        // Tapping the barrier dismisses the modal without deciding anything.
        await tester.tapAt(const Offset(4, 4));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 750));

        expect(
          find.byKey(const Key('work-generic-approval-dialog')),
          findsNothing,
          reason: '点击遮罩应当关闭弹窗。',
        );
        expect(find.text('已关闭审批弹窗，任务仍在等待审批。'), findsOneWidget);
        expect(find.text('查看任务'), findsOneWidget);
        expect(
          taskBox.get(task.id)?.status,
          AgentTaskStatus.waitingForApproval,
          reason: '关闭弹窗不是拒绝，任务必须继续等待审批。',
        );
      } finally {
        // Real I/O must be drained outside the fake-async zone, matching the
        // repository convention for widget tests that own a coordinator.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(() async {
          await coordinator.dispose();
          await eventStore.close();
        });
      }
    });
  });

  group('WorkTaskOverlayHost P3 decision prompt', () {
    late Directory hiveDirectory;
    late WorkTaskEventStore eventStore;
    late WorkTaskCoordinator coordinator;
    late Box<AgentTask> taskBox;

    setUpAll(() async {
      hiveDirectory = await openLifecycleHive();
      taskBox = Hive.box<AgentTask>(DatabaseService.agentTaskBoxName);
      eventStore = WorkTaskEventStore(appSupportDirectory: hiveDirectory);
      coordinator = WorkTaskCoordinator(
        taskBox: taskBox,
        eventStore: eventStore,
        runner: _HoldingWorkTaskRunner(),
      );
    });

    tearDownAll(() async {
      await closeLifecycleHive(hiveDirectory).timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    });

    testWidgets(
        'P3 active task auto-prompts once and panel reopens the same decision',
        (tester) async {
      const conversation = 'group-p3-dialog';
      ConversationPresenceService.instance.enter(conversation);
      addTearDown(
          () => ConversationPresenceService.instance.leave(conversation));
      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          coordinator: coordinator,
          eventStore: eventStore,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ));
      final task = _decisionTask('p3-dialog', conversation);
      await tester.runAsync(() => coordinator.submit(task));
      await _pumpUntilFound(
          tester, find.byKey(const Key('work-task-decision-dialog')));
      expect(find.text('交付格式选哪一种？'), findsOneWidget);
      expect(find.text('可保留标题'), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-task-decision-close')));
      await tester.pump();
      expect(find.byKey(const Key('work-task-decision-dialog')), findsNothing);
      expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
      await tester.pump();
      expect(find.byKey(const Key('work-task-decision-dialog')), findsNothing);
      await _pumpUntilFound(
          tester, find.byKey(const Key('work-task-open-decision')));
      await tester
          .ensureVisible(find.byKey(const Key('work-task-open-decision')));
      await tester.tap(find.byKey(const Key('work-task-open-decision')));
      await tester.pump();
      expect(
          find.byKey(const Key('work-task-decision-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('work-task-decision-option-md')));
      await _pumpUntil(
          tester,
          () =>
              WorkDiscussionState.fromExecutionState(
                      taskBox.get(task.id)!.executionStateJson)!
                  .collaboration!
                  .decisions
                  .single['status'] ==
              'answered');
      expect(
          WorkDiscussionState.fromExecutionState(
                  taskBox.get(task.id)!.executionStateJson)!
              .collaboration!
              .decisions
              .single['answer'],
          'Markdown');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  group('WorkTaskOverlayHost P3 conversation focus', () {
    late Directory hiveDirectory;
    late WorkTaskEventStore eventStore;
    late WorkTaskCoordinator coordinator;

    setUpAll(() async {
      hiveDirectory = await openLifecycleHive();
      eventStore = WorkTaskEventStore(appSupportDirectory: hiveDirectory);
      coordinator = WorkTaskCoordinator(
        taskBox: Hive.box<AgentTask>(DatabaseService.agentTaskBoxName),
        eventStore: eventStore,
        runner: _HoldingWorkTaskRunner(),
      );
    });

    tearDownAll(() async {
      await closeLifecycleHive(hiveDirectory).timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    });

    testWidgets('P3 other conversations do not replace an open decision',
        (tester) async {
      const firstConversation = 'group-p3-focus-first';
      const secondConversation = 'group-p3-focus-second';
      final first = _decisionTask('p3-focus-first', firstConversation);
      final second = _decisionTask('p3-focus-second', secondConversation);
      await tester.runAsync(() async {
        await coordinator.submit(first);
        await coordinator.submit(second);
      });
      ConversationPresenceService.instance.enter(firstConversation);
      addTearDown(
          () => ConversationPresenceService.instance.leave(secondConversation));
      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          coordinator: coordinator,
          eventStore: eventStore,
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ));
      await _pumpUntilFound(
          tester, find.byKey(const Key('work-task-decision-dialog')));
      ConversationPresenceService.instance.enter(secondConversation);
      await tester.pump();
      expect(
          tester
              .widget<WorkTaskDecisionDialog>(
                  find.byType(WorkTaskDecisionDialog))
              .decisions
              .first
              .taskId,
          first.id);
      await tester.tap(find.byKey(const Key('work-task-decision-close')));
      await _pumpUntil(
          tester,
          () =>
              find.byType(WorkTaskDecisionDialog).evaluate().isNotEmpty &&
              tester
                      .widget<WorkTaskDecisionDialog>(
                          find.byType(WorkTaskDecisionDialog))
                      .decisions
                      .first
                      .taskId ==
                  second.id);
      await tester.tap(find.byKey(const Key('work-task-decision-close')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  group('WorkTaskOverlayHost hidden tab persistence', () {
    // 隐藏标记是持久化的。撤销如果只停在内存里，数据库会继续留着运行中任务的
    // id，启动时又要重新撤销一次，历史列表也会把一条正在跑的任务标成
    // 「已从标签栏隐藏」。
    late Directory hiveDirectory;
    late DatabaseService database;

    setUpAll(() async {
      hiveDirectory = await openLifecycleHive();
      database = DatabaseService();
    });

    tearDownAll(() async {
      await closeLifecycleHive(hiveDirectory, database).timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    });

    setUp(() async {
      await database.appSettingsBox.delete('hidden_work_task_ids');
    });

    testWidgets('clears all persisted markers when hidden tasks are resumed',
        (tester) async {
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      });
      final firstTask = _task(
        id: 'first-persisted-hidden-task',
        conversationId: 'group-persisted',
        characterId: 'developer',
      )..status = AgentTaskStatus.failed;
      final secondTask = _task(
        id: 'second-persisted-hidden-task',
        conversationId: 'group-persisted',
        characterId: 'tester',
      )..status = AgentTaskStatus.failed;
      await tester.runAsync(() async {
        await database.setWorkTaskHidden(firstTask.id, true);
        await database.setWorkTaskHidden(secondTask.id, true);
      });

      await tester.pumpWidget(ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(database)],
        child: MaterialApp(
          home: WorkTaskOverlayHost(
            taskStream: taskUpdates.stream,
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onStopTask: (_) async {},
            onContinueTask: (_) async {},
            child: const SizedBox.expand(),
          ),
        ),
      ));
      taskUpdates.add(<AgentTask>[firstTask, secondTask]);
      await tester.pump();

      firstTask.status = AgentTaskStatus.planning;
      secondTask.status = AgentTaskStatus.runningTool;
      taskUpdates.add(<AgentTask>[firstTask, secondTask]);
      await tester.pump();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );

      expect(
        find.byKey(const Key('work-task-tab-first-persisted-hidden-task')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('work-task-tab-second-persisted-hidden-task')),
        findsOneWidget,
      );
      expect(database.hiddenWorkTaskIds(), isEmpty);
    });
  });

  group('WorkTaskOverlayHost task deletion', () {
    // 删除必须落到 Hive 记录上，并且连带清掉"标签隐藏"这个展示层标记：
    // 记录没了却留着标记，那个 id 会一直占着设置项。
    late Directory hiveDirectory;
    late WorkTaskEventStore eventStore;
    late WorkTaskCoordinator coordinator;
    late Box<AgentTask> taskBox;
    late DatabaseService database;

    setUpAll(() async {
      hiveDirectory = await openLifecycleHive();
      taskBox = Hive.box<AgentTask>(DatabaseService.agentTaskBoxName);
      eventStore = WorkTaskEventStore(appSupportDirectory: hiveDirectory);
      coordinator = WorkTaskCoordinator(
        taskBox: taskBox,
        eventStore: eventStore,
        runner: _HoldingWorkTaskRunner(),
      );
      database = DatabaseService();
    });

    tearDownAll(() async {
      // 理由同「hidden tab persistence」组：widget 测试的 fake-async 区可能留着
      // 未排空的 Hive 写入链，做一次有界等待即可。
      await closeLifecycleHive(hiveDirectory, database).timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    });

    setUp(() async {
      await taskBox.clear();
      await database.appSettingsBox.delete('hidden_work_task_ids');
    });

    testWidgets('removes the record and its hidden marker through the panel',
        (tester) async {
      final task = _task(
        id: 'overlay-delete-task',
        conversationId: 'group-overlay-delete',
        characterId: 'developer',
      )..status = AgentTaskStatus.completed;
      ConversationPresenceService.instance.enter('group-overlay-delete');
      addTearDown(
        () =>
            ConversationPresenceService.instance.leave('group-overlay-delete'),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
      // 预置"这条任务早先被关掉标签"的状态：不再让用例依赖"刚点完关闭、动作是否
      // 已释放"的时序（那会在全量并行时抖动）。
      await tester.runAsync(() async {
        await taskBox.put(task.id, task);
        await database.setWorkTasksHidden(<String>[task.id], true);
      });

      await tester.pumpWidget(ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(database)],
        child: MaterialApp(
          home: WorkTaskOverlayHost(
            coordinator: coordinator,
            eventStore: eventStore,
            onStopTask: (_) async {},
            onContinueTask: (_) async {},
            child: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      ));
      const tabKey = Key('work-task-tab-overlay-delete-task');
      await _pumpUntilFound(
          tester, find.byKey(const Key('work-task-history-open')));
      expect(find.byKey(tabKey), findsNothing, reason: '预置隐藏的标签不应出现');

      // 关掉的标签只能在历史任务里找到，删除入口也必须留在那一层。
      await tester.tap(find.byKey(const Key('work-task-history-open')));
      await tester.pump();
      await _pumpUntilFound(
        tester,
        find.byKey(Key('work-task-history-item-${task.id}')),
      );
      await tester.tap(find.byKey(Key('work-task-history-item-${task.id}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('work-task-history-delete')));
      await tester.pumpAndSettle();
      // 这条任务已经是终态，删除只影响记录本身，不弹确认框。
      expect(find.byKey(const Key('work-task-delete-dialog')), findsNothing);
      await _pumpUntil(tester, () => taskBox.get(task.id) == null);
      await _pumpUntil(
        tester,
        () => !database.hiddenWorkTaskIds().contains(task.id),
      );

      expect(taskBox.get(task.id), isNull);
      expect(database.hiddenWorkTaskIds(), isNot(contains(task.id)));
    });
  });

  group('WorkTaskOverlayHost 胶囊位置持久化', () {
    // 拖过的位置要记住：不落盘的话每次开 App 都得重新拖一遍。
    late Directory hiveDirectory;
    late DatabaseService database;

    setUpAll(() async {
      hiveDirectory = await openLifecycleHive();
      database = DatabaseService();
    });

    tearDownAll(() async {
      await closeLifecycleHive(hiveDirectory, database).timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    });

    setUp(() async {
      await database.appSettingsBox.delete(WorkTaskPillPosition.storageKey);
    });

    Future<void> pumpHost(
      WidgetTester tester, {
      required Size viewport,
      AgentTask? task,
      Future<void> Function(String taskId)? onDeleteTask,
    }) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final taskUpdates = StreamController<List<AgentTask>>.broadcast();
      addTearDown(taskUpdates.close);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(database)],
        child: MaterialApp(
          home: WorkTaskOverlayHost(
            taskStream: taskUpdates.stream,
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onStopTask: (_) async {},
            onContinueTask: (_) async {},
            onDeleteTask: onDeleteTask,
            child: const SizedBox.expand(),
          ),
        ),
      ));
      taskUpdates.add(<AgentTask>[
        task ??
            _task(
              id: 'pill-position-task',
              conversationId: 'group-one',
              characterId: 'developer',
            ),
      ]);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('drag end writes the pill position into app_settings',
        (tester) async {
      await pumpHost(tester, viewport: const Size(800, 800));
      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();

      final before =
          tester.getRect(find.byKey(const Key('work-task-mini-bar')));
      // 拖动手势要在真时钟区里做完：松手会同步发起一次 Hive 写，在假时钟区发起
      // 会让这个 box 的写队列再也推不动，tearDown 的 Hive.close() 直接挂到超时。
      await tester.runAsync(() async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('work-task-mini-bar'))),
        );
        await gesture.moveBy(const Offset(0, kTouchSlop * 2));
        await gesture.moveBy(const Offset(-150, 100));
        await gesture.up();
      });
      await tester.pump();

      final stored = WorkTaskPillPosition.read(database.appSettingsBox);
      expect(stored, isNotNull, reason: '松手后必须把位置写进 app_settings');
      expect(stored!.dx, closeTo(before.left - 150, 1));
      expect(stored.dy, closeTo(before.top + 100, 1));
    });

    testWidgets('a host reads the stored position back on start',
        (tester) async {
      // 重启后必须回到用户放下的地方。写与读分开验：上一条管拖完落盘，这条管
      // 新宿主起来时从 app_settings 里读回来。
      //
      // 不写成「同一条用例里拖动 → 卸掉宿主 → 重建」：那会在假区里留下一个
      // 尚未完成的 Hive 写，紧接着的 pumpWidget 撞上它，整条用例挂到超时。
      await tester.runAsync(() async {
        await WorkTaskPillPosition.write(
          database.appSettingsBox,
          const Offset(240, 300),
        );
      });

      await pumpHost(tester, viewport: const Size(800, 800));
      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();

      final restored =
          tester.getRect(find.byKey(const Key('work-task-mini-bar')));
      expect(restored.left, closeTo(240, 0.5));
      expect(restored.top, closeTo(300, 0.5));
    });

    testWidgets('the reopen button stays inside a window the user shrank',
        (tester) async {
      // 面板被弹窗要求让位时收起（见 _setPanelModalVisibility），只剩右下角那颗
      // 圆钮。它比胶囊小，夹取必须按它自己的尺寸算：按胶囊算会停在窗口外，而这时
      // 胶囊根本不在树上，读不到尺寸就再也修不回来——它是重新打开面板的唯一入口。
      ConversationPresenceService.instance.enter('group-one');
      addTearDown(
          () => ConversationPresenceService.instance.leave('group-one'));
      final task = _task(
        id: 'reopen-clamp-task',
        conversationId: 'group-one',
        characterId: 'developer',
      )..status = AgentTaskStatus.runningTool;

      await pumpHost(
        tester,
        viewport: const Size(800, 800),
        task: task,
        // 删除入口必须存在，历史详情才会去弹确认框；弹框正是让位的那条路径。
        onDeleteTask: (_) async {},
      );

      await tester.tap(find.byKey(const Key('work-task-collapse')));
      await tester.pump();
      // 拖动同样要在真时钟区里做完：松手会发起一次 Hive 写。
      await tester.runAsync(() async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('work-task-mini-bar'))),
        );
        await gesture.moveBy(const Offset(0, kTouchSlop * 2));
        await gesture.moveBy(const Offset(4000, 4000));
        await gesture.up();
      });
      await tester.pump();
      await tester.tap(find.byKey(const Key('work-task-mini-bar')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('work-task-history-open')));
      await tester.pump();
      await tester.tap(find.byKey(Key('work-task-history-item-${task.id}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('work-task-history-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('work-task-reopen')), findsOneWidget);

      // 用户把窗口拖小：圆钮必须跟着被夹回窗口内。
      tester.view.physicalSize = const Size(420, 520);
      await tester.pump();

      final reopen = tester.getRect(find.byKey(const Key('work-task-reopen')));
      expect(reopen.left, greaterThanOrEqualTo(0));
      expect(reopen.top, greaterThanOrEqualTo(0));
      expect(reopen.right, lessThanOrEqualTo(420));
      expect(reopen.bottom, lessThanOrEqualTo(520));
    });
  });

  // 面板覆盖在聊天区之上，静止时半透明以便看见下方内容，指针移入即恢复实体。
  // 触屏平台收不到 hover 事件，静止态会永远回不到实体，所以只在桌面平台生效。
  group('WorkTaskPanel 悬停透明度', () {
    const idleOpacity = 0.85;

    // 面板只占 400x300，画布其余部分是"面板外"，指针才能真的移出去。
    // 平台通过主题指定：生产里 ThemeData.platform 默认就是运行平台。
    Future<void> pumpPanel(
      WidgetTester tester, {
      required TargetPlatform platform,
    }) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                top: 0,
                width: 400,
                height: 300,
                child: WorkTaskPanel(
                  tasks: const <AgentTask>[],
                  eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
                  onSelectTask: (_) {},
                  onStop: (_) {},
                  onContinue: (_) {},
                  onOpenConversation: (_) {},
                  onCollapse: () {},
                  onClose: () {},
                ),
              ),
            ],
          ),
        ),
      ));
      await tester.pump();
    }

    // 读的是 AnimatedOpacity 的目标值，setState 后无需等动画跑完。
    double panelOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find.byKey(const Key('work-task-panel-opacity')),
        )
        .opacity;

    testWidgets('桌面平台：静止半透明，指针移入变实体，移出又变回半透明', (tester) async {
      await pumpPanel(tester, platform: TargetPlatform.macOS);
      expect(panelOpacity(tester), idleOpacity);

      // 指针先落在面板外，避免 addPointer 本身就触发了 onEnter。
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 500));
      addTearDown(mouse.removePointer);

      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('work-task-panel'))),
      );
      await tester.pump();
      expect(panelOpacity(tester), 1.0);

      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(panelOpacity(tester), idleOpacity);
    });

    testWidgets('触屏平台：恒定实体，不会停在半透明', (tester) async {
      await pumpPanel(tester, platform: TargetPlatform.android);

      expect(panelOpacity(tester), 1.0);
    });
  });
}
