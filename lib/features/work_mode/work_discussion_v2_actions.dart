part of 'work_discussion_runner.dart';

extension _V2DiscussionActions on _V2DiscussionSession {
  Future<String?> _consume(
      AICharacter member, WorkDiscussionV2Turn turn, String responseRef) async {
    final initialVerificationRevision = state.verificationRevision;
    for (final issue in turn.issues) {
      final relatedIssues = state.issues
          .where((existing) =>
              existing['kind'] == issue['kind'] &&
              existing['target'] == issue['target'] &&
              (existing['problem'] as String).trim() ==
                  (issue['problem'] as String).trim())
          .toList(growable: false);
      if (state.issues.any((existing) => existing['id'] == issue['id'])) {
        throw StateError('问题 ID 重复；同一问题的新证据必须使用新的问题 ID。');
      }
      if (relatedIssues.any((existing) => existing['status'] == 'open')) {
        throw StateError('已有同类未解决问题，请先处理原问题。');
      }
      if (relatedIssues.isNotEmpty &&
          relatedIssues.every((existing) => existing['status'] != 'open')) {
        if (relatedIssues.any((existing) => existing['status'] != 'resolved')) {
          throw StateError('同类问题已有已关闭记录，不能重复登记。');
        }
        final ref = issue['evidenceRef'] as String;
        final fresh = evidence[ref];
        final hasNewInvestigation = ref.startsWith('investigation:') &&
            fresh != null &&
            fresh['requestRevision'] == state.requestRevision &&
            fresh['teamRevision'] == state.teamRevision &&
            relatedIssues
                .any((existing) => fresh['issueId'] == existing['id']) &&
            relatedIssues.every((existing) =>
                ref != existing['evidenceRef'] &&
                ref != existing['resolutionRef']);
        if (!hasNewInvestigation) {
          throw StateError('该问题已解决；只有引用绑定到原问题的新实际调查结果，才能重新登记。');
        }
      }
      final normalized = {
        ...issue,
        'sourceId': member.id,
        'status': 'open',
        'evidenceRef':
            issue['evidenceRef'] == '' ? responseRef : issue['evidenceRef'],
        'resolution': '',
        'resolutionRef': '',
        'requestRevision': state.requestRevision
      };
      if (!_knownRef(normalized['evidenceRef'] as String, responseRef)) {
        throw StateError('问题证据不存在');
      }
      await _commit('member', member.id, {
        'issues': [...state.issues, normalized],
        'verificationRevision': state.verificationRevision + 1
      });
    }
    final resolutionWarning = turn.resolutions.isEmpty
        ? null
        : await _resolve(member, turn.resolutions, responseRef);
    switch (turn.action) {
      case 'investigate':
        await _investigate(member, turn, responseRef);
      case 'propose':
        await _proposal(member, turn.proposal!, responseRef, turn.issueId);
      case 'approve':
        if (state.verificationRevision != initialVerificationRevision) {
          lastProposalNoOpHint = '本轮记录或解决了问题，验证版本已更新；问题证据已保留，本轮认可未写入。'
              '请先处理这些问题，再按最新版本重新审阅。';
          break;
        }
        await _approve(member, turn.approval!, responseRef);
      case 'decide':
        final d = turn.decision!;
        if (d['kind'] == 'ruling') {
          await _coordinateRuling(member, d, responseRef);
          break;
        }
        await _decision(d['kind'] as String, d['targetId'] as String,
            d['reason'] as String, d['evidence'] as String,
            options: (d['options'] as List)
                .map((o) => Map<String, dynamic>.from(o as Map))
                .toList());
      default:
        break;
    }
    return resolutionWarning;
  }

  Map<String, dynamic> get _formalPlanSnapshot => {
        'taskId': task.id,
        'requestRevision': state.requestRevision,
        'teamRevision': state.teamRevision,
        'scope': state.scope,
        'plan': state.plan,
        'artifactContract': state.artifactContract,
        'workItems': [
          for (final item in state.workItems)
            {
              for (final key in ['id', 'ownerId', 'dependencies', 'kind'])
                if (item.containsKey(key)) key: item[key]
            }
        ],
        'acceptances': [
          for (final item in state.acceptances)
            {
              for (final key in ['id', 'method', 'requiredCapability'])
                key: item[key]
            }
        ],
        'usageAssignments': state.usageAssignments,
      };

  String get _formalPlanRef => _key('plan', jsonEncode(_formalPlanSnapshot));

  bool get _beforeProduction =>
      (state.currentIteration == null ||
          state.currentIteration!['requestRevision'] != state.requestRevision ||
          state.currentIteration!['teamRevision'] != state.teamRevision) &&
      state.plan.isNotEmpty &&
      state.phase == 'clarifying' &&
      state.workItems.every((item) => item['status'] == 'pending');

