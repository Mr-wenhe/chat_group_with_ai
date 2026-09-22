part of 'work_discussion_runner.dart';

extension _WorkDiscussionRunnerDecisions on WorkDiscussionRunner {
  Future<void> _finishBlocked(
    AgentTask task,
    WorkDiscussionState state,
    WorkTaskDiscussionStateSink updateState, {
    required String blocker,
    required String question,
    required WorkTaskCancellation cancellation,
    bool mentionOwner = false,
  }) async {
    if (cancellation.isCancelled) return;
    final group = database.chatGroupBox.get(task.groupId);
    if (group != null) {
      await _publish(
        task,
        group,
        '${mentionOwner ? '@${_ownerMentionName(group)} ' : ''}$question',
        isMention: mentionOwner,
        cancellation: cancellation,
      );
    }
    if (cancellation.isCancelled) return;
    await updateState(
      state.copyWith(
        phase: WorkDiscussionPhase.blocked,
        understandingPercent: state.understandingPercent.clamp(0, 99).toInt(),
        openQuestions: _unique(<String>[...state.openQuestions, question]),
        blockers: _discussionBlockers(
          <String>[...state.blockers, blocker],
          hasExecutor: state.executorId != null,
        ),
      ),
    );
  }

  String _ownerMentionName(ChatGroup group) {
    final fallback = group.ownerName.trim();
    return database.ownerNameFromProfile(
      fallback: fallback.isEmpty ? '我' : fallback,
    );
  }

  WorkDiscussionState _updateParticipant(
    WorkDiscussionState state,
    String characterId, {
    required String status,
    required String contribution,
  }) {
    final participants = <WorkDiscussionParticipant>[];
    var found = false;
    for (final item in state.participants) {
      if (item.characterId != characterId) {
        participants.add(item);
        continue;
      }
      found = true;
      participants.add(WorkDiscussionParticipant(
        characterId: characterId,
        status: status,
        contributionCount: item.contributionCount + 1,
        lastContribution: boundedDiscussionText(contribution, maximum: 512),
      ));
    }
    if (!found) {
      participants.add(WorkDiscussionParticipant(
        characterId: characterId,
        status: status,
        contributionCount: 1,
        lastContribution: boundedDiscussionText(contribution, maximum: 512),
      ));
    }
    return state.copyWith(participants: participants);
  }

  WorkDiscussionState _markParticipant(
    WorkDiscussionState state,
    String characterId, {
    required String status,
    required String contribution,
  }) {
    final participants = <WorkDiscussionParticipant>[];
    var found = false;
    for (final item in state.participants) {
      if (item.characterId != characterId) {
        participants.add(item);
        continue;
      }
      found = true;
      participants.add(WorkDiscussionParticipant(
        characterId: characterId,
        status: status,
        contributionCount: item.contributionCount,
        lastContribution: boundedDiscussionText(contribution, maximum: 512),
      ));
    }
    if (!found) {
      participants.add(WorkDiscussionParticipant(
        characterId: characterId,
        status: status,
        lastContribution: boundedDiscussionText(contribution, maximum: 512),
      ));
    }
    return state.copyWith(participants: participants);
  }

  List<WorkDiscussionParticipant> _ensureParticipants(
    WorkDiscussionState state,
    Iterable<String> ids,
  ) {
    final result = <WorkDiscussionParticipant>[...state.participants];
    final existing = result.map((item) => item.characterId).toSet();
    for (final id in ids) {
      if (existing.add(id)) {
        result.add(WorkDiscussionParticipant(characterId: id));
      }
    }
    return result.take(64).toList(growable: false);
  }

  String? _electedExecutor({
    required String? current,
    required Map<String, int> votes,
    required List<String> candidates,
  }) {
    if (current != null && candidates.contains(current)) return current;
    final ranked = candidates.where((id) => (votes[id] ?? 0) > 0).toList()
      ..sort((left, right) => (votes[right] ?? 0).compareTo(votes[left] ?? 0));
    if (ranked.isEmpty) {
      return candidates.length == 1 ? candidates.first : null;
    }
    final topVotes = votes[ranked.first] ?? 0;
    final tied = ranked.skip(1).any((id) => (votes[id] ?? 0) == topVotes);
    return tied ? null : ranked.first;
  }

