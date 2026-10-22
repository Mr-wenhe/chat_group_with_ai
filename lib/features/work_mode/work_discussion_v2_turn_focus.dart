part of 'work_discussion_runner.dart';

/// Narrow the next contribution without dropping obligations or signing for a
/// member. These are prompt hints; the existing gates remain authoritative.
extension _V2DiscussionTurnFocus on _V2DiscussionSession {
  List<Map<String, dynamic>> _formalPlanRevisionChecklist() => [
        for (final issue in state.issues)
          if (issue['status'] == 'open' &&
              _canReviewFormalPlanIssue(issue, issue['sourceId'] as String))
            {
              for (final key in const [
                'id',
                'target',
                'problem',
                'retestCondition',
                'evidenceRef'
              ])
                key: issue[key],
            }
      ];

  Map<String, dynamic> _turnFocus(String memberId) {
    if (!WorkDiscussionState.fromExecutionState(task.executionStateJson)!
        .isProductionExecutorConsistent) {
      return {
        'stage': WorkDiscussionStage.prepareProposal.name,
        'objective':
            '用户已经指定制作执行者，当前方案工作项责任不一致。保留用户范围和验收，重新提交由指定成员负责的单制作人方案及全员场景。'
      };
    }
    final rejectedIdea = _ideaNeedingRevision;
    if (memberId == state.coordinatorId && rejectedIdea != null) {
      return {
        'stage': WorkDiscussionStage.prepareProposal.name,
        'issueId': rejectedIdea['id'],
        'formalPlanRevisionChecklist': _formalPlanRevisionChecklist(),
        'objective':
            '当前完整提案已过期或收到真实反对。previousProposal 仅是已核验的历史修订依据，不能继续认可或采纳。保留真实异议和用户范围，'
                '按 formalPlanRevisionChecklist 中每个 id 核对其完整问题与复测条件，集中修订全部未决正式方案缺口，不把已知问题逐条留到下一版；'
                '提交完整 proposal，issue_id 继续关联此提案问题。'
                '新提案仍需全员重新审阅，不能代签、直接采纳或把普通测试口径分歧交用户；'
                '新增需求或扩大权限仍须用户决定。',
      };
    }
    final open = _openDiscussionIssue;
    if (open != null) {
      if (memberId == state.coordinatorId && _formalPlanNeedsRevision(open)) {
        return {
          'stage': WorkDiscussionStage.prepareProposal.name,
          'issueId': open['id'],
          'formalPlanRevisionChecklist': _formalPlanRevisionChecklist(),
          'objective': '提出者已核对当前正式方案，问题仍未解决。先修订完整方案，'
              '按 formalPlanRevisionChecklist 中每个 id 核对其完整问题与复测条件，集中补齐全部未决正式方案缺口，不再把同一份方案交提出者重复核对。'
              '保留用户范围、真实问题及已有验收；修改验收仍走关联提案与全员认可。'
              '正式采纳后再由各提出者复核，不代为关闭问题或宣称运行测试通过。',
        };
      }
      if (open['kind'] == 'idea' &&
          (open['resolutionRef'] as String).startsWith('proposal:')) {
        return _approvalFocus('idea', open['id'] as String);
      }
      if (_canReviewFormalPlanIssue(open, memberId)) {
        return {
          'stage': WorkDiscussionStage.resolveIssue.name,
          'issueId': open['id'],
          'objective': '你是此问题的提出者。核对当前已采纳的完整正式方案是否解决原问题；'
              '确已解决才引用 availableResolutionEvidence 的当前 formal-plan 关闭；'
              '这只结束制作前方案口径审查，实际命令和游戏结果仍由冻结后的独立测试验证，不能记为验收通过。'
              '仍有缺陷则保留并说明新证据，不用聊天预览或待审提案代替正式方案。',
        };
      }
      return {
        'stage': WorkDiscussionStage.resolveIssue.name,
        'issueId': open['id'],
        'objective': '本轮只推进此问题：需要依据则调查一次；已有依据则回应或解决。'
            '新范围需要协调成员提交完整提案，普通成员只说明异议。'
            '发现其它真实缺陷仍须记录，不把整个任务重新规划。',
      };
    }
    if (state.isAutonomous &&
        memberId == state.coordinatorId &&
        state.plan.isNotEmpty &&
        state.usagePlanReady &&
        (state.phase != 'reviewing' || state.allMembersUsed)) {
      final kind = state.phase == 'reviewing' ? 'delivery' : 'plan';
      final subject = kind == 'delivery'
          ? (state.currentIteration?['id'] as String?)
          : task.id;
      if (subject != null &&
          state.participantIds.every((id) => _opinion(id, kind, subject))) {
        return {
          'stage': WorkDiscussionStage.reviewApproval.name,
          'objective':
              '本轮仅核对当前版本意见并提交一条定案，不重新设计或复制整份方案。'
              'rulingOpinions 是当前意见索引，完整依据仍在 collaboration。'
              '保留反对与理由，实质失败不能通过；action=decide，'
              'decision.kind=ruling，targetId 逐字复制 rulingSubjectId，options=[]。'
              'reason/evidence/impact 各用一两句真实结论；proposal/approval/tool=null，'
              'issues/resolutions=[]。若发现真实新缺陷则按原协议记录，不能虚报通过。',
          'rulingSubjectId': subject,
          'rulingOpinions': [
            for (final id in state.participantIds)
              state.currentApprovals
                  .where((a) =>
                      a['memberId'] == id &&
                      a['source'] == 'memberModel' &&
                      a['verificationRevision'] == state.verificationRevision &&
                      a['kind'] == kind &&
                      a['subjectId'] == subject &&
                      a['iterationId'] ==
                          (kind == 'delivery' ? subject : '') &&
                      a['artifactDigest'] ==
                          (kind == 'delivery'
                              ? state.currentIteration!['artifactDigest']
                              : ''))
                  .lastOrNull,
          ],
        };
      }
    }
    final stale = state.workItems
            .any((i) => i['requestRevision'] != state.requestRevision) ||
        state.acceptances
            .any((i) => i['requestRevision'] != state.requestRevision);
    if (state.phase == 'reviewing' &&
        state.currentIteration != null &&
        !state.acceptances.any((a) => a['status'] == 'failed') &&
        !stale) {
      return _approvalFocus(
          'delivery', state.currentIteration!['id'] as String);
    }
    if (state.plan.isNotEmpty &&
        state.workItems.isNotEmpty &&
        state.acceptances.isNotEmpty &&
        !stale &&
        !state.acceptances.any((a) => a['status'] == 'failed')) {
      return _approvalFocus('plan', task.id);
    }
    return {
      'stage': WorkDiscussionStage.prepareProposal.name,
      'objective': memberId == state.coordinatorId
          ? '只补齐当前方案的缺项或已指出的错误，保留已有有效条目和完整用户约束。'
              '先在 plan 整理需求、技术及测试口径，再提交最小完整方案；'
              '本轮不生成实现代码、不执行测试、不代替成员认可。'
          : '只说明你职责内尚缺的需求、技术或测试条件，交协调成员整理。'
              '不重建整份方案，不生成实现代码。',
    };
  }

