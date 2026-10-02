part of 'work_collaboration_state.dart';

/// Deterministic plan and delivery gates over the one durable v2 record.
extension WorkCollaborationGate on WorkCollaborationState {
  bool get isValid {
    if (!WorkCollaborationState._id(taskId) ||
        !WorkCollaborationState._id(conversationId) ||
        !WorkCollaborationState._id(projectScopeId) ||
        !WorkCollaborationState._revision(revision) ||
        !WorkCollaborationState._revision(requestRevision) ||
        !WorkCollaborationState._revision(teamRevision) ||
        !WorkCollaborationState._revision(verificationRevision) ||
        !WorkCollaborationState._text(requestMessageId, max: 128) ||
        !WorkCollaborationState._text(scope) ||
        !WorkCollaborationState._text(plan) ||
        !WorkCollaborationState._text(coordinatorId, max: 128) ||
        !WorkCollaborationState.phases.contains(phase) ||
        !WorkCollaborationState._refs(pendingInputIds) ||
        !WorkCollaborationState._refs(appliedEventIds) ||
        !WorkCollaborationState._text(artifactContract['type'], max: 128) ||
        !WorkCollaborationState._text(artifactContract['format'], max: 128) ||
        !WorkCollaborationState._text(artifactContract['location'], max: 512) ||
        !WorkCollaborationState._text(artifactContract['revisionTarget'],
            max: 512) ||
        !WorkCollaborationState._only(artifactContract, {
          'type',
          'format',
          'location',
          'revisionTarget',
          'files',
          'verificationCommands'
        })) {
      return false;
    }
    final commands = artifactContract['verificationCommands'];
    if (commands != null &&
        (commands is! List ||
            commands.isEmpty ||
            commands.length > 64 ||
            !commands
                .every((c) => WorkCollaborationState._text(c, max: 1024)))) {
      return false;
    }
    final files = artifactContract['files'];
    if (files != null &&
        (files is! List ||
            files.isEmpty ||
            files.length > 64 ||
            !files.every(WorkCollaborationState._id))) {
      return false;
    }
    if (!WorkCollaborationState._records(
            team,
            (e) =>
                WorkCollaborationState._only(e, {
                  'memberId',
                  'role',
                  'qualificationRef',
                  'qualified',
                  'available'
                }) &&
                WorkCollaborationState._id(e['memberId']) &&
                WorkCollaborationState._text(e['role'], max: 128) &&
                WorkCollaborationState._text(e['qualificationRef'], max: 128) &&
                e['qualified'] is bool &&
                e['available'] is bool) ||
        !WorkCollaborationState._unique(team, 'memberId')) {
      return false;
    }
    if (!WorkCollaborationState._records(
            workItems,
            (e) =>
                WorkCollaborationState._only(e, {
                  'id',
                  'ownerId',
                  'kind',
                  'resultRef',
                  'dependencies',
                  'status',
                  'requestRevision'
                }) &&
                WorkCollaborationState._id(e['id']) &&
                WorkCollaborationState._id(e['ownerId']) &&
                (e['kind'] == null ||
                    {'material', 'produce'}.contains(e['kind'])) &&
                (e['resultRef'] == null ||
                    WorkCollaborationState._text(e['resultRef'], max: 128)) &&
                e['dependencies'] is List &&
                (e['dependencies'] as List).length <= 64 &&
                (e['dependencies'] as List).every(WorkCollaborationState._id) &&
                {'pending', 'active', 'done', 'blocked'}
                    .contains(e['status']) &&
                WorkCollaborationState._revision(e['requestRevision'])) ||
        !WorkCollaborationState._unique(workItems, 'id')) {
      return false;
    }
    if (!WorkCollaborationState._records(
            issues,
            (e) =>
                WorkCollaborationState._only(e, {
                  'id',
                  'sourceId',
                  'kind',
                  'status',
                  'target',
                  'problem',
                  'evidenceRef',
                  'resolution',
                  'resolutionRef',
                  'retestCondition',
                  'requestRevision'
                }) &&
                WorkCollaborationState._id(e['id']) &&
                WorkCollaborationState._id(e['sourceId']) &&
                WorkCollaborationState.issueKinds.contains(e['kind']) &&
                WorkCollaborationState.issueStatuses.contains(e['status']) &&
                WorkCollaborationState._text(e['target']) &&
                WorkCollaborationState._text(e['problem']) &&
                WorkCollaborationState._text(e['evidenceRef'], max: 128) &&
                WorkCollaborationState._text(e['resolution']) &&
                WorkCollaborationState._text(e['resolutionRef'], max: 128) &&
                WorkCollaborationState._text(e['retestCondition']) &&
                WorkCollaborationState._revision(e['requestRevision']),
            max: null) ||
        !WorkCollaborationState._unique(issues, 'id')) {
      return false;
    }
    if (!WorkCollaborationState._records(
            acceptances,
            (e) =>
                WorkCollaborationState._only(e, {
                  'id',
                  'method',
                  'requiredCapability',
                  'status',
                  'evidenceRef',
                  'requestRevision',
                  'verificationRevision'
                }) &&
                WorkCollaborationState._id(e['id']) &&
                WorkCollaborationState._text(e['method'], max: 128) &&
                WorkCollaborationState._text(e['requiredCapability'],
                    max: 128) &&
                WorkCollaborationState.acceptanceStatuses
                    .contains(e['status']) &&
                WorkCollaborationState._text(e['evidenceRef'], max: 128) &&
                WorkCollaborationState._revision(e['requestRevision']) &&
                WorkCollaborationState._revision(e['verificationRevision'])) ||
        !WorkCollaborationState._unique(acceptances, 'id')) {
      return false;
    }
    if (!WorkCollaborationState._records(
            iterations,
            (e) =>
                WorkCollaborationState._only(e, {
                  'id',
                  'artifactDigest',
                  'requestRevision',
                  'teamRevision',
                  'manifestRef',
                  'reviewRef',
                  'status'
                }) &&
                WorkCollaborationState._id(e['id']) &&
                WorkCollaborationState._id(e['artifactDigest']) &&
                WorkCollaborationState._revision(e['requestRevision']) &&
                WorkCollaborationState._revision(e['teamRevision']) &&
                WorkCollaborationState._text(e['manifestRef'], max: 128) &&
                WorkCollaborationState._text(e['reviewRef'], max: 128) &&
                {'candidate', 'reviewed', 'delivered'}.contains(e['status'])) ||
        !WorkCollaborationState._unique(iterations, 'id')) {
      return false;
    }
    if (!WorkCollaborationState._records(
            approvals,
            (e) =>
                WorkCollaborationState._only(e, {
                  'eventId',
                  'memberId',
                  'kind',
                  'subjectId',
                  'requestRevision',
                  'teamRevision',
                  'iterationId',
                  'artifactDigest',
                  'verificationRevision',
                  'approved',
                  'evidenceRef',
                  'source'
                }) &&
                WorkCollaborationState._id(e['eventId']) &&
                WorkCollaborationState._id(e['memberId']) &&
                WorkCollaborationState.approvalKinds.contains(e['kind']) &&
                WorkCollaborationState._id(e['subjectId']) &&
                WorkCollaborationState._revision(e['requestRevision']) &&
                WorkCollaborationState._revision(e['teamRevision']) &&
                WorkCollaborationState._text(e['iterationId'], max: 128) &&
                WorkCollaborationState._text(e['artifactDigest'], max: 128) &&
                WorkCollaborationState._revision(e['verificationRevision']) &&
                e['approved'] is bool &&
                WorkCollaborationState._id(e['evidenceRef']) &&
                {'memberModel', 'human'}.contains(e['source']),
            max: null) ||
        !WorkCollaborationState._unique(approvals, 'eventId') ||
        liveApprovalGroups > 64) {
      return false;
    }
    if (!WorkCollaborationState._records(
            decisions,
            (e) =>
                WorkCollaborationState._only(e, {
                  'id',
                  'revision',
                  'status',
                  'reason',
                  'answer',
                  'impact',
                  'responseRef',
                  'evidence',
                  'options',
                  'targetId',
                  'kind',
                  'answerKind',
                  'missingCondition',
                  'promptedReminder'
                }) &&
                WorkCollaborationState._id(e['id']) &&
                WorkCollaborationState._revision(e['revision']) &&
                {'pending', 'answered', 'deferred', 'waived'}
                    .contains(e['status']) &&
                WorkCollaborationState._text(e['reason']) &&
                WorkCollaborationState._text(e['answer']) &&
                WorkCollaborationState._text(e['impact']) &&
                WorkCollaborationState._text(e['responseRef'], max: 128) &&
                (e['evidence'] == null ||
                    WorkCollaborationState._text(e['evidence'])) &&
                (e['targetId'] == null ||
                    WorkCollaborationState._text(e['targetId'], max: 128)) &&
                (e['kind'] == null ||
                    {'question', 'choice', 'acceptance', 'member', 'dispute'}
                        .contains(e['kind'])) &&
                (e['answerKind'] == null ||
                    {'text', 'choice', 'manual', 'waiver'}
                        .contains(e['answerKind'])) &&
                (e['missingCondition'] == null ||
                    WorkCollaborationState._text(e['missingCondition'])) &&
                (e['promptedReminder'] == null ||
                    {'initial', 'remainderReady'}
                        .contains(e['promptedReminder'])) &&
                (e['options'] == null ||
                    e['options'] is List &&
                        (e['options'] as List).length <= 12 &&
                        (e['options'] as List)
                                .map((option) =>
                                    option is Map ? option['id'] : null)
                                .toSet()
                                .length ==
                            (e['options'] as List).length &&
                        (e['options'] as List).every((option) =>
                            option is Map &&
                            WorkCollaborationState._only(
                                Map<String, dynamic>.from(option),
                                {'id', 'label', 'impact'}) &&
                            WorkCollaborationState._id(option['id']) &&
                            WorkCollaborationState._text(option['label'],
                                max: 256) &&
                            WorkCollaborationState._text(option['impact'],
                                max: 1024))),
            max: null) ||
        !WorkCollaborationState._unique(decisions, 'id')) {
      return false;
    }
    return true;
  }

