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

  /// 去除 LLM 输出中可能出现的 Markdown 代码块包裹。
  ///
  /// 支持 ```json … ```、``` … ``` 等常见格式；无包裹时原样返回。
  static String _stripCodeFence(String text) {
    // 匹配以 ``` 开头、可选 json 标记、任意内容、以 ``` 结尾的模式。
    final codeFence = RegExp(r'^```(?:json)?\s*\n?(.*?)\n?```\s*$', dotAll: true);
    final match = codeFence.firstMatch(text);
    if (match != null) return match.group(1)!.trim();
    // 也兼容 ```json 不带换行的紧凑格式。
    final compactFence = RegExp(r'^```(?:json)?(.+?)```\s*$', dotAll: true);
    final compactMatch = compactFence.firstMatch(text);
    if (compactMatch != null) return compactMatch.group(1)!.trim();
    return text;
  }

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

  /// 从 LLM 回复中解析分层记忆 JSON。
  ///
  /// 兼容 LLM 输出被 Markdown 代码块包裹的情况（```json ... ``` 或 ``` ... ```），
  /// 不同模型行为不同，部分模型倾向于输出带 fence 的 JSON。
  static LayeredMemoryUpdate parseLayeredMemoryJson(String raw) {
    try {
      final text = _stripCodeFence(raw.trim());
      if (text.isEmpty) return const LayeredMemoryUpdate();
      final decoded = jsonDecode(text);
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
    LayeredMemoryUpdate update, {
    LayeredMemoryUpdate retained = const LayeredMemoryUpdate(),
  }) {
    memory.facts = _mergeLayer(
      memory.facts,
      update.facts,
      retained: retained.facts,
    );
    memory.relationshipNotes = _mergeLayer(
      memory.relationshipNotes,
      update.relationshipNotes,
      retained: retained.relationshipNotes,
    );
    memory.personaGrowth = _mergeLayer(
      memory.personaGrowth,
      update.personaGrowth,
      retained: retained.personaGrowth,
    );
    memory.lastUpdatedAt = DateTime.now();
  }

  /// 合并跨会话的角色长期记忆。
  ///
  /// [AICharacter.memorySummary] 是所有群聊和私聊都会注入的全局摘要，因此新一轮
  /// 记忆不能覆盖旧内容。这里解析现有分层文本、去重合并新内容并重新限制长度。
  static String mergeGlobalSummary({
    required String existing,
    required LayeredMemoryUpdate update,
    LayeredMemoryUpdate retained = const LayeredMemoryUpdate(),
    int maxChars = 900,
  }) {
    final current = _parseGlobalSummary(existing);
    final facts = _mergeLayer(
      current.facts,
      update.facts,
      retained: retained.facts,
    );
    final relationships = _mergeLayer(
      current.relationshipNotes,
      update.relationshipNotes,
      retained: retained.relationshipNotes,
    );
    final growth = _mergeLayer(
      current.personaGrowth,
      update.personaGrowth,
      retained: retained.personaGrowth,
    );
    final summaryFacts = _summaryLayer(facts, retained.facts, 6);
    final summaryRelationships =
        _summaryLayer(relationships, retained.relationshipNotes, 5);
    final summaryGrowth = _summaryLayer(growth, retained.personaGrowth, 5);
    String build() => [
          if (summaryFacts.isNotEmpty) '【事实】${summaryFacts.join('；')}',
          if (summaryRelationships.isNotEmpty)
            '【关系】${summaryRelationships.join('；')}',
          if (summaryGrowth.isNotEmpty) '【成长】${summaryGrowth.join('；')}',
        ].join('\n');

    var value = build();
    while (value.length > maxChars) {
      final removed = _removeOldestUnretained(summaryFacts, retained.facts) ||
          _removeOldestUnretained(
            summaryRelationships,
            retained.relationshipNotes,
          ) ||
          _removeOldestUnretained(summaryGrowth, retained.personaGrowth);
      if (!removed) break;
      value = build();
    }
    return value;
  }

  static LayeredMemoryUpdate _parseGlobalSummary(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const LayeredMemoryUpdate();
    List<String> layer(String label) {
      final match = RegExp('【$label】([^\\n]*)').firstMatch(text);
      if (match == null) return const [];
      return match
          .group(1)!
          .split('；')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList();
    }

    final facts = layer('事实');
    final relationships = layer('关系');
    final growth = layer('成长');
    if (facts.isEmpty && relationships.isEmpty && growth.isEmpty) {
      return LayeredMemoryUpdate(personaGrowth: [_clip(text)]);
    }
    return LayeredMemoryUpdate(
      facts: facts,
      relationshipNotes: relationships,
      personaGrowth: growth,
    );
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

  static List<String> _mergeLayer(
    List<String> existing,
    List<String> incoming, {
    List<String> retained = const [],
  }) {
    final result = <String>[];
    final retainedValues = retained.map((item) => _clip(item.trim())).toSet();
    for (final text in [...existing, ...retained, ...incoming]) {
      final clipped = _clip(text.trim());
      if (clipped.isEmpty) continue;
      result.remove(clipped);
      result.add(clipped);
    }
    while (result.length > maxLayerEntries) {
      if (!_removeOldestUnretained(result, retainedValues)) break;
    }
    return result;
  }

  static bool _removeOldestUnretained(
    List<String> values,
    Iterable<String> retained,
  ) {
    final retainedValues = retained.toSet();
    final index = values.indexWhere((item) => !retainedValues.contains(item));
    if (index < 0) return false;
    values.removeAt(index);
    return true;
  }

  static List<String> _summaryLayer(
    List<String> values,
    List<String> retained,
    int limit,
  ) {
    final result = values.toList();
    while (result.length > limit) {
      if (!_removeOldestUnretained(result, retained)) break;
    }
    return result;
  }

  static String _clip(String text) {
    if (text.length <= maxEntryChars) return text;
    return text.substring(0, maxEntryChars);
  }
}
