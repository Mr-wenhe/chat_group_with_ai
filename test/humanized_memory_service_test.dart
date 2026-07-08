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
}