  bool _canReviewFormalPlanIssue(Map<String, dynamic> issue, String memberId) =>
      _beforeProduction &&
      runner.eventStore != null &&
      issue['kind'] != 'idea' &&
      !(issue['evidenceRef'] as String).startsWith('work-task-action:') &&
      issue['sourceId'] == memberId &&
      issue['target'] != 'code' &&
      !(issue['evidenceRef'] as String).startsWith('investigation:') &&
      (issue['requestRevision'] as int) < state.requestRevision;

  bool _knownRef(String ref, String currentResponse) =>
      _beforeProduction && runner.eventStore != null && ref == _formalPlanRef ||
      _folderAuthorization['status'] == 'granted' &&
          ref == _folderAuthorizationRef ||
      ref == currentResponse ||
      evidence.containsKey(ref) ||
      state.decisions.any((d) =>
          d['responseRef'] == ref &&
          {'answered', 'waived'}.contains(d['status'])) ||
      runner.database.messageBox.get(ref)?.groupId == task.groupId;

  String? _resolutionRejection(int index, Map<String, dynamic> resolution,
      String responseRef, String memberId) {
    final field = 'resolutions[$index]';
    final issueId = resolution['id'] as String;
    final issue = state.issues
        .where((i) => i['id'] == issueId && i['status'] == 'open')
        .firstOrNull;
    if (issue == null) {
      return '$issueId：$field.id 指向的问题不存在或已关闭；状态未变化。';
    }
    if (issue['kind'] == 'idea') {
      return '$issueId：$field.id 指向方案提案，不能用解决项关闭；状态未变化。';
    }
    final evidenceRef = resolution['evidenceRef'] as String;
    if (evidenceRef == responseRef || !_knownRef(evidenceRef, responseRef)) {
      return '$issueId：$field.evidenceRef 无法核验（解决依据不存在或不是本轮之前的证据）；状态未变化。';
    }
    if (evidenceRef.startsWith('folder-grant:')) {
      if (evidenceRef != _folderAuthorizationRef ||
          _folderAuthorization['status'] != 'granted' ||
          issue['kind'] != 'decision' ||
          !(issue['evidenceRef'] as String)
              .startsWith('work-task-action:${task.id}:folderAuthorization:')) {
        return '$issueId：$field.evidenceRef 只能证明本任务当前目录授权，不能关闭其它问题或替代执行证据。';
      }
      return null;
    }
    if (evidenceRef.startsWith('plan:')) {
      // A plan review closes only its author's pre-production concern; it never
      // supplies execution evidence or marks a candidate acceptance as passed.
      if (evidenceRef != _formalPlanRef ||
          !_canReviewFormalPlanIssue(issue, memberId)) {
        return '$issueId：$field.evidenceRef 只能由问题提出者引用修订后的当前正式方案关闭制作前问题；代码或调查问题仍需工具结果。';
      }
      return null;
    }
    final requiresToolEvidence = issue['target'] == 'code' ||
        issue['kind'] == 'defect' &&
            WorkRoleRouter.requestsSoftwareImplementation(task.userRequest) ||
        (issue['evidenceRef'] as String).startsWith('investigation:');
    final receipt = evidence[evidenceRef];
    if (receipt != null &&
        (receipt['issueId'] != issueId ||
            receipt['requestRevision'] != state.requestRevision ||
            receipt['teamRevision'] != state.teamRevision)) {
      return '$issueId：$field.evidenceRef 必须引用绑定到该问题及当前需求、团队版本的真实工具结果；状态未变化。';
    }
    if (requiresToolEvidence && receipt == null) {
      return '$issueId：$field.evidenceRef 必须引用绑定到该问题及当前需求、团队版本的真实工具结果；状态未变化。';
    }
    return null;
  }

  String _resolutionValidationError(
      List<Map<String, dynamic>> resolutions, String memberId) {
    final rejected = <String>[];
    for (var index = 0; index < resolutions.length; index++) {
      final error =
          _resolutionRejection(index, resolutions[index], '', memberId);
      if (error != null) rejected.add(error);
    }
    return rejected.isEmpty
        ? ''
        : '解决项未被采纳：${rejected.join('；')} '
            '仅可引用当前仍开放问题的 ID 和列出的、与该问题及当前版本匹配的真实证据。';
  }

  Future<String?> _resolve(AICharacter member,
      List<Map<String, dynamic>> resolutions, String responseRef) async {
    if (resolutions.any((item) =>
        (item['evidenceRef'] as String).startsWith('folder-grant:'))) {
      await _refreshFolderAuthorization();
    }
    final updated =
        state.issues.map((i) => Map<String, dynamic>.from(i)).toList();
    final rejected = <String>[];
    var changed = false;
    for (var index = 0; index < resolutions.length; index++) {
      final resolution = resolutions[index];
      final rejection =
          _resolutionRejection(index, resolution, responseRef, member.id);
      if (rejection != null) {
        rejected.add(rejection);
        continue;
      }
      final reference = resolution['evidenceRef'] as String;
      if (reference.startsWith('plan:')) {
        try {
          final snapshot = await runner.eventStore!
              .readDiscussionDetail(task.id, reference.substring(5));
          if (_key('plan', snapshot) != reference) {
            throw StateError('正式方案证据摘要不匹配');
          }
        } on Object {
          rejected.add('${resolution['id']}：正式方案证据无法完整读取或核验，未关闭问题。');
          continue;
        }
      }
      final issue = updated.firstWhere((i) => i['id'] == resolution['id']);
      issue.addAll({
        'status': 'resolved',
        'resolution': resolution['resolution'],
        'resolutionRef': resolution['evidenceRef']
      });
      changed = true;
    }
    if (changed) {
      await _commit('memberResolution', member.id, {
        'issues': updated,
        'verificationRevision': state.verificationRevision + 1
      });
    }
    if (rejected.isEmpty) return null;

    final detail = '解决项未被采纳：${rejected.join('；')} '
        '仅可引用 collaboration.issues 中当前仍为 open 的问题 ID 和真实证据。';
    await runner._recordDiagnostic(task, '成员协作增量未被采纳：$detail');
    return detail;
  }

