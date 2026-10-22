import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/text/entity_labels.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_domain_labels.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';

WorkCollaborationState _state({
  required List<String> iterations,
  String conversationId = 'group-1',
}) {
  final raw = WorkCollaborationState.fromLegacy(
    taskId: 'task-1',
    conversationId: conversationId,
    projectScopeId: 'scope-1',
    requestRevision: 1,
    requestMessageId: 'request-1',
    scope: '生成一个 HTML 页面',
    artifactContract: <String, dynamic>{
      'type': 'software',
      'format': 'html',
      'location': 'out/index.html',
      'revisionTarget': '',
    },
  ).toJson()
    ..['iterations'] = [
      for (final id in iterations)
        <String, dynamic>{
          'id': id,
          'artifactDigest': 'digest-$id',
          'requestRevision': 1,
          'teamRevision': 1,
          'manifestRef': '',
          'reviewRef': '',
          'status': 'candidate',
        },
    ];
  return WorkCollaborationState.tryParse(raw)!;
}

/// 带 v2 协作状态的任务，用于气泡侧的按会话解析。
AgentTask _task(
  String id, {
  required List<String> iterations,
  String conversationId = 'group-1',
}) {
  final task = AgentTask(
    id: id,
    groupId: conversationId,
    characterId: 'member-1',
    userRequest: '生成一个 HTML 页面',
    workModeTask: true,
  )..status = AgentTaskStatus.paused;
  task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
    '',
    WorkDiscussionState.initial(
      conversationId: conversationId,
      requestRevision: 1,
    ).copyWith(
      schemaVersion: 2,
      collaboration:
          _state(iterations: iterations, conversationId: conversationId),
    ),
  );
  return task;
}

void main() {
  const first = '11111111-1111-4111-8111-111111111111';
  const second = '22222222-2222-4222-8222-222222222222';

  test('方案问题的任务目标显示为工作任务且不改写权威 id', () {
    final state = _state(iterations: const []);
    expect(WorkDomainLabels(state).resolver(state.taskId), '工作任务');
    expect(state.toJson()['taskId'], 'task-1');
  });

  test('迭代 id 映射为第 N 轮候选', () {
    final labels =
        WorkDomainLabels(_state(iterations: <String>[first, second]));
    expect(labels.resolver(first), '第 1 轮候选');
    expect(labels.resolver(second), '第 2 轮候选');
  });

  test('不认识的 id 返回 null，交给上层兜底', () {
    final labels = WorkDomainLabels(_state(iterations: <String>[first]));
    expect(labels.resolver('33333333-3333-4333-8333-333333333333'), isNull);
  });

  test('状态为空时不解析任何 id', () {
    expect(WorkDomainLabels(null).resolver(first), isNull);
  });

  test('humanize 把候选 id 变成人话', () {
    final labels = WorkDomainLabels(_state(iterations: <String>[first]));
    final entityLabels =
        EntityLabels(resolvers: <EntityIdResolver>[labels.resolver]);
    expect(
      entityLabels.humanize('候选送测 $first，文件已冻结。'),
      '候选送测 第 1 轮候选，文件已冻结。',
    );
  });

  group('forConversation（气泡侧按会话解析）', () {
    late Directory directory;
    late DatabaseService db;

    setUpAll(() async {
      directory = await openLifecycleHive();
      db = DatabaseService();
    });

    tearDownAll(() => closeLifecycleHive(directory, db));

    test('多任务会话按 id 归属解析，而不是只认第一条任务', () async {
      await db.agentTaskBox
          .put('task-newer', _task('task-newer', iterations: <String>[second]));
      await db.agentTaskBox
          .put('task-older', _task('task-older', iterations: <String>[first]));

      final resolve = WorkDomainLabels.forConversation(db, 'group-1');
      expect(resolve(first), '第 1 轮候选');
      expect(resolve(second), '第 1 轮候选');
    });

    test('首轮未命中后状态写入，下一次调用能重新解析', () async {
      final resolve = WorkDomainLabels.forConversation(db, 'group-2');
      expect(resolve(first), isNull);

      await db.agentTaskBox.put(
        'task-late',
        _task('task-late',
            iterations: <String>[first], conversationId: 'group-2'),
      );
      expect(resolve(first), '第 1 轮候选');
    });

    test('没有任何协作状态时不崩', () {
      final resolve = WorkDomainLabels.forConversation(db, 'group-none');
      expect(resolve(first), isNull);
    });

    test('labelsForTask 把任务协作状态叠加成领域解析器', () {
      const memberId = 'e1f80660-581f-488b-b8e6-94cb63192ec1';
      final base = EntityLabels.fixed(const {memberId: '程序媛'});
      final task = _task('task-labels', iterations: <String>[first]);

      final merged =
          WorkDomainLabels.labelsForTask(base, task.executionStateJson);
      expect(merged, isNotNull);
      expect(
        merged!.humanize('候选送测 $first，负责人 $memberId'),
        '候选送测 第 1 轮候选，负责人 程序媛',
      );
      // humanize 只换 UUID 形态 token：短 id 不猜、原样保留。
      expect(merged.humanize('负责人 member-1'), '负责人 member-1');
    });

    test('labelsForTask 对空标签与无协作状态保持原样', () {
      expect(WorkDomainLabels.labelsForTask(null, '{}'), isNull);
      final base = EntityLabels.fixed(const {'member-1': '程序媛'});
      expect(WorkDomainLabels.labelsForTask(base, '{}'), same(base));
    });
  });
}
