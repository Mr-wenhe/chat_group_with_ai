import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';

part 'work_discussion_state_metadata.dart';
part 'work_discussion_state_validation.dart';

/// Versioned, typed state for the group discussion and execution front gate.
///
/// This is intentionally a value object stored under AgentTask's existing
/// executionStateJson. It is not a second task model or a general workflow
/// engine. Unknown/malformed state must fail closed at the coordinator.
class WorkDiscussionState {
  static const int currentSchemaVersion = 1;
  static const String jsonKey = 'discussionState';

  /// Returns the current revision's scope only when its durable discussion
  /// contract still matches this task and conversation.
  static String currentRequestScope(AgentTask task) {
    final decoded = decodeExecutionState(task.executionStateJson);
    final state = decoded.state;
    if (!decoded.isValid ||
        state == null ||
        state.conversationId != task.groupId ||
        state.requestRevision <= 1) {
      return task.userRequest;
    }
    final contract = state.deliverableContract;
    final revision = contract?['requestRevision'];
    final scope = contract?['contentScope'];
    if (revision is! num ||
        revision.toInt() != state.requestRevision ||
        scope is! String ||
        scope.trim().isEmpty) {
      return task.userRequest;
    }
    return scope.trim();
  }

  /// Returns the newest follow-up portion of the durable request history.
  ///
  /// Follow-ups are intentionally appended for auditability. Stage routing
  /// must still judge only the newest stage; otherwise an earlier `QA-only`
  /// marker can incorrectly suppress a later developer repair.
  static String latestRequestScope(AgentTask task) {
    final queued = task.queuedUserRequests;
    if (queued.isNotEmpty && queued.last.trim().isNotEmpty) {
      return queued.last.trim();
    }
    final source = currentRequestScope(task).trim();
    if (source.isEmpty) return task.userRequest.trim();
    const markers = <String>[
      '用户补充要求：',
      '用户明确要求：',
      'User follow-up:',
    ];
    var markerIndex = -1;
    var markerLength = 0;
    for (final marker in markers) {
      final index = source.lastIndexOf(marker);
      if (index > markerIndex) {
        markerIndex = index;
        markerLength = marker.length;
      }
    }
    return markerIndex < 0
        ? source
        : source.substring(markerIndex + markerLength).trim();
  }

  /// Group work conversations use the discussion gate. A `dm:` conversation
  /// remains bound to one character even if an old checkpoint accidentally
  /// contains a group discussion extension.
  static bool requiresDiscussionForConversation(String conversationId) =>
      !conversationId.trim().startsWith('dm:');

  final int schemaVersion;
  final String conversationId;
  final String phase;
  final int requestRevision;
  final String? coordinatorId;
  final String? executorId;
  final List<String> candidateCharacterIds;
  final List<WorkDiscussionParticipant> participants;
  final int round;
  final int understandingPercent;
  final List<String> understandingEvidence;
  final List<String> openQuestions;
  final List<String> blockers;
  final Map<String, dynamic>? deliverableContract;
  final String decisionSummary;

  WorkDiscussionState({
    this.schemaVersion = currentSchemaVersion,
    required this.conversationId,
    required this.phase,
    required this.requestRevision,
    this.coordinatorId,
    this.executorId,
    Iterable<String> candidateCharacterIds = const [],
    Iterable<WorkDiscussionParticipant> participants = const [],
    this.round = 0,
    this.understandingPercent = 0,
    Iterable<String> understandingEvidence = const [],
    Iterable<String> openQuestions = const [],
    Iterable<String> blockers = const [],
    Map<String, dynamic>? deliverableContract,
    this.decisionSummary = '',
  })  : candidateCharacterIds = List.unmodifiable(candidateCharacterIds),
        participants = List.unmodifiable(participants),
        understandingEvidence = List.unmodifiable(understandingEvidence),
        openQuestions = List.unmodifiable(openQuestions),
        blockers = List.unmodifiable(blockers),
        deliverableContract = deliverableContract == null
            ? null
            : Map<String, dynamic>.unmodifiable(deliverableContract);