  Future<void> _investigate(
      AICharacter member, WorkDiscussionV2Turn turn, String responseRef) async {
    final binding = WorkInvestigationBinding(
        taskId: task.id,
        memberId: member.id,
        issueId: turn.issueId,
        requestRevision: state.requestRevision,
        teamRevision: state.teamRevision);
    if (!binding.matches(task)) throw StateError('调查问题或版本无效');
    final investigate = runner.investigate;
    if (investigate == null) {
      await _decision('question', turn.issueId, '当前受控调查工具未接入，请补充环境。', '未运行工具。');
      return;
    }
    final result =
        await investigate(task, member, turn.tool!, binding, cancellation);
    if (cancellation.isCancelled || !binding.matches(task)) return;
    if (!result.result.succeeded ||
        result.result.data['rejected'] == true ||
        result.result.data['skipped'] == true) {
      await _decision('question', turn.issueId, result.result.message,
          '工具返回 ${result.result.status.name}，未得到可用于判断的证据。');
      return;
    }
    final ref = result.evidenceRef;
    if (ref.isEmpty) throw StateError('工具结果缺少真实凭据');
    evidence[ref] = {
      'memberId': member.id,
      'issueId': turn.issueId,
      'requestRevision': binding.requestRevision,
      'teamRevision': binding.teamRevision,
      'tool': turn.tool!.name.wireName,
      'arguments': turn.tool!.arguments,
      'result': result.result.data
    };
    await _attachDetail(
        {...evidence[ref]!, 'evidenceRef': ref}, responseRef, '调查来源与结果.json');
    if (evidence.length > WorkDiscussionRunner.maxMembers) {
      evidence.remove(evidence.keys.first);
    }
    await _commit('tool', member.id, {
      'issues': [
        for (final i in state.issues)
          i['id'] == turn.issueId ? {...i, 'evidenceRef': ref} : i
      ],
      'verificationRevision': state.verificationRevision + 1
    });
    await _rememberInvestigation(
        member, responseRef, ref, turn.tool!.name.wireName, turn.issueId);
    requestedSpeaker = member.id;
    if (result.stalled) {
      await _decision(
          'dispute', turn.issueId, '调查没有取得新的有效进展，请补充条件。', 'P2 进展保护已触发。');
    }
  }

  Future<void> _rememberInvestigation(AICharacter member, String messageId,
      String evidenceRef, String tool, String issueId) async {
    try {
      final message = runner.database.messageBox.get(messageId);
      if (message == null ||
          message.senderId != member.id ||
          cancellation.isCancelled) {
        return;
      }
      message.workMemoryEvidence = {
        'taskId': task.id,
        'scopeId': state.projectScopeId,
        'evidenceRef': evidenceRef,
        'tool': tool,
        'issueId': issueId,
        'requestRevision': state.requestRevision,
      };
      await runner.database.updateMessage(message);
      await ObservationEntry(db: runner.database).recordWorkExperience(message);
    } on Object {
      // A memory write cannot turn a successful investigation into failure.
    }
  }

  Future<void> _proposal(AICharacter member, Map<String, dynamic> proposal,
      String responseRef, String issueId) async {
    if (member.id != state.coordinatorId) throw StateError('仅协调成员收敛方案');
    _validateProposal(proposal);
    _validateContract(proposal);
    lastProposalNoOpHint = '';
    final idea = state.issues
        .where((i) =>
            i['id'] == issueId && i['kind'] == 'idea' && i['status'] == 'open')
        .firstOrNull;
    if (idea == null && _proposalUnchanged(proposal)) {
      // 与当前状态一致的提案不写任何增量，但仍要留下可操作提示，否则成员只会重复重提。
      lastProposalNoOpHint = _proposalStallHint();
      return;
    }
    final acceptanceChanged = state.plan.isNotEmpty &&
            state.acceptances.isNotEmpty &&
            jsonEncode([
                  for (final a in state.acceptances)
                    {
                      'id': a['id'],
                      'method': a['method'],
                      'requiredCapability': a['requiredCapability']
                    }
                ]) !=
                jsonEncode(proposal['acceptances']) ||
        state.plan.isNotEmpty &&
            jsonEncode(state.artifactContract['verificationCommands']) !=
                jsonEncode((proposal['artifactContract']
                    as Map)['verificationCommands']);
    if (proposal['scope'] != state.scope || idea != null || acceptanceChanged) {
      if (idea == null) {
        throw StateError('新增范围或验收修改必须先登记一条 open 的 kind=idea 问题来承载它，'
            '并在 proposal.issue_id 指向该问题，再由全体成员逐人确认；'
            '只登记 defect 或不填 issue_id 不会被采纳');
      }
      await _recordScopeProposal(proposal, responseRef, idea);
    } else {
      await _detail(proposal, responseRef,
          requestRevision: state.requestRevision + 1,
          verificationRevision: state.verificationRevision + 1);
      await _installProposal(proposal);
    }
  }

