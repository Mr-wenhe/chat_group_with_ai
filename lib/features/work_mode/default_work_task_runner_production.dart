part of 'default_work_task_runner.dart';

/// One work item per scheduled lease. The business record remains collaboration;
/// workItemExecution only binds the loop's receipts and deduplication namespace.
extension _DefaultWorkTaskRunnerProduction on DefaultWorkTaskRunner {
  Future<bool> _runProductionTransportStage(AgentTask task) async {
    final state = _candidateState(task);
    final binding =
        _decodeMap(task.executionStateJson)['workItemExecution'] as Map?;
    if (binding == null ||
        binding['requestRevision'] != state.requestRevision ||
        binding['teamRevision'] != state.teamRevision ||
        binding['verificationRevision'] != state.verificationRevision ||
        binding['actorId'] != task.characterId ||
        !state.productionReady ||
        !state.activeMembers.contains(task.characterId)) {
      task
        ..status = AgentTaskStatus.paused
        ..resumeRequired = false
        ..lastError = '当前工作项未获得调度或方案认可。';
      await _persistCheckpoint(task);
      return true;
    }
    switch (binding['stage']) {
      case 'publish':
        await _publishCompletedProduction(task);
        task
          ..status = AgentTaskStatus.queued
          ..resumeRequired = false;
        await _persistCheckpoint(task);
      case 'baseline':
        await _republishProductionBaseline(task);
      case 'user-review':
        await _recordUserProductionReview(task);
      case 'final':
        await _deliverProduction(task);
      default:
        return false;
    }
    return true;
  }

  Future<bool> _prepareCollaborationWork(AgentTask task) async {
    final state = _candidateState(task);
    if (!state.productionReady || state.pendingInputIds.isNotEmpty) {
      return false;
    }
    if (!await _productionContractAvailable(task, state)) return false;
    final done = state.workItems
        .where((i) => i['status'] == 'done')
        .map((i) => i['id'])
        .toSet();
    final item = state.workItems
        .where((i) =>
            {'pending', 'active'}.contains(i['status']) &&
            !state.deferredWork.contains(i['id']) &&
            i['requestRevision'] == state.requestRevision &&
            (i['dependencies'] as List).every(done.contains))
        .firstOrNull;
    if (item != null) {
      task.characterId = item['ownerId'] as String;
      if (!await _productionActorAvailable(task, persist: false)) return false;
      await _productionCommit(
          task,
          'workItem',
          {
            'phase': 'producing',
            'workItems': [
              for (final i in state.workItems)
                i['id'] == item['id'] ? {...i, 'status': 'active'} : i
            ]
          },
          persist: false);
      _bindWorkItem(task, item['kind'] == 'material' ? 'material' : 'produce',
          item['id'] as String);
      return true;
    }
    return _prepareCompletedProduction(task, state);
  }

  Future<bool> _productionContractAvailable(
      AgentTask task, WorkCollaborationState state) async {
    if (state.artifactContract['type'] == 'software' &&
        ((state.artifactContract['files'] as List? ?? const []).isEmpty ||
            (state.artifactContract['verificationCommands'] as List? ??
                    const [])
                .isEmpty ||
            !state.workItems.any((i) => i['kind'] == 'material') ||
            !state.workItems.any((i) => i['kind'] == 'produce'))) {
      await _productionDecision(
          task, 'question', '', '软件方案缺少需求、技术、测试材料工作项或完整实现文件合同，请回群补齐后逐人确认。',
          persist: false);
      return false;
    }
    return true;
  }

  Future<bool> _prepareCompletedProduction(
      AgentTask task, WorkCollaborationState state) async {
    if (state.workItems.any((i) => i['status'] != 'done') ||
        state.workItems.isEmpty) {
      return false;
    }
    if (state.currentIteration == null ||
        state.currentIteration!['requestRevision'] != state.requestRevision) {
      final publisher = await candidatePublisher(task);
      final candidates = await publisher.recover();
      final userBaseline = state.acceptances
              .any((a) => {'manual', 'waived'}.contains(a['status'])) &&
          candidates.isNotEmpty;
      task.characterId = userBaseline
          ? candidates.last.producerId
          : state.workItems.lastWhere((i) => i['kind'] != 'material',
              orElse: () => state.workItems.last)['ownerId'] as String;
      if (!await _productionActorAvailable(task, persist: false)) return false;
      _bindWorkItem(task, userBaseline ? 'baseline' : 'publish',
          state.currentIteration?['id'] as String? ?? 'unpublished');
      return true;
    }
    if (state.phase == 'ready') {
      await _productionCommit(task, 'workItem', {'phase': 'verifying'},
          persist: false);
      return _prepareProductionReviewer(task, _candidateState(task));
    }
    if (state.phase == 'reviewing') {
      if (!state.deliveryReady) return false;
      _bindWorkItem(task, 'final', state.currentIteration!['id'] as String);
      return true;
    }
    if (state.phase != 'verifying') return false;
    if (state.hasPendingDecision &&
        state.acceptances.every((a) =>
            state.deferredWork.contains(a['id']) ||
            {'passed', 'manual', 'waived'}.contains(a['status']))) {
      return false;
    }
    return _prepareProductionReviewer(task, state);
  }

