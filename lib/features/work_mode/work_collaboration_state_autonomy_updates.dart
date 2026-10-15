part of 'work_collaboration_state.dart';

extension _WorkCollaborationAutonomyUpdates on WorkCollaborationState {
  void _validateParticipation(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    final policy = confirmedParticipationPolicy;
    if (!isAutonomous ||
        update.sourceId != 'application' ||
        _changed(policy, next.autonomyPolicy) ||
        !nextPolicyChanged(next) ||
        next.requestRevision != requestRevision + 1 ||
        next.teamRevision != teamRevision + 1 ||
        next.verificationRevision != verificationRevision + 1 ||
        next.plan.isNotEmpty ||
        next.workItems.isNotEmpty ||
        next.acceptances.isNotEmpty ||
        next.usageAssignments.isNotEmpty ||
        next.phase != 'clarifying' ||
        !_sameExcept(next, {
          'autonomyPolicy',
          'plan',
          'workItems',
          'acceptances',
          'usageAssignments',
          'requestRevision',
          'teamRevision',
          'verificationRevision',
          'phase'
        })) {
      throw StateError('参与范围调整必须来自明确的用户成员决策，并重新确认方案与场景。');
    }
  }

  void _validateAutonomy(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    if (update.sourceId != 'application' ||
        isAutonomous ||
        !next.isAutonomous ||
        next.plan.isNotEmpty ||
        next.usageAssignments.isNotEmpty ||
        next.usageEvidenceRefs.isNotEmpty ||
        next.coordinatorDecisions.isNotEmpty ||
        next.workItems.isNotEmpty ||
        next.acceptances.isNotEmpty ||
        next.requestRevision != requestRevision + 1 ||
        next.verificationRevision != verificationRevision + 1 ||
        next.phase != 'clarifying' ||
        !_sameExcept(next, {
          'autonomyPolicy',
          'usageAssignments',
          'usageEvidenceRefs',
          'coordinatorDecisions',
          'plan',
          'phase',
          'workItems',
          'acceptances',
          'requestRevision',
          'verificationRevision'
        })) {
      throw StateError('自主策略建立必须重新确认当前方案，不能补造历史使用。');
    }
  }

  void _validateUsage(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    if (!isAutonomous ||
        !activeMembers.contains(update.sourceId) ||
        !_sameExcept(next, {'usageEvidenceRefs'}) ||
        next.usageEvidenceRefs.length !=
            usageEvidenceRefs
                    .where((e) => e['memberId'] != update.sourceId)
                    .length +
                1) {
      throw StateError('使用证据只能由实际运行器提交当前试用成员的记录。');
    }
    final oldOthers = usageEvidenceRefs
        .where((e) => e['memberId'] != update.sourceId)
        .toList();
    final newOthers = next.usageEvidenceRefs
        .where((e) => e['memberId'] != update.sourceId)
        .toList();
    final receipt = next.usageEvidenceRefs
        .where((e) => e['memberId'] == update.sourceId)
        .single;
    final assignment = usageAssignments
        .where((a) => a['memberId'] == update.sourceId)
        .firstOrNull;
    if (_changed(oldOthers, newOthers) ||
        assignment == null ||
        receipt['taskId'] != taskId ||
        receipt['conversationId'] != conversationId ||
        receipt['scenarioId'] != assignment['scenarioId'] ||
        receipt['requestRevision'] != requestRevision ||
        receipt['teamRevision'] != teamRevision ||
        receipt['verificationRevision'] != verificationRevision ||
        receipt['iterationId'] != currentIteration?['id'] ||
        receipt['artifactDigest'] != currentIteration?['artifactDigest'] ||
        receipt['planDigest'] != usagePlanDigest) {
      throw StateError('使用证据的任务、成员、计划或候选不匹配。');
    }
  }

  void _validateRuling(
      WorkCollaborationState next, WorkCollaborationUpdate update) {
    if (!isAutonomous ||
        update.sourceId != coordinatorId ||
        !teamQualified ||
        !_sameExcept(next, {'coordinatorDecisions'}) ||
        next.coordinatorDecisions.length != coordinatorDecisions.length + 1 ||
        _changed(
            coordinatorDecisions,
            next.coordinatorDecisions
                .take(coordinatorDecisions.length)
                .toList())) {
      throw StateError('协调决议必须来自当前协调者的真实回应。');
    }
    final ruling = next.coordinatorDecisions.last;
    final delivery = ruling['kind'] == 'delivery';
    if (ruling['eventId'] != update.eventId ||
        ruling['coordinatorId'] != update.sourceId ||
        ruling['requestRevision'] != requestRevision ||
        ruling['teamRevision'] != teamRevision ||
        ruling['verificationRevision'] != verificationRevision ||
        ruling['subjectId'] !=
            (delivery ? (currentIteration?['id']) : taskId) ||
        ruling['iterationId'] != (delivery ? (currentIteration?['id']) : '') ||
        ruling['artifactDigest'] !=
            (delivery ? (currentIteration?['artifactDigest']) : '') ||
        !issuesResolved ||
        !delivery && !next.planReady ||
        delivery &&
            (!allMembersUsed ||
                acceptances.any((a) =>
                    a['status'] == 'failed' || a['status'] == 'pending')) ||
        !next.opinionsSettled(
            ruling['kind'] as String, ruling['subjectId'] as String,
            iterationId: ruling['iterationId'] as String,
            digest: ruling['artifactDigest'] as String)) {
      throw StateError('协调者不能覆盖缺失意见、实际失败或未完成的本人使用。');
    }
  }
}
