part of 'work_discussion_runner.dart';

extension _V2DiscussionApprovals on _V2DiscussionSession {
  Future<bool> _loadDeliveryEvidence() async {
    final iteration = state.currentIteration;
    if (iteration == null) return false;
    try {
      final publisher = WorkCandidatePublisher(const WorkModeDirectoryService()
          .deliveryTaskDir(await runner.database.mediaDir, task.id));
      final candidate = (await publisher.recover())
          .where((c) => c.iterationId == iteration['id'])
          .single;
      if (candidate.digest != iteration['artifactDigest'] ||
          !await publisher.evidenceValid(
              candidate, iteration['reviewRef'] as String)) {
        throw StateError('本轮证据失效');
      }
      final attempt = (iteration['reviewRef'] as String).split(':')[2];
      final report = await WorkCandidatePublisher.readMetadata(
          File('${candidate.directory.path}/reviews/$attempt/report.json'));
      evidence['delivery:${iteration['id']}'] = {
        'manifest': candidate.manifest,
        'report': report
      };
      return true;
    } on Object {
      await _decision(
          'acceptance', '', '当前候选或审查报告已变化，需重新验证，旧签字不能交付。', '候选文件与报告核验未通过。');
      return false;
    }
  }

  Future<void> _approve(AICharacter member, Map<String, dynamic> approval,
      String responseRef) async {
    if (approval['requestRevision'] != state.requestRevision ||
        approval['teamRevision'] != state.teamRevision ||
        approval['verificationRevision'] != state.verificationRevision) {
      throw StateError('认可版本已过期');
    }
    final kind = approval['kind'] as String;
    final subject = approval['subjectId'] as String;
    if (kind == 'plan' && subject != task.id) {
      throw StateError('方案认可 subjectId 必须逐字使用当前 taskId，不能使用方案名称或版本号');
    }
    if (kind == 'plan' &&
        (state.plan.isEmpty ||
            state.acceptances.isEmpty ||
            state.workItems.isEmpty ||
            state.workItems
                .any((i) => i['requestRevision'] != state.requestRevision) ||
            state.acceptances
                .any((i) => i['requestRevision'] != state.requestRevision) ||
            state.issues.any((i) => i['status'] == 'open'))) {
      throw StateError('方案仍有未决问题');
    }
    if (kind == 'idea' &&
        !state.issues.any((i) =>
            i['kind'] == 'idea' &&
            i['id'] == subject &&
            i['status'] == 'open')) {
      throw StateError('提案不存在');
    }
    if (kind == 'delivery' &&
        (subject != state.currentIteration?['id'] ||
            approval['iterationId'] != state.currentIteration?['id'] ||
            approval['artifactDigest'] !=
                state.currentIteration?['artifactDigest'] ||
            state.phase != 'reviewing' ||
            state.hasOpenIssue ||
            state.acceptances.any((a) =>
                !{'passed', 'manual', 'waived'}.contains(a['status']) ||
                a['verificationRevision'] != state.verificationRevision))) {
      throw StateError('当前候选或验证尚未就绪，不能签字');
    }
    final current = state;
    final previous = current.approvals
        .where((a) =>
            a['memberId'] == member.id &&
            a['kind'] == kind &&
            a['subjectId'] == subject &&
            a['requestRevision'] == current.requestRevision &&
            a['teamRevision'] == current.teamRevision &&
            a['verificationRevision'] == current.verificationRevision)
        .lastOrNull;
    if (previous?['approved'] == approval['approved']) return;
    final eventId = _key(
        'approval', '${task.id}:${current.revision}:${member.id}:$responseRef');
    final signature = {
      'eventId': eventId,
      'memberId': member.id,
      'kind': kind,
      'subjectId': subject,
      'requestRevision': current.requestRevision,
      'teamRevision': current.teamRevision,
      'verificationRevision': current.verificationRevision,
      'iterationId': kind == 'delivery' ? approval['iterationId'] : '',
      'artifactDigest': kind == 'delivery' ? approval['artifactDigest'] : '',
      'approved': approval['approved'],
      'evidenceRef': responseRef,
      'source': 'memberModel'
    };
    final nextJson = current.toJson()
      ..['revision'] = current.revision + 1
      ..['approvals'] = [...current.approvals, signature]
      ..['appliedEventIds'] = [
        ...current.appliedEventIds
            .skip(current.appliedEventIds.length == 64 ? 1 : 0),
        eventId
      ];
    final next = WorkCollaborationState.tryParse(nextJson);
    if (next == null) throw StateError('认可记录超出当前台账容量');
    task = await apply(WorkCollaborationUpdate(
        taskId: task.id,
        conversationId: task.groupId,
        expectedRevision: current.revision,
        eventId: eventId,
        sourceRole: 'member',
        sourceId: member.id,
        next: next));
    if (kind == 'idea' && approval['approved'] == true) {
      await _adoptIdea(subject);
    }
    if (approval['approved'] == false) {
      final idea = state.issues
          .where((i) => i['id'] == subject && i['kind'] == 'idea')
          .firstOrNull;
      await _decision(
          'dispute',
          subject,
          '成员 ${member.name} 对当前 $kind 有异议，请裁决或补充处理条件。',
          runner.database.messageBox.get(responseRef)?.content ?? '成员已明确反对。',
          options: idea == null
              ? const []
              : [
                  {
                    'id': 'reject-idea',
                    'label': '不采用新范围，按原范围继续',
                    'impact': '记录拒绝理由，重新确认原方案。'
                  },
                  {
                    'id': 'revise-idea',
                    'label': '修改提案后重新讨论',
                    'impact': '保留疑问，旧提案认可失效。'
                  },
                  if (!RegExp(r'禁止|不得|不要|不允许|never|must not|do not',
                          caseSensitive: false)
                      .hasMatch(task.userRequest))
                    {
                      'id': 'adopt:${idea['resolutionRef']}',
                      'label': '采用这份提案',
                      'impact': '以附件中的完整提案更新范围、计划和验收，仍需全员认可最终方案；不扩大工具授权。'
                    }
                ]);
    }
  }

