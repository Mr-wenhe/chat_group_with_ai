part of 'work_discussion_runner.dart';

/// Narrow the next contribution without dropping obligations or signing for a
/// member. These are prompt hints; the existing gates remain authoritative.
extension _V2DiscussionTurnFocus on _V2DiscussionSession {
  Map<String, dynamic> _turnFocus(String memberId) {
    final open = state.issues.where((i) => i['status'] == 'open').firstOrNull;
    if (open != null) {
      if (open['kind'] == 'idea' &&
          (open['resolutionRef'] as String).startsWith('proposal:')) {
        return _approvalFocus('idea', open['id'] as String);
      }
      return {
        'stage': WorkDiscussionStage.resolveIssue.name,
        'issueId': open['id'],
        'objective': '本轮只推进此问题：需要依据则调查一次；已有依据则回应或解决。'
            '新范围需要协调成员提交完整提案，普通成员只说明异议。'
            '发现其它真实缺陷仍须记录，不把整个任务重新规划。',
      };
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
            '是否认可必须由你审阅后决定，不能因为模板而自动通过。',
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
    final config = member.config;
    final provider = member.provider;
    final total = config == null || provider == null
        ? 0
        : runner._discussionOutputTokens(provider, config.modelName);
    // This provider exposes a shared limit, not a separate reasoning cap. Give
    // final JSON at least half of the planning target, but never claim a hard
    // reservation that the API cannot enforce.
    final finalTarget = min(
        total,
        max((total / 2).ceil(),
            min(total, WorkDiscussionRunner.preferredDiscussionFinalTokens)));
    return {
      'sharedMaxTokens': total,
      'preferredFinalTokens': finalTarget,
      'separateReasoningLimitEnforced': false,
      'instruction': '推理与正文共用额度，此处仅为规划建议，不是服务端硬预留。'
          '优先留足完整最终 JSON 和公开说明的空间；只处理 turnFocus，'
          '不反复复盘全部历史，不在内部模拟后续开发与测试。'
          '无需填满正文额度，不删未决义务，不省略协议必填字段。',
    };
  }
}
