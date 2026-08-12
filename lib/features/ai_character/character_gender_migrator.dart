import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_character/character_gender_inference.dart';
import 'package:chat_group/features/ai_character/character_gender_llm_inference.dart';
import 'package:chat_group/features/ai_character/character_gender_migration_support.dart';
import 'package:chat_group/features/ai_character/character_gender_migration_state.dart';
import 'package:chat_group/services/chat_api_service.dart';

/// Gives legacy characters one immutable gender value, once.
class CharacterGenderMigrator {
  static const migrationKey = 'character_gender_migration_v1';
  static const stateKey = 'character_gender_migration_v1_state';
  static const diagnosticKey = 'character_gender_migration_v1_diagnostic';
  static const llmPhaseTimeout = Duration(seconds: 5);
  static const apiRequestTimeout =
      CharacterGenderLlmInference.apiRequestTimeout;
  static const maxNameLength = CharacterGenderInference.maxNameLength;
  static const maxRoleLength = CharacterGenderInference.maxRoleLength;
  static const maxSystemPromptLength =
      CharacterGenderInference.maxSystemPromptLength;
  static const maxReplyLength = CharacterGenderInference.maxReplyLength;
  static const maxRecentReplies = CharacterGenderInference.maxRecentReplies;

  final DatabaseService db;
  final ChatApiService api;
  final ApiCredentialResolver credentials;
  final Future<void> Function(AICharacter character)? saveCharacter;
  final _sessionDecisions = <String, CharacterGender>{};
  final _sessionCompletedIds = <String>{};
  final _sessionCandidateIds = <String>{};
  final _sessionReasonCodes = <String>{};
  final _sessionReport = CharacterGenderMigrationReport();
  final _sessionSavedCharacterIds = <String>{};
  Completer<void>? _llmCancellation;
  List<AICharacter> _sessionCharacters = const [];
  Map<String, List<String>> _sessionReplies = const {};
  CharacterGenderMigrationState? _sessionState;
  bool _sessionCandidateIdsKnown = false;
  bool _remoteInferenceCancelled = false;
  late final CharacterGenderLlmInference _llmInference;

  CharacterGenderMigrator(
    this.db, {
    ChatApiService? api,
    ApiCredentialResolver? credentials,
    Duration? llmPhaseTimeout,
    this.saveCharacter,
  })  : api = api ?? ChatApiService(),
        credentials = credentials ?? SecureApiCredentialResolver() {
    _llmInference = CharacterGenderLlmInference(
      api: this.api,
      credentials: this.credentials,
      phaseTimeout: llmPhaseTimeout ?? CharacterGenderMigrator.llmPhaseTimeout,
    );
  }

  /// Cancels only the remote inference phase. The local fallback and durable
  /// character writes still finish before [migrate] completes.
  void cancel() {
    _remoteInferenceCancelled = true;
    final signal = _llmCancellation;
    if (signal != null && !signal.isCompleted) signal.complete();
    _llmInference.cancel();
  }

  Future<int> migrate() async {
    _resetSession();
    try {
      _sessionCharacters = db.aiCharacterBox.values.toList(growable: false);
      _sessionReplies = _readRepliesSafely(_sessionCharacters);
      return await _migrateSafely(_sessionCharacters, _sessionReplies);
    } on Object {
      final fallback = await _applySessionFallback();
      await writeCharacterGenderDiagnosticSafely(
        db,
        diagnosticKey: diagnosticKey,
        status: _reportStatus(fallback),
        characterCount: _sessionCharacterCount,
        remoteResolved: fallback.remoteResolved,
        localFallback: fallback.localFallback,
        saved: fallback.saved,
        saveFailures: fallback.saveFailures,
        stateSaveFailures: fallback.stateSaveFailures,
        reasonCodes: {
          ..._sessionReasonCodes,
          'storage_failure',
          'session_fallback',
        },
      );
      return 0;
    } finally {
      _llmCancellation = null;
    }
  }

  void _resetSession() {
    _remoteInferenceCancelled = false;
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
      character.gender = gender;
      if (state != null) {
        state.decisions[character.id] = gender;
        await _tryWriteFallbackState(state, report);
      }
      try {
        await _saveCharacter(character);
        if (_sessionSavedCharacterIds.add(character.id)) report.saved++;
        _sessionCompletedIds.add(character.id);
        if (state != null) {
          state.completedIds.add(character.id);
          state.decisions.remove(character.id);
          await _tryWriteFallbackState(state, report);
        }
      } on Object {
        report.saveFailures++;
        _sessionReasonCodes.add('character_save_failure');
      }
    }
    if (state != null &&
        state.candidateIds.every(state.completedIds.contains)) {
      try {
        await _completeMigration();
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
      return db.appSettingsBox.get(migrationKey) == true;
    } on Object {
      return false;
    }
  }