  bool _scopeConflicts(Map<String, dynamic> proposal) {
    final scope = proposal['scope'] as String;
    if (!scope.startsWith(state.scope)) return true;
    final extra = scope
        .substring(state.scope.length)
        .split(RegExp(r'[，,。；;\n]'))
        .where((clause) =>
            !RegExp(r'禁止|不得|不要|不允许|never|must not|do not', caseSensitive: false)
                .hasMatch(clause))
        .join(' ');
    final prohibited = RegExp(
            r'(?:禁止|不得|不要|不允许|never|must not|do not)\s*([^，,。；;\n]+)',
            caseSensitive: false)
        .allMatches(task.userRequest);
    return prohibited.any((m) {
      final subject = m
          .group(1)!
          .trim()
          .replaceFirst(
              RegExp(
                  r'^(?:先|直接)?(?:添加|增加|生成|实现|制作|写|做|使用|执行|进行|开发|安装|运行|add |create |use |run )',
                  caseSensitive: false),
              '')
          .trim();
      return subject.isNotEmpty && extra.contains(subject);
    });
  }

  Future<void> _recordScopeProposal(Map<String, dynamic> proposal,
      String responseRef, Map<String, dynamic> issue) async {
    // Conservatively ask the user around a prohibition; never let a model
    // reinterpret it or expand the actual tool permission set.
    if (_scopeConflicts(proposal)) {
      await _detail(proposal, responseRef);
      await _decision('dispute', issue['id'] as String, '提案涉及用户原范围或明确禁止事项，请裁决。',
          issue['problem'] as String,
          options: [
            {
              'id': 'reject-idea',
              'label': '不采用新范围，保留原要求',
              'impact': '禁止事项与工具授权保持原约束。'
            },
            {
              'id': 'revise-idea',
              'label': '改成不冲突的提案再讨论',
              'impact': '不采纳当前提案，重新逐人确认。'
            }
          ]);
      return;
    }
    final previousRef = issue['resolutionRef'];
    if (issue['requestRevision'] == state.requestRevision &&
        previousRef is String &&
        previousRef.startsWith('proposal:')) {
      final store = runner.eventStore;
      if (store == null) throw StateError('已保存提案详情不可用');
      try {
        final previous = _proposalFromDetail(
            previousRef,
            await store.readDiscussionDetail(
                task.id, previousRef.substring(9)));
        if (jsonEncode(previous) == jsonEncode(proposal)) return;
      } on Object catch (error) {
        await _decision(
          'question',
          issue['id'] as String,
          '当前已保存提案无法完整核验，已暂停重复提交。',
          sanitizeWorkTaskError(error),
        );
        return;
      }
    }
    final detail = _proposalDetailSnapshot(
      proposal,
      verificationRevision: state.verificationRevision + 1,
      pendingIssueId: issue['id'] as String,
    );
    final ref = _key('proposal', jsonEncode(detail));
    await _attachDetail(detail, responseRef, '方案与验收详情.json');
    await _commit('coordinator', state.coordinatorId, {
      'issues': [
        for (final i in state.issues)
          i['id'] == issue['id']
              ? {
                  ...i,
                  'resolution': 'scope-proposal',
                  'resolutionRef': ref,
                  'requestRevision': state.requestRevision
                }
              : i
      ],
      'verificationRevision': state.verificationRevision + 1
    });
    final activeGroup = group;
    if (activeGroup != null && _notifiedPendingProposalRefs.add(ref)) {
      await runner._publish(
        task,
        activeGroup,
        '🟡【提案待全员认可】完整提案已保存并供成员审阅；当前正式方案和验收仍未改变，全部当前成员明确认可后才会采纳。',
        cancellation: cancellation,
      );
    }
  }

