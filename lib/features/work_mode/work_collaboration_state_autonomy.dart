part of 'work_collaboration_state.dart';

/// Application-owned policy and current, personally attributed usage facts.
extension WorkCollaborationAutonomy on WorkCollaborationState {
  static Map<String, dynamic> policyFor(Iterable<String> participants) => {
        'schemaVersion': 1,
        'mode': 'coordinator',
        'source': 'application',
        'participantIds': participants.toList(),
      };

  bool get isAutonomous => autonomyPolicy != null;
  bool get isRecoverableClarifyingCheckpoint =>
      isAutonomous &&
      phase == 'clarifying' &&
      planReady &&
      workItems.isNotEmpty &&
      workItems.every((item) => item['status'] == 'done') &&
      currentIteration != null;
  List<String> get participantIds => autonomyPolicy == null
      ? activeMembers.toList()
      : List<String>.from(autonomyPolicy!['participantIds'] as List);

  String? get autonomyInvalidSection {
    final policy = autonomyPolicy;
    if (policy == null) {
      return usageAssignments.isEmpty &&
              usageEvidenceRefs.isEmpty &&
              coordinatorDecisions.isEmpty
          ? null
          : 'autonomyPolicy';
    }
    if (policy.length != 4 ||
        !WorkCollaborationState._only(
            policy, {'schemaVersion', 'mode', 'source', 'participantIds'}) ||
        policy['schemaVersion'] != 1 ||
        policy['mode'] != 'coordinator' ||
        policy['source'] != 'application' ||
        policy['participantIds'] is! List ||
        (policy['participantIds'] as List).isEmpty ||
        !(policy['participantIds'] as List).every(WorkCollaborationState._id) ||
        !WorkCollaborationState._refs(
            List<String>.from(policy['participantIds'] as List))) {
      return 'autonomyPolicy';
    }
    if (!WorkCollaborationState._records(usageAssignments, _validAssignment) ||
        !WorkCollaborationState._unique(usageAssignments, 'scenarioId') ||
        !WorkCollaborationState._unique(usageAssignments, 'memberId')) {
      return 'usageAssignments';
    }
    if (!WorkCollaborationState._records(usageEvidenceRefs, _validUsageRef) ||
        !WorkCollaborationState._unique(usageEvidenceRefs, 'receiptRef') ||
        !WorkCollaborationState._unique(usageEvidenceRefs, 'memberId')) {
      return 'usageEvidenceRefs';
    }
    if (!WorkCollaborationState._records(coordinatorDecisions, _validRuling,
            max: null) ||
        !WorkCollaborationState._unique(coordinatorDecisions, 'eventId')) {
      return 'coordinatorDecisions';
    }
    return null;
  }

  static bool _strings(Object? value, {bool ids = false}) =>
      value is List &&
      value.isNotEmpty &&
      value.length <= 64 &&
      value.every(ids
          ? WorkCollaborationState._id
          : (v) =>
              WorkCollaborationState._multilineText(v) &&
              (v as String).trim().isNotEmpty);

  static bool validProposalAssignment(Map<String, dynamic> value) =>
      !value.containsKey('requestRevision') &&
      _validAssignment({...value, 'requestRevision': 1});

  static bool _validAssignment(Map<String, dynamic> a) =>
      a.length == 10 &&
      WorkCollaborationState._only(a, {
        'memberId',
        'scenarioId',
        'goal',
        'preconditions',
        'stepGoals',
        'expectedResult',
        'acceptanceIds',
        'requiredCapabilities',
        'resetMethod',
        'requestRevision'
      }) &&
      ['memberId', 'scenarioId']
          .every((k) => WorkCollaborationState._id(a[k])) &&
      ['goal', 'preconditions', 'expectedResult', 'resetMethod'].every((k) =>
          WorkCollaborationState._multilineText(a[k]) &&
          (a[k] as String).trim().isNotEmpty) &&
      _strings(a['stepGoals']) &&
      _strings(a['acceptanceIds'], ids: true) &&
      _strings(a['requiredCapabilities'], ids: true) &&
      WorkCollaborationState._revision(a['requestRevision']);

