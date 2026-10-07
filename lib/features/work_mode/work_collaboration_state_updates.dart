part of 'work_collaboration_state.dart';

extension _WorkCollaborationUpdates on WorkCollaborationState {
  WorkCollaborationState _apply(WorkCollaborationUpdate update) {
    if (update.taskId != taskId || update.conversationId != conversationId) {
      throw StateError('协作增量属于其他任务或群组。');
    }
    if (appliedEventIds.contains(update.eventId)) return this;
    _validateRevision(update);
    _validateBaselineChanges(update.next);
    _validateOrigin(update);
    return update.next;
  }

  void _validateRevision(WorkCollaborationUpdate update) {
    final next = update.next;
    if (!WorkCollaborationState._id(update.eventId) ||
        !WorkCollaborationState._id(update.sourceId) ||
        update.taskId != taskId ||
        update.conversationId != conversationId ||
        update.expectedRevision != revision ||
        !next.isValid ||
        next.taskId != taskId ||
        next.conversationId != conversationId ||
        (next.projectScopeId != projectScopeId &&
            update.sourceRole != 'projectBinding') ||
        next.revision != revision + 1 ||
        next.requestRevision < requestRevision ||
        next.requestRevision > requestRevision + 1 ||
        next.teamRevision < teamRevision ||
        next.teamRevision > teamRevision + 1 ||
        next.verificationRevision < verificationRevision ||
        next.verificationRevision > verificationRevision + 1 ||
        jsonEncode(next.appliedEventIds) !=
            jsonEncode([...appliedEventIds, update.eventId]
                .skip(appliedEventIds.length == 64 ? 1 : 0)
                .toList())) {
      throw StateError('协作增量过期、越界或归属不匹配。');
    }
  }

  void _validateBaselineChanges(WorkCollaborationState next) {
    if ((_changed(scope, next.scope) ||
            _changed([
              for (final a in acceptances)
                {
                  'id': a['id'],
                  'method': a['method'],
                  'requiredCapability': a['requiredCapability']
                }
            ], [
              for (final a in next.acceptances)
                {
                  'id': a['id'],
                  'method': a['method'],
                  'requiredCapability': a['requiredCapability']
                }
            ]) ||
            _changed(plan, next.plan) ||
            _changed(artifactContract, next.artifactContract) ||
            _changed(
                workItems
                    .map((i) => {...i}
                      ..remove('status')
                      ..remove('resultRef'))
                    .toList(),
                next.workItems
                    .map((i) => {...i}
                      ..remove('status')
                      ..remove('resultRef'))
                    .toList()) ||
            _decisionContentChanged(next)) &&
        next.requestRevision == requestRevision) {
      throw StateError('方案、工作项或用户决策变化必须递增需求版本。');
    }
    if (_changed(team, next.team) && next.teamRevision == teamRevision) {
      throw StateError('团队变化必须递增团队版本。');
    }
    if ((_changed(issues, next.issues) ||
            _changed(acceptances, next.acceptances) ||
            _changed(iterations, next.iterations)) &&
        next.verificationRevision == verificationRevision) {
      throw StateError('问题、验收或候选变化必须递增验证版本。');
    }
  }

  bool _changed(Object? left, Object? right) =>
      jsonEncode(left) != jsonEncode(right);

  bool _decisionContentChanged(WorkCollaborationState next) {
    List<Map<String, dynamic>> content(List<Map<String, dynamic>> source) =>
        source.map((item) => {...item}..remove('promptedReminder')).toList();
    return _changed(content(decisions), content(next.decisions));
  }

  bool _sameExcept(WorkCollaborationState next, Set<String> allowed) {
    final before = toJson();
    final after = next.toJson();
    for (final key in {...allowed, 'revision', 'appliedEventIds'}) {
      before.remove(key);
      after.remove(key);
    }
    return !_changed(before, after);
  }