  void _validateContract(Map<String, dynamic> proposal) {
    final rawContract = proposal['artifactContract'];
    if (rawContract is! Map) {
      throw StateError('artifactContract 缺失或无效');
    }
    final contract = Map<String, dynamic>.from(rawContract);
    const fields = {
      'type',
      'format',
      'location',
      'revisionTarget',
      'files',
      'verificationCommands',
      'nativeBundle'
    };
    final unexpected = contract.keys.where((key) => !fields.contains(key));
    if (unexpected.isNotEmpty) {
      final safeNames = unexpected
          .take(8)
          .map((key) => RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(key)
              ? key
              : 'unknown')
          .toSet()
          .join(',');
      throw StateError('artifactContract.fields($safeNames)');
    }
    if (!WorkDiscussionV2Turn.isValidArtifactContractFields(contract) ||
        !WorkDiscussionV2Turn.isValidArtifactFiles(contract) ||
        !WorkDiscussionV2Turn.isValidVerificationCommands(contract)) {
      throw StateError('artifactContract 字段或内容不符合 v2 协议');
    }
    final requiredOutput =
        WorkTaskRequirementsConfirmation.requiredNestedHtmlOutputPath(task);
    if (requiredOutput != null) {
      final location = (contract['location'] as String).replaceAll('\\', '/');
      final desktopRoot = const WorkModeDirectoryService()
          .requestedDesktopPath(WorkDiscussionState.currentRequestScope(task));
      final normalizedDesktopRoot = desktopRoot?.replaceAll('\\', '/');
      final requestedPath = p.isAbsolute(requiredOutput)
          ? requiredOutput
          : p.join(normalizedDesktopRoot ?? '', requiredOutput);
      final proposedPaths = (contract['files'] as List? ?? const [])
          .whereType<String>()
          .map((file) {
        final normalized = file.replaceAll('\\', '/');
        final base = location.toLowerCase() == 'desktop'
            ? normalizedDesktopRoot ?? ''
            : location;
        // Keep UNC roots until the shared Windows-aware key normalizes them.
        return p.isAbsolute(normalized) ? normalized : p.join(base, normalized);
      });
      if (!proposedPaths.any((path) =>
          workArtifactPathKey(path) == workArtifactPathKey(requestedPath))) {
        throw StateError(
          'artifactContract.files 必须保留需求确认卡指定的交付路径 $requestedPath；请保持文件名和目录后重新提交。',
        );
      }
    }
    for (final key in state.artifactContract.keys) {
      final original = state.artifactContract[key];
      if (original is String &&
          original.isNotEmpty &&
          original != 'unspecified' &&
          original != 'generic' &&
          // 只有"用户亲口说过的值"不可覆盖；平台兜底推导出来的值允许协调成员
          // 提案改写（改写仍走既有提案路径，需求版本一并递增）。
          _isUserStatedContractValue(key, original) &&
          !_sameContractValue(key, original, contract[key])) {
        throw StateError('用户产物合同不可覆盖（$key），请保留当前合同字段原值');
      }
    }
    if (state.artifactContract['type'] == 'document' &&
        contract['type'] != 'document') {
      throw StateError('文档任务不能转开发');
    }
  }

  /// 合同字段的等价判定。
  ///
  /// `type` 走统一词表：模型把 v1 的 `source` 抄成 v2 的 `software`（或反过来）
  /// 说的是同一个交付类型，不该被当成改动用户合同。
  bool _sameContractValue(String key, String pinned, Object? proposed) {
    if (proposed == pinned) return true;
    if (proposed is! String) return false;
    if (key == 'location' || key == 'revisionTarget') {
      return workArtifactPathKey(pinned) == workArtifactPathKey(proposed);
    }
    if (key != 'type') return false;
    return WorkRoleRouter.canonicalArtifactType(proposed) ==
        WorkRoleRouter.canonicalArtifactType(pinned);
  }

  /// 这个合同值是否出自用户原话本身。
  ///
  /// 只认"作为该字段自己的表达"出现：`location` / `revisionTarget` 必须是独立
  /// 路径词元，`format` 必须是独立格式词或以该扩展名结尾的文件名。平台兜底产生、
  /// 用户从没亲口说过的值（例如路径片段里的 Desktop 被当成桌面）判为推导值，
  /// 允许协调成员提案改写。
  ///
  /// 判据作用在已落盘的 `state.scope` 上——scope 就是冻结的用户原话，所以
  /// "来源"不必新增持久化字段。
  bool _isUserStatedContractValue(String key, String value) {
    final scope = state.scope;
    if (scope.trim().isEmpty || value.trim().isEmpty) return true;
    switch (key) {
      case 'location':
        return value.toLowerCase() == 'desktop'
            ? statesDesktopLocation(scope)
            : statesToken(
                scope.replaceAll('\\', '/'), value.replaceAll('\\', '/'));
      case 'revisionTarget':
        return statesToken(
            scope.replaceAll('\\', '/'), value.replaceAll('\\', '/'));
      case 'format':
        // 与播种同源：直接问那个推导函数"用户原话指定了什么格式"。只认逐字词元、
        // 别名族与扩展名会漏掉路由自己认的中文格式词（`网页`/`网站` → html），
        // 于是用户亲口点名的格式被判成推导值、允许成员改掉——而 `formatAliases`
        // 里没有 CJK 项，不能靠它补。
        if (WorkRoleRouter.deliverableContractForRequest(scope).format ==
            value) {
          return true;
        }
        return _valueSpellings(value, asFormat: true).any((spelling) =>
            statesToken(scope, spelling) || statesExtension(scope, spelling));
      default:
        // `type` 等字段仍恒定视为用户声明：交付物的形态由用户原话决定，
        // 且软件闭环检查键在 `type == 'software'` 上，不放模型改。
        return true;
    }
  }