  Future<bool> _prepareProductionReviewer(
      AgentTask task, WorkCollaborationState state) async {
    final publisher = await candidatePublisher(task);
    final candidate = (await publisher.recover())
        .where((c) => c.iterationId == state.currentIteration!['id'])
        .single;
    if (state.acceptances.isNotEmpty &&
        state.acceptances
            .every((a) => {'manual', 'waived'}.contains(a['status']))) {
      task.characterId = candidate.producerId;
      if (!await _productionActorAvailable(task, persist: false)) return false;
      _bindWorkItem(task, 'user-review', candidate.iterationId);
      return true;
    }
    final reviewer = state.team
        .where((m) =>
            m['memberId'] != candidate.producerId &&
            !state.workItems.any((i) =>
                i['kind'] != 'material' && i['ownerId'] == m['memberId']) &&
            (state.artifactContract['type'] != 'software' ||
                RegExp(r'test|qa|测试|质量', caseSensitive: false)
                    .hasMatch(m['role'] as String)))
        .firstOrNull;
    if (reviewer == null) {
      await _productionDecision(
          task,
          'acceptance',
          state.acceptances.firstWhere(
                  (a) => !{'manual', 'waived'}.contains(a['status']))['id']
              as String,
          '缺少独立且合格的审查成员，请补充已有成员能力、人工验收、明确豁免或暂缓。',
          persist: false);
      return false;
    }
    task.characterId = reviewer['memberId'] as String;
    if (!await _productionActorAvailable(task, persist: false)) return false;
    _bindWorkItem(task, 'verify', candidate.iterationId);
    return true;
  }

  bool _productionMemberAuthorized(AgentTask task, String id) {
    final state = _candidateState(task);
    return database.chatGroupBox
                .get(task.groupId)
                ?.aiCharacterIds
                .contains(id) ==
            true ||
        state.decisions.any((d) =>
            d['kind'] == 'member' &&
            d['status'] == 'answered' &&
            d['answerKind'] == 'choice' &&
            (d['options'] as List? ?? const [])
                .whereType<Map>()
                .any((o) => o['id'] == id && o['label'] == d['answer']));
  }

  Future<bool> _productionActorAvailable(AgentTask task,
      {required bool persist}) async {
    final member = database.aiCharacterBox.get(task.characterId);
    final group = database.chatGroupBox.get(task.groupId);
    final config = member == null ? null : _resolveApiConfig(member);
    var available = member != null &&
        member.isActive &&
        member.agenticEnabled &&
        group != null &&
        _productionMemberAuthorized(task, member.id) &&
        WorkRoleRouter.qualifiesForResponsibility(
            member,
            _candidateState(task)
                    .team
                    .singleWhere((m) => m['memberId'] == member.id)['role']
                as String,
            database.characterSkillBox.values) &&
        config != null;
    if (available) {
      try {
        final credential = await credentials.resolve(config);
        available = credential?.trim().isNotEmpty == true;
      } on Object {
        available = false;
      }
    }
    if (available) return true;
    await _productionDecision(task, 'member', task.characterId,
        '当前责任成员失效或模型凭据不可用，请恢复或确认已有合格成员接任，未代签。',
        persist: persist);
    return false;
  }

  void _bindWorkItem(AgentTask task, String stage, String id) {
    final state = _candidateState(task);
    final root = _decodeMap(task.executionStateJson);
    final old = root['workItemExecution'];
    final binding = {
      'stage': stage,
      'workItemId': id,
      'iterationId': state.currentIteration?['id'] ?? 'unpublished',
      'requestRevision': state.requestRevision,
      'teamRevision': state.teamRevision,
      'verificationRevision': state.verificationRevision,
      'actorId': task.characterId,
    };
    if (jsonEncode(old) != jsonEncode(binding)) {
      // Prior actor's prompt/results and approval cannot become this actor's.
      task.pendingToolRequestJson = '';
      task.contextSummary = '';
      task.resultSummary = '';
      task.lastError = '';
      WorkFailure.clearFromTask(task);
      final cleaned = _decodeMap(_withoutApprovalCheckpoint(jsonEncode(root)));
      root
        ..clear()
        ..addAll(cleaned);
      task.plan = state.plan;
      root.remove('lastToolResult');
      root.remove('visionModelCharacterId');
      root.remove('publicUpdates');
      root.remove('v2WorkItemCompletion');
      root.remove('v2ReviewReceiptRef');
      _pendingRequests.remove(task.id);
    }
    root['workItemExecution'] = binding;
    task.executionStateJson = jsonEncode(root);
  }