  void _validateOrigin(WorkCollaborationUpdate update) {
    switch (update.sourceRole) {
      case 'projectBinding':
        return _validateProjectBinding(update.next, update);
      case 'member':
        return _validateHumanMember(update.next, update);
      case 'humanMember':
        return _validateHumanMember(update.next, update);
      case 'memberResolution':
        return _validateMemberResolution(update.next, update);
      case 'router':
        return _validateRouter(update.next, update);
      case 'coordinator':
        return _validateCoordinator(update.next, update);
      case 'user':
        return _validateUser(update.next, update);
      case 'system':
        return _validateSystem(update.next, update);
      case 'review':
        return _validateReview(update.next, update);
      case 'workItem':
        return _validateWorkItem(update.next, update);
      case 'tool':
        return _validateTool(update.next, update);
      default:
        throw StateError('未知的协作增量来源角色。');
    }
  }

  void _validateProjectBinding(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    if (projectScopeId == 'portable-unbound') {
      final patch = portableProjectBindingPatch(update.sourceId);
      final actual = next.toJson();
      if (!_sameExcept(next, patch.keys.toSet()) ||
          patch.entries
              .any((entry) => _changed(entry.value, actual[entry.key]))) {
        throw StateError('导入绑定必须重新确认方案、角色、工作项、决策与验收。');
      }
      return;
    }
    if (plan.isNotEmpty ||
        issues.isNotEmpty ||
        workItems.isNotEmpty ||
        next.projectScopeId != update.sourceId ||
        !_sameExcept(next, {'projectScopeId'})) {
      throw StateError('已有项目事实不能重绑定为另一个项目。');
    }
  }

  void _validateHumanMember(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    if (!activeMembers.contains(update.sourceId)) {
      throw StateError('来源成员不在当前有效团队。');
    }
    // 台账只追加，但解析器会归档被同键新签字取代的旧记录（见
    // WorkCollaborationState.compactedApprovals），所以追加后的列表必须正好是
    // “原列表 + 本条新签字”归档后的形状：要么多一条，要么顶掉同键的那一条。
    final appended = next.approvals.isEmpty
        ? const <Map<String, dynamic>>[]
        : WorkCollaborationState.compactedApprovals(
            <Map<String, dynamic>>[...approvals, next.approvals.last]);
    final approvalAdded = next.approvals.isNotEmpty &&
        jsonEncode(appended) == jsonEncode(next.approvals) &&
        next.approvals.last['eventId'] == update.eventId &&
        next.approvals.last['memberId'] == update.sourceId &&
        next.approvals.last['source'] ==
            (update.sourceRole == 'member' ? 'memberModel' : 'human');
    final issueAdded = next.issues.length == issues.length + 1 &&
        jsonEncode(next.issues.take(issues.length).toList()) ==
            jsonEncode(issues) &&
        next.issues.last['sourceId'] == update.sourceId &&
        next.issues.last['status'] == 'open' &&
        next.verificationRevision == verificationRevision + 1;
    if (approvalAdded) {
      if (!_sameExcept(next, {'approvals'})) {
        throw StateError('成员认可不能改写其他状态。');
      }
    } else if (issueAdded) {
      if (!_sameExcept(next, {'issues', 'verificationRevision'})) {
        throw StateError('成员提问不能改写其他状态。');
      }
    } else {
      throw StateError('成员只能提交自己的认可或新问题。');
    }
  }

  void _validateMemberResolution(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    if (!activeMembers.contains(update.sourceId) ||
        next.verificationRevision != verificationRevision + 1 ||
        next.issues.length != issues.length ||
        !_sameExcept(next, {'issues', 'verificationRevision'})) {
      throw StateError('成员答复只能更新已有问题的有据处置。');
    }
    for (var i = 0; i < issues.length; i++) {
      final old = Map<String, dynamic>.from(issues[i]);
      final resolved = Map<String, dynamic>.from(next.issues[i]);
      for (final key in {'status', 'resolution', 'resolutionRef'}) {
        old.remove(key);
        resolved.remove(key);
      }
      if (_changed(old, resolved) ||
          next.issues[i]['kind'] == 'idea' &&
              _changed(issues[i], next.issues[i])) {
        throw StateError('答复不能篡改问题或采纳范围提案。');
      }
    }
  }