  /// Creates the durable state used immediately after S1 routing. No runner
  /// may start until a later discussion transition marks this state ready.
  factory WorkDiscussionState.initial({
    required String conversationId,
    int requestRevision = 1,
    String? coordinatorId,
    String? executorId,
    Iterable<String> candidateCharacterIds = const [],
    Iterable<String> participantCharacterIds = const [],
    Map<String, dynamic>? deliverableContract,
    Iterable<String> openQuestions = const [],
    Iterable<String> blockers = const [],
  }) {
    final executor = _nullableId(executorId);
    final candidates = _cleanIds(candidateCharacterIds);
    final participants = <WorkDiscussionParticipant>[
      for (final id in _cleanIds(participantCharacterIds))
        WorkDiscussionParticipant(characterId: id),
    ];
    final allBlockers = <String>{
      ..._cleanList(blockers, maximum: 256),
      'discussionRequired',
      if (executor == null) 'executorSelectionRequired',
    };
    return WorkDiscussionState(
      conversationId: conversationId.trim(),
      phase: executor == null
          ? WorkDiscussionPhase.awaitingExecutor
          : WorkDiscussionPhase.awaitingDiscussion,
      requestRevision: requestRevision,
      coordinatorId: _nullableId(coordinatorId),
      executorId: executor,
      candidateCharacterIds: candidates,
      participants: participants,
      openQuestions: _cleanList(openQuestions, maximum: 256),
      blockers: allBlockers.toList(growable: false),
      deliverableContract: _safeContract(deliverableContract),
    ).bounded();
  }

  bool get hasExecutor => _nullableId(executorId) != null;

  /// Only this exact state is eligible to cross into the execution runner.
  /// Approval, installation, and folder permissions remain separate gates.
  bool get isExecutionReady =>
      isWithinBounds &&
      conversationId.trim().isNotEmpty &&
      phase == WorkDiscussionPhase.ready &&
      requestRevision >= 1 &&
      hasExecutor &&
      candidateCharacterIds.contains(executorId) &&
      understandingPercent == 100 &&
      understandingEvidence.isNotEmpty &&
      openQuestions.isEmpty &&
      blockers.isEmpty &&
      _hasValidContractForExecution(
        deliverableContract,
        requestRevision,
        executorId,
      );