  static bool _validUsageRef(Map<String, dynamic> e) =>
      e.length == 13 &&
      WorkCollaborationState._only(e, {
        'taskId',
        'conversationId',
        'memberId',
        'scenarioId',
        'requestRevision',
        'teamRevision',
        'verificationRevision',
        'iterationId',
        'artifactDigest',
        'planDigest',
        'receiptRef',
        'feedbackRef',
        'status'
      }) &&
      [
        'taskId',
        'conversationId',
        'memberId',
        'scenarioId',
        'iterationId',
        'artifactDigest',
        'receiptRef',
        'feedbackRef'
      ].every((k) => WorkCollaborationState._id(e[k])) &&
      RegExp(r'^usage:[a-f0-9]{24}$').hasMatch(e['receiptRef'] as String) &&
      e['planDigest'] is String &&
      RegExp(r'^[a-f0-9]{64}$').hasMatch(e['planDigest'] as String) &&
      ['requestRevision', 'teamRevision', 'verificationRevision']
          .every((k) => WorkCollaborationState._revision(e[k])) &&
      {'passed', 'failed', 'blocked'}.contains(e['status']);

  static bool _validRuling(Map<String, dynamic> d) =>
      d.length == 12 &&
      WorkCollaborationState._only(d, {
        'eventId',
        'coordinatorId',
        'kind',
        'subjectId',
        'requestRevision',
        'teamRevision',
        'verificationRevision',
        'iterationId',
        'artifactDigest',
        'opinionEventIds',
        'reason',
        'responseRef'
      }) &&
      ['eventId', 'coordinatorId', 'subjectId', 'responseRef']
          .every((k) => WorkCollaborationState._id(d[k])) &&
      {'plan', 'delivery'}.contains(d['kind']) &&
      ['requestRevision', 'teamRevision', 'verificationRevision']
          .every((k) => WorkCollaborationState._revision(d[k])) &&
      ['iterationId', 'artifactDigest']
          .every((k) => WorkCollaborationState._text(d[k], max: 128)) &&
      _strings(d['opinionEventIds'], ids: true) &&
      (d['opinionEventIds'] as List).toSet().length ==
          (d['opinionEventIds'] as List).length &&
      WorkCollaborationState._multilineText(d['reason']) &&
      (d['reason'] as String).trim().isNotEmpty;

  /// Hash the entire plan, so reassigning a scenario invalidates every receipt.
  String get usagePlanDigest {
    dynamic canonical(dynamic v) {
      if (v is Map) {
        final keys = v.keys.cast<String>().toList()..sort();
        return {for (final key in keys) key: canonical(v[key])};
      }
      return v is List ? v.map(canonical).toList() : v;
    }

    return sha256
        .convert(utf8.encode(jsonEncode(canonical({
          'taskId': taskId,
          'conversationId': conversationId,
          'requestRevision': requestRevision,
          'teamRevision': teamRevision,
          'scope': scope,
          'plan': plan,
          'artifactContract': artifactContract,
          'usageAssignments': usageAssignments,
        }))))
        .toString();
  }

  bool get singleMakerReady {
    if (!isAutonomous) return true;
    final owners = workItems.map((i) => i['ownerId']).toSet();
    if (owners.length != 1) return false;
    final role =
        team.where((m) => m['memberId'] == owners.single).firstOrNull?['role'];
    return artifactContract['type'] != 'software' ||
        {'development', 'developer', 'frontend'}.contains(role);
  }

  bool get usagePlanReady {
    if (!isAutonomous) return true;
    final members = participantIds.toSet();
    if (members.length != activeMembers.length ||
        !activeMembers.every(members.contains) ||
        usageAssignments.length != members.length ||
        !usageAssignments.every((a) =>
            members.contains(a['memberId']) &&
            a['requestRevision'] == requestRevision &&
            (a['acceptanceIds'] as List)
                .every((id) => acceptances.any((e) => e['id'] == id)))) {
      return false;
    }
    final scenarios = usageAssignments
        .map(
            (a) => jsonEncode([a['goal'], a['stepGoals'], a['expectedResult']]))
        .toSet();
    final covered =
        usageAssignments.expand((a) => a['acceptanceIds'] as List).toSet();
    return scenarios.length == members.length &&
        acceptances.every((a) => covered.contains(a['id']));
  }