  void _validateRouter(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    // Only the coordinator's internal discussion sink accepts this source.
    if (update.sourceId != 'router' ||
        _changed(approvals, next.approvals) ||
        !_sameExcept(next, {
          'team',
          'coordinatorId',
          'teamRevision',
          'phase',
          'decisions',
          'requestRevision'
        })) {
      throw StateError('角色路由只能核验团队与记录缺人决策。');
    }
  }

  void _validateCoordinator(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    final decisionAdded = next.decisions.length == decisions.length + 1 &&
        jsonEncode(next.decisions.take(decisions.length).toList()) ==
            jsonEncode(decisions) &&
        next.decisions.last['status'] == 'pending' &&
        next.decisions.last['answer'] == '' &&
        next.decisions.last['responseRef'] == '';
    if (update.sourceId != coordinatorId ||
        !teamQualified ||
        (_changed(decisions, next.decisions) && !decisionAdded) ||
        !_sameExcept(next, {
          'scope',
          'plan',
          'phase',
          'artifactContract',
          'workItems',
          'issues',
          'acceptances',
          'pendingInputIds',
          'decisions',
          'requestRevision',
          'verificationRevision'
        })) {
      throw StateError('协调者不能代签或替用户裁决。');
    }
  }

  void _validateUser(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    final changedAcceptances = _changed(acceptances, next.acceptances);
    final changedIssues = _changed(issues, next.issues);
    if (changedAcceptances) _validateUserAcceptance(next);
    if (changedIssues) _validateUserIssue(next);
    // 产物合同是**用户自己的**要求：补充要求里点名改写输出目标时由用户身份落盘
    // （见 `_V2DiscussionActions._adoptUserRewrittenContract`），随需求版本一起
    // 递增，旧认可自然失效。成员认可与团队资格仍然不能由用户改写。
    if (update.sourceId != 'user' ||
        !_sameExcept(next, {
          'team',
          'teamRevision',
          'decisions',
          'scope',
          'requestRevision',
          'pendingInputIds',
          'acceptances',
          'issues',
          'verificationRevision',
          'artifactContract'
        })) {
      throw StateError('用户决策不能改写成员认可。');
    }
  }

  void _validateSystem(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    if (update.sourceId != 'system' ||
        _decisionContentChanged(next) ||
        !_sameExcept(next, {'decisions'})) {
      throw StateError('系统只能记录决策提醒。');
    }
  }

  void _validateReview(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    if (!activeMembers.contains(update.sourceId) ||
        next.verificationRevision != verificationRevision + 1 ||
        !_sameExcept(next, {
          'acceptances',
          'iterations',
          'issues',
          'verificationRevision',
          'phase'
        }) ||
        next.issues.length < issues.length ||
        _changed(issues, next.issues.take(issues.length).toList()) ||
        next.issues.skip(issues.length).any((i) =>
            i['sourceId'] != update.sourceId ||
            i['kind'] != 'defect' ||
            i['status'] != 'open')) {
      throw StateError('审查结果只能记录当前成员的证据和缺陷。');
    }
  }

  void _validateWorkItem(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    if (!activeMembers.contains(update.sourceId) ||
        !_sameExcept(next, {'workItems', 'phase'}) ||
        next.workItems.length != workItems.length) {
      throw StateError('工作项结果不能改写方案、验收或成员认可。');
    }
    for (var i = 0; i < workItems.length; i++) {
      final old = {...workItems[i]}
        ..remove('status')
        ..remove('resultRef');
      final item = {...next.workItems[i]}
        ..remove('status')
        ..remove('resultRef');
      if (_changed(old, item) ||
          _changed(workItems[i], next.workItems[i]) &&
              workItems[i]['ownerId'] != update.sourceId) {
        throw StateError('只能推进当前责任人的工作项。');
      }
    }
  }

