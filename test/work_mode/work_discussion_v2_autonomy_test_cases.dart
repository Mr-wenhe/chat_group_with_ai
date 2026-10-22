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
  test('非自主任务的提案反对仍等待用户裁决', () async {
    await modelRunner((member, context) async {
      final state = context['collaboration'] as Map<String, dynamic>;
      if (state['pendingProposal'] == null) {
        return _turn('propose',
            issue: 'legacy-idea',
            issues: [
              {
                'id': 'legacy-idea',
                'kind': 'idea',
                'target': 'plan',
                'problem': '提案需逐人核对',
                'evidenceRef': '',
                'retestCondition': '取得真实成员意见',
              }
            ],
            proposal: proposal(state));
      }
      return _turn('approve', approval: {
        ...approval(state),
        'kind': 'idea',
        'subjectId': 'legacy-idea',
        'approved': false,
      });
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    final current =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(current.isAutonomous, isFalse);
    expect(current.hasPendingDecision, isTrue);
    expect(current.decisions.last['kind'], 'dispute');
    expect(current.plan, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('自主提案异议自动回到协调者修订并重新逐人认可', () async {
    task.executionStateJson = jsonEncode({
      ...jsonDecode(task.executionStateJson) as Map,
      'autonomyUpgradePending': true,
    });
    Future<Map<String, dynamic>> accept(
        AICharacter member, Map<String, dynamic> context) async {
      final state = context['collaboration'] as Map<String, dynamic>;
      if ((state['plan'] as String).isEmpty) {
        return _turn('propose', proposal: _autonomousProposal(state));
      }
      if (context['turnFocus']?['rulingSubjectId'] != null) {
        final focus = context['turnFocus'] as Map;
        final opinions = focus['rulingOpinions'] as List;
        expect(opinions.length,
            (state['autonomyPolicy']['participantIds'] as List).length);
        for (final opinion in opinions) {
          expect(opinion['kind'], 'plan');
          expect(opinion['subjectId'], task.id);
          expect(opinion['requestRevision'], state['requestRevision']);
          expect(opinion['source'], 'memberModel');
          expect(
              (state['approvals'] as List)
                  .singleWhere((a) => a['eventId'] == opinion['eventId']),
              equals(opinion));
        }
        expect(focus['objective'], contains('不重新设计或复制整份方案'));
        return _turn('decide', decision: {
          'kind': 'ruling',
          'targetId': task.id,
          'reason': '已听取全员意见',
          'evidence': '逐人真实认可',
          'impact': '按当前范围制作',
          'options': [],
        });
      }
      final response = _turn('approve', approval: approval(state));
      final body = jsonDecode(response['message'] as String) as Map;
      body['next_member_id'] = state['coordinatorId'];
      return {...response, 'message': jsonEncode(body)};
    }

    await modelRunner(accept)
        .runCollaboration(task, WorkTaskCancellation(), apply);
    final shell =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    final before = shell.collaboration!;
    final candidate = _autonomousProposal(before.toJson())
      ..['plan'] = '待修订的测试步骤';
    final serialized = jsonEncode(candidate);
    final digest =
        sha256.convert(utf8.encode(serialized)).toString().substring(0, 24);
    await events.writeDiscussionDetail(task.id, digest, serialized);
    const issueId = 'test-steps-proposal';
    final pending = WorkCollaborationState.tryParse(before.toJson()
      ..['revision'] = before.revision + 1
      ..['verificationRevision'] = before.verificationRevision + 1
      ..['issues'] = [
        ...before.issues,
        {
          'id': 'old-test-defect',
          'sourceId': 'qa',
          'kind': 'defect',
          'status': 'open',
          'target': 'plan',
          'problem': '旧测试步骤不可复现',
          'evidenceRef': 'old-review',
          'resolution': '',
          'resolutionRef': '',
          'retestCondition': '提出者核对正式修订方案',
          'requestRevision': before.requestRevision,
        },
        {
          'id': issueId,
          'sourceId': 'dev',
          'kind': 'idea',
          'status': 'open',
          'target': 'plan',
          'problem': '测试步骤需修订',
          'evidenceRef': 'request',
          'resolution': 'scope-proposal',
          'resolutionRef': 'proposal:$digest',
          'retestCondition': '全员重新审阅',
          'requestRevision': before.requestRevision,
        }
      ])!;
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      task.executionStateJson,
      shell.copyWith(collaboration: pending),
      expectedCollaborationRevision: before.revision,
    );
    final reviewers = <String>[];
    var revised = false;
    var unresolvedReviews = 0;
    var repairedFormalPlan = false;
    await modelRunner((member, context) async {
      final state = context['collaboration'] as Map<String, dynamic>;
      final proposal = state['pendingProposal'] as Map?;
      expect(
          (state['usageAssignments'] as List).cast<Map>().every(
              (assignment) => !assignment.containsKey('requestRevision')),
          isTrue,
          reason: '提案参考不能混入运行时版本字段');
      if (proposal != null) {
        expect((state['issues'] as List).first['status'], 'open',
            reason: '待审提案不能提前关闭旧缺陷');
        if (context['turnFocus']?['issueId'] == issueId &&
            context['turnFocus']?['stage'] ==
                WorkDiscussionStage.prepareProposal.name) {
          expect(member.id, before.coordinatorId);
          expect(reviewers.length, 1, reason: '首个真实反对后即可返修，不能等全员反复拒绝同一稿');
          revised = true;
          return _turn('propose',
              issue: issueId, proposal: {...candidate, 'plan': '修订后的可复现测试步骤'});
        }
        if (!revised) reviewers.add(member.id);
        expect(reviewers.toSet().length, reviewers.length,
            reason: '模型重复点名不能让已表态成员抢占尚未表态成员');
        final response = _turn('approve', approval: {
          ...approval(state),
          'kind': 'idea',
          'subjectId': issueId,
          'approved': revised,
        });
        final body = jsonDecode(response['message'] as String) as Map;
        body['next_member_id'] = member.id;
        return {...response, 'message': jsonEncode(body)};
      }
      final defect = (state['issues'] as List)
          .cast<Map>()
          .firstWhere((issue) => issue['id'] == 'old-test-defect');
      if (defect['status'] == 'open') {
        if (context['turnFocus']?['stage'] ==
            WorkDiscussionStage.prepareProposal.name) {
          expect(member.id, before.coordinatorId);
          expect(unresolvedReviews, 1, reason: '同一正式方案复核未解决后应交回协调者，而非重复询问提出者');
          repairedFormalPlan = true;
          return _turn('propose', proposal: {
            ...candidate,
            'plan': '修订后的可复现测试步骤，已补齐全部已知规则',
          });
        }
        expect(member.id, 'qa', reason: '正式采纳后必须调度问题提出者复核');
        if (!repairedFormalPlan) {
          unresolvedReviews++;
          expect(unresolvedReviews, 1);
          return _turn('respond', text: '正式方案仍缺同格规则，请协调者集中修订。');
        }
        final ref = (context['availableResolutionEvidence'] as List)
            .cast<Map>()
            .firstWhere((e) => e['kind'] == 'formal-plan')['ref'];
        return _turn('respond', resolutions: [
          {
            'id': 'old-test-defect',
            'resolution': '本人核对正式方案，步骤已可复现',
            'evidenceRef': ref,
          }
        ]);
      }
      return accept(member, context);
    }).runCollaboration(task, WorkTaskCancellation(), apply);
    final after =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(revised, isTrue);
    expect(repairedFormalPlan, isTrue);
    expect(after.decisions, isEmpty);
    expect(after.plan, '修订后的可复现测试步骤，已补齐全部已知规则');
    expect(after.planReady, isTrue);
    expect(
        after.usageAssignments.every((assignment) =>
            assignment['requestRevision'] == after.requestRevision),
        isTrue,
        reason: '只投影模型输入，不能删除权威版本绑定');
    expect(
        after.issues.firstWhere((i) => i['id'] == 'old-test-defect')['status'],
        'resolved');
    expect(
        after.approvals
            .any((a) => a['kind'] == 'idea' && a['approved'] == false),
        isTrue);
    expect(await events.readDiscussionDetail(task.id, digest), serialized);
  }, timeout: const Timeout(Duration(seconds: 30)));

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
    final omitted = _autonomousProposal(state)..remove('usageAssignments');
    String? error;
    expect(
        WorkDiscussionV2Turn.parse(_turn('propose', proposal: omitted),
            autonomous: true, onInvalid: (value) => error = value),
        isNull);
    expect(error, contains('proposal.usageAssignments'));
    final invalidType = _autonomousProposal(state);
    (invalidType['usageAssignments'] as List).first['preconditions'] = ['空数据'];
    expect(
        WorkDiscussionV2Turn.parse(_turn('propose', proposal: invalidType),
            autonomous: true, onInvalid: (value) => error = value),
        isNull);
    expect(error, contains('usageAssignments[0].preconditions'));
    expect(error, contains('不是数组'));
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
    for (final prompt in [autonomous, repair]) {
      expect(prompt, contains(WorkDiscussionProtocolText.autonomyRules));
      expect('usageAssignments 数量必须等于'.allMatches(prompt), hasLength(1));
      expect(prompt, contains('不提供键盘、输入框填值'));
      expect(prompt, contains('有名称的可点击按钮或已确认的 queryParameters'));
      expect(prompt, contains('至少一名非制作人实际执行'));
    }
  });

  test('自主提案遗漏场景的修复请求带齐自主协议和参与者名册', () async {
    // `autonomyRules` 要求按名册的 memberId 对齐参与者，而修复请求也嵌入这份
    // 规则；名册只出现在首轮上下文里时，修复器只能拿显示名去凑 memberId。
    task.executionStateJson = jsonEncode({
      ...jsonDecode(task.executionStateJson) as Map,
      'autonomyUpgradePending': true,
    });
    final repairs = <Map<String, dynamic>>[];
    final repairInstructions = <String>[];
    Object? assignments;
    await modelRunner((member, context) async {
      if (context['field'] == 'usageAssignments') {
        repairs.add(context);
        expect(context.containsKey('collaboration'), isFalse);
        expect(context.containsKey('originalFinal'), isFalse);
        return {
          'success': true,
          'message': jsonEncode({'usageAssignments': assignments})
        };
      }
      final state = context['collaboration'] as Map<String, dynamic>;
      if ((state['plan'] as String).isEmpty) {
        final next = _autonomousProposal(state);
        assignments = next.remove('usageAssignments');
        return _turn('propose', proposal: next);
      }
      return _turn('approve', approval: {...approval(state)});
    }, onMessages: (_, messages) {
      if ((messages.last['content'] as String).contains('protocolError')) {
        repairInstructions.add(messages.first['content'] as String);
      }
    }).runCollaboration(task, WorkTaskCancellation(), apply);

    expect(repairs, isNotEmpty);
    expect(
        repairs.first['protocolError'], contains('proposal.usageAssignments'));
    expect(repairInstructions.single,
        contains(WorkDiscussionProtocolText.autonomyRules));
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