  List<String> get activeMembers => [
        for (final m in team)
          if (m['qualified'] == true && m['available'] == true)
            m['memberId'] as String
      ];
  bool get teamQualified =>
      team.isNotEmpty &&
      activeMembers.length == team.length &&
      team.every((m) =>
          (m['role'] as String).trim().isNotEmpty &&
          (m['qualificationRef'] as String).trim().isNotEmpty) &&
      activeMembers.contains(coordinatorId);
  bool get hasPendingDecision => decisions.any((d) =>
      d['status'] == 'pending' ||
      d['status'] == 'deferred' ||
      (d['status'] == 'answered' || d['status'] == 'waived') &&
          (d['responseRef'] as String).isEmpty);
  bool get hasOpenIssue => issues.any((i) =>
      i['status'] == 'open' ||
      i['status'] == 'deferred' ||
      i['kind'] == 'defect' &&
          i['status'] != 'resolved' &&
          i['status'] != 'waived');

  bool _userResolved(String id) => decisions.any((d) =>
      (d['id'] == id || d['targetId'] == id) &&
      {'answered', 'waived'}.contains(d['status']) &&
      (d['responseRef'] as String).isNotEmpty);
  bool get issuesResolved => issues.every((i) {
        if ((i['target'] as String).trim().isEmpty ||
            (i['problem'] as String).trim().isEmpty ||
            (i['evidenceRef'] as String).isEmpty ||
            (i['retestCondition'] as String).trim().isEmpty) {
          return false;
        }
        if (i['status'] == 'open' || i['status'] == 'deferred') return false;
        if (i['kind'] == 'idea' && i['status'] == 'resolved') {
          return ideaApproved(i['id'] as String,
                  requestRevision: i['requestRevision'] as int) ||
              _userResolved(i['id'] as String);
        }
        if (i['kind'] == 'idea' && i['status'] == 'rejected') {
          return _userResolved(i['id'] as String);
        }
        if (i['status'] == 'waived') return _userResolved(i['id'] as String);
        return i['status'] == 'resolved' &&
            (i['resolution'] as String).trim().isNotEmpty &&
            (i['resolutionRef'] as String).isNotEmpty;
      });

