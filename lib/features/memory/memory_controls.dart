import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/chat_group/humanized_memory_service.dart';
import 'package:chat_group/features/memory/memory_conflict_resolver.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

enum CharacterMemoryLayer { facts, relationshipNotes, personaGrowth }

class MemoryPromptSelector {
  static String groupSummary(GroupMemory? memory) =>
      memory?.topicSummary.trim() ?? '';

  static String legacySummary(AICharacter character) =>
      character.memorySummary.trim();

  static CharacterMemory characterMemory({
    required String conversationId,
    required AICharacter character,
    required List<CharacterMemory> memories,
  }) {
    return HumanizedMemoryService.memoryForCharacter(
      groupId: conversationId,
      character: character,
      existing: memories,
    );
  }
}

class MemoryControls {
  static const _pinnedKey = 'memory_pinned_keys_v1';
  static final Expando<Future<void>> _editTails =
      Expando<Future<void>>('permanent-memory-edit-tail');

  final DatabaseService db;

  MemoryControls(this.db);

  static Future<void> _rejectLegacyWrite(String method) => Future.error(
        UnsupportedError(
          '$method 已退役；旧 CharacterMemory/AICharacter/RelationshipState '
          '仅保留用于兼容读取，请改用全局永久记忆或关系事件 API',
        ),
      );

  /// Test seam: when true, the second write in editPermanent's idempotent
  /// path throws, triggering compensation rollback.
  @visibleForTesting
  bool testFailExistingSupersedesWrite = false;

  /// Test seam: when true, the write that supersedes old in the matching
  /// active path throws, triggering rollback of the supersedesIds update.
  @visibleForTesting
  bool testFailOldSupersedeWrite = false;

  bool get automaticMemoryEnabled =>
      AiGovernanceStore.forDatabase(db).budgetSettings.summaryEnabled;

  Future<void> setAutomaticMemoryEnabled(bool enabled) {
    final store = AiGovernanceStore.forDatabase(db);
    return store.saveBudgetSettings(
      store.budgetSettings.copyWith(summaryEnabled: enabled),
    );
  }

  Set<String>? _pinnedCache;

  Set<String> get pinnedKeys {
    _pinnedCache ??= () {
      final raw = db.appSettingsBox.get(_pinnedKey);
      return raw is List ? raw.whereType<String>().toSet() : <String>{};
    }();
    return Set<String>.from(_pinnedCache!);
  }

  bool isPinned(String key) => pinnedKeys.contains(key);

  Future<void> setPinned(String key, bool pinned) async {
    final values = pinnedKeys;
    pinned ? values.add(key) : values.remove(key);
    _pinnedCache = null;
    await db.appSettingsBox.put(_pinnedKey, values.toList()..sort());
  }

  String groupKey(GroupMemory memory) =>
      'group:${memory.groupId}:${memory.key ?? 'current'}';

  String characterKey(CharacterMemory memory) => 'character:${memory.id}';

  String characterEntryKey(
    CharacterMemory memory,
    CharacterMemoryLayer layer,
    String value,
  ) =>
      '${characterKey(memory)}:${layer.name}:'
      '${sha256.convert(utf8.encode(value.trim()))}';

  String legacyKey(AICharacter character) => 'legacy:${character.id}';

  String relationshipKey(RelationshipState relationship) =>
      'relationship:${relationship.id}';

  bool canAutoUpdateGroup(GroupMemory? memory) =>
      automaticMemoryEnabled && (memory == null || !isPinned(groupKey(memory)));

  bool canAutoUpdateCharacter(
    CharacterMemory memory,
    AICharacter character,
  ) =>
      automaticMemoryEnabled &&
      !isPinned(characterKey(memory)) &&
      !isPinned(legacyKey(character));

  bool canAutoUpdateRelationship(RelationshipState relationship) =>
      automaticMemoryEnabled && !isPinned(relationshipKey(relationship));

  LayeredMemoryUpdate pinnedCharacterEntries(CharacterMemory memory) =>
      LayeredMemoryUpdate(
        facts: _pinnedLayer(memory, CharacterMemoryLayer.facts),
        relationshipNotes:
            _pinnedLayer(memory, CharacterMemoryLayer.relationshipNotes),
        personaGrowth: _pinnedLayer(memory, CharacterMemoryLayer.personaGrowth),
      );

