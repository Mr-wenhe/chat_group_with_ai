import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/text/entity_labels.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _memberId = 'e1f80660-581f-488b-b8e6-94cb63192ec1';
const _iterationId = '11111111-1111-4111-8111-111111111111';

/// 带 v2 协作状态的群任务：执行人是 [_memberId]，可选带一条候选版本。
AgentTask _v2Task(
  String id, {
  String? iterationId,
  String request = '生成一个 HTML 页面',
}) {
  final base = WorkDiscussionState.initial(
    conversationId: 'group-$id',
    requestRevision: 1,
    executorId: _memberId,
    candidateCharacterIds: const <String>[_memberId],
    participantCharacterIds: const <String>[_memberId],
  );
  final raw = WorkCollaborationState.fromLegacy(
    taskId: id,
    conversationId: 'group-$id',
    projectScopeId: 'scope-$id',
    requestRevision: 1,
    requestMessageId: 'request-$id',
    scope: request,
    artifactContract: <String, dynamic>{
      'type': 'software',
      'format': 'html',
      'location': 'out/index.html',
      'revisionTarget': '',
    },
  ).toJson();
  if (iterationId != null) {
    raw['iterations'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'id': iterationId,
        'artifactDigest': 'sha256-3f9a1c7e5b2d8046',
        'requestRevision': 1,
        'teamRevision': 1,
        'manifestRef': '',
        'reviewRef': '',
        'status': 'candidate',
      },
    ];
  }
  final task = AgentTask(
    id: id,
    groupId: 'group-$id',
    characterId: _memberId,
    userRequest: request,
    assignedCharacterIds: const <String>[_memberId],
    plan: '角色路由候选',
    workModeTask: true,
  )
    ..status = AgentTaskStatus.paused
    ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      base.copyWith(
        schemaVersion: 2,
        collaboration: WorkCollaborationState.tryParse(raw)!,
      ),
    );
  return task;
}

Future<void> _pumpPanel(
  WidgetTester tester,
  AgentTask task, {
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
            entityLabels: entityLabels,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

/// 「问题与方案详情」默认收起，当前成员与候选版本都在展开后才渲染。
Future<void> _expandDiscussion(WidgetTester tester) async {
  await tester.tap(find.text('问题与方案详情'));
  await tester.pump();
}

void main() {
  testWidgets('面板不再显示成员 UUID，改为角色名', (tester) async {
    await _pumpPanel(
      tester,
      _v2Task('label-1'),
      entityLabels: EntityLabels.fixed(const {_memberId: '产品经理'}),
    );
    await _expandDiscussion(tester);

    expect(find.textContaining(_memberId), findsNothing);
    expect(find.textContaining('产品经理'), findsWidgets);
  });

  testWidgets('候选版本 id 显示为第 N 轮候选', (tester) async {
    await _pumpPanel(
      tester,
      _v2Task('label-2', iterationId: _iterationId),
      entityLabels: EntityLabels.fixed(const {
        _memberId: '产品经理',
        _iterationId: '第 1 轮候选',
      }),
    );
    await _expandDiscussion(tester);

    expect(find.textContaining(_iterationId), findsNothing);
    expect(find.textContaining('第 1 轮候选'), findsWidgets);
  });

  testWidgets('labels 为空时不崩、文本原样', (tester) async {
    await _pumpPanel(tester, _v2Task('label-3', iterationId: _iterationId));
    await _expandDiscussion(tester);

    expect(tester.takeException(), isNull);
    expect(find.textContaining(_iterationId), findsWidgets);
  });

  testWidgets('长正文截断不产生半个名字', (tester) async {
    final task = _v2Task(
      'label-4',
      iterationId: _iterationId,
      request: '${'长'.padRight(3990, '长')}$_memberId 结束',
    );
    await _pumpPanel(
      tester,
      task,
      entityLabels: EntityLabels.fixed(const {_memberId: '产品经理'}),
    );

    expect(tester.takeException(), isNull);
  });
}