  /// Adopted scope proposals retain their actual pre-adoption signatures.
  /// Advancing the requirement invalidates plan signatures, not the recorded
  /// unanimous vote on the immutable proposal itself.
  bool ideaApproved(String subject, {int? requestRevision}) {
    final opinions = approvals.where((a) =>
        a['kind'] == 'idea' &&
        a['subjectId'] == subject &&
        a['requestRevision'] == (requestRevision ?? this.requestRevision) &&
        a['teamRevision'] == teamRevision);
    final version = opinions.lastOrNull?['verificationRevision'];
    return teamQualified &&
        version != null &&
        activeMembers.every((id) =>
            opinions
                .where((a) =>
                    a['memberId'] == id && a['verificationRevision'] == version)
                .lastOrNull?['approved'] ==
            true);
  }

  bool _allApproved(String kind, String subjectId,
      {String iterationId = '', String digest = ''}) {
    if (!teamQualified) return false;
    return activeMembers.every((member) {
      final opinions = approvals.where((a) =>
          a['memberId'] == member &&
          a['kind'] == kind &&
          a['subjectId'] == subjectId &&
          a['requestRevision'] == requestRevision &&
          a['teamRevision'] == teamRevision &&
          a['iterationId'] == iterationId &&
          a['artifactDigest'] == digest &&
          (kind == 'plan' ||
              a['verificationRevision'] == verificationRevision));
      return opinions.isNotEmpty && opinions.last['approved'] == true;
    });
  }

  /// A deferred question does not authorize its target or dependent work.
  /// This read-only projection permits only the unaffected confirmed plan.
  bool get productionReady {
    if (!decisions.any((d) => d['status'] == 'deferred')) return planReady;
    final raw = toJson()
      ..['decisions'] =
          decisions.where((d) => d['status'] != 'deferred').toList()
      ..['issues'] = issues.where((i) => i['status'] != 'deferred').toList();
    return WorkCollaborationState.tryParse(raw)?.planReady == true;
  }