  void mergeAutomaticCharacterMemory(
    CharacterMemory memory,
    LayeredMemoryUpdate update,
  ) {
    HumanizedMemoryService.mergeLayeredMemory(
      memory,
      update,
      retained: pinnedCharacterEntries(memory),
    );
  }

  String mergeAutomaticGlobalSummary({
    required AICharacter character,
    required CharacterMemory memory,
    required LayeredMemoryUpdate update,
  }) =>
      HumanizedMemoryService.mergeGlobalSummary(
        existing: character.memorySummary,
        update: update,
        retained: pinnedCharacterEntries(memory),
      );

  Future<void> updateGroup(GroupMemory memory, String value) async {
    memory
      ..topicSummary = value.trim()
      ..lastSummaryAt = DateTime.now();
    await db.groupMemoryBox.put(memory.key, memory);
  }

  Future<void> deleteGroup(GroupMemory memory) async {
    await updateGroup(memory, '');
    await setPinned(groupKey(memory), false);
  }

  @Deprecated('旧 CharacterMemory 已只读；请使用永久记忆审计 API')
  Future<void> updateCharacterEntry({
    required CharacterMemory memory,
    required AICharacter character,
    required CharacterMemoryLayer layer,
    required int index,
    required String value,
  }) =>
      _rejectLegacyWrite('updateCharacterEntry');

  @Deprecated('旧 CharacterMemory 已只读；请使用永久记忆审计 API')
  Future<void> deleteCharacterEntry({
    required CharacterMemory memory,
    required AICharacter character,
    required CharacterMemoryLayer layer,
    required int index,
  }) =>
      _rejectLegacyWrite('deleteCharacterEntry');

  @Deprecated('memorySummary 已只读；请使用永久记忆审计 API')
  Future<void> updateLegacy(AICharacter character, String value) =>
      _rejectLegacyWrite('updateLegacy');

  @Deprecated('memorySummary 已只读；请使用永久记忆审计 API')
  Future<void> deleteLegacy(AICharacter character) =>
      _rejectLegacyWrite('deleteLegacy');

  @Deprecated('旧 RelationshipState 已只读；请使用 RelationshipControls')
  Future<void> deleteRelationship(RelationshipState relationship) =>
      _rejectLegacyWrite('deleteRelationship');

  // ── Permanent memory ──────────────────────────────────────────────────────

  /// Resolve the actual Hive box key for [memory].
  ///
  /// Resolution order:
  /// 1. If [memory.key] is non-null and the box contains a record at that key
  ///    whose id matches [memory.id], use [memory.key] (stable migrator key).
  /// 2. If the box contains a record at [memory.id] whose value's id matches,
  ///    use [memory.id].
  /// 3. Scan all box entries for a record whose value.id matches [memory.id],
  ///    return that entry's actual key.
  /// 4. Throw [StateError] — never silently succeed with a wrong key.
  dynamic _resolvePermanentKey(PermanentMemory memory) {
    final box = db.permanentMemoryBox;
    final key = memory.key;
    if (key != null && box.get(key)?.id == memory.id) return key;
    if (box.get(memory.id)?.id == memory.id) return memory.id;
    for (final k in box.keys) {
      final value = box.get(k);
      if (value != null && value.id == memory.id) {
        return k;
      }
    }
    throw StateError('PermanentMemory not found in box: id=${memory.id}');
  }

  Future<void> pinPermanent(PermanentMemory memory) async {
    final key = _resolvePermanentKey(memory);
    final stored = db.permanentMemoryBox.get(key)!;
    await _writePermanent(key, stored, pinned: true);
  }

  Future<void> unpinPermanent(PermanentMemory memory) async {
    final key = _resolvePermanentKey(memory);
    final stored = db.permanentMemoryBox.get(key)!;
    await _writePermanent(key, stored, pinned: false);
  }

