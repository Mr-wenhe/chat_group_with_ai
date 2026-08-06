import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/chat_group/humanized_memory_service.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:crypto/crypto.dart';

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

/// Mutates the existing Hive models and stores only control metadata in
/// app_settings, avoiding a model migration for the first memory-management UI.
class MemoryControls {
  static const _pinnedKey = 'memory_pinned_keys_v1';

  final DatabaseService db;

  MemoryControls(this.db);

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
    _pinnedCache = null; // invalidate cache
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

  Future<void> updateCharacterEntry({
    required CharacterMemory memory,
    required AICharacter character,
    required CharacterMemoryLayer layer,
    required int index,
    required String value,
  }) async {
    final values = _layer(memory, layer);
    final previous = values[index];
    final previousKey = characterEntryKey(memory, layer, previous);
    final wasPinned = isPinned(previousKey);
    values[index] = value.trim();
    values.removeWhere((item) => item.isEmpty);
    memory.lastUpdatedAt = DateTime.now();
    character.memorySummary = _replaceLegacyEntry(
      character.memorySummary,
      layer,
      previous,
      value.trim(),
    );
    await db.characterMemoryBox.put(memory.id, memory);
    await db.aiCharacterBox.put(character.id, character);
    await setPinned(previousKey, false);
    if (wasPinned && value.trim().isNotEmpty) {
      await setPinned(characterEntryKey(memory, layer, value), true);
    }
  }

  Future<void> deleteCharacterEntry({
    required CharacterMemory memory,
    required AICharacter character,
    required CharacterMemoryLayer layer,
    required int index,
  }) async {
    final values = _layer(memory, layer);
    final previous = values.removeAt(index);
    final entryKey = characterEntryKey(memory, layer, previous);
    memory.lastUpdatedAt = DateTime.now();
    character.memorySummary = _replaceLegacyEntry(
      character.memorySummary,
      layer,
      previous,
      '',
    );
    await db.characterMemoryBox.put(memory.id, memory);
    await db.aiCharacterBox.put(character.id, character);
    await setPinned(entryKey, false);
  }

  Future<void> updateLegacy(AICharacter character, String value) async {
    character.memorySummary = value.trim();
    await db.aiCharacterBox.put(character.id, character);
  }

  Future<void> deleteLegacy(AICharacter character) async {
    await updateLegacy(character, '');
    await setPinned(legacyKey(character), false);
  }

  Future<void> deleteRelationship(RelationshipState relationship) async {
    await db.relationshipStateBox.delete(relationship.key ?? relationship.id);
    await setPinned(relationshipKey(relationship), false);
  }

  Future<void> pinPermanent(PermanentMemory memory) async {
    memory.pinned = true;
    await memory.save();
  }

  Future<void> unpinPermanent(PermanentMemory memory) async {
    memory.pinned = false;
    await memory.save();
  }

  Future<PermanentMemory> editPermanent(
    PermanentMemory old, {
    required String correctedContent,
    required List<String> subjectIds,
  }) async {
    // Idempotency: if an active record already exists with the same content + subjects, return it.
    final existing = db.permanentMemoryBox.values.any(
      (m) =>
          m.observerCharacterId == old.observerCharacterId &&
          m.kind == old.kind &&
          m.status == MemoryStatus.active &&
          m.content == correctedContent &&
          _listsEqual(m.subjectIds, subjectIds),
    );
    if (existing) {
      return db.permanentMemoryBox.values.firstWhere(
        (m) =>
            m.observerCharacterId == old.observerCharacterId &&
            m.kind == old.kind &&
            m.status == MemoryStatus.active &&
            m.content == correctedContent &&
            _listsEqual(m.subjectIds, subjectIds),
      );
    }

    final now = DateTime.now();
    final replacement = PermanentMemory(
      observerCharacterId: old.observerCharacterId,
      kind: old.kind,
      content: correctedContent.trim(),
      subjectIds: List<String>.from(subjectIds),
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: old.originNameSnapshot,
      confidence: 1.0,
      explicitlyRequested: false,
      supersedesIds: [old.id],
      occurredAt: old.occurredAt,
      createdAt: now,
      updatedAt: now,
    );
    await db.permanentMemoryBox.put(replacement.id, replacement);

    final superseded = PermanentMemory(
      observerCharacterId: old.observerCharacterId,
      kind: old.kind,
      content: old.content,
      subjectIds: List<String>.from(old.subjectIds),
      status: MemoryStatus.superseded,
      originType: old.originType,
      originNameSnapshot: old.originNameSnapshot,
      confidence: old.confidence,
      explicitlyRequested: old.explicitlyRequested,
      pinned: old.pinned,
      supersedesIds: List<String>.from(old.supersedesIds),
      occurredAt: old.occurredAt,
      createdAt: old.createdAt,
      updatedAt: now,
    );
    await db.permanentMemoryBox.put(old.id, superseded);

    return replacement;
  }