  /// Returns whether this in-memory value is already within the persisted
  /// state limits. Constructors used by S3 are trusted only after this check;
  /// silently clamping an invalid value before the gate could turn a forged
  /// transition (for example, 101% understanding) into an executable one.
  bool get isWithinBounds {
    if (schemaVersion != currentSchemaVersion ||
        !_boundedText(conversationId, maximum: 256, required: true) ||
        !_boundedText(phase, maximum: 64, required: true) ||
        !WorkDiscussionPhase.values.contains(phase) ||
        requestRevision < 1 ||
        requestRevision > 2147483647 ||
        round < 0 ||
        round > 100000 ||
        understandingPercent < 0 ||
        understandingPercent > 100 ||
        candidateCharacterIds.length > 64 ||
        participants.length > 64 ||
        candidateCharacterIds.toSet().length != candidateCharacterIds.length ||
        participants.map((item) => item.characterId).toSet().length !=
            participants.length ||
        understandingEvidence.length > 64 ||
        openQuestions.length > 64 ||
        blockers.length > 64 ||
        !_boundedNullableId(coordinatorId) ||
        !_boundedNullableId(executorId) ||
        !_boundedIds(candidateCharacterIds) ||
        !_boundedParticipants(participants) ||
        !_boundedStrings(understandingEvidence, maximum: 512) ||
        !_boundedStrings(openQuestions, maximum: 256) ||
        !_boundedStrings(blockers, maximum: 256) ||
        !_boundedText(decisionSummary, maximum: 1024) ||
        deliverableContract != null &&
            _strictContract(deliverableContract) == null) {
      return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'conversationId': conversationId,
        'phase': phase,
        'requestRevision': requestRevision,
        'coordinatorId': coordinatorId,
        'executorId': executorId,
        'candidateCharacterIds': candidateCharacterIds,
        'participants': participants.map((item) => item.toJson()).toList(),
        'round': round,
        'understandingPercent': understandingPercent,
        'understandingEvidence': understandingEvidence,
        'openQuestions': openQuestions,
        'blockers': blockers,
        'deliverableContract': deliverableContract,
        'decisionSummary': decisionSummary,
      };

  WorkDiscussionState bounded() => WorkDiscussionState(
        schemaVersion: schemaVersion,
        conversationId: _cleanText(conversationId, maximum: 256),
        phase: WorkDiscussionPhase.values.contains(phase)
            ? phase
            : WorkDiscussionPhase.blocked,
        requestRevision: requestRevision.clamp(0, 2147483647).toInt(),
        coordinatorId: _nullableId(coordinatorId),
        executorId: _nullableId(executorId),
        candidateCharacterIds: _cleanIds(candidateCharacterIds),
        participants: participants
            .map((item) => item.bounded())
            .where((item) => item.characterId.isNotEmpty)
            .take(64),
        round: round.clamp(0, 100000).toInt(),
        understandingPercent: understandingPercent.clamp(0, 100).toInt(),
        understandingEvidence: _cleanList(understandingEvidence, maximum: 512),
        openQuestions: _cleanList(openQuestions, maximum: 256),
        blockers: _cleanList(blockers, maximum: 256),
        deliverableContract: _safeContract(deliverableContract),
        decisionSummary: _cleanText(decisionSummary, maximum: 1024),
      );

  /// A compact form used in WorkContextSnapshot. The full value remains in
  /// executionStateJson; the summary only needs enough data to keep recovery
  /// and the execution gate authoritative after compression.
  WorkDiscussionState compactForContext({
    int candidateLimit = 32,
    int participantLimit = 16,
    int evidenceLimit = 4,
    int questionLimit = 8,
    int blockerLimit = 8,
    int textLimit = 128,
    int contractScopeLimit = 512,
  }) {
    final boundedCandidateLimit = candidateLimit.clamp(1, 32).toInt();
    final boundedParticipantLimit = participantLimit.clamp(0, 16).toInt();
    final boundedEvidenceLimit = evidenceLimit.clamp(0, 4).toInt();
    final boundedQuestionLimit = questionLimit.clamp(0, 8).toInt();
    final boundedBlockerLimit = blockerLimit.clamp(0, 8).toInt();
    final boundedTextLimit = textLimit.clamp(32, 128).toInt();
    final boundedContractScopeLimit = contractScopeLimit.clamp(32, 512).toInt();
    // A malformed in-memory value must never become executable merely because
    // context compression clipped it. Preserve only bounded diagnostics and
    // force a blocked phase when the source was already outside the state
    // contract.
    final source = isWithinBounds
        ? this
        : WorkDiscussionState(
            schemaVersion: currentSchemaVersion,
            conversationId: _cleanText(conversationId, maximum: 256),
            phase: WorkDiscussionPhase.blocked,
            requestRevision: requestRevision.clamp(1, 2147483647).toInt(),
            coordinatorId: _nullableId(coordinatorId),
            executorId: null,
            candidateCharacterIds: _cleanIds(candidateCharacterIds),
            participants: participants
                .map((item) => item.bounded())
                .where((item) => item.characterId.isNotEmpty)
                .take(64),
            round: round.clamp(0, 100000).toInt(),
            understandingPercent: understandingPercent.clamp(0, 100).toInt(),
            blockers: const ['discussionStateInvalid'],
            decisionSummary: _cleanText(decisionSummary, maximum: 1024),
          );
    return WorkDiscussionState(
      schemaVersion: source.schemaVersion,
      conversationId: _cleanText(source.conversationId, maximum: 256),
      phase: source.phase,
      requestRevision: source.requestRevision,
      coordinatorId: source.coordinatorId,
      executorId: source.executorId,
      candidateCharacterIds: _compactCandidateIds(
        source.candidateCharacterIds,
        requiredId: source.executorId,
        maximum: boundedCandidateLimit,
      ),
      participants: source.participants.take(boundedParticipantLimit).map(
            (item) => item.compactForContext(textLimit: boundedTextLimit),
          ),
      round: source.round,
      understandingPercent: source.understandingPercent,
      understandingEvidence:
          source.understandingEvidence.take(boundedEvidenceLimit).map(
                (item) => _cleanText(item, maximum: boundedTextLimit),
              ),
      openQuestions: source.openQuestions.take(boundedQuestionLimit).map(
            (item) => _cleanText(item, maximum: boundedTextLimit),
          ),
      blockers: source.blockers.take(boundedBlockerLimit).map(
            (item) => _cleanText(item, maximum: boundedTextLimit),
          ),
      deliverableContract: _compactContractForContext(
        source.deliverableContract,
        maximumContentScope: boundedContractScopeLimit,
      ),
      decisionSummary:
          _cleanText(source.decisionSummary, maximum: boundedTextLimit),
    ).bounded();
  }

  WorkDiscussionState copyWith({
    int? schemaVersion,
    String? conversationId,
    String? phase,
    int? requestRevision,
    String? coordinatorId,
    String? executorId,
    Iterable<String>? candidateCharacterIds,
    Iterable<WorkDiscussionParticipant>? participants,
    int? round,
    int? understandingPercent,
    Iterable<String>? understandingEvidence,
    Iterable<String>? openQuestions,
    Iterable<String>? blockers,
    Map<String, dynamic>? deliverableContract,
    bool clearDeliverableContract = false,
    bool clearCoordinatorId = false,
    bool clearExecutorId = false,
    String? decisionSummary,
  }) {
    return WorkDiscussionState(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      conversationId: conversationId ?? this.conversationId,
      phase: phase ?? this.phase,
      requestRevision: requestRevision ?? this.requestRevision,
      coordinatorId:
          clearCoordinatorId ? null : coordinatorId ?? this.coordinatorId,
      executorId: clearExecutorId ? null : executorId ?? this.executorId,
      candidateCharacterIds:
          candidateCharacterIds ?? this.candidateCharacterIds,
      participants: participants ?? this.participants,
      round: round ?? this.round,
      understandingPercent: understandingPercent ?? this.understandingPercent,
      understandingEvidence:
          understandingEvidence ?? this.understandingEvidence,
      openQuestions: openQuestions ?? this.openQuestions,
      blockers: blockers ?? this.blockers,
      deliverableContract: clearDeliverableContract
          ? null
          : deliverableContract ?? this.deliverableContract,
      decisionSummary: decisionSummary ?? this.decisionSummary,
    );
  }

  /// Returns a strict decoding result so a malformed marker cannot be
  /// mistaken for a legacy task with no discussion gate.
  static WorkDiscussionDecodeResult decodeExecutionState(String raw) {
    if (raw.trim().isEmpty) return const WorkDiscussionDecodeResult.absent();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || !decoded.containsKey(jsonKey)) {
        return const WorkDiscussionDecodeResult.absent();
      }
      final state = tryParse(decoded[jsonKey]);
      return state == null
          ? const WorkDiscussionDecodeResult.invalid('讨论状态格式无效')
          : WorkDiscussionDecodeResult.present(state);
    } on Object {
      return const WorkDiscussionDecodeResult.invalid('任务执行状态 JSON 无效');
    }
  }

  static WorkDiscussionState? fromExecutionState(String raw) =>
      decodeExecutionState(raw).state;

  static WorkDiscussionState? tryParse(Object? value) {
    try {
      if (value is! Map || value.keys.any((key) => key is! String)) {
        return null;
      }
      final raw = <String, dynamic>{
        for (final entry in value.entries) entry.key as String: entry.value,
      };
      final version = _wholeInt(raw['schemaVersion']);
      final conversationId = _strictText(
        raw['conversationId'],
        maximum: 256,
        required: true,
      );
      final phase = _strictText(
        raw['phase'],
        maximum: 64,
        required: true,
      );
      final revision = _wholeInt(raw['requestRevision'], maximum: 2147483647);
      final round = _wholeInt(raw['round'], maximum: 100000);
      final understanding =
          _wholeInt(raw['understandingPercent'], maximum: 100);
      if (version != currentSchemaVersion ||
          conversationId == null ||
          conversationId.isEmpty ||
          phase == null ||
          !WorkDiscussionPhase.values.contains(phase) ||
          revision == null ||
          revision < 1 ||
          round == null ||
          understanding == null) {
        return null;
      }
      final participantsValue = raw['participants'];
      if (participantsValue is! List) return null;
      final candidateValue = _strictStrings(
        raw['candidateCharacterIds'],
        maximumItemLength: 128,
      );
      final evidenceValue = _strictStrings(
        raw['understandingEvidence'],
        maximumItemLength: 512,
      );
      final openQuestionsValue = _strictStrings(
        raw['openQuestions'],
        maximumItemLength: 256,
      );
      final blockersValue = _strictStrings(
        raw['blockers'],
        maximumItemLength: 256,
      );
      // These fields are part of the gate contract. Treat an omitted field as
      // an invalid/legacy marker instead of silently turning it into an empty
      // list that could make a forged ready state executable.
      if (candidateValue == null ||
          evidenceValue == null ||
          openQuestionsValue == null ||
          blockersValue == null) {
        return null;
      }
      if (participantsValue.length > 64) return null;
      final rawParticipants = <WorkDiscussionParticipant>[];
      for (final item in participantsValue) {
        final participant = WorkDiscussionParticipant.tryParse(item);
        if (participant == null) return null;
        rawParticipants.add(participant);
      }
      final participants = rawParticipants.toList(growable: false);
      if (candidateValue.toSet().length != candidateValue.length ||
          participants.map((item) => item.characterId).toSet().length !=
              participants.length) {
        return null;
      }
      final contract = _strictContract(raw['deliverableContract']);
      if (raw['deliverableContract'] != null && contract == null) return null;
      final rawCoordinatorId = raw['coordinatorId'];
      final rawExecutorId = raw['executorId'];
      final coordinatorId = rawCoordinatorId == null
          ? null
          : _strictText(rawCoordinatorId, maximum: 128, required: true);
      final executorId = rawExecutorId == null
          ? null
          : _strictText(rawExecutorId, maximum: 128, required: true);
      if ((rawCoordinatorId != null && coordinatorId == null) ||
          (rawExecutorId != null && executorId == null)) {
        return null;
      }
      final decisionSummary = raw['decisionSummary'] == null
          ? ''
          : _strictText(raw['decisionSummary'], maximum: 1024);
      if (decisionSummary == null) return null;
      return WorkDiscussionState(
        schemaVersion: version!,
        conversationId: conversationId,
        phase: phase,
        requestRevision: revision,
        coordinatorId: coordinatorId,
        executorId: executorId,
        candidateCharacterIds: _cleanIds(candidateValue),
        participants: participants,
        round: round,
        understandingPercent: understanding,
        understandingEvidence: _cleanList(evidenceValue, maximum: 512),
        openQuestions: _cleanList(openQuestionsValue, maximum: 256),
        blockers: _cleanList(blockersValue, maximum: 256),
        deliverableContract: contract,
        decisionSummary: decisionSummary,
      ).bounded();
    } on Object {
      return null;
    }
  }

  /// Preserves existing approval/resource/attachment metadata while replacing
  /// only the typed discussion extension.
  static String mergeIntoExecutionState(
    String raw,
    WorkDiscussionState state,
  ) {
    if (!state.isWithinBounds) {
      throw StateError('讨论状态字段越界或未规范化，不能写入执行门禁。');
    }
    Map<String, dynamic> metadata = <String, dynamic>{};
    try {
      final decoded = raw.trim().isEmpty ? null : jsonDecode(raw);
      if (decoded is Map) metadata = Map<String, dynamic>.from(decoded);
    } on Object {
      // An invalid legacy payload cannot be trusted as metadata. The typed
      // state is still persisted so the coordinator fails closed safely.
    }
    metadata[jsonKey] = state.bounded().toJson();
    return jsonEncode(metadata);
  }
}