  /// Write [stored] back with [pinned] updated, preserving all other fields.
  Future<void> _writePermanent(
    dynamic key,
    PermanentMemory stored, {
    required bool pinned,
    MemoryStatus? status,
    DateTime? updatedAt,
    String? invalidationReason,
  }) async {
    final updated = PermanentMemory(
      id: stored.id,
      observerCharacterId: stored.observerCharacterId,
      kind: stored.kind,
      content: stored.content,
      subjectIds: List<String>.from(stored.subjectIds),
      status: status ?? stored.status,
      importance: stored.importance,
      confidence: stored.confidence,
      explicitlyRequested: stored.explicitlyRequested,
      pinned: pinned,
      supersedesIds: List<String>.from(stored.supersedesIds),
      originType: stored.originType,
      originConversationId: stored.originConversationId,
      originNameSnapshot: stored.originNameSnapshot,
      sourceMessageIds: List<String>.from(stored.sourceMessageIds),
      participantIds: List<String>.from(stored.participantIds),
      occurredAt: stored.occurredAt,
      createdAt: stored.createdAt,
      updatedAt: updatedAt ?? stored.updatedAt,
      invalidationReason: invalidationReason ?? stored.invalidationReason,
    );
    await db.permanentMemoryBox.put(key, updated);
  }

  /// Edit (correct) a permanent memory.
  ///
  /// Creates a new manual record and marks the original as superseded.
  ///
  /// **Idempotency rules:**
  /// 1. If [old] itself is already the desired manual correction, return it.
  /// 2. If another active record already supersedes [old] with the desired
  ///    content + subjects, supersede [old] if needed and return that record.
  /// 3. Never self-supersede: if [old] is not active, skip the supersede step.
  ///
  /// **Rollback:** both writes succeed or neither does — partial state is
  /// never left behind.
  Future<PermanentMemory> editPermanent(
    PermanentMemory old, {
    required String correctedContent,
    required List<String> subjectIds,
  }) async {
    // Multiple audit widgets may share one DatabaseService. Serialize the
    // read-check-write sequence per database so two identical saves cannot
    // both observe the same old active record and create duplicates.
    final previous = _editTails[db] ?? Future<void>.value();
    final release = Completer<void>();
    _editTails[db] = release.future;
    try {
      await previous;
      return await _editPermanentUnlocked(
        old,
        correctedContent: correctedContent,
        subjectIds: subjectIds,
      );
    } finally {
      release.complete();
    }
  }