  int _maxRounds(String request) {
    final normalized = request.trim();
    if (normalized.length > 700 ||
        RegExp(r'复杂|多模块|架构|集成|迁移|全面|跨端|系统', caseSensitive: false)
            .hasMatch(normalized)) {
      return 6;
    }
    if (normalized.length <= 180 &&
        !RegExp(r'并且|同时|以及|验收|测试|方案', caseSensitive: false)
            .hasMatch(normalized)) {
      return 2;
    }
    return 4;
  }

  int _safeUnderstandingPercent(
    int requested,
    Map<String, dynamic>? contract,
    List<String> questions,
    List<String> blockers, {
    required List<String> evidence,
    required String publicUpdate,
    required String? executorId,
  }) {
    final completeContract = _contractComplete(
      contract,
      executorId: executorId,
    );
    if (requested >= 100 &&
        (executorId == null ||
            questions.isNotEmpty ||
            blockers.isNotEmpty ||
            !completeContract ||
            _unique(evidence).length <
                WorkDiscussionRunner.minimumEvidenceItems ||
            publicUpdate.trim().isEmpty)) {
      return 99;
    }
    return requested.clamp(0, 100).toInt();
  }

  bool _contractComplete(
    Map<String, dynamic>? contract, {
    required String? executorId,
  }) {
    if (contract == null) return false;
    final type = contract['deliverableType'];
    final scope = contract['contentScope'];
    final format = contract['format'];
    final revision = contract['requestRevision'];
    final explicitExecutor = contract['explicitExecutorId'];
    if (type is! String ||
        type.trim().isEmpty ||
        revision is! num ||
        !revision.isFinite ||
        revision != revision.truncate() ||
        revision.toInt() < 1 ||
        explicitExecutor != null &&
            (explicitExecutor is! String ||
                explicitExecutor.trim() != executorId)) {
      return false;
    }
    // `location` is deliberately not required here. "unspecified" means the
    // artifact is delivered to the conversation's default workspace, which is
    // a legitimate target; requiring a concrete place would keep a perfectly
    // understood plan stuck at 99% and never let the group converge.
    return scope is String &&
        scope.trim().isNotEmpty &&
        format is String &&
        format.trim().isNotEmpty &&
        format != 'unspecified';
  }

  List<String> _discussionBlockers(List<String> blockers,
      {required bool hasExecutor}) {
    final result = List<String>.from(_unique(blockers))
      ..remove('discussionRequired')
      ..remove('executorSelectionRequired');
    if (!hasExecutor) {
      result.add('executorSelectionRequired');
    }
    return result;
  }

  String _missingSuffix(List<String> questions, List<String> blockers) {
    final values = <String>[...questions.take(3), ...blockers.take(2)];
    return values.isEmpty ? '' : '\n待解决：${values.join('；')}';
  }

  String _formatContractSuggestion(Map<String, dynamic>? patch) {
    if (patch == null || patch.isEmpty) return '';
    try {
      return boundedDiscussionText(jsonEncode(patch), maximum: 900);
    } on Object {
      return '';
    }
  }

  String? _discussionExtensionReason(String blocker) {
    if (!blocker.startsWith(WorkDiscussionRunner.discussionExtensionPrefix)) {
      return null;
    }
    return boundedDiscussionText(
      blocker.substring(WorkDiscussionRunner.discussionExtensionPrefix.length),
      maximum: 256,
    );
  }

  Map<String, dynamic> _mergeContract(
    Map<String, dynamic>? current,
    Map<String, dynamic> patch,
  ) {
    final merged = <String, dynamic>{if (current != null) ...current};
    for (final entry in patch.entries) {
      final key = entry.key;
      final existing = merged[key];
      // The S1 contract records the user's authoritative output request. A
      // discussion suggestion may fill an unspecified field, but it cannot
      // silently turn DOCX into Markdown, move a desktop deliverable, narrow
      // the requested scope, or replace an explicitly named executor.
      if (_contractFieldIsAuthoritative(key, existing)) continue;
      merged[key] = entry.value;
    }
    merged['requestRevision'] =
        current?['requestRevision'] ?? patch['requestRevision'] ?? 1;
    for (final key in const [
      'deliverableType',
      'format',
      'location',
      'contentScope',
      'revisionTarget',
    ]) {
      final value = merged[key];
      if (value is! String) merged[key] = '';
    }
    merged['explicitExecutorId'] = merged['explicitExecutorId'] is String
        ? merged['explicitExecutorId']
        : null;
    return merged;
  }

