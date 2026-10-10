import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/backup/backup_entity_codec.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_context_builder.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:flutter_test/flutter_test.dart';

part 'work_collaboration_state_regressions.dart';

Map<String, dynamic> _approval(String member, String kind, String subject,
        {String iteration = '',
        String digest = '',
        int request = 1,
        int team = 1,
        int verification = 1}) =>
    {
      'eventId': '$kind-$member-$request-$team-$verification-$digest',
      'memberId': member,
      'kind': kind,
      'subjectId': subject,
      'requestRevision': request,
      'teamRevision': team,
      'iterationId': iteration,
      'artifactDigest': digest,
      'verificationRevision': verification,
      'approved': true,
      'evidenceRef': 'message-$member-$kind',
      'source': 'memberModel',
    };

Map<String, dynamic> _fixture() => {
      'taskId': 'task-a',
      'conversationId': 'group-a',
      'projectScopeId': 'scope-a',
      'revision': 1,
      'requestRevision': 1,
      'teamRevision': 1,
      'verificationRevision': 1,
      'requestMessageId': 'request-message',
      'scope': '制作可运行页面',
      'plan': '先实现，再测试',
      'coordinatorId': 'a',
      'phase': 'reviewing',
      'artifactContract': {
        'type': 'software',
        'format': 'html',
        'location': 'game.html',
        'revisionTarget': ''
      },
      'team': [
        {
          'memberId': 'a',
          'role': 'developer',
          'qualificationRef': 'skill-a',
          'qualified': true,
          'available': true
        },
        {
          'memberId': 'b',
          'role': 'tester',
          'qualificationRef': 'skill-b',
          'qualified': true,
          'available': true
        },
      ],
      'workItems': <Map<String, dynamic>>[],
      'issues': <Map<String, dynamic>>[],
      'acceptances': [
        {
          'id': 'qa',
          'method': 'run',
          'requiredCapability': 'browser',
          'status': 'passed',
          'evidenceRef': 'report-a',
          'requestRevision': 1,
          'verificationRevision': 1
        },
      ],
      'iterations': [
        {
          'id': 'r001',
          'artifactDigest': 'sha256-a',
          'requestRevision': 1,
          'teamRevision': 1,
          'manifestRef': 'manifest-a',
          'reviewRef': 'review-a',
          'status': 'reviewed'
        },
      ],
      'approvals': [
        _approval('a', 'plan', 'task-a'),
        _approval('b', 'plan', 'task-a'),
        _approval('a', 'delivery', 'r001',
            iteration: 'r001', digest: 'sha256-a'),
        _approval('b', 'delivery', 'r001',
            iteration: 'r001', digest: 'sha256-a'),
      ],
      'decisions': <Map<String, dynamic>>[],
      'pendingInputIds': <String>[],
      'appliedEventIds': <String>[],
    };

WorkCollaborationState _state(Map<String, dynamic> value) =>
    WorkCollaborationState.tryParse(value)!;

Map<String, dynamic> _issue(String id, String status) => {
      'id': id,
      'sourceId': 'a',
      'kind': 'defect',
      'status': status,
      'target': 'game.html',
      'problem': '缺陷 $id',
      'evidenceRef': 'report-$id',
      'resolution': status == 'resolved' ? '已修复 $id' : '',
      'resolutionRef': status == 'resolved' ? 'fix-$id' : '',
      'retestCondition': '复测 $id',
      'requestRevision': 1
    };

void _replaceRecord(Map<String, dynamic> fixture, String key, int index,
    Map<String, dynamic> patch) {
  final records = (fixture[key] as List)
      .map((item) => Map<String, dynamic>.from(item as Map))
      .toList();
  records[index] = {...records[index], ...patch};
  fixture[key] = records;
}