  Future<PermanentMemory> _editPermanentUnlocked(
    PermanentMemory old, {
    required String correctedContent,
    required List<String> subjectIds,
  }) async {
    final now = DateTime.now();
    final normalizedContent = correctedContent.trim();
    final normalizedSubjects = _normalizedSubjectIds(subjectIds);

    // Fast path: [old] itself is already the desired manual correction.
    final oldKey = _resolvePermanentKey(old);
    final storedOld = db.permanentMemoryBox.get(oldKey)!;
    if (storedOld.id != old.id) {
      throw StateError(
          'Old record id mismatch: expected ${old.id}, got ${storedOld.id}');
    }
    if (storedOld.status == MemoryStatus.active &&
        storedOld.originType == MemoryOriginType.manual &&
        storedOld.content == normalizedContent &&
        _listsEqual(storedOld.subjectIds, normalizedSubjects)) {
      return storedOld;
    }

    // Idempotency: find an existing active record with same content+subjects.
    final existing = _findMatchingActive(
      observerCharacterId: old.observerCharacterId,
      kind: old.kind,
      content: normalizedContent,
      subjectIds: normalizedSubjects,
      excludeId: old.id,
    );
    if (existing != null) {
      // Save keys and raw snapshots before any writes.
      final existingKey = _resolvePermanentKey(existing);
      final rawExisting = db.permanentMemoryBox.get(existingKey)!;
      final oldKey = _resolvePermanentKey(old);
      final storedOld = db.permanentMemoryBox.get(oldKey)!;
      if (storedOld.id != old.id) {
        throw StateError(
            'Old record id mismatch: expected ${old.id}, got ${storedOld.id}');
      }
      final oldWasActive = storedOld.status == MemoryStatus.active;

      // Write 1 first: update existing.supersedesIds (this never mutates old).
      if (!rawExisting.supersedesIds.contains(old.id)) {
        final updatedExisting = PermanentMemory(
          id: rawExisting.id,
          observerCharacterId: rawExisting.observerCharacterId,
          kind: rawExisting.kind,
          content: rawExisting.content,
          subjectIds: List<String>.from(rawExisting.subjectIds),
          status: rawExisting.status,
          importance: rawExisting.importance,
          confidence: rawExisting.confidence,
          explicitlyRequested: rawExisting.explicitlyRequested,
          pinned: rawExisting.pinned,
          supersedesIds: List<String>.from(rawExisting.supersedesIds)
            ..add(old.id),
          originType: rawExisting.originType,
          originConversationId: rawExisting.originConversationId,
          originNameSnapshot: rawExisting.originNameSnapshot,
          sourceMessageIds: List<String>.from(rawExisting.sourceMessageIds),
          participantIds: List<String>.from(rawExisting.participantIds),
          occurredAt: rawExisting.occurredAt,
          createdAt: rawExisting.createdAt,
          updatedAt: now,
          invalidationReason: rawExisting.invalidationReason,
        );
        try {
          if (testFailExistingSupersedesWrite) {
            testFailExistingSupersedesWrite = false;
            throw Exception('Test-induced second-write failure');
          }
          await db.permanentMemoryBox.put(existingKey, updatedExisting);
        } on Object {
          // Write 1 failed: old is untouched, just propagate.
          rethrow;
        }
      }

      // Write 2: supersede old only after existing is confirmed updated.
      if (oldWasActive) {
        try {
          if (testFailOldSupersedeWrite) {
            testFailOldSupersedeWrite = false;
            throw Exception('Test-induced Write-2 failure');
          }
          await _writePermanent(
            oldKey,
            storedOld,
            pinned: storedOld.pinned,
            status: MemoryStatus.superseded,
            updatedAt: now,
          );
        } on Object {
          // Rollback Write 1: remove old.id from existing.supersedesIds.
          final rollbackExisting = PermanentMemory(
            id: rawExisting.id,
            observerCharacterId: rawExisting.observerCharacterId,
            kind: rawExisting.kind,
            content: rawExisting.content,
            subjectIds: List<String>.from(rawExisting.subjectIds),
            status: rawExisting.status,
            importance: rawExisting.importance,
            confidence: rawExisting.confidence,
            explicitlyRequested: rawExisting.explicitlyRequested,
            pinned: rawExisting.pinned,
            supersedesIds: List<String>.from(rawExisting.supersedesIds),
            originType: rawExisting.originType,
            originConversationId: rawExisting.originConversationId,
            originNameSnapshot: rawExisting.originNameSnapshot,
            sourceMessageIds: List<String>.from(rawExisting.sourceMessageIds),
            participantIds: List<String>.from(rawExisting.participantIds),
            occurredAt: rawExisting.occurredAt,
            createdAt: rawExisting.createdAt,
            updatedAt: rawExisting.updatedAt,
            invalidationReason: rawExisting.invalidationReason,
          );
          await db.permanentMemoryBox.put(existingKey, rollbackExisting);
          rethrow;
        }
      }
      return db.permanentMemoryBox.get(existingKey)!;
    }

    // Also check if [old] is already superseded and a different correction
    // is active with the same content/subjects — avoid creating a duplicate.
    if (storedOld.status != MemoryStatus.active) {
      final duplicateCorrection = _findActiveSuperseding(
        observerCharacterId: old.observerCharacterId,
        kind: old.kind,
        content: normalizedContent,
        subjectIds: normalizedSubjects,
        supersedesAny: true,
      );
      if (duplicateCorrection != null) {
        return duplicateCorrection;
      }
    }

    final replacement = PermanentMemory(
      id: const Uuid().v4(),
      observerCharacterId: old.observerCharacterId,
      kind: old.kind,
      content: normalizedContent,
      subjectIds: normalizedSubjects,
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: old.originNameSnapshot,
      confidence: 1.0,
      explicitlyRequested: false,
      pinned: false,
      supersedesIds: [old.id],
      originConversationId: null,
      sourceMessageIds: const [],
      participantIds: const [],
      occurredAt: old.occurredAt,
      createdAt: now,
      updatedAt: now,
      invalidationReason: null,
    );

    await db.permanentMemoryBox.put(replacement.id, replacement);

    try {
      await _writePermanent(
        oldKey,
        storedOld,
        pinned: storedOld.pinned,
        status: MemoryStatus.superseded,
        updatedAt: now,
      );
    } on Object {
      await db.permanentMemoryBox.delete(replacement.id);
      rethrow;
    }

    return replacement;
  }

