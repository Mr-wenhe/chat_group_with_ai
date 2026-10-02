part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerProductionDelivery on DefaultWorkTaskRunner {
  Future<void> _republishProductionBaseline(AgentTask task) async {
    final state = _candidateState(task);
    final publisher = await candidatePublisher(task);
    final candidate = (await publisher.recover()).last;
    final workspace = _workspaceRootForTask(task)!;
    final tested = {
      for (final f in candidate.files)
        f['path'] as String: File(p.join(workspace, f['path'] as String))
    };
    // User review never transfers to changed content or a changed test baseline.
    await publisher.verify(candidate,
        expectedDigest: candidate.digest, testedFiles: tested);
    await _productionCommit(task, 'workItem', {'phase': 'producing'});
    await publishCandidate(task,
        publicationId:
            'user-baseline-${state.requestRevision}-${state.teamRevision}',
        requiredPaths: tested.values.map((f) => f.path).toList());
    task
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false;
    await _persistCheckpoint(task);
  }

  Future<void> _recordUserProductionReview(AgentTask task) async {
    final state = _candidateState(task);
    final publisher = await candidatePublisher(task);
    final candidate = (await publisher.recover())
        .singleWhere((c) => c.iterationId == state.currentIteration!['id']);
    final decisions = [
      for (final a in state.acceptances)
        state.decisions.singleWhere((d) =>
            d['targetId'] == a['id'] &&
            d['responseRef'] == a['evidenceRef'] &&
            {'answered', 'waived'}.contains(d['status']))
    ];
    final review = await publisher.beginReview(
        candidate: candidate,
        attemptId: 'user-${state.revision}',
        actorId: 'user',
        verificationRevision: state.verificationRevision + 1,
        testedFiles: {
          for (final f in candidate.files)
            f['path'] as String:
                File(p.join(_workspaceRootForTask(task)!, f['path'] as String))
        });
    final report = await publisher.appendReview(review,
        method: '用户明确人工验收或豁免；未声称自动验证通过',
        source: 'human',
        receipt: decisions.map((d) => d['responseRef']).join(','),
        result: 'manual',
        acceptanceIds: state.acceptances.map((a) => a['id'] as String).toList(),
        report: jsonEncode({
          'decisions': decisions,
          'acceptances': state.acceptances,
          'candidate': candidate.reference
        }));
    await _commitUserReviewBaseline(task, state, review);
    await sendCandidateVersion(task, candidate, kind: 'review', report: report);
    task
      ..status = AgentTaskStatus.paused
      ..resumeRequired = false;
    await _persistCheckpoint(task);
  }

  Future<void> _commitUserReviewBaseline(AgentTask task,
      WorkCollaborationState state, WorkCandidateReview review) async {
    final candidate = review.candidate;
    await _productionCommit(task, 'review', {
      'verificationRevision': review.verificationRevision,
      'phase': 'reviewing',
      'acceptances': [
        for (final a in state.acceptances)
          {...a, 'verificationRevision': review.verificationRevision}
      ],
      'iterations': [
        for (final i in state.iterations)
          i['id'] == candidate.iterationId
              ? {...i, 'status': 'reviewed', 'reviewRef': review.reference}
              : i
      ]
    });
  }

  Future<void> _deliverProduction(AgentTask task) async {
    final state = _candidateState(task);
    if (!state.deliveryReady || task.queuedUserRequests.isNotEmpty) return;
    final publisher = await candidatePublisher(task);
    final candidate = (await publisher.recover())
        .where((c) => c.iterationId == state.currentIteration!['id'])
        .single;
    await publisher.verify(candidate, expectedDigest: candidate.digest);
    if (_candidateState(task).revision != state.revision ||
        task.queuedUserRequests.isNotEmpty) {
      return;
    }
    // The coordinator checks this receipt and FIFO inside its serial completion.
    final root = _decodeMap(task.executionStateJson);
    root['v2DeliveryPrepared'] = {
      'revision': state.revision,
      'iterationId': candidate.iterationId,
      'artifactDigest': candidate.digest
    };
    task.executionStateJson = jsonEncode(root);
    task
      ..status = AgentTaskStatus.runningTool
      ..lastError = ''
      ..resultSummary = '候选与逐员认可已核对 ${candidate.iterationId}，等待正式封存投递。';
    await _persistCheckpoint(task);
  }

  Future<void> _validateDeliveryMembers(
      AgentTask task, WorkCollaborationState state) async {
    final group = database.chatGroupBox.get(task.groupId);
    for (final id in state.activeMembers) {
      final member = database.aiCharacterBox.get(id);
      if (member == null ||
          !member.isActive ||
          !member.agenticEnabled ||
          !WorkRoleRouter.qualifiesForResponsibility(
              member,
              state.team.singleWhere((m) => m['memberId'] == id)['role']
                  as String,
              database.characterSkillBox.values) ||
          group == null ||
          !_productionMemberAuthorized(task, id)) {
        await _productionDecision(task, 'member', id, '成员 $id 当前失效，需重新确认团队与认可。',
            persist: false);
        throw StateError('成员 $id 当前失效，需重新确认团队与认可。');
      }
      final config = _resolveApiConfig(member);
      var credentialAvailable = false;
      if (config != null) {
        try {
          credentialAvailable =
              (await credentials.resolve(config))?.trim().isNotEmpty == true;
        } on Object {/* Unavailable credentials require user action. */}
      }
      if (!credentialAvailable) {
        await _productionDecision(
            task, 'member', id, '成员 $id 模型凭据已失效，请恢复后重新确认。',
            persist: false);
        throw StateError('成员 $id 模型凭据已失效。');
      }
    }
  }

  Future<void> _commitCollaborationDelivery(AgentTask task,
      {bool Function()? hasArrivingInput}) async {
    final state = _candidateState(task);
    if (!state.deliveryReady ||
        task.queuedUserRequests.isNotEmpty ||
        hasArrivingInput?.call() == true) {
      throw StateError('正式交付基线已变化。');
    }
    if (state.phase != 'delivered') await _validateDeliveryMembers(task, state);
    final publisher = await candidatePublisher(task);
    final candidate = (await publisher.recover())
        .where((c) => c.iterationId == state.currentIteration!['id'])
        .single;
    if (!await publisher.evidenceValid(
        candidate, state.currentIteration!['reviewRef'] as String)) {
      throw StateError('验收证据失效，不能正式交付。');
    }
    // This callback runs inside the coordinator serial boundary. Checkpoints
    // stay in that transaction rather than recursively awaiting the same queue.
    _coordinatorDeliveryTasks.add(task.id);
    try {
      if (hasArrivingInput?.call() == true) throw StateError('新输入待纳入，未正式完成。');
      await publisher.sealOutcome(candidate, state, accepted: true);
      if (hasArrivingInput?.call() == true) {
        throw StateError('本轮已封存，新输入待纳入，未正式完成。');
      }
      final sealed = _decodeMap(task.executionStateJson);
      sealed['v2DeliverySealed'] = sealed['v2DeliveryPrepared'];
      task.executionStateJson = jsonEncode(sealed);
      await _sendProductionDelivery(task, candidate, hasArrivingInput);
      if (state.phase != 'delivered') {
        await _productionCommit(task, 'workItem', {'phase': 'delivered'});
        final checkpoint = _decodeMap(task.executionStateJson);
        (checkpoint['v2DeliveryPrepared'] as Map)['revision'] =
            _candidateState(task).revision;
        task.executionStateJson = jsonEncode(checkpoint);
      }
    } finally {
      _coordinatorDeliveryTasks.remove(task.id);
    }
  }

  Future<void> _sendProductionDelivery(AgentTask task, WorkCandidate candidate,
      bool Function()? hasArrivingInput) async {
    final delivered =
        await sendCandidateVersion(task, candidate, kind: 'final');
    await _checkDeliveryInput(task, candidate, hasArrivingInput);
    task.resumeRequired = !delivered;
    task.lastError = delivered ? '' : '验收已通过，封存版本附件投递失败，可重发。';
    if (!delivered) {
      WorkFailure.persistOnTask(
          task,
          WorkFailure.fromToolFailure(
              code: 'artifactDelivery',
              message: task.lastError,
              scope: 'delivery',
              completedContent:
                  candidate.files.map((f) => f['path'] as String).toList(),
              retryable: true));
    } else {
      WorkFailure.clearFromTask(task);
    }
  }

  Future<void> _checkDeliveryInput(AgentTask task, WorkCandidate candidate,
      bool Function()? hasArrivingInput) async {
    if (hasArrivingInput?.call() == true) {
      for (final message in database.messageBox.values.where((m) =>
          m.workDelivery?['taskId'] == task.id &&
          m.workDelivery?['iterationId'] == candidate.iterationId &&
          m.workDelivery?['kind'] == 'final')) {
        message.content = '本轮 ${candidate.iterationId} 已封存；新增输入待处理，任务未正式完成。';
        await database.updateMessage(message);
      }
      throw StateError('新增输入待处理，任务未正式完成。');
    }
  }
}