  /// 用户在自己的补充要求里点名改写的合同字段：`{字段: 用户点名的新值}`。
  ///
  /// 只认用户原话，而且必须是一句**变更**：旧值后面紧接变更动词，随后才是新值。
  /// 名称共现本身不是授权——"保持 game.html 文件名，不要改成 game2.html" 里两个
  /// 名称也都在，而它恰恰是用户禁止改名。提案里的新值还必须与用户点名的那一个完全
  /// 一致，模型不能借"用户授权"之名改合同——这条判据是 `_validateContract` 拒绝
  /// 模型擅改之外的唯一例外。
  Map<String, String> _userRewrittenContractFields(
      Map<String, dynamic> proposal) {
    final proposed = proposal['artifactContract'];
    if (proposed is! Map) return const {};
    final supplement = WorkDiscussionState.latestRequestScope(task);
    if (supplement.trim().isEmpty) return const {};
    final rewritten = <String, String>{};
    for (final key in const ['type', 'format', 'location']) {
      final pinned = state.artifactContract[key];
      final next = proposed[key];
      if (pinned is! String || next is! String) continue;
      if (pinned.isEmpty || pinned == 'unspecified' || pinned == 'generic') {
        continue;
      }
      if (_sameContractValue(key, pinned, next)) continue;
      if (!_statesChange(supplement,
          from: pinned, to: next, asFormat: key == 'format')) {
        continue;
      }
      rewritten[key] = next;
    }
    return rewritten;
  }

  /// 用户是否在 [text] 里**下达**了把 [from] 改成 [to] 的指令。
  ///
  /// 判据是"旧值 → 变更连接 → 新值"的相邻结构，不是两个名称同时出现：变更连接
  /// （见 [_changeLinkSource]）只允许夹着"的文件名"这类结构性字词，所以
  /// "game.html 文件名，不要改成 game2.html" 里的逗号直接断开匹配。三处否定都必须
  /// 弄清作用对象才算拦得住：连接自身带否定（"不要改成 X"）、旧值**紧邻**之前是
  /// "保持/不要"（见 [_prohibitionAdjacent]）、目标之后紧跟否定——每一处都只处理
  /// 与这次变更相邻的字词，不是整句扫一遍。最后，这次变更必须是指令而不是被讨论的
  /// 提议（见 [_evaluationFrame]）。[to] 还必须逐字出现在这句指令里：模型提案里的
  /// 新值只有被用户原话点名才算数，不能反过来由提案推定用户授权。
  bool _statesChange(String text,
          {required String from, required String to, required bool asFormat}) =>
      statesWorkContractChange(text, from: from, to: to, asFormat: asFormat);

  List<String> _valueSpellings(String value, {required bool asFormat}) =>
      workContractValueSpellings(value, asFormat: asFormat);

  /// 由**用户身份**落盘用户明确改写的产物目标。
  ///
  /// 模型这次的提案仍然作废——它是照着旧合同写的；合同一改，需求版本随之递增，
  /// 旧工作项、验收与认可全部失效，必须由协调成员在新版本下重新形成方案。
  Future<bool> _adoptUserRewrittenContract(
      Map<String, dynamic> proposal) async {
    final rewritten = _userRewrittenContractFields(proposal);
    if (rewritten.isEmpty) return false;
    await _commit('user', 'user', {
      'artifactContract': <String, dynamic>{
        ...state.artifactContract,
        ...rewritten
      },
      'requestRevision': state.requestRevision + 1,
    });
    return true;
  }

  Future<void> _installProposal(Map<String, dynamic> proposal,
      {List<Map<String, dynamic>>? issues}) async {
    final request = state.requestRevision + 1;
    final verification = state.verificationRevision + 1;
    final userReview = _preservesUserReview(proposal);
    await _commit('coordinator', state.coordinatorId, {
      'scope': proposal['scope'],
      'plan': proposal['plan'],
      'artifactContract': proposal['artifactContract'],
      'workItems': _proposalWorkItems(proposal, userReview, request),
      'acceptances':
          _proposalAcceptances(proposal, userReview, request, verification),
      if (state.isAutonomous)
        'usageAssignments': [
          for (final a in proposal['usageAssignments'] as List)
            {...a as Map, 'requestRevision': request}
        ],
      if (issues != null) 'issues': issues,
      'requestRevision': request,
      'verificationRevision': verification,
      'phase': 'clarifying'
    });
  }

