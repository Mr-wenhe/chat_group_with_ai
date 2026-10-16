part of 'work_collaboration_state_test.dart';

Map<String, dynamic> _autonomousFixture() {
  final raw = _fixture()
    ..['autonomyPolicy'] = WorkCollaborationAutonomy.policyFor(['a', 'b'])
    ..['workItems'] = [
      {
        'id': 'make',
        'ownerId': 'a',
        'kind': 'produce',
        'dependencies': [],
        'status': 'done',
        'requestRevision': 1
      }
    ]
    ..['usageEvidenceRefs'] = []
    ..['coordinatorDecisions'] = []
    ..['usageAssignments'] = [
      for (final m in ['a', 'b'])
        {
          'memberId': m,
          'scenarioId': 'scenario-$m',
          'goal': '使用路径 $m',
          'preconditions': '独立空数据',
          'stepGoals': ['完成路径 $m'],
          'expectedResult': '结果 $m',
          'acceptanceIds': ['qa'],
          'requiredCapabilities': ['native'],
          'resetMethod': '删除本场景测试数据',
          'requestRevision': 1,
        }
    ];
  final current = _state(raw);
  raw['usageEvidenceRefs'] = [
    for (final m in ['a', 'b'])
      {
        'taskId': 'task-a',
        'conversationId': 'group-a',
        'memberId': m,
        'scenarioId': 'scenario-$m',
        'requestRevision': 1,
        'teamRevision': 1,
        'iterationId': 'r001',
        'artifactDigest': 'sha256-a',
        'planDigest': current.usagePlanDigest,
        'verificationRevision': 1,
        'receiptRef': 'usage:${m * 24}',
        'feedbackRef': 'feedback-$m',
        'status': 'passed',
      }
  ];
  raw['coordinatorDecisions'] = [
    for (final kind in ['plan', 'delivery'])
      {
        'eventId': 'ruling-$kind',
        'coordinatorId': 'a',
        'kind': kind,
        'subjectId': kind == 'plan' ? 'task-a' : 'r001',
        'requestRevision': 1,
        'teamRevision': 1,
        'verificationRevision': 1,
        'iterationId': kind == 'plan' ? '' : 'r001',
        'artifactDigest': kind == 'plan' ? '' : 'sha256-a',
        'opinionEventIds': [
          for (final a in raw['approvals'] as List)
            if (a['kind'] == kind) a['eventId']
        ],
        'reason': '依据全体真实意见确认当前方案',
        'responseRef': 'response-$kind',
      }
  ];
  return raw;
}

