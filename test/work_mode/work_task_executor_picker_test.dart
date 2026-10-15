import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/text/entity_labels.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 还没有执行人、但检查点里已经有合格候选的群任务。
///
/// 这正是路由把执行人交给群推举之后、讨论结果出来之前的那段中间态：执行人为空，
/// 候选已知。面板要在这段时间里给出可点的选择，而不是只留一句"你无需操作"。
AgentTask _taskWithCandidates(
  String id, {
  String? executorId,
  List<String> candidates = const <String>['front', 'engine'],
  String? collaborationPhase,
  AgentTaskStatus status = AgentTaskStatus.paused,
  bool workModeTask = true,
}) {
  final state = WorkDiscussionState.initial(
    conversationId: 'group-$id',
    requestRevision: 1,
    executorId: executorId,
    candidateCharacterIds: candidates,
    participantCharacterIds: candidates,
  );
  var effective = state;
  if (collaborationPhase != null) {
    final raw = WorkCollaborationState.fromLegacy(
      taskId: id,
      conversationId: 'group-$id',
      projectScopeId: 'scope-$id',
      requestRevision: 1,
      requestMessageId: 'request-$id',
      scope: '生成一个 HTML 页面',
      artifactContract: <String, dynamic>{
        'type': 'software',
        'format': 'html',
        'location': 'out/index.html',
        'revisionTarget': '',
      },
    ).toJson()
      ..['phase'] = collaborationPhase;
    effective = state.copyWith(
      schemaVersion: 2,
      collaboration: WorkCollaborationState.tryParse(raw)!,
    );
  }
  final task = AgentTask(
    id: id,
    groupId: 'group-$id',
    characterId: executorId ?? '',
    userRequest: '生成一个 HTML 页面',
    assignedCharacterIds: candidates,
    plan: '角色路由候选',
    workModeTask: workModeTask,
  )
    ..status = status
    ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      effective,
    );
  return task;
}

Future<void> _pumpPanel(
  WidgetTester tester,
  AgentTask task, {
  WorkTaskExecutorPick? onSelectExecutor,
  EntityLabels? entityLabels,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 420,
          height: 620,
          child: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
            onSelectExecutor: onSelectExecutor,
            entityLabels: entityLabels,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('无执行人但有候选时把候选列成可点按钮', (tester) async {
    final task = _taskWithCandidates('pick-shown');
    await _pumpPanel(
      tester,
      task,
      onSelectExecutor: (_, __) {},
      entityLabels: EntityLabels(resolvers: <EntityIdResolver>[(id) => id == 'front' ? '程序媛' : '周鹏飞']),
    );

    expect(find.text('指定最终执行人'), findsOneWidget);
    expect(find.text('程序媛'), findsOneWidget);
    expect(find.text('周鹏飞'), findsOneWidget);
    // 讨论此刻正在自动推举：文案必须先说清用户不是非动手不可。
    expect(find.text('你无需操作；群内也会自动推举。点选即直接指定。'), findsOneWidget);
    expect(
      find.byKey(const Key('work-task-executor-option-front')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点击候选按钮把该角色 id 交给协调器', (tester) async {
    final task = _taskWithCandidates('pick-tapped');
    final picked = <String>[];
    await _pumpPanel(
      tester,
      task,
      onSelectExecutor: (taskId, characterId) {
        picked.add('$taskId:$characterId');
      },
      entityLabels: EntityLabels.none(),
    );

    await tester.tap(find.byKey(const Key('work-task-executor-option-engine')));
    await tester.pump();

    expect(picked, <String>['pick-tapped:engine']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('已经有执行人时不再显示选择框', (tester) async {
    final task = _taskWithCandidates(
      'pick-assigned',
      executorId: 'front',
      candidates: const <String>['front'],
    );
    await _pumpPanel(tester, task, onSelectExecutor: (_, __) {});

    expect(find.text('指定最终执行人'), findsNothing);
    expect(
      find.byKey(const Key('work-task-executor-option-front')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('没有候选时不显示空的选择框', (tester) async {
    final task = _taskWithCandidates(
      'pick-no-candidates',
      candidates: const <String>[],
    );
    await _pumpPanel(tester, task, onSelectExecutor: (_, __) {});

    expect(find.text('指定最终执行人'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('终态任务不显示选择框', (tester) async {
    final task = _taskWithCandidates(
      'pick-terminal',
      status: AgentTaskStatus.completed,
    );
    await _pumpPanel(tester, task, onSelectExecutor: (_, __) {});

    expect(find.text('指定最终执行人'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('协作已进入制作阶段后不再显示选择框', (tester) async {
    final task = _taskWithCandidates(
      'pick-producing',
      collaborationPhase: 'producing',
    );
    await _pumpPanel(tester, task, onSelectExecutor: (_, __) {});

    expect(find.text('指定最终执行人'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('协作仍在澄清阶段时选择框可用', (tester) async {
    final task = _taskWithCandidates(
      'pick-clarifying',
      collaborationPhase: 'clarifying',
    );
    await _pumpPanel(tester, task, onSelectExecutor: (_, __) {});

    expect(find.text('指定最终执行人'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('宿主没有提供回调时选择框不出现', (tester) async {
    final task = _taskWithCandidates('pick-no-callback');
    await _pumpPanel(tester, task);

    expect(find.text('指定最终执行人'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('候选重名时按钮补上 id 前缀，两个按钮不再一模一样', (tester) async {
    final task = _taskWithCandidates(
      'pick-duplicate-name',
      candidates: const <String>['front-a', 'front-b'],
    );
    await _pumpPanel(
      tester,
      task,
      onSelectExecutor: (_, __) {},
      entityLabels: EntityLabels(resolvers: <EntityIdResolver>[(id) => '程序媛']),
    );

    expect(find.text('程序媛（front-a）'), findsOneWidget);
    expect(find.text('程序媛（front-b）'), findsOneWidget);
    // 提交的仍是完整 id：只有 id 能区分同名候选。
    expect(
      find.byKey(const Key('work-task-executor-option-front-a')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