  Future<CharacterGenderMigrationState?> _prepareFallbackState() async {
    if (_sessionState != null) return _sessionState;
    try {
      return await _prepareState(_indexCharacters(_sessionCharacters));
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
    } on Object {
      _sessionReasonCodes.add('state_save_failure');
      report.stateSaveFailures++;
    }
  }

  Future<int> _migrateSafely(
    List<AICharacter> snapshot,
    Map<String, List<String>> replies,
  ) async {
    if (db.appSettingsBox.get(migrationKey) == true) return 0;

    final charactersById = _indexCharacters(snapshot);
    if (charactersById.isEmpty) return _completeEmptyMigration();

    final state = await _prepareState(charactersById);
    final pending = _pendingCharacters(state, charactersById);
    if (pending.isEmpty) return _completeWithoutPending(state);

    final needsInference = pending
        .where((character) => !state.decisions.containsKey(character.id))
        .toList(growable: false);
    final llm = await _inferWithLlm(needsInference, replies);
    final reasons = <String>{..._sessionReasonCodes, ...llm.reasonCodes};
    final report = await _persistPendingCharacters(
      state,
      pending,
      replies,
      llm,
      reasons,
    );

    if (state.candidateIds.every(state.completedIds.contains)) {
      try {
        await _completeMigration();
      } on Object {
        reasons.add('state_save_failure');
        report.stateSaveFailures++;
      }
      report.completed = _migrationIsLocked();
    }
    if (report.localFallback > 0 && reasons.isEmpty) {
      reasons.add('local_fallback');
    }
    await writeCharacterGenderDiagnosticSafely(
      db,
      diagnosticKey: diagnosticKey,
      status: _reportStatus(report),
      characterCount: state.candidateIds.length,
      remoteResolved: report.remoteResolved,
      localFallback: report.localFallback,
      saved: report.saved,
      saveFailures: report.saveFailures,
      stateSaveFailures: report.stateSaveFailures,
      batches: llm.batchCount,
      reasonCodes: reasons,
    );
    return report.saved;
  }

  Map<String, AICharacter> _indexCharacters(List<AICharacter> characters) => {
        for (final character in characters) character.id: character,
      };

  Future<int> _completeEmptyMigration() async {
    await db.appSettingsBox.put(migrationKey, true);
    await writeCharacterGenderDiagnosticSafely(
      db,
      diagnosticKey: diagnosticKey,
      status: 'completed',
      characterCount: 0,
    );
    return 0;
  }

  Future<CharacterGenderMigrationState> _prepareState(
    Map<String, AICharacter> charactersById,
  ) async {
    final state = await _loadOrCreateState(charactersById.keys.toSet());
    _sessionState = state;
    _sessionCandidateIdsKnown = true;
    _sessionCandidateIds
      ..clear()
      ..addAll(state.candidateIds);
    state.completedIds.addAll(
      state.candidateIds.difference(charactersById.keys.toSet()),
    );
    state.decisions.removeWhere(
      (id, _) => state.completedIds.contains(id),
    );
    _sessionCompletedIds
      ..clear()
      ..addAll(state.completedIds);
    _sessionDecisions
      ..clear()
      ..addAll(state.decisions);
    await _writeState(state);
    return state;
  }

  List<AICharacter> _pendingCharacters(
    CharacterGenderMigrationState state,
    Map<String, AICharacter> charactersById,
  ) =>
      state.candidateIds
          .where((id) => !state.completedIds.contains(id))
          .map((id) => charactersById[id])
          .whereType<AICharacter>()
          .toList(growable: false);

  Future<int> _completeWithoutPending(
    CharacterGenderMigrationState state,
  ) async {
    await _completeMigration();
    await writeCharacterGenderDiagnosticSafely(
      db,
      diagnosticKey: diagnosticKey,
      status: 'completed',
      characterCount: state.candidateIds.length,
    );
    return 0;
  }