  Map<String, dynamic>? currentUsageFor(String memberId) {
    final candidate = currentIteration;
    final assignment =
        usageAssignments.where((a) => a['memberId'] == memberId).firstOrNull;
    if (!usagePlanReady || candidate == null || assignment == null) return null;
    return usageEvidenceRefs
        .where((e) =>
            e['memberId'] == memberId &&
            e['taskId'] == taskId &&
            e['conversationId'] == conversationId &&
            e['scenarioId'] == assignment['scenarioId'] &&
            e['requestRevision'] == requestRevision &&
            e['teamRevision'] == teamRevision &&
            e['verificationRevision'] == verificationRevision &&
            e['iterationId'] == candidate['id'] &&
            e['artifactDigest'] == candidate['artifactDigest'] &&
            e['planDigest'] == usagePlanDigest &&
            e['status'] == 'passed')
        .lastOrNull;
  }

  bool get allMembersUsed =>
      !isAutonomous ||
      usagePlanReady && participantIds.every((m) => currentUsageFor(m) != null);

  Map<String, String> get confirmedMemberChoices {
    final choices = <String, String>{};
    for (final decision in decisions) {
      if (decision['kind'] != 'member' ||
          decision['status'] != 'answered' ||
          decision['answerKind'] != 'choice' ||
          (decision['responseRef'] as String).isEmpty) {
        continue;
      }
      final selected = (decision['options'] as List)
          .whereType<Map>()
          .where((o) =>
              o['label'] == decision['answer'] && o['id'] != 'human-review')
          .firstOrNull;
      if (selected != null) {
        choices[decision['targetId'] as String] = selected['id'] as String;
      }
    }
    return choices;
  }

  Map<String, dynamic> get confirmedParticipationPolicy {
    final choices = confirmedMemberChoices;
    final participants = participantIds.toList();
    for (final entry in choices.entries) {
      final index = participants.indexOf(entry.key);
      if (index >= 0) {
        participants[index] = entry.value;
      } else if (entry.key.startsWith('role:') &&
          !participants.contains(entry.value)) {
        participants.add(entry.value);
      }
    }
    return WorkCollaborationAutonomy.policyFor(participants.toSet());
  }

  Iterable<Map<String, dynamic>> get currentCoordinatorDecisions =>
      coordinatorDecisions.where((d) =>
          d['coordinatorId'] == coordinatorId &&
          d['requestRevision'] == requestRevision &&
          d['teamRevision'] == teamRevision &&
          (d['kind'] == 'plan' ||
              d['iterationId'] == currentIteration?['id'] &&
                  d['artifactDigest'] == currentIteration?['artifactDigest'] &&
                  d['verificationRevision'] == verificationRevision));

  bool opinionsSettled(String kind, String subject,
      {String iterationId = '', String digest = ''}) {
    final opinions = <Map<String, dynamic>>[];
    for (final member in participantIds) {
      final opinion = currentApprovals
          .where((a) =>
              a['memberId'] == member &&
              a['kind'] == kind &&
              a['subjectId'] == subject &&
              a['iterationId'] == iterationId &&
              a['artifactDigest'] == digest)
          .lastOrNull;
      if (opinion == null ||
          opinion['source'] != 'memberModel' ||
          kind == 'delivery' && currentUsageFor(member) == null) {
        return false;
      }
      opinions.add(opinion);
    }
    final ids = opinions.map((a) => a['eventId']).toSet();
    return coordinatorDecisions.any((d) =>
        d['kind'] == kind &&
        d['subjectId'] == subject &&
        d['coordinatorId'] == coordinatorId &&
        d['requestRevision'] == requestRevision &&
        d['teamRevision'] == teamRevision &&
        (kind == 'plan' || d['verificationRevision'] == verificationRevision) &&
        d['iterationId'] == iterationId &&
        d['artifactDigest'] == digest &&
        (d['opinionEventIds'] as List).length == ids.length &&
        (d['opinionEventIds'] as List).every(ids.contains));
  }
}
