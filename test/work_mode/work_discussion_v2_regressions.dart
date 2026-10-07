part of 'work_discussion_v2_test.dart';

void _registerDiscussionHistoryRegressions() {
  test('历史回归：explicit negative rename must keep the pinned file', () async {
    await db.agentTaskBox.put(task.id, task);
    final coordinator = WorkTaskCoordinator(
        taskBox: db.agentTaskBox, runner: execution, eventStore: events);
    addTearDown(coordinator.dispose);
    const supplement = '不要把game.html改名为game2.html，保持现有文件名。';
    await coordinator.enqueueFollowUp(task.id, supplement,
        sourceMessageId: 'rereview3-negative');
    final discussion = modelRunner((member, context) async {
      final current =
          Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((current['plan'] as String).isEmpty) {
        final next = proposal(current);
        next['workItems'] = [
          {
            'id': 'implementation',
            'ownerId': current['coordinatorId'],
            'dependencies': <String>[]
          }
        ];
        next['artifactContract'] = {
          ...current['artifactContract'] as Map,
          'location': 'game2.html'
        };
        return _turn('propose', proposal: next);
      }
      return _turn('approve', approval: approval(current));
    });
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    final current =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(current.artifactContract['location'], 'game.html',
        reason: '$supplement; ${task.lastError}');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
      '历史回归：settled history must preserve a current member joining authorization',
      () async {
    final group = db.chatGroupBox.get(task.groupId)!;
    await db.chatGroupBox.put(
        group.id,
        ChatGroup(
            id: group.id,
            name: group.name,
            theme: group.theme,
            aiCharacterIds: const ['dev']));
    await db.agentTaskBox.put(task.id, task);
    final discussion = modelRunner(confirm);
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    var current =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    final joining = current.decisions.singleWhere(
        (d) => d['kind'] == 'member' && d['targetId'] == 'role:testing');
    final option = (joining['options'] as List)
        .cast<Map>()
        .singleWhere((o) => o['id'] == 'qa');
    const choiceEvent = 'user-confirm-qa-rereview3';
    final answered = WorkCollaborationState.tryParse(current.toJson()
      ..['revision'] = current.revision + 1
      ..['requestRevision'] = current.requestRevision + 1
      ..['appliedEventIds'] = [...current.appliedEventIds, choiceEvent]
          .skip(current.appliedEventIds.length == 64 ? 1 : 0)
          .toList()
      ..['decisions'] = [
        for (final d in current.decisions)
          if (d['id'] == joining['id'])
            {
              ...d,
              'status': 'answered',
              'answer': option['label'],
              'answerKind': 'choice',
              'responseRef': 'user-answer-qa'
            }
          else
            d
      ]);
    expect(answered, isNotNull);
    await apply(WorkCollaborationUpdate(
        taskId: task.id,
        conversationId: task.groupId,
        expectedRevision: current.revision,
        eventId: choiceEvent,
        sourceRole: 'user',
        sourceId: 'user',
        next: answered!));
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    current = WorkDiscussionState.fromExecutionState(task.executionStateJson)!
        .collaboration!;
    expect(current.planReady, isTrue);
    expect(current.team.singleWhere((m) => m['memberId'] == 'qa')['available'],
        isTrue);
    expect(current.decisions.any((d) => d['id'] == joining['id']), isTrue);
    expect(db.chatGroupBox.get(group.id)!.aiCharacterIds, const ['dev']);
    const historyEvent = 'user-history-rereview3';
    final withHistory = WorkCollaborationState.tryParse(current.toJson()
      ..['revision'] = current.revision + 1
      ..['requestRevision'] = current.requestRevision + 1
      ..['appliedEventIds'] = [...current.appliedEventIds, historyEvent]
          .skip(current.appliedEventIds.length == 64 ? 1 : 0)
          .toList()
      ..['decisions'] = [
        ...current.decisions,
        for (var i = 0; i < 64; i++)
          {
            'id': 'answered-$i',
            'revision': i + 1,
            'status': 'answered',
            'kind': 'question',
            'targetId': 'other-$i',
            'reason': '已经确认的细节 $i',
            'evidence': '用户已答复',
            'answer': '继续',
            'answerKind': 'text',
            'impact': '保持方案',
            'responseRef': 'user-$i'
          }
      ]);
    expect(withHistory, isNotNull);
    await apply(WorkCollaborationUpdate(
        taskId: task.id,
        conversationId: task.groupId,
        expectedRevision: current.revision,
        eventId: historyEvent,
        sourceRole: 'user',
        sourceId: 'user',
        next: withHistory!));
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    final after =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(after.team.singleWhere((m) => m['memberId'] == 'qa')['available'],
        isTrue,
        reason: '有效加入授权不应被普通已答复问题挤掉。${jsonEncode(after.decisions)}');
    expect(after.decisions.any((d) => d['id'] == joining['id']), isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final withHistoricalApprovals in [false, true]) {
    test(
        '历史回归：archive signatures do not consume current discussion window: $withHistoricalApprovals',
        () async {
      await db.agentTaskBox.put(task.id, task);
      await modelRunner(confirm)
          .runCollaboration(task, WorkTaskCancellation(), apply);
      final before =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
      final current = before.collaboration!;
      expect(current.productionReady, isTrue);
      final checkpoint = WorkCollaborationState.tryParse(current.toJson()
        ..['revision'] = current.revision + 1
        ..['requestRevision'] = current.requestRevision + 1
        ..['phase'] = 'clarifying'
        ..['iterations'] = [
          for (var i = 1; i <= 70; i++)
            {
              'id': 'r${i.toString().padLeft(3, '0')}',
              'artifactDigest': 'digest-$i',
              'requestRevision': current.requestRevision,
              'teamRevision': current.teamRevision,
              'manifestRef': 'candidate:r$i',
              'reviewRef': 'report-$i',
              'status': 'reviewed'
            }
        ]
        ..['approvals'] = [
          ...current.approvals,
          if (withHistoricalApprovals)
            for (var i = 1; i <= 70; i++)
              for (final member in current.activeMembers)
                {
                  'eventId': 'delivery-$member-$i',
                  'memberId': member,
                  'kind': 'delivery',
                  'subjectId': 'r${i.toString().padLeft(3, '0')}',
                  'requestRevision': current.requestRevision,
                  'teamRevision': current.teamRevision,
                  'verificationRevision': current.verificationRevision,
                  'iterationId': 'r${i.toString().padLeft(3, '0')}',
                  'artifactDigest': 'digest-$i',
                  'approved': true,
                  'evidenceRef': 'reply-$member-$i',
                  'source': 'memberModel'
                }
        ]);
      expect(checkpoint, isNotNull);
      expect(checkpoint!.isValid, isTrue);
      expect(checkpoint.productionReady, isFalse);
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          task.executionStateJson,
          before.copyWith(
              collaboration: checkpoint,
              requestRevision: checkpoint.requestRevision),
          expectedCollaborationRevision: current.revision);
      task.contextSummary = jsonEncode({
        'schemaVersion': 1,
        'conversationId': task.groupId,
        'discussionState': before
            .copyWith(
                collaboration: checkpoint,
                requestRevision: checkpoint.requestRevision)
            .toJson()
      });
      await db.agentTaskBox.put(task.id, task);
      var calls = 0;
      final discussion = modelRunner((member, context) async {
        calls++;
        return confirm(member, context);
      });
      await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
      final after =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!;
      expect(calls, greaterThan(0),
          reason:
              'archive=$withHistoricalApprovals; ${jsonEncode(after.decisions)}');
      expect(after.approvals.where((a) => a['kind'] == 'delivery').length,
          withHistoricalApprovals ? 140 : 0,
          reason: '模型投影不能改写权威历史');
      expect(after.productionReady, isTrue,
          reason:
              'archive=$withHistoricalApprovals; ${jsonEncode(after.decisions)}');
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
}