  Map<String, dynamic> _approvalFocus(String kind, String subject) => {
        'stage': WorkDiscussionStage.reviewApproval.name,
        // 气泡文风条款只在协议里说一遍（`_protocolHead`）。这里复述一遍不会更
        // 有效，只会让同一批规则在一轮里出现两次、占掉成员的注意力与额度。
        'objective': '仅审阅当前 $kind 的方案或证据并表达自己的意见；'
            '有缺陷则记录，有未知条件则调查，不重新生成已有方案。'
            'approvalIdentifiers 只用于 approval 字段，照抄进 approval 即可；'
            '发现的缺陷与补丁要求写进 issues。'
            '是否认可必须由你审阅后决定，不能因为模板而自动通过。'
            '本轮输出审阅结论及对应 action，不复制完整方案、工作项或历史台账。'
            '已解决问题仅在有新证据时重开；旧版本记载不能取代当前正式方案。',
        'approvalIdentifiers': {
          'kind': kind,
          'subjectId': subject,
          'requestRevision': state.requestRevision,
          'teamRevision': state.teamRevision,
          'verificationRevision': state.verificationRevision,
          if (kind == 'delivery') 'iterationId': subject,
          if (kind == 'delivery')
            'artifactDigest': state.currentIteration!['artifactDigest'],
        },
      };

  Map<String, dynamic> _outputGuidance(_DiscussionMember member) {
    return {
      'instruction': '本次请求不由客户端指定输出 token 上限；最终长度仍受模型与服务商能力约束。'
          '优先留足完整最终 JSON 和公开说明的空间；只处理 turnFocus，'
          '不反复复盘全部历史，不在内部模拟后续开发与测试。'
          '无需刻意填满输出，不删未决义务，不省略协议必填字段。',
    };
  }
}