  Map<String, dynamic> _safeDiscussionContractPatch(
    Map<String, dynamic> patch, {
    required String? executorId,
    required Set<String> qualifiedExecutorIds,
  }) {
    final safe = Map<String, dynamic>.from(patch);
    final suggestedExecutor = safe['explicitExecutorId'];
    if (suggestedExecutor is String && suggestedExecutor.trim().isNotEmpty) {
      final normalized = suggestedExecutor.trim();
      // An executor suggestion is advisory. It can only describe the already
      // selected, locally-qualified owner; it must never poison the durable
      // contract with an arbitrary model-supplied ID while the group is still
      // electing a role.
      if (executorId == null ||
          normalized != executorId ||
          !qualifiedExecutorIds.contains(normalized)) {
        safe.remove('explicitExecutorId');
      }
    } else if (suggestedExecutor != null) {
      safe.remove('explicitExecutorId');
    }
    return safe;
  }

  bool _contractFieldIsAuthoritative(String key, Object? existing) {
    if (existing is! String || existing.trim().isEmpty) return false;
    if (key == 'explicitExecutorId' || key == 'contentScope') return true;
    return key == 'deliverableType' && existing != 'generic' ||
        (key == 'format' || key == 'location') && existing != 'unspecified' ||
        key == 'revisionTarget';
  }

  Iterable<String> _removeResolved(
    Iterable<String> current,
    Iterable<String> resolved,
  ) {
    final keys = resolved.map(_comparisonKey).where((key) => key.isNotEmpty);
    if (keys.isEmpty) return current;
    final result = <String>[];
    for (final value in current) {
      final key = _comparisonKey(value);
      if (_protectedBlocker(value) || !keys.contains(key)) {
        result.add(value);
      }
    }
    return result;
  }

  String _comparisonKey(String value) =>
      value.replaceAll(RegExp(r'\s+'), '').trim().toLowerCase();

  bool _protectedBlocker(String value) {
    if (WorkDiscussionRunner.userDecisionBlockers.contains(value)) return true;
    if (value.startsWith('structuredResponseInvalid:')) return true;
    return value == 'discussionRequired' ||
        value == 'executorSelectionRequired' ||
        value == 'routePending' ||
        value == 'discussionNotConverged' ||
        value == 'discussionRoundLimit' ||
        value == 'executorIdentityMismatch';
  }

  bool _hasProgressChange({
    required int previousPercent,
    required int nextPercent,
    required Iterable<String> previousEvidence,
    required Iterable<String> nextEvidence,
    required Iterable<String> previousQuestions,
    required Iterable<String> nextQuestions,
    required Iterable<String> previousBlockers,
    required Iterable<String> nextBlockers,
    required String publicUpdate,
    required Iterable<String> priorPublicResponses,
    required bool contractChanged,
  }) {
    if (nextPercent > previousPercent || contractChanged) return true;
    if (_unique(nextEvidence).length > _unique(previousEvidence).length ||
        !_sameStringSet(nextQuestions, previousQuestions) ||
        !_sameStringSet(nextBlockers, previousBlockers)) {
      return true;
    }
    final update = publicUpdate.trim();
    if (update.isEmpty) return false;
    final normalized = _comparisonKey(update);
    return !priorPublicResponses.any(
      (value) => _comparisonKey(value).contains(normalized),
    );
  }

  bool _sameStringSet(Iterable<String> left, Iterable<String> right) {
    final leftSet = _unique(left).map(_comparisonKey).toSet();
    final rightSet = _unique(right).map(_comparisonKey).toSet();
    return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
  }

  List<String> _unique(Iterable<String> values) => values
      .map((value) => WorkPublicUpdateStream.sanitize(value))
      .where((value) => value.isNotEmpty)
      .toSet()
      .take(32)
      .toList(growable: false);

  ApiConfig? _resolveApiConfig(AICharacter character) {
    final id = character.apiConfigId.trim();
    if (id.isNotEmpty) {
      final configured = database.apiConfigBox.get(id);
      if (configured != null) return configured;
    }
    for (final config in database.apiConfigBox.values) {
      if (config.provider == character.apiProvider &&
          config.modelName == character.modelName) {
        return config;
      }
    }
    return null;
  }

  ApiProvider _providerFor(ApiConfig config) => ApiProvider.values.firstWhere(
        (provider) => provider.name == config.provider,
        orElse: () => throw StateError('模型提供商配置无效。'),
      );
}