void main() {
  _registerCollaborationHistoryRegressions();

  test('REREVIEW2 obsolete delivery iterations do not exhaust approvals', () {
    final raw = _fixture()
      ..['verificationRevision'] = 31
      ..['team'] = [
        ..._fixture()['team'] as List,
        {
          'memberId': 'c',
          'role': 'tester',
          'qualificationRef': 'skill-c',
          'qualified': true,
          'available': true
        }
      ]
      ..['acceptances'] = [
        for (final a in _fixture()['acceptances'] as List)
          {...a as Map, 'verificationRevision': 31}
      ]
      ..['iterations'] = [
        for (var i = 1; i <= 31; i++)
          {
            'id': 'r$i',
            'artifactDigest': 'digest-$i',
            'requestRevision': 1,
            'teamRevision': 1,
            'manifestRef': 'manifest-$i',
            'reviewRef': 'report-$i',
            'status': 'reviewed'
          }
      ]
      ..['approvals'] = [
        for (final member in ['a', 'b', 'c'])
          _approval(member, 'plan', 'task-a'),
        for (var i = 1; i <= 30; i++)
          for (final member in ['a', 'b'])
            _approval(member, 'delivery', 'r$i',
                iteration: 'r$i', digest: 'digest-$i', verification: i)
      ];
    final parsed = WorkCollaborationState.tryParse(raw);
    expect(parsed, isNotNull);
    var current = parsed!;
    expect(current.approvals, hasLength(63));
    expect(current.iterations, hasLength(31));
    expect(current.planReady, isTrue);
    for (final member in ['a', 'b']) {
      final eventId = 'current-delivery-$member';
      final signature = {
        ..._approval(member, 'delivery', 'r31',
            iteration: 'r31', digest: 'digest-31', verification: 31),
        'eventId': eventId
      };
      final next = current.toJson()
        ..['revision'] = current.revision + 1
        ..['appliedEventIds'] = [...current.appliedEventIds, eventId]
        ..['approvals'] = [...current.approvals, signature];
      final nextState = WorkCollaborationState.tryParse(next);
      expect(nextState, isNotNull,
          reason: '成员 $member 的当前签字不应被 30 轮已失效的 delivery 签字阻塞');
      current = current.apply(WorkCollaborationUpdate(
          taskId: 'task-a',
          conversationId: 'group-a',
          expectedRevision: current.revision,
          eventId: eventId,
          sourceRole: 'member',
          sourceId: member,
          next: nextState!));
    }
  });

  test('候选迭代超过上限只丢最旧一条，不阻塞状态解析', () {
    // 索引是"最新 N 条"的滚动窗口（见 WorkCollaborationState.boundedIterations）：
    // 候选目录与 candidate.json 仍完整留在工作区，状态里这一行只是有界镜像。
    // 若超限就让 tryParse 返回 null，第 65 轮候选会把任务永久卡死。
    Map<String, dynamic> withIterations(int count) => _fixture()
      ..['iterations'] = [
        for (var i = 1; i <= count; i++)
          {
            'id': 'r${i.toString().padLeft(3, '0')}',
            'artifactDigest': 'digest-$i',
            'requestRevision': 1,
            'teamRevision': 1,
            'manifestRef': 'candidate:r$i',
            'reviewRef': 'report-$i',
            'status': 'reviewed'
          }
      ];

    final overflowed = WorkCollaborationState.tryParse(
        withIterations(WorkCollaborationState.maxIterations + 1));
    expect(overflowed, isNotNull, reason: '超过上限的候选索引仍必须可解析');
    expect(overflowed!.iterations,
        hasLength(WorkCollaborationState.maxIterations));
    expect(overflowed.iterations.first['id'], 'r002');
    expect(overflowed.currentIteration!['id'], 'r065');

    // 满窗口时再追加一轮候选：增量仍被接受，窗口随之前移。
    final current = WorkCollaborationState.tryParse(
        withIterations(WorkCollaborationState.maxIterations))!;
    const eventId = 'candidate-r065';
    final next = WorkCollaborationState.tryParse(current.toJson()
      ..['revision'] = current.revision + 1
      ..['verificationRevision'] = current.verificationRevision + 1
      ..['appliedEventIds'] = [...current.appliedEventIds, eventId]
      ..['iterations'] = [
        ...current.iterations,
        {
          'id': 'r065',
          'artifactDigest': 'digest-65',
          'requestRevision': 1,
          'teamRevision': 1,
          'manifestRef': 'candidate:r065',
          'reviewRef': '',
          'status': 'candidate'
        }
      ])!;
    final applied = current.apply(WorkCollaborationUpdate(
        taskId: 'task-a',
        conversationId: 'group-a',
        expectedRevision: current.revision,
        eventId: eventId,
        sourceRole: 'tool',
        sourceId: 'a',
        next: next));
    expect(applied.iterations, hasLength(WorkCollaborationState.maxIterations));
    expect(applied.iterations.first['id'], 'r002');
    expect(applied.iterations.last['id'], 'r065');
  });

  test('已了结问题按窗口裁剪，未决问题与门槛结论都不变', () {
    // 旧行为：问题台账撞上 64 条上限后整个状态解析成 null，任务永久卡住，连问题
    // 都打不开。实例上未决义务一条不能丢，只有已了结的历史参与窗口。
    final open = _fixture()
      ..['issues'] = [
        for (var i = 1; i <= 66; i++) _issue('d$i', 'resolved'),
        for (var i = 1; i <= 4; i++) _issue('open$i', 'open'),
      ];
    final current = WorkCollaborationState.tryParse(open);
    expect(current, isNotNull, reason: '超过上限的问题台账仍必须可解析');
    expect(current!.issues, hasLength(70));
    expect(current.issuesResolved, isFalse, reason: '4 条未决问题必须继续拦住方案');

    final stored = current.boundedHistory();
    expect(stored.issues, hasLength(68), reason: '66 条已了结只留最新 64 条');
    expect(stored.issues.first['id'], 'd3');
    expect(stored.issues.where((i) => i['status'] == 'open'), hasLength(4));
    expect(stored.issuesResolved, isFalse);

    final settled = _fixture()
      ..['issues'] = [for (var i = 1; i <= 70; i++) _issue('d$i', 'resolved')];
    final before = WorkCollaborationState.tryParse(settled)!;
    expect(before.issuesResolved, isTrue);
    final after = before.boundedHistory();
    expect(after.issues, hasLength(WorkCollaborationState.maxSettledHistory));
    expect(after.issuesResolved, isTrue, reason: '裁剪已了结问题不能改变门槛结论');

    // 唯一落盘入口确实用了这个窗口。
    final persisted = WorkDiscussionState.tryParse(jsonDecode(
        WorkDiscussionState.mergeIntoExecutionState(
            '',
            WorkDiscussionState(
                schemaVersion: 2,
                conversationId: 'group-a',
                phase: WorkDiscussionPhase.ready,
                requestRevision: 1,
                collaboration: before)))['discussionState'])!;
    expect(persisted.collaboration!.issues,
        hasLength(WorkCollaborationState.maxSettledHistory),
        reason: 'mergeIntoExecutionState 必须把台账收口成有界镜像');
    expect(persisted.collaboration!.issuesResolved, isTrue);
  });

  test('已了结问题超上限时仍能答复最后一条未决问题', () {
    // 窗口只挂在落盘入口：按下标比对新旧问题的 _validateMemberResolution 必须看到
    // 完整台账，否则下标错位会把一次正常答复判成"篡改问题或采纳范围提案"。
    final raw = _fixture()
      ..['issues'] = [
        for (var i = 1; i <= 70; i++) _issue('d$i', 'resolved'),
        _issue('open1', 'open'),
      ];
    final current = WorkCollaborationState.tryParse(raw)!;
    const eventId = 'resolution-open1';
    final next = WorkCollaborationState.tryParse(current.toJson()
      ..['revision'] = current.revision + 1
      ..['verificationRevision'] = current.verificationRevision + 1
      ..['appliedEventIds'] = [...current.appliedEventIds, eventId]
      ..['issues'] = [
        for (final issue in current.issues)
          issue['id'] == 'open1'
              ? {
                  ...issue,
                  'status': 'resolved',
                  'resolution': '已修复 open1',
                  'resolutionRef': 'fix-open1'
                }
              : issue
      ])!;
    final applied = current.apply(WorkCollaborationUpdate(
        taskId: 'task-a',
        conversationId: 'group-a',
        expectedRevision: current.revision,
        eventId: eventId,
        sourceRole: 'memberResolution',
        sourceId: 'a',
        next: next));
    expect(applied.issues, hasLength(71));
    expect(applied.issuesResolved, isTrue);
    expect(applied.boundedHistory().issues,
        hasLength(WorkCollaborationState.maxSettledHistory));
  });

  test('决策只丢无人引用的已了结条目', () {
    Map<String, dynamic> decision(String id, String status,
            {String target = ''}) =>
        {
          'id': id,
          'revision': 1,
          'status': status,
          'reason': '需要确认 $id',
          'answer': status == 'pending' ? '' : '按 $id 处理',
          'impact': '影响 $id',
          'responseRef': status == 'pending' ? '' : 'm-$id',
          if (target.isNotEmpty) 'targetId': target,
        };
    final raw = _fixture()
      ..['issues'] = [
        {
          'id': 'w1',
          'sourceId': 'a',
          'kind': 'idea',
          'status': 'waived',
          'target': 'game.html',
          'problem': '范围提案',
          'evidenceRef': 'report-w1',
          'resolution': '',
          'resolutionRef': '',
          'retestCondition': '复测 w1',
          'requestRevision': 1
        }
      ]
      ..['decisions'] = [
        for (var i = 1; i <= 70; i++)
          decision('old$i', 'answered', target: 'gone$i'),
        decision('keep-w1', 'waived', target: 'w1'),
        for (var i = 1; i <= 3; i++) decision('pending$i', 'pending'),
      ];
    final current = WorkCollaborationState.tryParse(raw);
    expect(current, isNotNull, reason: '超过上限的决策台账仍必须可解析');
    expect(current!.decisions, hasLength(74));
    expect(current.issuesResolved, isTrue, reason: '豁免问题靠用户裁决放行');

    final stored = current.boundedHistory();
    expect(stored.decisions, hasLength(68));
    expect(
        stored.decisions.where((d) => d['status'] == 'pending'), hasLength(3));
    expect(stored.decisions.any((d) => d['id'] == 'keep-w1'), isTrue,
        reason: '仍被保留问题引用的裁决不能丢');
    expect(stored.decisions.any((d) => d['id'] == 'old1'), isFalse);
    expect(stored.issuesResolved, isTrue, reason: '裁剪不能改变门槛结论');
  });

  test('没有用户裁决的豁免问题不参与窗口', () {
    // 判据只认"这条自己已经满足门槛"，不能只看状态是 waived：没有用户裁决的豁免
    // 判据并不成立，裁掉它等于替用户放行一条结论。
    final raw = _fixture()
      ..['issues'] = [
        for (var i = 1; i <= 70; i++) _issue('d$i', 'resolved'),
        {..._issue('w-bare', 'waived'), 'kind': 'idea'},
      ];
    final current = WorkCollaborationState.tryParse(raw)!;
    expect(current.issuesResolved, isFalse, reason: '没有用户裁决的豁免不成立');

    final stored = current.boundedHistory();
    expect(stored.issues.any((i) => i['id'] == 'w-bare'), isTrue,
        reason: '判据不成立的条目不能被裁掉');
    expect(stored.issuesResolved, current.issuesResolved);
  });

  test('跨需求版本的历史签字同样归档，不撑满台账', () {
    // 归档键若保留需求版本，32 个版本各留两条就是 64 条，第 65 条签字让整个状态
    // 解析失败、任务被永久卡住——而 plan 的每一个读取判据都钉在当前需求版本上，
    // 更早版本对任何判据都不可见。
    final raw = _fixture()
      ..['requestRevision'] = 33
      ..['phase'] = 'clarifying'
      ..['workItems'] = [
        {
          'id': 'materials',
          'ownerId': 'a',
          'dependencies': <String>[],
          'kind': 'material',
          'status': 'pending',
          'requestRevision': 33
        },
        {
          'id': 'implementation',
          'ownerId': 'a',
          'dependencies': ['materials'],
          'kind': 'produce',
          'status': 'pending',
          'requestRevision': 33
        }
      ]
      ..['acceptances'] = [
        for (final a in _fixture()['acceptances'] as List)
          {
            ...a as Map,
            'requestRevision': 33,
            'status': 'pending',
            'evidenceRef': ''
          }
      ]
      ..['approvals'] = [
        for (var i = 0; i < 64; i++)
          {
            ..._approval(i.isEven ? 'a' : 'b', 'plan', 'task-a',
                request: i ~/ 2 + 1),
            'eventId': 'revision-approval-$i'
          }
      ];
    final current = WorkCollaborationState.tryParse(raw);
    expect(current, isNotNull);
    expect(current!.approvals, hasLength(2), reason: '两个成员各留一条当前有效认可，其余版本是历史');
    final next = current.toJson()
      ..['revision'] = current.revision + 1
      ..['appliedEventIds'] = ['revision-current-approval']
      ..['approvals'] = [
        ...current.approvals,
        {
          ..._approval('a', 'plan', 'task-a', request: 33),
          'eventId': 'revision-current-approval'
        }
      ];
    expect(WorkCollaborationState.tryParse(next), isNotNull,
        reason: '32 个历史需求版本的签字是历史，不该永久占着容量');
  });

  test('归档的历史签字不挡住当前这一次签字', () {
    final raw = _fixture()
      ..['verificationRevision'] = 2
      // 迭代够久时台账会攒下 64 条历史签字：只追加的台账撞上容量上限，下一条就让
      // 整个状态解析失败，任务被永久卡住。
      ..['approvals'] = [
        for (var i = 0; i < 64; i++)
          {..._approval('a', 'plan', 'task-a'), 'eventId': 'historical-$i'}
      ];
    final current = WorkCollaborationState.tryParse(raw);
    expect(current, isNotNull);
    // 同键记录只留最新一条，所以 64 条历史在这里归档成 1 条当前有效认可。
    expect(current!.approvals, hasLength(1));
    final next = current.toJson()
      ..['revision'] = current.revision + 1
      ..['appliedEventIds'] = ['new-current-signature']
      ..['approvals'] = [
        ...current.approvals,
        {
          ..._approval('a', 'plan', 'task-a', verification: 2),
          'eventId': 'new-current-signature'
        }
      ];
    expect(WorkCollaborationState.tryParse(next), isNotNull,
        reason: '历史签字不该永久挡住下一条当前签字');
  });

  test('同一成员改口再改回来仍逐条留证，不并成一条', () {
    // 归档键里带着 `approved`：同意→反对→同意必须各自留证，否则增量校验认不出
    // "这次追加"，改口会被判成非法改写。
    var current = _state(_fixture());
    for (final (index, approved) in [false, true].indexed) {
      final revision = current.revision + 1;
      final eventId = 'flip-$index';
      final map = current.toJson()
        ..['revision'] = revision
        ..['appliedEventIds'] = [...current.appliedEventIds, eventId];
      map['approvals'] = [
        ...current.approvals,
        {
          ..._approval('a', 'plan', 'task-a'),
          'eventId': eventId,
          'approved': approved,
        },
      ];
      current = current.apply(WorkCollaborationUpdate(
          taskId: 'task-a',
          conversationId: 'group-a',
          expectedRevision: current.revision,
          eventId: eventId,
          sourceRole: 'member',
          sourceId: 'a',
          next: _state(map)));
      expect(current.approvals.last['approved'], approved);
    }
    final memberOpinions = current.approvals
        .where((a) => a['memberId'] == 'a' && a['kind'] == 'plan')
        .toList();
    expect(memberOpinions, hasLength(2), reason: '反对与最后的同意都留着');
    expect(memberOpinions.last['approved'], isTrue);
  });

  test('方案和交付要求真实全员认可，百分比与代签不能放行', () {
    final full = _fixture();
    expect(_state(full).planReady, isTrue);
    expect(_state(full).deliveryReady, isTrue);
    final majority = _fixture()
      ..['approvals'] = (_fixture()['approvals'] as List)
          .where((e) => e['memberId'] == 'a')
          .toList();
    expect(_state(majority).planReady, isFalse);
    expect(_state(majority).deliveryReady, isFalse);
    final dissent = _fixture();
    (dissent['approvals'] as List).add({
      ..._approval('b', 'delivery', 'r001',
          iteration: 'r001', digest: 'sha256-a'),
      'eventId': 'dissent-b',
      'approved': false,
    });
    expect(_state(dissent).deliveryReady, isFalse);
    final empty = _fixture()..['team'] = <Map<String, dynamic>>[];
    expect(_state(empty).deliveryReady, isFalse);
    final unavailable = _fixture();
    _replaceRecord(unavailable, 'team', 1, {'available': false});
    expect(_state(unavailable).deliveryReady, isFalse);
    final question = _fixture()
      ..['issues'] = [
        {
          'id': 'rule',
          'sourceId': 'a',
          'kind': 'decision',
          'status': 'open',
          'target': 'goal',
          'problem': '终点规则?',
          'evidenceRef': 'msg',
          'resolution': '',
          'resolutionRef': '',
          'retestCondition': '确认规则',
          'requestRevision': 1
        },
      ];
    expect(_state(question).planReady, isFalse);
    final fake = WorkDiscussionState(
      schemaVersion: 2,
      conversationId: 'group-a',
      phase: WorkDiscussionPhase.ready,
      requestRevision: 1,
      understandingPercent: 100,
      collaboration: _state(majority),
    );
    expect(fake.isExecutionReady, isFalse);
  });

  test('需求、团队、产物和验证变化分别使旧认可失效', () {
    for (final change in [
      'requestRevision',
      'teamRevision',
      'verificationRevision'
    ]) {
      final changed = _fixture()..[change] = 2;
      expect(_state(changed).deliveryReady, isFalse, reason: change);
    }
    final artifact = _fixture();
    _replaceRecord(artifact, 'iterations', 0, {'artifactDigest': 'sha256-b'});
    expect(_state(artifact).deliveryReady, isFalse);
  });

  test('deferred 不是通过或豁免，idea 要全员或用户裁决', () {
    final deferred = _fixture();
    _replaceRecord(deferred, 'acceptances', 0, {'status': 'deferred'});
    expect(_state(deferred).deliveryReady, isFalse);
    final idea = _fixture()
      ..['issues'] = [
        {
          'id': 'idea-a',
          'sourceId': 'a',
          'kind': 'idea',
          'status': 'resolved',
          'target': 'scope',
          'problem': '增加计分',
          'evidenceRef': 'msg',
          'resolution': '加入',
          'resolutionRef': 'msg',
          'retestCondition': '复测',
          'requestRevision': 1
        },
      ];
    expect(_state(idea).planReady, isFalse);
    (idea['approvals'] as List).add(_approval('a', 'idea', 'idea-a'));
    expect(_state(idea).planReady, isFalse);
    (idea['approvals'] as List).add(_approval('b', 'idea', 'idea-a'));
    expect(_state(idea).planReady, isTrue);
  });

  test('增量检查来源、归属和修订；重放不重复认可', () {
    final base = _state(_fixture());
    final nextMap = _fixture();
    nextMap['revision'] = 2;
    nextMap['appliedEventIds'] = ['member-c'];
    (nextMap['approvals'] as List)
        .add({..._approval('a', 'plan', 'task-a'), 'eventId': 'member-c'});
    final next = _state(nextMap);
    WorkCollaborationUpdate update(
            {String task = 'task-a',
            String group = 'group-a',
            int expected = 1,
            String member = 'a'}) =>
        WorkCollaborationUpdate(
            taskId: task,
            conversationId: group,
            expectedRevision: expected,
            eventId: 'member-c',
            sourceRole: 'member',
            sourceId: member,
            next: next);
    final applied = base.apply(update());
    expect(applied.revision, 2);
    expect(applied.apply(update()), same(applied));
    expect(() => base.apply(update(expected: 0)), throwsStateError);
    expect(() => base.apply(update(task: 'other')), throwsStateError);
    expect(() => base.apply(update(group: 'other')), throwsStateError);
    expect(() => base.apply(update(member: 'b')), throwsStateError);
    expect(() => base.apply(update(member: 'coordinator')), throwsStateError);
  });

  test('状态拒绝未知字段且依赖列表不能在构造后被外部改写', () {
    final unknown = _fixture()..['apiConfigId'] = 'secret-ref';
    expect(WorkCollaborationState.tryParse(unknown), isNull);
    final raw = _fixture();
    final dependencies = <String>['item-a'];
    raw['workItems'] = [
      {
        'id': 'item-b',
        'ownerId': 'a',
        'dependencies': dependencies,
        'status': 'pending',
        'requestRevision': 1
      },
    ];
    final state = _state(raw);
    dependencies.add('item-c');
    expect(state.workItems.single['dependencies'], ['item-a']);
  });

  test('状态边界拒绝时只返回具体字段路径诊断', () {
    final raw = _fixture()
      ..['artifactContract'] = {
        ..._fixture()['artifactContract'] as Map,
        'files': [42]
      };
    String? section;
    expect(
        WorkCollaborationState.tryParse(raw,
            onInvalid: (value) => section = value),
        isNull);
    expect(section, 'artifactContract.files');

    final invalidLocation = _fixture()
      ..['artifactContract'] = {
        ..._fixture()['artifactContract'] as Map,
        'location': 42
      };
    section = null;
    expect(
        WorkCollaborationState.tryParse(invalidLocation,
            onInvalid: (value) => section = value),
        isNull);
    expect(section, 'artifactContract.location');

    final unexpectedContractField = _fixture()
      ..['artifactContract'] = {
        ..._fixture()['artifactContract'] as Map,
        'verificationEnvironment': 'node+jsdom'
      };
    section = null;
    expect(
        WorkCollaborationState.tryParse(unexpectedContractField,
            onInvalid: (value) => section = value),
        isNull);
    expect(section, 'artifactContract.fields(verificationEnvironment)');
  });

  test('成员新问题保存来源并使旧认可失效，决策不能沿用旧需求版本', () {
    final current = _state(_fixture());
    final issueRaw = _fixture();
    issueRaw['revision'] = 2;
    issueRaw['verificationRevision'] = 2;
    issueRaw['appliedEventIds'] = ['issue-event'];
    issueRaw['issues'] = [
      {
        'id': 'issue-a',
        'sourceId': 'a',
        'kind': 'defect',
        'status': 'open',
        'target': 'qa',
        'problem': '按钮重复执行',
        'evidenceRef': 'message-a',
        'resolution': '',
        'resolutionRef': '',
        'retestCondition': '复测连点',
        'requestRevision': 1
      },
    ];
    WorkCollaborationUpdate issueUpdate(String source) =>
        WorkCollaborationUpdate(
            taskId: 'task-a',
            conversationId: 'group-a',
            expectedRevision: 1,
            eventId: 'issue-event',
            sourceRole: 'member',
            sourceId: source,
            next: _state(issueRaw));
    expect(() => current.apply(issueUpdate('b')), throwsStateError);
    final afterIssue = current.apply(issueUpdate('a'));
    expect(afterIssue.deliveryReady, isFalse);
    expect(afterIssue.issues.single['sourceId'], 'a');

    final decisionRaw = _fixture();
    decisionRaw['revision'] = 2;
    decisionRaw['appliedEventIds'] = ['user-decision'];
    decisionRaw['decisions'] = [
      {
        'id': 'decision-a',
        'revision': 1,
        'status': 'answered',
        'reason': '范围取舍',
        'answer': '增加计分',
        'impact': '改变范围',
        'responseRef': 'user-message'
      },
    ];
    final decision = WorkCollaborationUpdate(
        taskId: 'task-a',
        conversationId: 'group-a',
        expectedRevision: 1,
        eventId: 'user-decision',
        sourceRole: 'user',
        sourceId: 'user',
        next: _state(decisionRaw));
    expect(() => current.apply(decision), throwsStateError);
  });

  test(
      'P8 portable rebinding retains history and pending work but invalidates old approvals',
      () {
    final raw = _fixture()..['projectScopeId'] = 'portable-unbound';
    raw['decisions'] = [
      for (final status in ['answered', 'deferred', 'waived'])
        {
          'id': 'decision-$status',
          'revision': 1,
          'status': status,
          'reason': '旧环境核对',
          'answer': '旧答案',
          'impact': '需核对',
          'responseRef': 'old-answer',
          'answerKind': 'waiver',
          'promptedReminder': 'initial'
        }
    ];
    final imported = _state(raw);
    final patch = imported.portableProjectBindingPatch('new-scope');
    final next = _state({
      ...raw,
      ...patch,
      'revision': imported.revision + 1,
      'appliedEventIds': [...imported.appliedEventIds, 'rebind']
    });
    WorkCollaborationUpdate update(WorkCollaborationState value) =>
        WorkCollaborationUpdate(
            taskId: imported.taskId,
            conversationId: imported.conversationId,
            expectedRevision: imported.revision,
            eventId: 'rebind',
            sourceRole: 'projectBinding',
            sourceId: 'new-scope',
            next: value);
    final rebound = imported.apply(update(next));
    expect(rebound.projectScopeId, 'new-scope');
    expect(rebound.planReady, isFalse);
    expect(rebound.deliveryReady, isFalse);
    expect(rebound.approvals, imported.approvals);
    expect(rebound.iterations, imported.iterations);
    expect(rebound.workItems.every((i) => i['status'] == 'pending'), isTrue);
    expect(rebound.acceptances.every((a) => a['status'] == 'pending'), isTrue);
    expect(rebound.pendingInputIds, imported.pendingInputIds);
    expect(rebound.decisions.map((d) => d['status']),
        ['pending', 'deferred', 'pending']);
    expect(rebound.decisions.every((d) => d['answer'] == ''), isTrue);
    expect(rebound.decisions.every((d) => !d.containsKey('promptedReminder')),
        isTrue);
    expect(imported.plan, isNotEmpty);
    final forged = _state({...next.toJson(), 'plan': imported.plan});
    expect(() => imported.apply(update(forged)), throwsStateError);
    expect(() => _state(_fixture()).portableProjectBindingPatch('new-scope'),
        throwsStateError);
  });

  test('v1 显式转换、未知和坏 JSON 阻塞；压缩不改权威状态', () {
    final task = AgentTask(
        id: 'task-a',
        groupId: 'group-a',
        characterId: 'a',
        userRequest: '做页面',
        workModeTask: true);
    final v1 = WorkDiscussionState.initial(
        conversationId: 'group-a',
        executorId: 'a',
        candidateCharacterIds: ['a']);
    final converted =
        WorkDiscussionState.fromLegacyTask(task, v1, projectScopeId: 'scope-a');
    expect(converted.schemaVersion, 2);
    expect(converted.isExecutionReady, isFalse);
    expect(WorkDiscussionState.tryParse({...v1.toJson(), 'schemaVersion': 99}),
        isNull);
    expect(
        WorkDiscussionState.decodeExecutionState('{broken').isValid, isFalse);
    expect(workExecutionCheckpointRequiresReview('{broken'), isTrue);
    expect(
        workExecutionCheckpointRequiresReview('{"schemaVersion":99}'), isTrue);
    final ready = WorkDiscussionState(
        schemaVersion: 2,
        conversationId: 'group-a',
        phase: WorkDiscussionPhase.ready,
        requestRevision: 1,
        collaboration: _state(_fixture()));
    task.executionStateJson =
        WorkDiscussionState.mergeIntoExecutionState('', ready);
    final before = task.executionStateJson;
    final snapshot = const WorkContextBuilder().fromTask(task);
    expect(snapshot.discussionState?.collaboration?.deliveryReady, isTrue);
    expect(task.executionStateJson, before);
    expect(() => WorkDiscussionState.mergeIntoExecutionState('{broken', ready),
        throwsA(anything));
    expect(() => WorkDiscussionState.mergeIntoExecutionState(before, v1),
        throwsStateError);
    expect(() => WorkDiscussionState.mergeIntoExecutionState(before, ready),
        throwsStateError);
    expect(
        () => WorkDiscussionState.mergeIntoExecutionState(
            jsonEncode({
              'discussionState': {'schemaVersion': 99}
            }),
            ready),
        throwsStateError);
    expect(WorkDiscussionState.currentRequestScope(task), '制作可运行页面');
    final backup = BackupEntityCodec.task(task);
    final portable = jsonDecode(backup['executionStateJson'] as String) as Map;
    final restored = WorkDiscussionState.tryParse(portable['discussionState']);
    expect(restored?.collaboration?.deliveryReady, isFalse);
    expect(restored?.collaboration?.projectScopeId, 'portable-unbound');
    expect(restored?.collaboration?.team.every((e) => e['available'] == false),
        isTrue);
    expect((backup['executionStateJson'] as String),
        isNot(contains('manifest-a')));
    expect(
        WorkDiscussionState.requiresDiscussionForConversation('dm:a'), isFalse);
  });
}