  List<Map<String, dynamic>> _proposalWorkItems(
          Map<String, dynamic> proposal, bool userReview, int request) =>
      (proposal['workItems'] as List)
          .map((i) => {
                ...Map<String, dynamic>.from(i as Map),
                'status': userReview &&
                        state.workItems.any((old) =>
                            old['id'] == i['id'] &&
                            old['ownerId'] == i['ownerId'] &&
                            old['status'] == 'done')
                    ? 'done'
                    : 'pending',
                'requestRevision': request
              })
          .toList();

  List<Map<String, dynamic>> _proposalAcceptances(Map<String, dynamic> proposal,
          bool userReview, int request, int verification) =>
      (proposal['acceptances'] as List)
          .map((i) => {
                ...Map<String, dynamic>.from(i as Map),
                'status': userReview
                    ? (state.acceptances
                            .where((old) => old['id'] == i['id'])
                            .firstOrNull?['status'] ??
                        'pending')
                    : 'pending',
                'evidenceRef': userReview
                    ? (state.acceptances
                            .where((old) => old['id'] == i['id'])
                            .firstOrNull?['evidenceRef'] ??
                        '')
                    : '',
                'requestRevision': request,
                'verificationRevision': verification
              })
          .toList();

  bool _preservesUserReview(Map<String, dynamic> proposal) {
    return state.decisions.any((d) =>
            {'answered', 'waived'}.contains(d['status']) &&
            {'manual', 'waiver'}.contains(d['answerKind'])) &&
        jsonEncode(proposal['artifactContract']) ==
            jsonEncode(state.artifactContract) &&
        !state.acceptances.any((a) => a['status'] == 'failed') &&
        state.acceptances.any((a) =>
            {'manual', 'waived'}.contains(a['status']) &&
            a['requestRevision'] == state.requestRevision) &&
        jsonEncode([
              for (final a in proposal['acceptances'] as List)
                {
                  for (final key in ['id', 'method', 'requiredCapability'])
                    key: a[key]
                }
            ]) ==
            jsonEncode([
              for (final a in state.acceptances)
                {
                  for (final key in ['id', 'method', 'requiredCapability'])
                    key: a[key]
                }
            ]) &&
        jsonEncode([
              for (final i in proposal['workItems'] as List)
                {
                  for (final key in ['id', 'ownerId', 'kind', 'dependencies'])
                    key: i[key]
                }
            ]) ==
            jsonEncode([
              for (final i in state.workItems)
                {
                  for (final key in ['id', 'ownerId', 'kind', 'dependencies'])
                    key: i[key]
                }
            ]);
  }

  void _validateProposal(Map<String, dynamic> proposal) {
    final items = (proposal['workItems'] as List).cast<Map>();
    if (items.isEmpty || (proposal['acceptances'] as List).isEmpty) {
      throw StateError('方案缺少可执行工作项或验收');
    }
    if (state.isAutonomous) {
      final makers = items.map((i) => i['ownerId']).toSet();
      final executor =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .explicitlyPinnedExecutorId;
      if (makers.length != 1 || executor != null && makers.single != executor) {
        throw StateError('本轮制作必须由唯一执行者负责，并保持用户指定的执行者。');
      }
      final maker = makers.single as String;
      final responsibility =
          state.team.singleWhere((m) => m['memberId'] == maker);
      final role = responsibility['role'] as String;
      final character = runner.database.aiCharacterBox.get(maker);
      if (character == null ||
          !WorkRoleRouter.qualifiesForResponsibility(
              character, role, const []) ||
          state.artifactContract['type'] == 'software' &&
              !{'development', 'developer', 'frontend'}.contains(role)) {
        throw StateError('制作执行者缺少当前任务的真实实现职责，普通试用资格不能冒充开发资格。');
      }
      final assignments = proposal['usageAssignments'];
      if (assignments is! List) throw StateError('自主方案缺少全员使用场景');
      final raw = state.toJson()
        ..['requestRevision'] = state.requestRevision + 1
        ..['usageAssignments'] = [
          for (final a in assignments)
            {...a as Map, 'requestRevision': state.requestRevision + 1}
        ]
        ..['acceptances'] = _proposalAcceptances(proposal, false,
            state.requestRevision + 1, state.verificationRevision);
      if (WorkCollaborationState.tryParse(raw)?.usagePlanReady != true) {
        throw StateError('使用计划必须覆盖全部成员、不同场景和全部必达验收');
      }
    }
    final ids = items.map((i) => i['id']).toSet();
    if (ids.length != items.length ||
        items.any((i) =>
            !state.activeMembers.contains(i['ownerId']) ||
            i['dependencies'] is! List ||
            (i['dependencies'] as List)
                .any((d) => !ids.contains(d) || d == i['id']))) {
      throw StateError('工作项责任或依赖无效');
    }
    final resolved = <Object?>{};
    for (var pass = 0; pass < items.length; pass++) {
      resolved.addAll(items
          .where((i) => (i['dependencies'] as List).every(resolved.contains))
          .map((i) => i['id']));
    }
    if (resolved.length != items.length) {
      throw StateError('工作项依赖不能成环');
    }
  }