  Future<CharacterGenderMigrationReport> _persistPendingCharacters(
    CharacterGenderMigrationState state,
    List<AICharacter> pending,
    Map<String, List<String>> replies,
    CharacterGenderLlmInferenceReport llm,
    Set<String> reasons,
  ) async {
    final report = _sessionReport;
    for (final character in pending) {
      final recovered = state.decisions[character.id];
      final remote = llm.genders[character.id];
      final gender = recovered ??
          remote ??
          CharacterGenderInference.inferLocally(
            character,
            replies[character.id] ?? const [],
          );
      if (recovered == null) {
        if (remote == null) {
          report.localFallback++;
        } else {
          report.remoteResolved++;
        }
      }

      CharacterGenderDecisionPersistenceResult result;
      try {
        result = await _persistDecision(state, character, gender);
      } on Object {
        result = (
          characterSaved: false,
          characterSaveFailed: false,
          stateSaveFailed: true,
        );
      }
      if (result.characterSaved &&
          _sessionSavedCharacterIds.add(character.id)) {
        report.saved++;
      }
      if (result.characterSaveFailed) {
        // A failed character write is retried from the persisted decision.
        report.saveFailures++;
        reasons.add('character_save_failure');
      }
      if (result.stateSaveFailed) {
        character.gender = _sessionDecisions[character.id] ?? gender;
        report.stateSaveFailures++;
        reasons.add('state_save_failure');
      }
    }
    return report;
  }

  Future<CharacterGenderDecisionPersistenceResult> _persistDecision(
    CharacterGenderMigrationState state,
    AICharacter character,
    CharacterGender gender,
  ) async {
    // Persist the decision before the character write so a restart does not
    // ask the LLM again if the process is killed between the two Hive writes.
    _sessionDecisions[character.id] = gender;
    state.decisions[character.id] = gender;
    try {
      await _writeState(state);
    } on Object {
      return (
        characterSaved: false,
        characterSaveFailed: false,
        stateSaveFailed: true,
      );
    }
    character.gender = gender;
    try {
      await _saveCharacter(character);
    } on Object {
      return (
        characterSaved: false,
        characterSaveFailed: true,
        stateSaveFailed: false,
      );
    }
    state.completedIds.add(character.id);
    _sessionCompletedIds.add(character.id);
    state.decisions.remove(character.id);
    try {
      await _writeState(state);
    } on Object {
      // The character is already durable; only the progress retry is needed.
      return (
        characterSaved: true,
        characterSaveFailed: false,
        stateSaveFailed: true,
      );
    }
    return (
      characterSaved: true,
      characterSaveFailed: false,
      stateSaveFailed: false,
    );
  }

  Future<void> _saveCharacter(AICharacter character) =>
      saveCharacter?.call(character) ??
      db.aiCharacterBox.put(character.id, character);

  Future<CharacterGenderMigrationState> _loadOrCreateState(
    Set<String> characterIds,
  ) async {
    final raw = db.appSettingsBox.get(stateKey);
    if (raw is Map) {
      final restored = CharacterGenderMigrationState.tryFromMap(raw);
      if (restored != null) return restored;
      _sessionReasonCodes.add('state_rebuilt');
    }
    final state = CharacterGenderMigrationState(candidateIds: characterIds);
    await _writeState(state);
    return state;
  }

  Future<void> _writeState(CharacterGenderMigrationState state) =>
      db.appSettingsBox.put(stateKey, state.toMap());

  Future<void> _completeMigration() async {
    await db.appSettingsBox.put(migrationKey, true);
    await db.appSettingsBox.delete(stateKey);
  }

  Future<CharacterGenderLlmInferenceReport> _inferWithLlm(
    List<AICharacter> characters,
    Map<String, List<String>> replies,
  ) async {
    return _llmInference.infer(
      characters,
      replies,
      configs: db.apiConfigBox.values,
      cancellation: _llmCancellation?.future,
      isCancelled: () => _remoteInferenceCancelled,
    );
  }

  static List<Map<String, dynamic>> buildInferenceEntries(
    List<AICharacter> characters,
    Iterable<Message> messages,
  ) =>
      CharacterGenderInference.buildInferenceEntries(characters, messages);

  static Map<String, CharacterGender> parseLlmResult(
    String raw, {
    required Set<String> knownCharacterIds,
  }) =>
      CharacterGenderInference.parseLlmResult(
        raw,
        knownCharacterIds: knownCharacterIds,
      );

  static CharacterGender inferLocally(
    AICharacter character,
    List<String> replies,
  ) =>
      CharacterGenderInference.inferLocally(character, replies);
}
