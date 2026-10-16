part of 'work_discussion_v2_test.dart';

Map<String, dynamic> _autonomousProposal(Map<String, dynamic> state) => {
      ...proposal(state),
      'workItems': [
        {
          'id': 'implementation',
          'ownerId': 'dev',
          'kind': 'produce',
          'dependencies': <String>[]
        }
      ],
      'usageAssignments': [
        for (final id
            in (state['autonomyPolicy'] as Map)['participantIds'] as List)
          {
            'memberId': id,
            'scenarioId': 'scenario-$id',
            'goal': '使用路径 $id',
            'preconditions': '空测试数据',
            'stepGoals': ['执行路径 $id'],
            'expectedResult': '路径 $id 结果符合预期',
            'acceptanceIds': ['dice'],
            'requiredCapabilities': ['native'],
            'resetMethod': '清理独立测试数据',
          }
      ],
    };

void _registerAutonomousDiscussionTests() {
  test('P1 显式恢复冻结全体成员并保留反对，由真实协调者定案', () async {
    task.executionStateJson = jsonEncode({
      ...jsonDecode(task.executionStateJson) as Map,
      'autonomyUpgradePending': true,
    });
    final calls = <String>[];
    final prompts = <String, String>{};
    Map<String, dynamic>? autonomousContext;
    await modelRunner((member, context) async {
      calls.add(member.id);
      autonomousContext ??= context;
      final state = context['collaboration'] as Map<String, dynamic>;
      if ((state['plan'] as String).isEmpty) {
        return _turn('propose', proposal: _autonomousProposal(state));
      }
      if (context['turnFocus']?['rulingSubjectId'] != null) {
        return _turn('decide', text: '按这个方案推进，保留刚才的布局意见。', decision: {
          'kind': 'ruling',
          'targetId': task.id,
          'reason': '选择已确认的布局，偏好留待后续',
          'evidence': '已听取全部成员意见',
          'impact': '只推进当前范围',
          'options': [],
        });
      }
      return _turn('approve',
          approval: {...approval(state), 'approved': member.id != 'qa'});
    }, onMessages: (member, messages) {
      prompts[member.id] = messages.first['content'] as String;
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    final current =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(current.isAutonomous, isTrue);
    expect(current.participantIds, ['dev', 'qa', 'extra']);
    expect(current.activeMembers, containsAll(['dev', 'qa', 'extra']));
    expect(current.usageAssignments.length, 3);
    expect(current.planReady, isTrue);
    expect(
        current.approvals.where((a) => a['memberId'] == 'qa').last['approved'],
        isFalse);
    expect(current.decisions, isEmpty);
    expect(current.coordinatorDecisions.single['coordinatorId'], 'dev');
    expect(calls, containsAll(['dev', 'qa', 'extra']));
    final roster = autonomousContext!['participantRoster'] as List;
    expect(roster.map((item) => (item as Map)['memberId']).toList(),
        ['dev', 'qa', 'extra']);
    expect(
        roster.every((item) =>
            (item as Map)['displayName'] ==
            db.aiCharacterBox.get(item['memberId'])!.name),
        isTrue);
    expect(prompts['dev'], contains('协调者按 turnFocus 分阶段推进'));
    expect(prompts['dev'], contains('displayName 仅供识人'));
    expect(prompts['dev'], contains('普通分歧据证据定案并保留异议'));
    expect(prompts['dev'], contains('先核当前候选与本人收据'));
    expect(prompts['dev'], isNot(contains('真实分歧走用户决策')));
    expect(prompts['qa'], isNot(contains('协调者按 turnFocus 分阶段推进')));
    expect(prompts['qa'], isNot(contains('真实分歧走用户决策')));
    final ref = current.coordinatorDecisions.single['responseRef'] as String;
    expect(db.messageBox.get(ref)?.senderId, 'dev');
    task.status = AgentTaskStatus.paused;
    await db.agentTaskBox.put(task.id, task);
    final coordinator = WorkTaskCoordinator(
        taskBox: db.agentTaskBox, runner: execution, eventStore: events);
    addTearDown(coordinator.dispose);
    const event = 'forged-coordinator';
    final nextRaw = current.toJson()
      ..['revision'] = current.revision + 1
      ..['appliedEventIds'] = [
        ...current.appliedEventIds
            .skip(current.appliedEventIds.length == 64 ? 1 : 0),
        event
      ];
    await expectLater(
        coordinator.applyCollaborationUpdate(WorkCollaborationUpdate(
            taskId: task.id,
            conversationId: task.groupId,
            expectedRevision: current.revision,
            eventId: event,
            sourceRole: 'coordinator',
            sourceId: 'dev',
            next: WorkCollaborationState.tryParse(nextRaw)!)),
        throwsStateError);
  });

  test('P1 自主提案严格解析并拒绝模型填写收据', () {
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .toJson()
          ..['autonomyPolicy'] = {
            'schemaVersion': 1,
            'mode': 'coordinator',
            'source': 'application',
            'participantIds': ['dev', 'qa', 'extra']
          };
    final valid = _autonomousProposal(state);
    expect(WorkDiscussionV2Turn.parse(_turn('propose', proposal: valid)),
        isNotNull);
    final unknown = _autonomousProposal(state);
    (unknown['usageAssignments'] as List).first['receiptId'] = 'fake';
    expect(WorkDiscussionV2Turn.parse(_turn('propose', proposal: unknown)),
        isNull);
  });

  test('P1 自主协议不把普通分歧交用户，旧协议保留原决策规则', () {
    final autonomous = WorkDiscussionV2Turn.protocolFor('',
        stage: WorkDiscussionStage.resolveIssue, autonomous: true);
    expect(autonomous, contains('普通技术和偏好分歧由协调者据证据定案'));
    expect(autonomous, contains('真实缺陷与分歧必须继续记录'));
    expect(autonomous, isNot(contains('真实分歧走用户决策')));

    final legacy = WorkDiscussionV2Turn.protocolFor('旧任务',
        stage: WorkDiscussionStage.resolveIssue);
    expect(legacy, contains('真实分歧走用户决策'));

    final repair = WorkDiscussionV2Turn.repairProtocolFor('', autonomous: true);
    expect(repair, contains('普通技术和偏好分歧由协调者据证据定案'));
    expect(repair, isNot(contains('真实分歧走用户决策')));
  });

  test('自主协议修复请求同样带上参与者名册', () async {
    // `autonomyRules` 要求按名册的 memberId 对齐参与者，而修复请求也嵌入这份
    // 规则；名册只出现在首轮上下文里时，修复器只能拿显示名去凑 memberId。
    task.executionStateJson = jsonEncode({
      ...jsonDecode(task.executionStateJson) as Map,
      'autonomyUpgradePending': true,
    });
    final repairs = <Map<String, dynamic>>[];
    await modelRunner((member, context) async {
      if (context.containsKey('originalFinal')) {
        repairs.add(context);
        final repaired = context['collaboration'] as Map<String, dynamic>;
        return _turn('propose', proposal: _autonomousProposal(repaired));
      }
      final state = context['collaboration'] as Map<String, dynamic>;
      if ((state['plan'] as String).isEmpty) {
        final clean = _turn('propose', proposal: _autonomousProposal(state));
        // 围栏包裹的正文通不过 JSON 语法校验，修复器因此一定会被调用。
        return {'success': true, 'message': '```json\n${clean['message']}\n```'};
      }
      return _turn('approve', approval: {...approval(state)});
    }).runCollaboration(task, WorkTaskCancellation(), apply);

    expect(repairs, isNotEmpty);
    final roster = repairs.first['participantRoster'];
    expect(roster, isA<List>(),
        reason: '修复器与首轮请求看到的名册必须是同一份，缺了它模型只能拿显示名凑 memberId');
    expect(
        (roster as List)
            .map((item) => (item as Map)['memberId'] as String)
            .toList(),
        ['dev', 'qa', 'extra']);
  });
}