  Future<void> _adoptIdea(String subject, {bool userRuling = false}) async {
    final current = state;
    final votes = current.approvals.where((a) =>
        a['kind'] == 'idea' &&
        a['subjectId'] == subject &&
        a['requestRevision'] == current.requestRevision &&
        a['teamRevision'] == current.teamRevision &&
        a['verificationRevision'] == current.verificationRevision);
    if (!userRuling &&
        !current.activeMembers.every((id) =>
            votes.where((a) => a['memberId'] == id).lastOrNull?['approved'] ==
            true)) {
      return;
    }
    final issue = current.issues.where((i) => i['id'] == subject).single;
    final ref = issue['resolutionRef'] as String;
    final store = runner.eventStore;
    if (store == null || !ref.startsWith('proposal:')) {
      throw StateError('提案缺少完整范围、计划及验收详情');
    }
    final proposal = Map<String, dynamic>.from(
        jsonDecode(await store.readDiscussionDetail(task.id, ref.substring(9)))
            as Map);
    if (_key('proposal', jsonEncode(proposal)) != ref) {
      throw StateError('提案详情已变化');
    }
    if (_scopeConflicts(proposal)) {
      final originalIssue = issue['problem'] as String;
      await _decision(
          'dispute',
          issue['id'] as String,
          '当前提案与用户明确禁止事项冲突，请裁决或要求修改提案。',
          '关联提案 ${issue['resolutionRef']} 仍含与当前用户范围冲突的内容：$originalIssue',
          options: [
            {
              'id': 'reject-idea',
              'label': '保留原要求，不采用当前提案',
              'impact': '记录拒绝理由，回到原范围重新确认方案。'
            },
            {
              'id': 'revise-idea',
              'label': '修改提案后重新讨论',
              'impact': '当前提案认可失效，成员按保留的原要求重新确认。'
            }
          ]);
      return;
    }
    try {
      _validateProposal(proposal);
      _validateContract(proposal);
    } on Object catch (error) {
      final detail =
          error is StateError ? error.message.toString() : '提案不符合当前协作状态结构';
      await _decision('dispute', issue['id'] as String,
          '关联提案不符合当前协作状态结构，需要修改后重新讨论。', '旧提案 $ref 校验失败：$detail',
          options: [
            {
              'id': 'reject-idea',
              'label': '保留原要求，不采用这份提案',
              'impact': '作废当前提案，按原范围重新确认方案。'
            },
            {
              'id': 'revise-idea',
              'label': '修改提案后重新讨论',
              'impact': '旧提案认可失效，协调成员提交新的完整提案。'
            }
          ]);
      return;
    }
    await _installProposal(proposal, issues: [
      for (final i in current.issues)
        i['id'] == subject
            ? {
                ...i,
                'status': 'resolved',
                'resolution': userRuling
                    ? '用户裁决采用提案，已更新范围、方案、工作项与验收；保留成员原始意见。'
                    : '全员明确认可提案，已更新范围、方案、工作项与验收。'
              }
            : i
    ]);
  }
}