  bool get hasBlockingDecision => decisions.any((d) =>
      d['status'] == 'pending' ||
      {'answered', 'waived'}.contains(d['status']) &&
          (d['responseRef'] as String).isEmpty);

  Set<String> get deferredWork {
    final blocked = decisions
        .where((d) => d['status'] == 'deferred')
        .map((d) => d['targetId'] as String)
        .toSet();
    for (var pass = 0; pass < workItems.length; pass++) {
      blocked.addAll(workItems
          .where((i) => (i['dependencies'] as List).any(blocked.contains))
          .map((i) => i['id'] as String));
    }
    return blocked;
  }

  bool get planReady =>
      isValid &&
      teamQualified &&
      scope.trim().isNotEmpty &&
      plan.trim().isNotEmpty &&
      ['type', 'format', 'location'].every((key) =>
          (artifactContract[key] as String).trim().isNotEmpty &&
          artifactContract[key] != 'unspecified') &&
      acceptances.isNotEmpty &&
      acceptances.every((a) =>
          a['method'].toString().trim().isNotEmpty &&
          a['requiredCapability'].toString().trim().isNotEmpty) &&
      issuesResolved &&
      !hasPendingDecision &&
      pendingInputIds.isEmpty &&
      _allApproved('plan', taskId);

  Map<String, dynamic>? get currentIteration =>
      iterations.isEmpty ? null : iterations.last;

  /// 容量只数**当前可读**的签字。
  ///
  /// 台账解析时先按同键归档（[WorkCollaborationState.compactedApprovals]），但
  /// delivery 的键带着随迭代变化的 `subjectId`，失效候选的签字因此永远不与新签字
  /// 同键、只能一路堆下去：迭代够久就把上限占满，第 65 条**当前**签字让整个状态
  /// 解析成 null，任务被永久卡住。而所有读取判据都钉在当前主体上——[planReady] 读
  /// `taskId`、[deliveryReady] 读当前迭代 id、[ideaApproved] 读问题 id——旧迭代的
  /// 签字对任何判据都不可见，历史凭证仍在群里的公开回复（`evidenceRef`）与事件日志
  /// 里，所以容量只看当前主体及门禁实际读取的版本。
  int get liveApprovalGroups {
    return currentApprovals
        .map(WorkCollaborationState._approvalKey)
        .toSet()
        .length;
  }

  /// 与方案、提案及交付门禁使用相同的版本绑定。过期签字只作历史凭证。
  Iterable<Map<String, dynamic>> get currentApprovals {
    final members = activeMembers.toSet();
    final issueRequests = {
      for (final issue in issues) issue['id']: issue['requestRevision']
    };
    return approvals.where((a) {
      if (a['teamRevision'] != teamRevision) return false;
      if (a['kind'] == 'idea') {
        // ideaApproved 以最后一条意见的验证版本为准，不能隐去反对意见。
        return issueRequests[a['subjectId']] == a['requestRevision'];
      }
      if (!members.contains(a['memberId']) ||
          a['requestRevision'] != requestRevision) {
        return false;
      }
      if (a['kind'] == 'plan') {
        return a['subjectId'] == taskId &&
            a['iterationId'] == '' &&
            a['artifactDigest'] == '';
      }
      final iteration = currentIteration;
      return a['kind'] == 'delivery' &&
          iteration != null &&
          a['subjectId'] == iteration['id'] &&
          a['iterationId'] == iteration['id'] &&
          a['artifactDigest'] == iteration['artifactDigest'] &&
          a['verificationRevision'] == verificationRevision;
    });
  }

  bool get deliveryReady {
    final iteration = currentIteration;
    if (!isValid ||
        !planReady ||
        !{'reviewing', 'delivered'}.contains(phase) ||
        iteration == null ||
        iteration['requestRevision'] != requestRevision ||
        iteration['teamRevision'] != teamRevision ||
        iteration['status'] != 'reviewed' ||
        (iteration['manifestRef'] as String).isEmpty ||
        (iteration['reviewRef'] as String).isEmpty ||
        !issuesResolved ||
        hasPendingDecision ||
        pendingInputIds.isNotEmpty ||
        acceptances.any((a) =>
            a['requestRevision'] != requestRevision ||
            a['verificationRevision'] != verificationRevision ||
            !{'passed', 'manual', 'waived'}.contains(a['status']) ||
            (a['evidenceRef'] as String).isEmpty ||
            a['status'] == 'waived' && !_userResolved(a['id'] as String))) {
      return false;
    }
    return _allApproved('delivery', iteration['id'] as String,
        iterationId: iteration['id'] as String,
        digest: iteration['artifactDigest'] as String);
  }
}