  bool _proposalUnchanged(Map<String, dynamic> proposal) {
    if (state.acceptances.any((a) => a['status'] == 'failed')) return false;
    if (state.workItems
            .any((i) => i['requestRevision'] != state.requestRevision) ||
        state.acceptances
            .any((i) => i['requestRevision'] != state.requestRevision)) {
      return false;
    }
    bool same(Object? a, Object? b) {
      if (a is Map && b is Map) {
        return a.length == b.length &&
            a.keys.every((k) => b.containsKey(k) && same(a[k], b[k]));
      }
      if (a is List && b is List) {
        return a.length == b.length &&
            List.generate(a.length, (i) => same(a[i], b[i])).every((v) => v);
      }
      return a == b;
    }

    return same(proposal, {
      'scope': state.scope,
      'plan': state.plan,
      'artifactContract': state.artifactContract,
      if (state.isAutonomous)
        'usageAssignments': [
          for (final a in state.usageAssignments)
            {...a}..remove('requestRevision')
        ],
      'workItems': [
        for (final i in state.workItems)
          {
            'id': i['id'],
            'ownerId': i['ownerId'],
            'dependencies': i['dependencies']
          }
      ],
      'acceptances': [
        for (final i in state.acceptances)
          {
            'id': i['id'],
            'method': i['method'],
            'requiredCapability': i['requiredCapability']
          }
      ]
    });
  }

  /// 未变化的提案被静默丢弃时，给协调成员一份可操作的缺口清单。
  ///
  /// 复制 [WorkCollaborationState.planReady] 的判据会随门禁漂移，这里只挑出最常卡住
  /// 成员的几项（交付合同三元组、验收方式、未决问题），措辞保持"缺什么补什么"。
  String _proposalStallHint() {
    final blockers = _planReadyBlockers();
    if (blockers.isEmpty) {
      return '你提交的提案与当前讨论状态完全一致，没有带来任何新进展；'
          '请确认是否已可进入制作阶段，或直接处理未决事项。';
    }
    return '你提交的提案与当前讨论状态完全一致，没有带来任何新进展。'
        '进入制作还缺少：${blockers.join('、')}。请在提案中补齐后再提交。';
  }

  /// 方案已全员认可、却因合同字段不齐而反复重发同一份认可时，回灌给成员的缺口清单。
  ///
  /// 与 [_proposalStallHint] 共享 [_planReadyBlockers]，但措辞指向"补齐合同字段"：
  /// 此时范围与验收已经确认，缺的是进入制作的交付合同三元组，且这些字段（如
  /// location）本就允许直接改写，无需登记 idea 问题。没有这条回馈，重复的认可会被
  /// [WorkCollaborationState] 静默吞掉，成员只能一遍遍重发同一句话。
  String _approvalStallHint() {
    final blockers = _planReadyBlockers();
    if (blockers.isEmpty) {
      return '本轮认可与已有记录完全相同，没有带来新的进展；请确认是否还有未决事项需要处理。';
    }
    return '本轮认可与已有记录完全相同，没有带来新的进展。方案认可已齐备，'
        '但进入制作还缺少：${blockers.join('、')}。'
        '请协调成员用一次 propose 补齐这些字段（为空或 unspecified 的合同字段可直接改写，'
        '不涉及范围与验收变更，无需登记 idea 问题），随后即可进入制作。';
  }

  /// 进入制作前仍缺失的门禁项，供各类"没有进展"提示共用。
  List<String> _planReadyBlockers() {
    final blockers = <String>[];
    for (final key in const ['type', 'format', 'location']) {
      final value = state.artifactContract[key]?.toString().trim() ?? '';
      if (value.isEmpty || value == 'unspecified') {
        blockers.add('artifactContract.$key');
      }
    }
    if (state.acceptances.isEmpty) {
      blockers.add('acceptances');
    } else if (state.acceptances.any((a) =>
        a['method'].toString().trim().isEmpty ||
        a['requiredCapability'].toString().trim().isEmpty)) {
      blockers.add('acceptances 的 method/requiredCapability');
    }
    if (!state.issuesResolved) blockers.add('未解决的问题');
    return blockers;
  }

  Map<String, dynamic> _proposalDetailSnapshot(
    Map<String, dynamic> proposal, {
    int? requestRevision,
    int? verificationRevision,
    String? pendingIssueId,
  }) =>
      {
        'proposal': proposal,
        'issues': [
          for (final issue in state.issues)
            {
              ...issue,
              if (issue['id'] == pendingIssueId)
                'resolution': '等待全员审阅；尚未改变正式方案。'
            }
        ],
        'requestRevision': requestRevision ?? state.requestRevision,
        'teamRevision': state.teamRevision,
        'verificationRevision':
            verificationRevision ?? state.verificationRevision,
      };

  Future<void> _detail(
    Map<String, dynamic> proposal,
    String responseRef, {
    int? requestRevision,
    int? verificationRevision,
  }) =>
      _attachDetail(
        _proposalDetailSnapshot(proposal,
            requestRevision: requestRevision,
            verificationRevision: verificationRevision),
        responseRef,
        '方案与验收详情.json',
      );
}
