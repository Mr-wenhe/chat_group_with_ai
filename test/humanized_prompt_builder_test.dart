import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/humanized_prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HumanizedPromptBuilder', () {
    test('builds concrete humanized context without debug reason', () {
      final character = AICharacter(
        id: 'a',
        name: '阿月',
        avatar: 'A',
        age: 24,
        role: '插画师',
        personalityTags: ['敏感', '会接梗'],
        systemPrompt: '说话轻一点',
        apiKey: 'k',
        apiProvider: 'deepseek',
        gender: CharacterGender.female,
      );
      final target = AICharacter(
        id: 'b',
        name: '小林',
        avatar: 'B',
        age: 27,
        role: '程序员',
        personalityTags: ['较真'],
        systemPrompt: '说话直接',
        apiKey: 'k',
        apiProvider: 'deepseek',
      );
      final memory = CharacterMemory(
        groupId: 'group-1',
        characterId: 'a',
        facts: ['用户最近在准备一个海报'],
        relationshipNotes: ['我觉得小林说话有点冲，但观点有用'],
        personaGrowth: ['我最近习惯先开个小玩笑再认真说'],
      );
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        friction: 70,
        affinity: -10,
        notes: '互相不太服',
        recentMood: RelationshipMood.annoyed,
      );
      const intent = ReplyIntent(
        speakerId: 'a',
        action: ReplyAction.challenge,
        targetId: 'b',
        lengthHint: ReplyLengthHint.oneLiner,
        toneHint: '带刺、别太客气',
        reason: 'relationship-friction,debug-only',
      );

      final content = HumanizedPromptBuilder.buildIntentContext(
        character: character,
        groupName: '灵感群',
        groupTheme: '日常创作',
        ownerName: '老冯',
        intent: intent,
        memory: memory,
        relationships: [relation],
        charactersById: {'a': character, 'b': target},
      );

      expect(content, contains('你是阿月'));
      expect(content.split(character.rolePlaySystemPrompt).length - 1, 1);
      expect(content.split(character.promptIdentity).length - 1, 1);
      expect(content, contains(character.rolePlaySystemPrompt));
      expect(content, contains('性别女'));
      expect(content, contains('用户最近在准备一个海报'));
      expect(content, contains('我觉得小林说话有点冲'));
      expect(content, contains('互相不太服'));
      expect(content, contains('本轮动作：challenge'));
      expect(content, contains('一句话'));
      expect(content, contains('不要说自己是 AI'));
      expect(content, isNot(contains('debug-only')));
      expect(content, isNot(contains('relationship-friction')));
    });

    test('length hints are explicit', () {
      expect(
        HumanizedPromptBuilder.lengthInstruction(ReplyLengthHint.oneLiner),
        contains('25 个字'),
      );
      expect(
        HumanizedPromptBuilder.lengthInstruction(ReplyLengthHint.short),
        contains('1-2 句'),
      );
      expect(
        HumanizedPromptBuilder.lengthInstruction(ReplyLengthHint.normal),
        contains('2-4 句'),
      );
    });

    test('owner mention instruction allows occasional @me or owner mention',
        () {
      expect(
        HumanizedPromptBuilder.ownerMentionInstruction(''),
        allOf(
          contains('真人用户/群主叫「我」'),
          contains('用「@我」'),
          contains('但不要每条都@'),
        ),
      );
      expect(
        HumanizedPromptBuilder.ownerMentionInstruction('风野'),
        allOf(
          contains('真人用户/群主叫「风野」'),
          contains('用「@风野」'),
          contains('但不要每条都@'),
        ),
      );
    });

    test('dating context discourages resume-like professional replies', () {
      final alice = AICharacter(
        id: 'a',
        name: '阿月',
        avatar: 'A',
        age: 24,
        role: '插画师',
        personalityTags: ['敏感'],
        systemPrompt: '自然一点',
        apiKey: 'k',
        apiProvider: 'deepseek',
      );
      final bob = AICharacter(
        id: 'b',
        name: '小林',
        avatar: 'B',
        age: 27,
        role: '程序员',
        personalityTags: ['慢热'],
        systemPrompt: '自然一点',
        apiKey: 'k',
        apiProvider: 'deepseek',
      );
      const intent = ReplyIntent(
        speakerId: 'a',
        action: ReplyAction.askBack,
        targetId: 'b',
        lengthHint: ReplyLengthHint.short,
        toneHint: '相亲局真人感',
        reason: 'dating-approach',
      );

      final content = HumanizedPromptBuilder.buildIntentContext(
        character: alice,
        groupName: '相亲群',
        groupTheme: '相亲交友',
        ownerName: '老冯',
        intent: intent,
        memory: CharacterMemory(groupId: 'group-1', characterId: 'a'),
        relationships: const [],
        charactersById: {'a': alice, 'b': bob},
      );

      expect(content, contains('相亲/交友场景规则'));
      expect(content, contains('优先对 小林 说话'));
      expect(content, contains('不要排队报简历'));
      expect(content, contains('少用职业术语'));
      expect(content, contains('不要每次都先介绍自己'));
    });
  });
}
