import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('默认群工作面板可打开全部问题详情，不拼职业模板或理解百分比', (tester) async {
    final task = AgentTask(
        id: 'panel-v2',
        groupId: 'group-v2',
        characterId: 'dev',
        userRequest: '开发游戏',
        workModeTask: true,
        status: AgentTaskStatus.paused);
    final initial = WorkDiscussionState.fromLegacyTask(
        task, WorkDiscussionState.initial(conversationId: task.groupId),
        projectScopeId: 'project');
    final json = initial.collaboration!.toJson();
    json['issues'] = [
      for (var i = 0; i < 3; i++)
        {
          'id': 'issue$i',
          'kind': 'decision',
          'sourceId': 'dev',
          'target': 'rule',
          'status': 'open',
          'problem': '玩法问题$i',
          'evidenceRef': 'response$i',
          'retestCondition': '明确规则$i',
          'resolution': '',
          'resolutionRef': '',
          'requestRevision': 1
        }
    ];
    json['iterations'] = [
      {
        'id': 'r001',
        'artifactDigest': 'a' * 64,
        'requestRevision': 1,
        'teamRevision': 1,
        'manifestRef': 'candidate:r001',
        'reviewRef': 'review:r001:a1',
        'status': 'reviewed'
      }
    ];
    json['approvals'] = [
      for (final id in ['dev', 'qa'])
        {
          'eventId': 'approval-$id',
          'memberId': id,
          'kind': 'delivery',
          'subjectId': 'r001',
          'requestRevision': 1,
          'teamRevision': 1,
          'verificationRevision': 1,
          'iterationId': 'r001',
          'artifactDigest': 'a' * 64,
          'approved': id == 'dev',
          'evidenceRef': 'response-$id',
          'source': 'memberModel'
        }
    ];
    final collaboration = WorkCollaborationState.tryParse(json)!;
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '', initial.copyWith(collaboration: collaboration));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 700,
                height: 500,
                child: WorkTaskPanel(
                    tasks: [task],
                    eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
                    onSelectTask: (_) {},
                    onStop: (_) {},
                    onContinue: (_) {},
                    onOpenConversation: (_) {},
                    onCollapse: () {},
                    onClose: () {})))));
    await tester.pump();
    await tester.tap(find.byKey(const Key('work-v2-discussion-details')));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      expect(find.textContaining('玩法问题$i'), findsOneWidget);
    }
    expect(find.textContaining('候选 r001'), findsOneWidget);
    expect(find.textContaining('认可 dev：同意'), findsOneWidget);
    expect(find.textContaining('认可 qa：异议'), findsOneWidget);
    expect(find.textContaining('理解进度'), findsNothing);
    json['verificationRevision'] = 2;
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        initial.copyWith(
            collaboration: WorkCollaborationState.tryParse(json)!));
    await tester.tap(find.byKey(const Key('work-v2-discussion-details')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('work-v2-discussion-details')));
    await tester.pump();
    expect(find.textContaining('已失效'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
  testWidgets('自主面板分开显示制作执行者和当前试用成员，未使用不显示通过', (tester) async {
    final task = AgentTask(
        id: 'autonomy-panel',
        groupId: 'group',
        characterId: 'qa',
        userRequest: '制作文件',
        workModeTask: true,
        status: AgentTaskStatus.paused);
    final legacy = WorkDiscussionState.initial(conversationId: 'group')
        .copyWith(executorId: 'qa');
    final shell = WorkDiscussionState.fromLegacyTask(task, legacy,
        projectScopeId: 'project');
    final raw = shell.collaboration!.toJson()
      ..['autonomyPolicy'] = WorkCollaborationAutonomy.policyFor(['dev', 'qa'])
      ..['workItems'] = [
        {
          'id': 'make',
          'ownerId': 'dev',
          'kind': 'produce',
          'dependencies': [],
          'status': 'pending',
          'requestRevision': 1,
        }
      ]
      ..['usageAssignments'] = [
        for (final id in ['dev', 'qa'])
          {
            'memberId': id,
            'scenarioId': 'scene-$id',
            'goal': '使用场景 $id',
            'preconditions': '测试数据',
            'stepGoals': ['执行路径 $id'],
            'expectedResult': '路径 $id 的结果',
            'acceptanceIds': ['qa'],
            'requiredCapabilities': ['native'],
            'resetMethod': '独立重置',
            'requestRevision': 1,
          }
      ]
      ..['usageEvidenceRefs'] = []
      ..['coordinatorDecisions'] = [];
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState('',
        shell.copyWith(collaboration: WorkCollaborationState.tryParse(raw)!));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 700,
                height: 500,
                child: WorkTaskPanel(
                    tasks: [task],
                    eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
                    characterNameFor: (id) => id == 'dev' ? '制作成员' : '试用成员',
                    onSelectTask: (_) {},
                    onStop: (_) {},
                    onContinue: (_) {},
                    onOpenConversation: (_) {},
                    onCollapse: () {},
                    onClose: () {})))));
    await tester.pump();
    await tester.tap(find.byKey(const Key('work-v2-discussion-details')));
    await tester.pump();
    expect(find.text('制作执行者：制作成员'), findsOneWidget);
    expect(find.textContaining('当前成员：试用成员'), findsOneWidget);
    expect(find.textContaining('待实际使用'), findsNWidgets(2));
    expect(find.textContaining('已记录本轮反馈'), findsNothing);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
