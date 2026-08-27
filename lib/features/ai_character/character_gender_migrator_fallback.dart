part of 'character_gender_migrator.dart';

extension _CharacterGenderMigratorFallback on CharacterGenderMigrator {
  void _resetSession() {
    _remoteInferenceCancelled = false;
    _lateWritesFenced = false;
    _llmCancellation = Completer<void>();
    _sessionCharacters = const [];
    _sessionReplies = const {};
    _sessionState = null;
    _sessionCandidateIds.clear();
    _sessionDecisions.clear();
    _sessionCompletedIds.clear();
    _sessionReasonCodes.clear();
    _sessionReport
      ..remoteResolved = 0
      ..localFallback = 0
      ..saved = 0
      ..saveFailures = 0
      ..stateSaveFailures = 0
      ..completed = false;
    _sessionSavedCharacterIds.clear();
    _sessionCandidateIdsKnown = false;
  }

  Map<String, List<String>> _readRepliesSafely(
    List<AICharacter> characters,
  ) {
    try {
      return CharacterGenderInference.repliesByCharacter(
        characters,
        db.messageBox.values,
      );
    } on Object {
      _sessionReasonCodes.add('storage_failure');
      return {
        for (final character in characters) character.id: const <String>[],
      };
    }
  }

  int get _sessionCharacterCount => _sessionCandidateIdsKnown
      ? _sessionCandidateIds.length
      : _sessionCharacters.length;

  String _reportStatus(CharacterGenderMigrationReport report) =>
      report.completed && report.saveFailures == 0
          ? 'completed'
          : report.saved > 0
              ? 'partial'
              : 'failed';

  Future<CharacterGenderMigrationReport> _applySessionFallback() async {
    final report = _sessionReport;
    final state = await _prepareFallbackState();
    for (final character in _sessionCharacters) {
      if (character.hasKnownGender) continue;
      if (_sessionCandidateIdsKnown &&
          !_sessionCandidateIds.contains(character.id)) {
        continue;
      }
      if (_sessionCompletedIds.contains(character.id)) continue;
      final recovered = _sessionDecisions[character.id];
      final gender = recovered ??
          CharacterGenderInference.inferLocally(
            character,
            _sessionReplies[character.id] ?? const [],
          );
      if (recovered == null) report.localFallback++;
      _sessionDecisions[character.id] = gender;
      final resolvedCharacter = character.withGender(gender);
      if (state != null) {
        state.decisions[character.id] = gender;
        await _tryWriteFallbackState(state, report);
      }
      try {
        await _saveCharacter(resolvedCharacter);
        if (_sessionSavedCharacterIds.add(character.id)) report.saved++;
        _sessionCompletedIds.add(character.id);
        if (state != null) {
          state.completedIds.add(character.id);
          state.decisions.remove(character.id);
          await _tryWriteFallbackState(state, report);
        }
      } on StaleMigrationWrite {
        rethrow;
      } on Object {
        report.saveFailures++;
        _sessionReasonCodes.add('character_save_failure');
      }
    }
    if (state != null &&
        state.candidateIds.every(state.completedIds.contains)) {
      try {
        await _completeMigration();
      } on StaleMigrationWrite {
        rethrow;
      } on Object {
        _sessionReasonCodes.add('state_save_failure');
        report.stateSaveFailures++;
      }
      report.completed = _migrationIsLocked();
    }
    return report;
  }

  bool _migrationIsLocked() {
    try {
      return db.appSettingsBox.get(CharacterGenderMigrator.migrationKey) ==
          true;
    } on Object {
      return false;
    }
  }

  Future<CharacterGenderMigrationState?> _prepareFallbackState() async {
    if (_sessionState != null) return _sessionState;
    try {
      return await _prepareState(
        _indexCharacters(
          _sessionCharacters
              .where((character) => !character.hasKnownGender)
              .toList(growable: false),
        ),
      );
    } on StaleMigrationWrite {
      rethrow;
    } on Object {
      _sessionReasonCodes.add('state_save_failure');
      return _sessionState;
    }
  }

  Future<void> _tryWriteFallbackState(
    CharacterGenderMigrationState state,
    CharacterGenderMigrationReport report,
  ) async {
    try {
      await _writeState(state);
    } on StaleMigrationWrite {
      rethrow;
    } on Object {
      _sessionReasonCodes.add('state_save_failure');
      report.stateSaveFailures++;
    }
  }
}
