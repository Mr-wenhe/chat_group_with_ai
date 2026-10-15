import 'package:chat_group/core/text/entity_labels.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_domain_labels.dart';
import 'package:flutter_test/flutter_test.dart';

WorkCollaborationState _state({required List<String> iterations}) {
  final raw = WorkCollaborationState.fromLegacy(
    taskId: 'task-1',
    conversationId: 'group-1',
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

void main() {
  const first = '11111111-1111-4111-8111-111111111111';
  const second = '22222222-2222-4222-8222-222222222222';

  test('迭代 id 映射为第 N 轮候选', () {
    final labels = WorkDomainLabels(_state(iterations: <String>[first, second]));
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
}