  void _validateTool(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    if (_changed(issues, next.issues)) {
      if (next.issues.length != issues.length ||
          next.verificationRevision != verificationRevision + 1) {
        throw StateError('调查回执只能绑定已有问题。');
      }
      for (var i = 0; i < issues.length; i++) {
        final before = {...issues[i]}..remove('evidenceRef');
        final after = {...next.issues[i]}..remove('evidenceRef');
        if (_changed(before, after) ||
            _changed(issues[i], next.issues[i]) &&
                !((next.issues[i]['evidenceRef'] as String)
                    .startsWith('investigation:'))) {
          throw StateError('工具不能代替成员关闭问题。');
        }
      }
    }
    if (!activeMembers.contains(update.sourceId) ||
        !_sameExcept(next, {
          'iterations',
          'issues',
          'acceptances',
          'verificationRevision',
          'phase'
        })) {
      throw StateError('工具结果来源无效。');
    }
  }

  void _validateUserAcceptance(WorkCollaborationState next) {
    final changedIds = <String>[
      for (var i = 0; i < acceptances.length; i++)
        if (i >= next.acceptances.length ||
            _changed(acceptances[i], next.acceptances[i]))
          acceptances[i]['id'] as String,
    ];
    final target =
        changedIds.length == 1 && next.acceptances.length == acceptances.length
            ? next.acceptances.firstWhere(
                (item) => item['id'] == changedIds.single,
                orElse: () => const <String, dynamic>{},
              )
            : const <String, dynamic>{};
    final decision = next.decisions
        .where((item) =>
            item['targetId'] == changedIds.firstOrNull &&
            {'answered', 'waived'}.contains(item['status']))
        .firstOrNull;
    if (target.isEmpty ||
        decision == null ||
        !{'manual', 'waived'}.contains(target['status']) ||
        target['status'] == 'manual' && decision['answerKind'] != 'manual' ||
        target['status'] == 'waived' && decision['answerKind'] != 'waiver' ||
        target['evidenceRef'] != decision['responseRef'] ||
        target['requestRevision'] != next.requestRevision ||
        target['verificationRevision'] != next.verificationRevision) {
      throw StateError('人工验收或豁免必须来自当前指定事项的用户答复。');
    }
  }

  void _validateUserIssue(WorkCollaborationState next) {
    final changedIds = <String>[
      for (var i = 0; i < issues.length; i++)
        if (i >= next.issues.length || _changed(issues[i], next.issues[i]))
          issues[i]['id'] as String,
    ];
    final target = changedIds.length == 1 && next.issues.length == issues.length
        ? next.issues.firstWhere(
            (item) => item['id'] == changedIds.single,
            orElse: () => const <String, dynamic>{},
          )
        : const <String, dynamic>{};
    final decision = next.decisions
        .where((item) =>
            item['targetId'] == changedIds.firstOrNull &&
            {'answered', 'waived'}.contains(item['status']))
        .lastOrNull;
    final selected = decision == null
        ? null
        : (decision['options'] as List? ?? const [])
            .whereType<Map>()
            .where((o) => o['label'] == decision['answer'])
            .firstOrNull;
    final ideaChoice = target['kind'] == 'idea' &&
        decision?['kind'] == 'dispute' &&
        decision?['answerKind'] == 'choice' &&
        selected != null &&
        ((selected['id'] == 'reject-idea' &&
                target['status'] == 'rejected' &&
                target['resolutionRef'] == decision?['responseRef']) ||
            (selected['id'] == 'revise-idea' &&
                target['status'] == 'open' &&
                target['resolutionRef'] == ''));
    final waiver = decision?['status'] == 'waived' &&
        decision?['answerKind'] == 'waiver' &&
        target['status'] == 'waived' &&
        target['resolutionRef'] == decision?['responseRef'];
    if (target.isEmpty || decision == null || !(ideaChoice || waiver)) {
      throw StateError('问题处置必须来自当前指定事项的明确用户裁决。');
    }
  }
}
