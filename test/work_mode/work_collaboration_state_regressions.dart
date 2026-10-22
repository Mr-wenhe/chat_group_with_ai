part of 'work_collaboration_state_test.dart';

void _registerCollaborationHistoryRegressions() {
  test('仅路由可在不改变需求版本时追加成员请求恢复问题', () {
    final before = _state(_fixture());
    final decision = {
      'id': 'retry',
      'revision': 1,
      'kind': 'member',
      'targetId': 'a',
      'status': 'pending',
      'reason': '请求超时',
      'answer': '',
      'impact': '等待恢复',
      'responseRef': '',
      'options': [
        {'id': 'retry-same-member', 'label': '重试', 'impact': '原需求继续'},
        {'id': 'member-config-updated', 'label': '配置已更新', 'impact': '原需求继续'}
      ]
    };
    WorkCollaborationState apply(String role, {bool changeScope = false}) =>
        before.apply(WorkCollaborationUpdate(
          taskId: before.taskId,
          conversationId: before.conversationId,
          expectedRevision: before.revision,
          eventId: 'recovery',
          sourceRole: role,
          sourceId: role,
          next: _state(before.toJson()
            ..['revision'] = before.revision + 1
            ..['scope'] = changeScope ? '新增需求' : before.scope
            ..['appliedEventIds'] = ['recovery']
            ..['decisions'] = [...before.decisions, decision]),
        ));
    expect(apply('router').requestRevision, before.requestRevision);
    expect(() => apply('user'), throwsStateError);
    expect(() => apply('router', changeScope: true), throwsStateError);
  });

  test('成员请求重试保留需求基线，系统和夹带变更不能借此越过版本校验', () {
    final before = _state(_fixture()
      ..['decisions'] = [
        {
          'id': 'retry',
          'revision': 1,
          'kind': 'member',
          'targetId': 'a',
          'status': 'pending',
          'reason': '请求超时',
          'answer': '',
          'impact': '等待恢复',
          'responseRef': '',
          'options': [
            {'id': 'retry-same-member', 'label': '保留成员重试', 'impact': '原需求继续'}
          ]
        }
      ]);
    WorkCollaborationState next({String? changedScope, String? target}) =>
        _state(before.toJson()
          ..['revision'] = before.revision + 1
          ..['scope'] = changedScope ?? before.scope
          ..['appliedEventIds'] = ['retry-answer']
          ..['decisions'] = [
            {
              ...before.decisions.single,
              'revision': 2,
              'status': 'answered',
              'answerKind': 'choice',
              'answer': '保留成员重试',
              'responseRef': 'user-answer',
              'missingCondition': '',
              if (target != null) 'targetId': target,
            }
          ]);
    WorkCollaborationState apply(WorkCollaborationState after, String role) =>
        before.apply(WorkCollaborationUpdate(
          taskId: before.taskId,
          conversationId: before.conversationId,
          expectedRevision: before.revision,
          eventId: 'retry-answer',
          sourceRole: role,
          sourceId: role,
          next: after,
        ));
    final after = apply(next(), 'user');
    expect(after.requestRevision, before.requestRevision);
    expect(after.approvals, before.approvals);
    expect(after.acceptances, before.acceptances);
    expect(after.iterations, before.iterations);
    expect(() => apply(next(), 'system'), throwsStateError);
    expect(() => apply(next(target: 'b'), 'user'), throwsStateError);
    expect(() => apply(next(changedScope: '新增需求'), 'user'), throwsStateError);
  });

  test('历史回归：obsolete idea revision signatures are not live approvals', () {
    final raw = _fixture()
      ..['requestRevision'] = 32
      ..['teamRevision'] = 32
      ..['issues'] = [
        {
          ..._issue('idea-active', 'open'),
          'kind': 'idea',
          'requestRevision': 32
        }
      ]
      ..['approvals'] = [
        for (final member in ['a', 'b'])
          _approval(member, 'plan', 'task-a', request: 32, team: 32),
        for (var version = 1; version <= 31; version++)
          for (final member in ['a', 'b'])
            _approval(member, 'idea', 'idea-active',
                request: version, team: version)
      ];
    final current = WorkCollaborationState.tryParse(raw);
    expect(current, isNotNull);
    expect(current!.approvals, hasLength(64));
    expect(
        current.approvals.where((a) =>
            a['kind'] == 'idea' &&
            a['requestRevision'] == 32 &&
            a['teamRevision'] == 32),
        isEmpty);
    const eventId = 'current-idea-approval-a';
    final signature = {
      ..._approval('a', 'idea', 'idea-active', request: 32, team: 32),
      'eventId': eventId
    };
    final withoutArchive = WorkCollaborationState.tryParse(current.toJson()
      ..['approvals'] = [
        for (final a in current.approvals)
          if (a['kind'] != 'idea') a,
        signature
      ]);
    expect(withoutArchive, isNotNull, reason: '同一条当前签字本身合法');
    final next = WorkCollaborationState.tryParse(current.toJson()
      ..['revision'] = current.revision + 1
      ..['appliedEventIds'] = [eventId]
      ..['approvals'] = [...current.approvals, signature]);
    expect(next, isNotNull,
        reason:
            '62 条旧需求／团队版本的 idea 签字不能挤掉当前签字；liveApprovalGroups=${current.liveApprovalGroups}');
    expect(
        () => current.apply(WorkCollaborationUpdate(
            taskId: current.taskId,
            conversationId: current.conversationId,
            expectedRevision: current.revision,
            eventId: eventId,
            sourceRole: 'member',
            sourceId: 'a',
            next: next!)),
        returnsNormally);
  });

  for (final member in ['b', 'human-review']) {
    test('历史裁剪保留持续成员授权：$member', () {
      final raw = _fixture()
        ..['decisions'] = [
          {
            'id': 'joining',
            'revision': 1,
            'status': 'answered',
            'kind': 'member',
            'targetId': 'role:testing',
            'reason': '确认测试责任',
            'answer': '选择测试',
            'answerKind': 'choice',
            'impact': '只加入本任务',
            'responseRef': 'user-joining',
            'options': [
              {'id': member, 'label': '选择测试', 'impact': '承担测试'}
            ]
          },
          for (var i = 0; i < 64; i++)
            {
              'id': 'old-$i',
              'revision': 1,
              'status': 'answered',
              'reason': '已解决',
              'answer': '继续',
              'impact': '已确认',
              'responseRef': 'user-$i'
            }
        ];
      final before = _state(raw);
      final after = before.boundedHistory();
      expect(after.decisions.any((d) => d['id'] == 'joining'), isTrue);
      expect(after.planReady, before.planReady);
    });
  }
  test('缺答复凭据的决策仍阻塞，不能被历史窗口放行', () {
    final raw = _fixture()
      ..['decisions'] = [
        {
          'id': 'missing-ref',
          'revision': 1,
          'status': 'answered',
          'reason': '尚未确认',
          'answer': '继续',
          'impact': '需核对',
          'responseRef': ''
        },
        for (var i = 0; i < 64; i++)
          {
            'id': 'old-$i',
            'revision': 1,
            'status': 'answered',
            'reason': '已解决',
            'answer': '继续',
            'impact': '已确认',
            'responseRef': 'user-$i'
          }
      ];
    final before = _state(raw);
    expect(before.hasPendingDecision, isTrue);
    final after = before.boundedHistory();
    expect(after.hasPendingDecision, isTrue);
    expect(after.decisions.any((d) => d['id'] == 'missing-ref'), isTrue);
  });
  test('模型投影保留采纳前提案签字、反对意见及所有当前门禁', () {
    for (final unknownMemberVote in [false, true]) {
      final raw = _fixture()
        ..['requestRevision'] = 2
        ..['issues'] = [
          {
            ..._issue('adopted', 'resolved'),
            'kind': 'idea',
            'requestRevision': 1
          }
        ]
        ..['approvals'] = [
          for (final member in ['a', 'b'])
            _approval(member, 'plan', 'task-a', request: 2),
          for (final member in ['a', 'b'])
            _approval(member, 'idea', 'adopted', request: 1),
          if (unknownMemberVote)
            {
              ..._approval('c', 'idea', 'adopted', request: 1, verification: 2),
              'approved': false
            }
        ];
      final before = _state(raw);
      final encoded = jsonEncode(before.toJson());
      final projected = _state(before.toPromptJson());
      expect(projected.ideaApproved('adopted', requestRevision: 1),
          before.ideaApproved('adopted', requestRevision: 1));
      expect(projected.issuesResolved, before.issuesResolved);
      expect(projected.planReady, before.planReady);
      expect(projected.deliveryReady, before.deliveryReady);
      expect(projected.hasPendingDecision, before.hasPendingDecision);
      expect(jsonEncode(before.toJson()), encoded, reason: '只读投影不能修改原始状态');
    }
    final before = _state(_fixture());
    expect(_state(before.toPromptJson()).deliveryReady, isTrue);
    final legacy = WorkDiscussionState.initial(conversationId: 'group-a');
    expect(legacy.toPromptJson(), legacy.compactForContext().toJson());
  });
}
