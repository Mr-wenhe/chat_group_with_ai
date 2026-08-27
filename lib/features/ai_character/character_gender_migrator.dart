import 'dart:async';

import 'package:chat_group/core/database/database_mutation_gate.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_character/character_gender_inference.dart';
import 'package:chat_group/features/ai_character/character_gender_llm_inference.dart';
import 'package:chat_group/features/ai_character/character_gender_migration_support.dart';
import 'package:chat_group/features/ai_character/character_gender_migration_state.dart';
import 'package:chat_group/services/chat_api_service.dart';

part 'character_gender_migrator_fallback.dart';

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
  Completer<void>? _migrationCompletion;
  List<AICharacter> _sessionCharacters = const [];
  Map<String, List<String>> _sessionReplies = const {};
  CharacterGenderMigrationState? _sessionState;
  bool _sessionCandidateIdsKnown = false;
  bool _remoteInferenceCancelled = false;
  bool _lateWritesFenced = false;
  late int _migrationEpoch;
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

  /// Stops a timed-out local fallback from writing after startup has moved on.
  /// The write currently holding the shared gate is allowed to finish; later
  /// writes fail with [StaleMigrationWrite] and are retried next run.
  void fencePendingWrites() {
    _lateWritesFenced = true;
    try {
      _mutationGate.invalidate();
    } on Object {
      // The boolean fence remains effective when recovery has closed both
      // candidate boxes.
    }
  }

  /// Completes when a cancelled migration has finished its local fallback.
  ///
  /// Custom migrators used by tests or embedders may override [migrate]
  /// without participating in this signal; in that case there is no local
  /// drain to wait for and the returned future is already complete.
  Future<void> waitForCancellationDrain() =>
      _migrationCompletion?.future ?? Future<void>.value();

  Future<int> migrate() async {
    final completion = Completer<void>();
    _migrationCompletion = completion;
    _resetSession();
    _migrationEpoch = _mutationGate.epoch;
    try {
      _sessionCharacters = db.aiCharacterBox.values.toList(growable: false);
      _sessionReplies = _readRepliesSafely(_sessionCharacters);
      return await _migrateSafely(_sessionCharacters, _sessionReplies);
    } on StaleMigrationWrite {
      // A lifecycle operation or the startup timeout superseded this
      // snapshot. Do not apply a second fallback to records the user may
      // already have deleted or restored.
      return 0;
    } on Object {
      final fallback = await _applySessionFallback();
      await _writeDiagnostic(
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
      if (identical(_migrationCompletion, completion)) {
        _migrationCompletion = null;
      }
      if (!completion.isCompleted) completion.complete();
    }
  }

  Future<int> _migrateSafely(
    List<AICharacter> snapshot,
    Map<String, List<String>> replies,
  ) async {
    final locked = db.appSettingsBox.get(migrationKey) == true;
    final lockedBackfill = locked
        ? snapshot.where((character) => !character.hasKnownGender).toList()
        : const <AICharacter>[];
    if (lockedBackfill.isEmpty && locked) return 0;
    if (lockedBackfill.isNotEmpty) {
      await _prepareLockedGenderBackfill(lockedBackfill);
    }

    // Only legacy records are eligible for inference. A known gender is a
    // permanent user choice and must remain outside every migration retry,
    // including a rebuilt or stale progress state.
    final charactersById = _indexCharacters(
      snapshot.where((character) => !character.hasKnownGender).toList(
            growable: false,
          ),
    );
    if (charactersById.isEmpty) return _completeEmptyMigration();

    final state = await _prepareState(charactersById);
    final pending = _pendingCharacters(state, charactersById);
    if (pending.isEmpty) return _completeWithoutPending(state);

    final needsInference = pending
        .where((character) => !state.decisions.containsKey(character.id))
        .toList(growable: false);
    final llm = await _inferWithLlm(needsInference, replies);
    final reasons = <String>{
      ..._sessionReasonCodes,
      if (lockedBackfill.isNotEmpty) 'gender_metadata_backfill',
      ...llm.reasonCodes,
    };
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
    await _writeDiagnostic(
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
    await _runMigrationMutation(
      () => db.appSettingsBox.put(migrationKey, true),
    );
    await _writeDiagnostic(
      status: 'completed',
      characterCount: 0,
    );
    return 0;
  }

  Future<void> _prepareLockedGenderBackfill(
    List<AICharacter> characters,
  ) async {
    // Older completed migrations already resolved field 21 but predate the
    // known/unknown marker. Reuse that durable gender instead of re-inferring
    // it, then let the normal write path persist field 22.
    await _writeState(
      CharacterGenderMigrationState(
        candidateIds: {for (final character in characters) character.id},
        decisions: {
          for (final character in characters) character.id: character.gender,
        },
      ),
    );
    await _runMigrationMutation(
      () => db.appSettingsBox.put(migrationKey, false),
    );
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
    await _writeDiagnostic(
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
      } on StaleMigrationWrite {
        rethrow;
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
    } on StaleMigrationWrite {
      rethrow;
    } on Object {
      return (
        characterSaved: false,
        characterSaveFailed: false,
        stateSaveFailed: true,
      );
    }
    final resolvedCharacter = character.withGender(gender);
    try {
      await _saveCharacter(resolvedCharacter);
    } on StaleMigrationWrite {
      rethrow;
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
    } on StaleMigrationWrite {
      rethrow;
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

  Future<void> _saveCharacter(AICharacter character) => _runMigrationMutation(
        () =>
            saveCharacter?.call(character) ??
            db.aiCharacterBox.put(character.id, character),
      );

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
      _runMigrationMutation(
        () => db.appSettingsBox.put(stateKey, state.toMap()),
      );

  Future<void> _completeMigration() async {
    await _runMigrationMutation(() async {
      await db.appSettingsBox.put(migrationKey, true);
      await db.appSettingsBox.delete(stateKey);
    });
  }

  DatabaseMutationGate get _mutationGate {
    try {
      return DatabaseMutationGate.forBox(db.appSettingsBox);
    } on Object {
      // Some recovery paths intentionally close app_settings to exercise the
      // character fallback. Keep the character write fenced even there.
      return DatabaseMutationGate.forBox(db.aiCharacterBox);
    }
  }

  Future<T> _runMigrationMutation<T>(Future<T> Function() operation) =>
      _mutationGate.run(() async {
        if (_lateWritesFenced || !_mutationGate.isCurrent(_migrationEpoch)) {
          throw const StaleMigrationWrite();
        }
        return operation();
      });

  Future<void> _writeDiagnostic({
    required String status,
    required int characterCount,
    int remoteResolved = 0,
    int localFallback = 0,
    int saved = 0,
    int saveFailures = 0,
    int stateSaveFailures = 0,
    int batches = 0,
    Iterable<String> reasonCodes = const [],
  }) =>
      _runMigrationMutation(
        () => writeCharacterGenderDiagnosticSafely(
          db,
          diagnosticKey: diagnosticKey,
          status: status,
          characterCount: characterCount,
          remoteResolved: remoteResolved,
          localFallback: localFallback,
          saved: saved,
          saveFailures: saveFailures,
          stateSaveFailures: stateSaveFailures,
          batches: batches,
          reasonCodes: reasonCodes,
        ),
      );

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
          List<AICharacter> characters, Iterable<Message> messages) =>
      CharacterGenderInference.buildInferenceEntries(characters, messages);

  static Map<String, CharacterGender> parseLlmResult(String raw,
          {required Set<String> knownCharacterIds}) =>
      CharacterGenderInference.parseLlmResult(raw,
          knownCharacterIds: knownCharacterIds);

  static CharacterGender inferLocally(
          AICharacter character, List<String> replies) =>
      CharacterGenderInference.inferLocally(character, replies);
}
