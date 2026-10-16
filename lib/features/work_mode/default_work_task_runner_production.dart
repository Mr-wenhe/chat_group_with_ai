part of 'default_work_task_runner.dart';

/// 状态闸门对单条决策的选项上限（校验里写死 12，与
/// `WorkDiscussionRunner.maxDecisionOptions` 同值）；本决策还要留 1 个“人工验收”。
const int _reviewerOptionLimit = 11;

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
    if (!WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .isProductionExecutorConsistent ||
        !state.productionReady ||
        state.pendingInputIds.isNotEmpty) {
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
    if (state.artifactContract['type'] != 'software') return true;
    // 用户只点名一个交付文件时不强制材料工作项：验证力来自 acceptances、下面的
    // verificationCommands 与独立审查，那三样一项没少；材料文档只是过程证据，在
    // 单文件交付上会把任务放大数倍（2026-10-10 现场：一个 HTML 变成五份产物）。
    //
    // 判定必须读**冻结**的需求范围，不能读 `task.userRequest`：讨论时播出去的协议
    // 文本是按冻结范围生成的，而跟进推广会覆盖 `task.userRequest`。两处各读各的
    // 时候，一次跟进就能让"方案必须有材料工作项"的承诺在这里静默消失——没有状态
    // 变更、没有事件，只是门禁少了一条。
    final singleArtifact = requestsSingleArtifact(
      WorkDiscussionState.currentRequestScope(task),
    );
    if ((state.artifactContract['files'] as List? ?? const []).isEmpty ||
        (state.artifactContract['verificationCommands'] as List? ?? const [])
            .isEmpty ||
        !state.workItems.any((i) => i['kind'] == 'produce') ||
        (!singleArtifact &&
            !state.workItems.any((i) => i['kind'] == 'material'))) {
      await _productionDecision(
          task,
          'question',
          '',
          singleArtifact
              ? '软件方案缺少完整的实现文件清单或验证命令，请回群补齐后逐人确认。'
              : '软件方案缺少需求、技术、测试材料工作项或完整实现文件合同，请回群补齐后逐人确认。',
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
      if (await _prepareUsageActor(task, state)) return true;
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
      final acceptanceId = state.acceptances.firstWhere(
          (a) => !{'manual', 'waived'}.contains(a['status']))['id'] as String;
      // 纯文档任务只会选出单一 product 阶段，团队里没有第二个人能当审查人；
      // 直接在弹窗里给角色库候选，用户点选后由下一轮讨论写进团队
      // （见 _formTeam 对 kind='member' + targetId='role:xxx' 的处理）。
      final role = WorkRoleRouter.canonicalArtifactType(
                  state.artifactContract['type']?.toString()) ==
              'software'
          ? 'testing'
          : 'reviewer';
      if (!_reviewerOptedManual(state, role)) {
        final options = await _independentReviewerOptions(
            state, candidate.producerId, role);
        if (options.isNotEmpty) {
          options.add({
            'id': 'human-review',
            'label': '无需额外审查，改由人工验收',
            'impact': '不新增审查成员，改为对当前候选记录人工验收或明确豁免。'
          });
          await _productionDecision(task, 'member', 'role:$role',
              '缺少独立且合格的审查成员，请从角色库指定一位审查角色，或改为人工验收。',
              options: options, persist: false);
          return false;
        }
      }
      await _productionDecision(task, 'acceptance', acceptanceId,
          '缺少独立且合格的审查成员，请补充已有成员能力、人工验收、明确豁免或暂缓。',
          persist: false);
      return false;
    }
    task.characterId = reviewer['memberId'] as String;
    if (!await _productionActorAvailable(task, persist: false)) return false;
    _bindWorkItem(task, 'verify', candidate.iterationId);
    return true;
  }

  /// 用户是否已在“指定审查角色”弹窗里选了“改由人工验收”。
  ///
  /// 该选项 id 不属于任何角色，`_formTeam` 不会因此改动团队；若不在这里识别，
  /// 团队不变会再次走到同一个候选弹窗，形成“选了人工验收又弹回候选”的死循环。
  bool _reviewerOptedManual(WorkCollaborationState state, String role) =>
      state.decisions.any((d) =>
          d['kind'] == 'member' &&
          d['status'] == 'answered' &&
          d['answerKind'] == 'choice' &&
          d['targetId'] == 'role:$role' &&
          (d['options'] as List? ?? const []).whereType<Map>().any(
              (o) => o['id'] == 'human-review' && o['label'] == d['answer']));

  /// 角色库里“独立、可用、且能承担 [role] 责任”的审查候选，用于“缺审查人”弹窗。
  ///
  /// 与讨论换人同口径：排除产出人、已在团队的人，以及承担非材料工作项的人；
  /// 凭据并发解析，避免一个挂住的凭据提供方把弹窗推迟 N × 凭据超时。
  Future<List<Map<String, dynamic>>> _independentReviewerOptions(
      WorkCollaborationState state, String producerId, String role) async {
    final candidates = database.aiCharacterBox.values
        .where((c) =>
            c.id != producerId &&
            !state.team.any((m) => m['memberId'] == c.id) &&
            !state.workItems
                .any((i) => i['kind'] != 'material' && i['ownerId'] == c.id) &&
            WorkRoleRouter.qualifiesForResponsibility(
                c, role, database.characterSkillBox.values))
        .toList();
    final resolved = await Future.wait(candidates.map((c) async {
      final config = _resolveApiConfig(c);
      if (config == null) return null;
      try {
        final credential = await credentials.resolve(config);
        return credential?.trim().isNotEmpty == true ? config : null;
      } on Object {
        return null;
      }
    }));
    // 状态闸门限制单条决策 12 个选项，本决策还要留 1 个“人工验收”。
    const optionLimit = _reviewerOptionLimit;
    final options = <Map<String, dynamic>>[];
    for (var i = 0;
        i < candidates.length && options.length < optionLimit;
        i++) {
      final config = resolved[i];
      if (config == null) continue;
      final c = candidates[i];
      options.add({
        'id': c.id,
        'label': '${c.name}（${c.role}，${config.modelName}）',
        'impact': '只加入本次任务的审查责任；保留目录、工具和模型治理边界。'
      });
    }
    return options;
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
    // 成因逐条分开报：把启用状态、团队授权、责任资格、模型配置与凭据揉成一句
    // 「当前责任成员失效或模型凭据不可用」，用户不知道该恢复配置、补人还是改
    // 责任（与讨论侧 `_checkTeam` 同一条理由，2026-10-15 现场）。
    String? failure;
    if (member == null) {
      failure = '成员已删除';
    } else {
      failure = _productionMemberFailure(task, _candidateState(task), member);
      failure ??= await _productionCredentialFailure(member);
    }
    if (failure == null) return true;
    await _productionDecision(task, 'member', task.characterId,
        '当前责任成员不可用：$failure。请恢复或确认已有合格成员接任，未代签。',
        persist: persist);
    return false;
  }

  /// 责任成员在 [state] 这次任务里不可用的**具体成因**，null 表示可用。
  ///
  /// `qualifiesForResponsibility` 把可用性与职业资格合成一个布尔，只报它就只能
  /// 写出「当前失效」「资格或配置不可用」——用户看不出该恢复配置、重新启用成员、
  /// 补人还是改责任。授权/离群、不在团队里、资格不足、模型配置缺失**各说各的**，
  /// 不要再加分支把它们合并回去（讨论侧 `_checkTeam` 与执行侧各入口共用这条判据）。
  ///
  /// 判断顺序即处置顺序：先看成员与群是否还在、是否仍获任务加入确认，再看团队
  /// 责任与可用性。团队责任**先于**可用性——成员不在团队里时，它有没有绑模型都
  /// 不影响结论，先报配置只会让用户白修一轮，下次再撞上"不在团队里"。
  String? _productionMemberFailure(
      AgentTask task, WorkCollaborationState state, AICharacter member) {
    if (database.chatGroupBox.get(task.groupId) == null) return '群组已删除';
    if (!_productionMemberAuthorized(task, member.id)) {
      return '成员已离开当前群，未获任务加入确认';
    }
    // 责任条目缺失时 `singleWhere` 会抛 StateError，执行期不该以异常代替一句
    // 可处置的成因。
    final role = state.team
        .where((item) => item['memberId'] == member.id)
        .firstOrNull?['role'];
    if (role is! String) return '成员已不在本次任务的团队里';
    final unavailable = WorkRoleRouter.availabilityFailure(member);
    if (unavailable != null) return unavailable;
    if (!WorkRoleRouter.qualifiesForResponsibility(
        member, role, database.characterSkillBox.values)) {
      return '成员不具备本次任务所需的${WorkRoleRouter.responsibilityLabel(role)}能力';
    }
    return null;
  }

  /// 责任成员的模型配置与凭据成因，null 表示可用。单独一步是因为解析凭据是
  /// 异步的，且它只在前面的成员级检查都通过后才值得做。
  Future<String?> _productionCredentialFailure(AICharacter member) async {
    final config = _resolveApiConfig(member);
    if (config == null) return '没有绑定模型配置';
    try {
      final credential = await credentials.resolve(config);
      return credential?.trim().isNotEmpty == true ? null : '模型凭据不可用';
    } on Object {
      return '模型凭据不可用';
    }
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
      root.remove('v2UsageObservationRef');
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
      {List<Map<String, dynamic>> options = const [],
      bool persist = true}) async {
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
                'responseRef': '',
                if (options.isNotEmpty) 'options': options,
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
