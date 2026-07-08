import 'dart:convert';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';

class LayeredMemoryUpdate {
  final List<String> facts;
  final List<String> relationshipNotes;
  final List<String> personaGrowth;

  const LayeredMemoryUpdate({
    this.facts = const [],
    this.relationshipNotes = const [],
    this.personaGrowth = const [],
  });
}

class HumanizedMemoryService {
  static const int maxLayerEntries = 10;
  static const int maxEntryChars = 80;

  static CharacterMemory memoryForCharacter({
    required String groupId,
    required AICharacter character,
    required List<CharacterMemory> existing,
  }) {
    for (final memory in existing) {
      if (memory.groupId == groupId && memory.characterId == character.id) {
        return memory;
      }
    }

    final legacy = character.memorySummary.trim();
    return CharacterMemory(
      groupId: groupId,
      characterId: character.id,
      personaGrowth: legacy.isEmpty ? const [] : [_clip(legacy)],
    );
  }

  static List<RelationshipState> applyLocalRelationshipRules({
    required List<RelationshipState> relationships,
    required String groupId,
    required String speakerId,
    required String? targetId,
    required RelationshipTargetType targetType,
    required String actionName,
    required bool friendlyTone,
  }) {
    if (targetId == null || targetId.isEmpty) return relationships;

    final updated = relationships.toList();
    var index = updated.indexWhere((r) =>
        r.groupId == groupId &&
        r.sourceCharacterId == speakerId &&
        r.targetId == targetId);
    if (index == -1) {
      updated.add(RelationshipState(
        groupId: groupId,
        sourceCharacterId: speakerId,
        targetId: targetId,
        targetType: targetType,
      ));
      index = updated.length - 1;
    }

    final relation = updated[index];
    relation.familiarity += 6;
    relation.lastInteractionAt = DateTime.now();

    switch (actionName) {
      case 'challenge':
      case 'callOut':
        relation.friction += 12;
        relation.affinity -= 3;
        relation.recentMood = RelationshipMood.annoyed;
        break;
      case 'agree':
      case 'comfort':
        relation.affinity += 8;
        relation.trust += 6;
        relation.recentMood = RelationshipMood.warm;
        break;
      case 'askBack':
        relation.affinity += friendlyTone ? 5 : 1;
        relation.recentMood =
            friendlyTone ? RelationshipMood.warm : RelationshipMood.neutral;
        break;
      case 'joke':
        relation.affinity += friendlyTone ? 4 : 0;
        relation.friction += friendlyTone ? 0 : 4;
        relation.recentMood =
            friendlyTone ? RelationshipMood.warm : RelationshipMood.awkward;
        break;
      default:
        relation.familiarity += 2;
    }

    relation.clampScores();
    return updated;
  }

  static LayeredMemoryUpdate parseLayeredMemoryJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const LayeredMemoryUpdate();
      return LayeredMemoryUpdate(
        facts: _readLayer(decoded['facts']),
        relationshipNotes: _readLayer(decoded['relationshipNotes']),
        personaGrowth: _readLayer(decoded['personaGrowth']),
      );
    } catch (_) {
      return const LayeredMemoryUpdate();
    }
  }

  static void mergeLayeredMemory(
    CharacterMemory memory,
    LayeredMemoryUpdate update,
  ) {
    memory.facts = _mergeLayer(memory.facts, update.facts);
    memory.relationshipNotes =
        _mergeLayer(memory.relationshipNotes, update.relationshipNotes);
    memory.personaGrowth =
        _mergeLayer(memory.personaGrowth, update.personaGrowth);
    memory.lastUpdatedAt = DateTime.now();
  }

  static List<String> _readLayer(Object? raw) {
    if (raw is! List) return const [];
    final result = <String>[];
    for (final item in raw) {
      final text = _clip(item.toString().trim());
      if (text.isEmpty || result.contains(text)) continue;
      result.add(text);
    }
    return result.take(maxLayerEntries).toList();
  }

  static List<String> _mergeLayer(List<String> existing, List<String> incoming) {
    final result = <String>[];
    for (final text in [...existing, ...incoming]) {
      final clipped = _clip(text.trim());
      if (clipped.isEmpty) continue;
      result.remove(clipped);
      result.add(clipped);
    }
    if (result.length <= maxLayerEntries) return result;
    return result.sublist(result.length - maxLayerEntries);
  }

  static String _clip(String text) {
    if (text.length <= maxEntryChars) return text;
    return text.substring(0, maxEntryChars);
  }
}