  Future<void> _productionCommit(
      AgentTask task, String role, Map<String, dynamic> patch,
      {bool persist = true}) async {
    final state = _candidateState(task);
    final event = 'production-${state.revision}';
    final raw = state.toJson()
      ..addAll(patch)
      ..['revision'] = state.revision + 1
      ..['appliedEventIds'] = [
        ...state.appliedEventIds
            .skip(state.appliedEventIds.length == 64 ? 1 : 0),
        event
      ];
    final next = WorkCollaborationState.tryParse(raw);
    if (next == null) throw StateError('制作或审查记录越界，保留原记录等待处理。');
    final applied = state.apply(WorkCollaborationUpdate(
        taskId: task.id,
        conversationId: task.groupId,
        expectedRevision: state.revision,
        eventId: event,
        sourceRole: role,
        sourceId: task.characterId,
        next: next));
    final discussion =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        discussion.copyWith(
            collaboration: applied, requestRevision: applied.requestRevision),
        expectedCollaborationRevision: state.revision);
    if (persist) await _persistCheckpoint(task);
  }

  Future<void> _productionDecision(
      AgentTask task, String kind, String target, String reason,
      {bool persist = true}) async {
    final state = _candidateState(task);
    final actor = task.characterId;
    task.characterId = state.coordinatorId;
    try {
      await _productionCommit(
          task,
          'coordinator',
          {
            'requestRevision': state.requestRevision + 1,
            'decisions': [
              ...state.decisions,
              {
                'id': 'production-decision-${state.revision}',
                'revision': 1,
                'status': 'pending',
                'kind': kind,
                'targetId': target,
                'reason': reason,
                'evidence': jsonEncode({
                  'iterationId': state.currentIteration?['id'],
                  'artifactDigest': state.currentIteration?['artifactDigest'],
                  'verificationRevision': state.verificationRevision,
                  'fact': '本轮执行无法形成有效验收证据。'
                }),
                'answer': '',
                'impact': '保留候选，处理后重新核对方案与验收。',
                'responseRef': ''
              }
            ]
          },
          persist: persist);
      task
        ..status = AgentTaskStatus.paused
        ..resumeRequired = false
        ..lastError = reason;
    } finally {
      task.characterId = actor;
    }
    if (persist) await _persistCheckpoint(task);
  }

  Future<String?> _validateProductionMaterials(
      AgentTask task, AgentFinishCompletion completion) async {
    if (completion.evidence.isEmpty) return '工作材料缺少可打开的证据文件。';
    final files = workspaceFileService;
    final root = _workspaceRootForTask(task);
    if (files == null || root == null) return '工作材料读取能力不可用。';
    for (final path in completion.evidence) {
      final result = await files
          .readTextRange(p.isAbsolute(path) ? path : p.join(root, path));
      if (result.cancelled || result.sensitive || result.text.trim().isEmpty) {
        return '工作材料文件缺失或正文为空。';
      }
    }
    return null;
  }

  Future<void> _completeProductionItem(
      AgentTask task, AICharacter actor) async {
    task.status = AgentTaskStatus.runningTool;
    final root = _decodeMap(task.executionStateJson);
    final binding = root['workItemExecution'] as Map;
    final state = _candidateState(task);
    final id = binding['workItemId'];
    final text = jsonEncode({
      'actorId': actor.id,
      'binding': binding,
      'summary': task.resultSummary,
      'completion': root['v2WorkItemCompletion']
    });
    final digest =
        sha256.convert(utf8.encode(text)).toString().substring(0, 24);
    final detail =
        await eventStore.writeDiscussionDetail(task.id, digest, text);
    await _productionCommit(task, 'workItem', {
      'workItems': [
        for (final i in state.workItems)
          i['id'] == id
              ? {...i, 'status': 'done', 'resultRef': 'proposal:$digest'}
              : i
      ]
    });
    await database.persistMessage(Message(
        groupId: task.groupId,
        senderId: actor.id,
        senderType: 'ai',
        isWorkMode: true,
        content: task.resultSummary,
        media: [
          MediaAttachment(
              type: 'file', localPath: detail.path, fileName: '工作项交接.json')
        ]));
    await _publishCompletedProduction(task);
    task
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false;
    await _persistCheckpoint(task);
  }

  Future<void> _publishCompletedProduction(AgentTask task) async {
    final current = _candidateState(task);
    if (current.workItems.every((i) => i['status'] == 'done')) {
      if (current.phase == 'ready') {
        await _productionCommit(task, 'workItem', {'phase': 'producing'});
      }
      final declared = (current.artifactContract['files'] as List? ?? const [])
          .cast<String>();
      final workspace = _workspaceRootForTask(task);
      final paths = declared
          .map((f) => p.isAbsolute(f) ? f : p.join(workspace!, f))
          .toList();
      await publishCandidate(task,
          publicationId:
              'production-${current.requestRevision}-${current.teamRevision}',
          requiredPaths: paths);
    }
  }
}