void _registerAutonomyTests() {
  test('旧 clarifying 检查点仅可通过显式恢复进入复核讨论', () {
    final raw = _autonomousFixture()..['phase'] = 'clarifying';
    final state = _state(raw);
    expect(state.isRecoverableClarifyingCheckpoint, isTrue);
    final incomplete = state.toJson()
      ..['workItems'] = [
        for (final item in state.workItems) {...item, 'status': 'pending'}
      ];
    expect(
      WorkCollaborationState.tryParse(incomplete)!
          .isRecoverableClarifyingCheckpoint,
      isFalse,
    );
  });

  test('参与成员只能随明确用户选择变更，变更后重新形成方案与场景', () {
    WorkCollaborationState nextFor(WorkCollaborationState current) =>
        _state(current.toJson()
          ..['revision'] = 2
          ..['requestRevision'] = 2
          ..['teamRevision'] = 2
          ..['verificationRevision'] = 2
          ..['autonomyPolicy'] = WorkCollaborationAutonomy.policyFor(['c', 'b'])
          ..['plan'] = ''
          ..['workItems'] = []
          ..['acceptances'] = []
          ..['usageAssignments'] = []
          ..['phase'] = 'clarifying'
          ..['appliedEventIds'] = ['participants']);
    WorkCollaborationUpdate change(WorkCollaborationState current) =>
        WorkCollaborationUpdate(
            taskId: current.taskId,
            conversationId: current.conversationId,
            expectedRevision: 1,
            eventId: 'participants',
            sourceRole: 'participation',
            sourceId: 'application',
            next: nextFor(current));
    final unsigned = _state(_autonomousFixture());
    expect(() => unsigned.apply(change(unsigned)), throwsStateError);
    final raw = _autonomousFixture()
      ..['decisions'] = [
        {
          'id': 'replace',
          'revision': 1,
          'status': 'answered',
          'reason': '用户更换此任务成员',
          'answer': '由 c 替换 a',
          'impact': '重新确认职责和方案',
          'responseRef': 'user-response',
          'evidence': '用户选择',
          'options': [
            {'id': 'c', 'label': '由 c 替换 a', 'impact': '重新核验当前资格'}
          ],
          'targetId': 'a',
          'kind': 'member',
          'answerKind': 'choice',
        }
      ];
    final current = _state(raw);
    expect(current.confirmedMemberChoices, {'a': 'c'});
    final next = current.apply(change(current));
    expect(next.participantIds, ['c', 'b']);
    expect(next.planReady, isFalse);
    expect(next.usageAssignments, isEmpty);
    expect(next.allMembersUsed, isFalse);
  });

  test('重试控制项不被当作参与成员替换', () {
    final baseline = _state(_autonomousFixture());
    for (final id in ['retry-same-member', 'member-config-updated']) {
      final current = _state(_autonomousFixture()
        ..['decisions'] = [
          {
            'id': 'retry-$id',
            'revision': 1,
            'status': 'answered',
            'reason': '保留当前成员继续任务',
            'answer': id,
            'impact': '原成员与责任不变',
            'responseRef': 'response-$id',
            'evidence': '用户选择继续',
            'options': [
              {'id': id, 'label': id, 'impact': '原成员与责任不变'}
            ],
            'targetId': 'a',
            'kind': 'member',
            'answerKind': 'choice',
          }
        ]);

      expect(current.confirmedMemberChoices, isEmpty, reason: id);
      expect(current.confirmedParticipationPolicy, baseline.autonomyPolicy,
          reason: id);
    }
  });

  test('缺少 options 的已答复成员决策不会让团队核对抛异常', () {
    // 状态闸门明确接受 `options == null`（旧检查点里就有这种记录）。团队核对现在
    // 走 `confirmedMemberChoices`，它曾经用 `as List` 硬转，这条记录会让整轮核对
    // 抛 TypeError 而不是"没有候选可选"。
    final current = _state(_autonomousFixture()
      ..['decisions'] = [
        {
          'id': 'no-options',
          'revision': 1,
          'status': 'answered',
          'reason': '用户答复了一个没有候选的问题',
          'answer': '稍后再说',
          'impact': '原成员与责任不变',
          'responseRef': 'user-response',
          'evidence': '用户选择',
          'targetId': 'a',
          'kind': 'member',
          'answerKind': 'choice',
        }
      ]);

    expect(current.confirmedMemberChoices, isEmpty);
    expect(current.confirmedParticipationPolicy,
        _state(_autonomousFixture()).autonomyPolicy);
  });

  test('本人使用反馈严格解析；通过标签、命令 tests 与未列真实失败均不能冒充反馈', () {
    final valid = {
      'method': '实际使用',
      'result': 'passed',
      'acceptanceIds': ['qa'],
      'report': '实际结果符合预期',
      'defects': []
    };
    Map<String, dynamic>? parse(Map<String, dynamic> json) =>
        parseWorkUsageFeedback(
            AgentFinishCompletion(
                summary: '实际反馈', evidence: [jsonEncode(json)]),
            acceptanceIds: ['qa']);
    expect(parse(valid), isNotNull);
    for (final patch in [
      {'receiptId': 'fake'},
      {'approved': true},
      {'result': 'failed'},
      {'report': ''},
      {'acceptanceIds': []},
      {
        'acceptanceIds': ['other']
      },
      {
        'acceptanceIds': ['qa', 'qa']
      },
    ]) {
      expect(parse({...valid, ...patch}), isNull, reason: '$patch');
    }
    final failed = {
      ...valid,
      'result': 'failed',
      'defects': [
        {
          'acceptanceId': 'qa',
          'reproduction': '修改后重开',
          'expected': '保留数据',
          'actual': '数据丢失',
          'retestCondition': '修复后重开核对',
        }
      ]
    };
    expect(parse(failed), isNotNull);
    expect(parse({...failed, 'result': 'passed'}), isNull);
    expect(parse({'artifactDigest': 'digest', 'tests': []}), isNull);
  });

  test('单一生产循环暂停检查点保留自主合同和设备观察引用', () async {
    final raw = _autonomousFixture()..['usageEvidenceRefs'] = [];
    final state = _state(raw);
    final task = AgentTask(
        id: 'task-a',
        groupId: 'group-a',
        characterId: 'a',
        userRequest: '使用当前候选',
        workModeTask: true,
        executionStateJson: jsonEncode({
          'discussionState': WorkDiscussionState(
                  schemaVersion: 2,
                  conversationId: 'group-a',
                  phase: WorkDiscussionPhase.ready,
                  requestRevision: 1,
                  executorId: 'a',
                  collaboration: state)
              .toJson(),
          'workItemExecution': {
            'stage': 'usage',
            'workItemId': 'scenario-a',
            'iterationId': 'r001',
            'requestRevision': 1,
            'teamRevision': 1,
            'verificationRevision': 1,
            'actorId': 'a'
          },
          'v2UsageObservationRef': 'a' * 24,
        }));
    final loop = WorkAgentLoop(
        registry: WorkToolRegistry(),
        model: (_) async => {
              'success': true,
              'message': jsonEncode({
                'action': 'clarify',
                'public_update': '缺少原生操作工具，当前场景还没使用。',
                'tool': null,
                'completion': {'question': '当前原生能力缺失', 'options': []},
              }),
            });
    await loop.execute(task, cancellation: WorkTaskCancellation());
    final after =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    expect(after.collaboration!.toJson(), state.toJson());
    expect(after.executorId, 'a');
    expect(
        (jsonDecode(task.executionStateJson) as Map)['v2UsageObservationRef'],
        'a' * 24);
    expect(after.collaboration!.deliveryReady, isFalse);
  });

  test('使用正文 JSON 不能取得本地运行器收据，跨设备引用不继承权限', () async {
    final directory = await Directory.systemTemp.createTemp('p1-receipts-');
    final events = WorkTaskEventStore(appSupportDirectory: directory);
    final receipts = WorkUsageReceiptStore(events);
    try {
      final initial = _state(_autonomousFixture());
      expect(await receipts.valid(initial, 'a'), isFalse);
      await expectLater(
          receipts.record(
              state: initial,
              actorId: 'a',
              observations: [],
              feedbackRef: 'feedback-a'),
          throwsStateError);
      final fake = WorkUsageObservation(
          taskId: 'task-a',
          conversationId: 'group-a',
          actorId: 'a',
          scenarioId: 'scenario-a',
          iterationId: 'r001',
          artifactDigest: 'sha256-a',
          planDigest: initial.usagePlanDigest,
          verificationRevision: 1,
          runtime: 'macos-native',
          sessionRef: 'session-a',
          operation: 'click',
          beforeRef: 'before',
          afterRef: 'after',
          outputRefs: ['image']);
      await expectLater(
          receipts.record(
              state: initial,
              actorId: 'a',
              observations: [fake],
              feedbackRef: 'feedback-a'),
          throwsStateError);
      final actual = WorkUsageObservation(
          taskId: 'task-a',
          conversationId: 'group-a',
          actorId: 'a',
          scenarioId: 'scenario-a',
          iterationId: 'r001',
          artifactDigest: 'sha256-a',
          planDigest: initial.usagePlanDigest,
          verificationRevision: 1,
          runtime: 'macos-native',
          sessionRef: 'session-a',
          operation: 'click',
          beforeRef: 'before',
          afterRef: 'after',
          outputRefs: [
            await events.writeNativeEvidence('task-a', 'png', [1, 2, 3])
          ],
          businessResultVerified: true,
          verifiedAcceptanceIds: ['qa']);
      await expectLater(
          receipts.record(
              state: initial,
              actorId: 'b',
              observations: [actual],
              feedbackRef: 'feedback-b'),
          throwsStateError);
      final blocked = await receipts.record(
          state: initial,
          actorId: 'a',
          observations: [],
          feedbackRef: 'blocked-feedback',
          status: 'blocked');
      expect(blocked, startsWith('usage:'));
      final ref = await receipts.record(
          state: initial,
          actorId: 'a',
          observations: [actual],
          feedbackRef: 'feedback-a');
      final raw = initial.toJson();
      _replaceRecord(raw, 'usageEvidenceRefs', 0,
          {'verificationRevision': 1, 'receiptRef': ref});
      final current = _state(raw);
      expect(await receipts.valid(current, 'a'), isTrue);
      _replaceRecord(raw, 'usageEvidenceRefs', 1, {
        'verificationRevision': 1,
        'receiptRef': ref,
        'feedbackRef': 'feedback-a'
      });
      expect(WorkCollaborationState.tryParse(raw), isNull);
      final other = WorkTaskEventStore(
          appSupportDirectory: Directory('${directory.path}/other-device'));
      expect(await WorkUsageReceiptStore(other).valid(current, 'a'), isFalse);
      await other.close();
      await events.recordCommittedAction(
          'task-a', 'native-session-invalidated:session-a');
      expect(await receipts.valid(current, 'a'), isFalse,
          reason: '清理时发现包变化后必须使已封存的本人观察失效');
      await events.deleteEvents('task-a');
      expect(await receipts.valid(current, 'a'), isFalse);
    } finally {
      await events.close();
      await directory.delete(recursive: true);
    }
  });

  test('旧已完成记录保持旧门禁，不补造自主策略或使用', () {
    final old = _state(_fixture()..['phase'] = 'delivered');
    expect(old.deliveryReady, isTrue);
    expect(old.toJson().containsKey('autonomyPolicy'), isFalse);
    expect(old.usageEvidenceRefs, isEmpty);
  });
  test('自主门禁需要全员不同场景、覆盖全部必达项及协调决议', () {
    expect(_state(_autonomousFixture()).deliveryReady, isTrue);
    final missing = _autonomousFixture();
    (missing['usageAssignments'] as List).removeLast();
    expect(_state(missing).planReady, isFalse);
    final same = _autonomousFixture();
    _replaceRecord(same, 'usageAssignments', 1, {
      'goal': '使用路径 a',
      'stepGoals': ['完成路径 a'],
      'expectedResult': '结果 a'
    });
    expect(_state(same).planReady, isFalse);
    final twoMakers = _autonomousFixture();
    (twoMakers['workItems'] as List).add({
      'id': 'other',
      'ownerId': 'b',
      'kind': 'produce',
      'dependencies': [],
      'status': 'done',
      'requestRevision': 1
    });
    expect(_state(twoMakers).planReady, isFalse);
    final materialMaker = _autonomousFixture();
    (materialMaker['workItems'] as List).add({
      'id': 'materials',
      'ownerId': 'b',
      'kind': 'material',
      'dependencies': [],
      'status': 'done',
      'requestRevision': 1
    });
    expect(_state(materialMaker).planReady, isFalse);
    final fakeDeveloper = _autonomousFixture();
    _replaceRecord(fakeDeveloper, 'team', 0, {'role': 'general'});
    expect(_state(fakeDeveloper).planReady, isFalse);
    final noRuling = _autonomousFixture()..['coordinatorDecisions'] = [];
    expect(_state(noRuling).planReady, isFalse);
  });
  test('当前成员不能借用收据或旧计划、旧候选、跨任务摘要', () {
    for (final patch in [
      {'taskId': 'other-task'},
      {'conversationId': 'other-group'},
      {'scenarioId': 'scenario-b'},
      {'requestRevision': 2},
      {'teamRevision': 2},
      {'verificationRevision': 2},
      {'iterationId': 'old'},
      {'artifactDigest': 'old'},
      {'planDigest': 'c' * 64},
      {'status': 'failed'},
      {'memberId': 'outside'},
    ]) {
      final raw = _autonomousFixture();
      _replaceRecord(raw, 'usageEvidenceRefs', 0, patch);
      expect(_state(raw).deliveryReady, isFalse, reason: '$patch');
    }
    final borrowed = _autonomousFixture();
    _replaceRecord(borrowed, 'usageEvidenceRefs', 1,
        {'verificationRevision': 1, 'receiptRef': 'usage:${'a' * 24}'});
    expect(WorkCollaborationState.tryParse(borrowed), isNull);
  });
  test('偏好反对保留原签字可由协调者收敛，实质失败不能覆盖', () {
    final raw = _autonomousFixture();
    _replaceRecord(raw, 'approvals', 1, {'approved': false});
    _replaceRecord(raw, 'approvals', 3, {'approved': false});
    expect(_state(raw).deliveryReady, isTrue);
    expect(_state(raw).approvals[3]['approved'], isFalse);
    _replaceRecord(raw, 'acceptances', 0, {'status': 'failed'});
    expect(_state(raw).deliveryReady, isFalse);
    final defect = _autonomousFixture()
      ..['issues'] = [_issue('broken', 'open')];
    expect(_state(defect).deliveryReady, isFalse);
  });
  test('协调身份、用户身份和成员身份均不能代签或代造使用', () {
    final current = _state(_autonomousFixture());
    for (final role in ['coordinator', 'user', 'member', 'tool']) {
      final next = current.toJson()
        ..['revision'] = 2
        ..['appliedEventIds'] = ['forged'];
      _replaceRecord(
          next, 'usageEvidenceRefs', 0, {'feedbackRef': 'foreign-feedback'});
      expect(
          () => current.apply(WorkCollaborationUpdate(
              taskId: 'task-a',
              conversationId: 'group-a',
              expectedRevision: 1,
              eventId: 'forged',
              sourceRole: role,
              sourceId: role == 'user' ? 'user' : 'a',
              next: _state(next))),
          throwsStateError,
          reason: role);
    }
    final unsigned = _autonomousFixture()..['usageEvidenceRefs'] = [];
    final before = _state(unsigned);
    final next = before.toJson()
      ..['revision'] = 2
      ..['appliedEventIds'] = ['signature'];
    next['approvals'] = [
      ...before.approvals,
      {
        ..._approval('b', 'delivery', 'r001',
            iteration: 'r001', digest: 'sha256-a'),
        'eventId': 'signature',
      }
    ];
    expect(
        () => before.apply(WorkCollaborationUpdate(
            taskId: 'task-a',
            conversationId: 'group-a',
            expectedRevision: 1,
            eventId: 'signature',
            sourceRole: 'member',
            sourceId: 'b',
            next: _state(next))),
        throwsStateError);
  });

  test('协调决议历史滚动不成为累计轮次上限，也不丢当前方案定案', () {
    final raw = _autonomousFixture();
    final current = _state(raw);
    raw['coordinatorDecisions'] = [
      current.coordinatorDecisions.first,
      for (var i = 0; i < 130; i++)
        {
          ...current.coordinatorDecisions.last,
          'eventId': 'old-ruling-$i',
          'iterationId': 'old-$i',
          'subjectId': 'old-$i'
        },
      current.coordinatorDecisions.last,
    ];
    final bounded = _state(raw).boundedHistory();
    expect(bounded.coordinatorDecisions.length, lessThanOrEqualTo(66));
    expect(bounded.deliveryReady, isTrue);
    expect(bounded.toPromptJson()['coordinatorDecisions'], hasLength(2));
  });

  test('FIFO 输入、候选变化和未知自主 schema 均阻塞', () {
    expect(
        _state(_autonomousFixture()..['pendingInputIds'] = ['new-input'])
            .deliveryReady,
        isFalse);
    final raw = _autonomousFixture();
    _replaceRecord(raw, 'iterations', 0, {'artifactDigest': 'new'});
    expect(_state(raw).deliveryReady, isFalse);
    (raw['autonomyPolicy'] as Map)['schemaVersion'] = 99;
    expect(WorkCollaborationState.tryParse(raw), isNull);
    expect(
        WorkCollaborationState.tryParse(_fixture()..['usageEvidenceRefs'] = []),
        isNotNull);
  });
  test('自主字段经检查点、上下文及备份完整保留，导入不授权运行', () {
    final collaboration = _state(_autonomousFixture());
    final task = AgentTask(
        id: 'task-a',
        groupId: 'group-a',
        characterId: 'a',
        userRequest: '制作可运行页面',
        workModeTask: true);
    final shell = WorkDiscussionState(
        schemaVersion: 2,
        conversationId: 'group-a',
        phase: WorkDiscussionPhase.ready,
        requestRevision: 1,
        collaboration: collaboration);
    task.executionStateJson =
        WorkDiscussionState.mergeIntoExecutionState('', shell);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .compactForContext()
            .collaboration!
            .toJson(),
        collaboration.toJson());
    final backup = BackupEntityCodec.task(task);
    final portable = WorkDiscussionState.fromExecutionState(
            backup['executionStateJson'] as String)!
        .collaboration!;
    expect(portable.autonomyPolicy, collaboration.autonomyPolicy);
    expect(portable.usageAssignments, collaboration.usageAssignments);
    expect(portable.usageEvidenceRefs, collaboration.usageEvidenceRefs);
    expect(portable.coordinatorDecisions, collaboration.coordinatorDecisions);
    expect(portable.deliveryReady, isFalse);
  });

  test('状态严格解析、不可变计划与上下文投影往返保持新字段', () {
    final current = _state(_autonomousFixture());
    expect(
        _state(jsonDecode(jsonEncode(current.toJson())) as Map<String, dynamic>)
            .toJson(),
        current.toJson());
    expect(_state(current.toPromptJson()).deliveryReady, isTrue);
    expect(
        () => (current.usageAssignments.first['stepGoals'] as List).add('伪造'),
        throwsUnsupportedError);
    final extra = _autonomousFixture();
    _replaceRecord(extra, 'usageAssignments', 0, {'grantShell': true});
    expect(WorkCollaborationState.tryParse(extra), isNull);
    final lost = _autonomousFixture()..remove('usageEvidenceRefs');
    expect(WorkCollaborationState.tryParse(lost), isNull);
    expect(
        WorkCollaborationState.tryParse(
            _autonomousFixture()..['autonomyPolicy'] = null),
        isNull);
  });
}