  Future<void> deletePermanent(PermanentMemory memory) async {
    await db.permanentMemoryBox.delete(memory.id);
  }

  int supersededByCount(String memoryId) =>
      db.permanentMemoryBox.values
          .where((m) => m.status == MemoryStatus.active && m.supersedesIds.contains(memoryId))
          .length;

  static bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> updateRelationship(
    RelationshipState relationship,
    String notes,
  ) async {
    relationship
      ..notes = notes.trim()
      ..lastInteractionAt = DateTime.now();
    await db.relationshipStateBox.put(relationship.id, relationship);
  }

  Future<void> forgetTopic(String conversationId) async {
    for (final memory in db.groupMemoryBox.values
        .where((item) => item.groupId == conversationId)) {
      await deleteGroup(memory);
    }
  }

  Future<void> forgetAboutUser(String conversationId) async {
    final memories = db.characterMemoryBox.values
        .where((item) => item.groupId == conversationId)
        .toList(growable: false);
    final characterIds = memories.map((item) => item.characterId).toSet();
    final directCharacterId = DirectChatSession.characterIdFrom(conversationId);
    if (directCharacterId != null) characterIds.add(directCharacterId);
    characterIds.addAll(
      db.chatGroupBox.get(conversationId)?.aiCharacterIds ?? const [],
    );
    for (final memory in memories) {
      final removedKeys = [
        for (final value in memory.facts)
          characterEntryKey(memory, CharacterMemoryLayer.facts, value),
        for (final value in memory.relationshipNotes)
          characterEntryKey(
            memory,
            CharacterMemoryLayer.relationshipNotes,
            value,
          ),
      ];
      memory
        ..facts = []
        ..relationshipNotes = []
        ..lastUpdatedAt = DateTime.now();
      await db.characterMemoryBox.put(memory.id, memory);
      await _removePinnedKeys(removedKeys);
    }
    for (final characterId in characterIds) {
      final character = db.aiCharacterBox.get(characterId);
      if (character == null) continue;
      await deleteLegacy(character);
    }
    final relationships = db.relationshipStateBox.values
        .where((item) =>
            item.groupId == conversationId &&
            item.targetType == RelationshipTargetType.user)
        .toList(growable: false);
    for (final relationship in relationships) {
      await deleteRelationship(relationship);
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

  Future<void> _removePinnedKeys(Iterable<String> keys) async {
    final values = pinnedKeys;
    values.removeAll(keys);
    _pinnedCache = null;
    await db.appSettingsBox.put(_pinnedKey, values.toList()..sort());
  }

  static String _replaceLegacyEntry(
    String summary,
    CharacterMemoryLayer layer,
    String previous,
    String replacement,
  ) {
    final label = switch (layer) {
      CharacterMemoryLayer.facts => '事实',
      CharacterMemoryLayer.relationshipNotes => '关系',
      CharacterMemoryLayer.personaGrowth => '成长',
    };
    return _replaceInTaggedLayer(summary, label, previous, replacement);
  }

  static String _replaceInTaggedLayer(
    String summary,
    String label,
    String previous,
    String replacement,
  ) {
    if (summary.trim() == previous.trim()) return replacement.trim();
    final pattern = RegExp('【$label】([^\\n]*)');
    return summary
        .replaceFirstMapped(pattern, (match) {
          final values = match
              .group(1)!
              .split('；')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList();
          final index = values.indexOf(previous.trim());
          if (index < 0) return match.group(0)!;
          if (replacement.trim().isEmpty) {
            values.removeAt(index);
          } else {
            values[index] = replacement.trim();
          }
          return values.isEmpty ? '' : '【$label】${values.join('；')}';
        })
        .replaceAll(RegExp(r'\n{2,}'), '\n')
        .trim();
  }
}
