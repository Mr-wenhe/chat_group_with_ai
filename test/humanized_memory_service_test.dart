import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/humanized_memory_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Humanized memory models', () {
    test('CharacterMemory stores layered memory per group and character', () {
      final memory = CharacterMemory(
        groupId: 'group-1',
        characterId: 'char-1',
        facts: ['用户喜欢夜跑'],
        relationshipNotes: ['我对小林有点不服'],
        personaGrowth: ['我最近说话更爱反问'],
      );

      expect(memory.groupId, 'group-1');
      expect(memory.characterId, 'char-1');
      expect(memory.facts, ['用户喜欢夜跑']);
      expect(memory.relationshipNotes, ['我对小林有点不服']);
      expect(memory.personaGrowth, ['我最近说话更爱反问']);
      expect(memory.lastUpdatedAt, isA<DateTime>());
      expect(memory.createdAt, isA<DateTime>());
    });

    test('RelationshipState stores one directional relationship', () {
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'char-a',
        targetId: 'char-b',
        targetType: RelationshipTargetType.ai,
        affinity: 20,
        trust: 15,
        friction: 5,
        familiarity: 40,
        recentMood: RelationshipMood.warm,
        notes: '熟，但偶尔互怼',
      );

      expect(relation.groupId, 'group-1');
      expect(relation.sourceCharacterId, 'char-a');
      expect(relation.targetId, 'char-b');
      expect(relation.targetType, RelationshipTargetType.ai);
      expect(relation.affinity, 20);
      expect(relation.trust, 15);
      expect(relation.friction, 5);
      expect(relation.familiarity, 40);
      expect(relation.recentMood, RelationshipMood.warm);
      expect(relation.notes, '熟，但偶尔互怼');
    });

    test('legacy memorySummary seeds personaGrowth when new memory is empty',
        () {
      final character = AICharacter(
        name: '阿月',
        avatar: 'A',
        age: 24,
        role: '插画师',
        personalityTags: ['敏感'],
        systemPrompt: '说话轻一点',
        memorySummary: '我记得自己在这个群里慢慢开始敢开玩笑。',
        apiKey: 'k',
        apiProvider: 'deepseek',
      );

      final memory = HumanizedMemoryService.memoryForCharacter(
        groupId: 'group-1',
        character: character,
        existing: const [],
      );

      expect(memory.groupId, 'group-1');
      expect(memory.characterId, character.id);
      expect(memory.facts, isEmpty);
      expect(memory.relationshipNotes, isEmpty);
      expect(memory.personaGrowth, ['我记得自己在这个群里慢慢开始敢开玩笑。']);
    });

    test('RelationshipState clamps relationship score ranges', () {
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'char-a',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
        affinity: 300,
        trust: -300,
        friction: 300,
        familiarity: 300,
      );

      relation.clampScores();

      expect(relation.affinity, 100);
      expect(relation.trust, -100);
      expect(relation.friction, 100);
      expect(relation.familiarity, 100);
    });
  });

  group('HumanizedMemoryService relationship and JSON behavior', () {
    test('applyLocalRelationshipRules updates friction after challenge', () {
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        friction: 10,
        familiarity: 20,
      );

      final updated = HumanizedMemoryService.applyLocalRelationshipRules(
        relationships: [relation],
        groupId: 'group-1',
        speakerId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        actionName: 'challenge',
        friendlyTone: false,
      );

      expect(updated.single.friction, greaterThan(10));
      expect(updated.single.familiarity, greaterThan(20));
      expect(updated.single.recentMood, RelationshipMood.annoyed);
    });

    test('applyLocalRelationshipRules creates missing relation', () {
      final updated = HumanizedMemoryService.applyLocalRelationshipRules(
        relationships: const [],
        groupId: 'group-1',
        speakerId: 'a',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
        actionName: 'askBack',
        friendlyTone: true,
      );

      expect(updated, hasLength(1));
      expect(updated.single.targetType, RelationshipTargetType.user);
      expect(updated.single.affinity, greaterThan(0));
      expect(updated.single.familiarity, greaterThan(0));
    });

    test('parseLayeredMemoryJson returns clipped unique entries', () {
      final parsed = HumanizedMemoryService.parseLayeredMemoryJson('''
{
  "facts": ["用户喜欢夜跑", "用户喜欢夜跑", "这是一条非常非常非常非常非常非常非常非常非常非常非常非常非常非常非常非常长的事实"],
  "relationshipNotes": ["我对小林有点不服"],
  "personaGrowth": ["我最近爱用反问"],
  "discard": ["寒暄"]
}
''');

      expect(parsed.facts.length, 2);
      expect(parsed.facts.first, '用户喜欢夜跑');
      expect(parsed.relationshipNotes, ['我对小林有点不服']);
      expect(parsed.personaGrowth, ['我最近爱用反问']);
    });

    test('parseLayeredMemoryJson returns empty result for invalid JSON', () {
      final parsed = HumanizedMemoryService.parseLayeredMemoryJson('not json');

      expect(parsed.facts, isEmpty);
      expect(parsed.relationshipNotes, isEmpty);
      expect(parsed.personaGrowth, isEmpty);
    });

    test('mergeLayeredMemory keeps each layer bounded', () {
      final memory = CharacterMemory(
        groupId: 'group-1',
        characterId: 'a',
        facts: List.generate(12, (i) => '旧事实$i'),
        relationshipNotes: List.generate(12, (i) => '旧关系$i'),
        personaGrowth: List.generate(12, (i) => '旧成长$i'),
      );
      const parsed = LayeredMemoryUpdate(
        facts: ['新事实'],
        relationshipNotes: ['新关系'],
        personaGrowth: ['新成长'],
      );

      HumanizedMemoryService.mergeLayeredMemory(memory, parsed);

      expect(memory.facts.length, lessThanOrEqualTo(10));
      expect(memory.relationshipNotes.length, lessThanOrEqualTo(10));
      expect(memory.personaGrowth.length, lessThanOrEqualTo(10));
      expect(memory.facts.last, '新事实');
      expect(memory.relationshipNotes.last, '新关系');
      expect(memory.personaGrowth.last, '新成长');
    });
  });
}