  /// Find an active record superseding [supersedesOldId] with matching
  /// content + subjects.
  ///
  /// If [supersedesAny] is true, match any active record with the given
  /// content + subjects regardless of which IDs it supersedes.
  PermanentMemory? _findActiveSuperseding({
    required String observerCharacterId,
    required MemoryKind kind,
    required String content,
    required List<String> subjectIds,
    String? supersedesOldId,
    bool supersedesAny = false,
  }) {
    for (final m in db.permanentMemoryBox.values) {
      if (m.observerCharacterId != observerCharacterId) continue;
      if (m.kind != kind) continue;
      if (m.status != MemoryStatus.active) continue;
      if (m.content != content) continue;
      if (!_listsEqual(m.subjectIds, subjectIds)) continue;
      // Never match the old record itself.
      if (m.id == supersedesOldId) continue;
      if (supersedesAny) return m;
      if (m.supersedesIds.contains(supersedesOldId)) return m;
    }
    return null;
  }

  /// Find an active record matching content+subjects+kind+observer, excluding
  /// [excludeId]. Does NOT require supersedesIds match.
  PermanentMemory? _findMatchingActive({
    required String observerCharacterId,
    required MemoryKind kind,
    required String content,
    required List<String> subjectIds,
    String? excludeId,
  }) {
    for (final m in db.permanentMemoryBox.values) {
      if (m.observerCharacterId != observerCharacterId) continue;
      if (m.kind != kind) continue;
      if (m.status != MemoryStatus.active) continue;
      if (m.content != content) continue;
      if (!_listsEqual(m.subjectIds, subjectIds)) continue;
      if (m.id == excludeId) continue;
      return m;
    }
    return null;
  }

  Future<void> deletePermanent(PermanentMemory memory) async {
    final key = _resolvePermanentKey(memory);
    await db.permanentMemoryBox.delete(key);
  }

  int supersededByCount(String memoryId) => db.permanentMemoryBox.values
      .where((m) =>
          m.status == MemoryStatus.active && m.supersedesIds.contains(memoryId))
      .length;

  static List<String> _normalizedSubjectIds(List<String> ids) {
    return ids.map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().toList();
  }

  static bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @Deprecated('旧 RelationshipState 已只读；请使用 RelationshipControls')
  Future<void> updateRelationship(
    RelationshipState relationship,
    String notes,
  ) =>
      _rejectLegacyWrite('updateRelationship');

  Future<void> forgetTopic(String conversationId) async {
    for (final memory in db.groupMemoryBox.values
        .where((item) => item.groupId == conversationId)) {
      await deleteGroup(memory);
    }
  }

  @Deprecated('旧会话记忆已只读；仅失效对应来源的永久记忆')
  Future<void> forgetAboutUser(String conversationId) async {
    final memories = db.permanentMemoryBox.values
        .where(
          (memory) =>
              memory.status == MemoryStatus.active &&
              memory.originConversationId == conversationId &&
              memory.subjectIds.contains('user'),
        )
        .toList(growable: false);
    final now = DateTime.now();
    for (final memory in memories) {
      final key = _resolvePermanentKey(memory);
      await _writePermanent(
        key,
        memory,
        pinned: memory.pinned,
        status: MemoryStatus.invalidated,
        updatedAt: now,
        invalidationReason: MemoryConflictResolver.userForgetReason,
      );
    }
  }

  static List<String> _layer(
    CharacterMemory memory,
    CharacterMemoryLayer layer,
  ) =>
      switch (layer) {
        CharacterMemoryLayer.facts => memory.facts,
        CharacterMemoryLayer.relationshipNotes => memory.relationshipNotes,
        CharacterMemoryLayer.personaGrowth => memory.personaGrowth,
      };

  List<String> _pinnedLayer(
    CharacterMemory memory,
    CharacterMemoryLayer layer,
  ) =>
      _layer(memory, layer)
          .where((value) => isPinned(characterEntryKey(memory, layer, value)))
          .toList(growable: false);
}
