import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

AICharacter character(String id, String name, String role,
        {List<String> tags = const []}) =>
    AICharacter(
      id: id,
      name: name,
      avatar: name.substring(0, 1),
      age: 25,
      role: role,
      personalityTags: tags,
      systemPrompt: '你是$name',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

void main() {
  group('HumanizedChatOrchestrator.selectReplyIntents', () {
    test('mentioned character gets top priority', () {
      final alice = character('a', '阿月', '插画师');
      final bob = character('b', '小林', '程序员');

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'user',
            senderType: 'user',
            content: '@小林 你怎么看？',
            mentionedAiIds: ['b'],
            isMention: true,
          ),
        ],
        groupId: 'group-1',
        groupTheme: '日常聊天',
        userMessage: '@小林 你怎么看？',
        mentionedIds: ['b'],
        memories: const [],
        relationships: const [],
        isEligible: (_) => true,
        random: Random(1),
      );

      expect(intents, isNotEmpty);
      expect(intents.first.speakerId, 'b');
      expect(intents.first.action, ReplyAction.answer);
      expect(intents.first.reason, contains('mentioned'));
    });

    test('high friction makes challenge intent more likely', () {
      final alice = character('a', '阿月', '插画师');
      final bob = character('b', '小林', '程序员');
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        friction: 80,
        affinity: -20,
        recentMood: RelationshipMood.annoyed,
      );

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'b',
            senderType: 'ai',
            content: '这个想法太粗糙了。',
          ),
        ],
        groupId: 'group-1',
        groupTheme: '日常聊天',
        userMessage: null,
        mentionedIds: const [],
        memories: const [],
        relationships: [relation],
        isEligible: (c) => c.id == 'a',
        random: Random(2),
      );

      expect(intents, hasLength(1));
      expect(intents.first.speakerId, 'a');
      expect(intents.first.action, ReplyAction.challenge);
      expect(intents.first.toneHint, contains('带刺'));
    });

    test('warm relationship can produce comfort or agree intent', () {
      final alice = character('a', '阿月', '插画师');
      final bob = character('b', '小林', '程序员');
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        affinity: 70,
        trust: 60,
        familiarity: 80,
        recentMood: RelationshipMood.warm,
      );

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'b',
            senderType: 'ai',
            content: '我今天有点累。',
          ),
        ],
        groupId: 'group-1',
        groupTheme: '日常聊天',
        userMessage: null,
        mentionedIds: const [],
        memories: const [],
        relationships: [relation],
        isEligible: (c) => c.id == 'a',
        random: Random(3),
      );

      expect(intents, hasLength(1));
      expect(
        [ReplyAction.comfort, ReplyAction.agree, ReplyAction.askBack],
        contains(intents.first.action),
      );
    });

    test('per-character history callback excludes hidden messages from intent',
        () {
      final alice = character('a', '阿月', '插画师');
      final relation = RelationshipState(
        groupId: 'group-1',
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        affinity: 70,
        trust: 60,
        familiarity: 80,
        recentMood: RelationshipMood.warm,
      );

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'b',
            senderType: 'ai',
            content: '只给小林看的内容',
            visibleToCharacterIds: const ['b'],
          ),
        ],
        recentMessagesForCharacter: (_) => const [],
        groupId: 'group-1',
        groupTheme: '日常聊天',
        userMessage: null,
        mentionedIds: const [],
        memories: const [],
        relationships: [relation],
        isEligible: (_) => true,
        random: Random(3),
      );

      expect(intents, hasLength(1));
      expect(intents.single.targetId, isNull);
    });

    test('recent speaker receives cooldown penalty', () {
      final alice = character('a', '阿月', '插画师');
      final bob = character('b', '小林', '程序员');

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'a',
            senderType: 'ai',
            content: '我刚说了一大段。',
          ),
          Message(
            groupId: 'group-1',
            senderId: 'user',
            senderType: 'user',
            content: '还有谁想说？',
          ),
        ],
        groupId: 'group-1',
        groupTheme: '日常聊天',
        userMessage: '还有谁想说？',
        mentionedIds: const [],
        memories: const [],
        relationships: const [],
        isEligible: (_) => true,
        random: Random(4),
      );

      expect(intents, isNotEmpty);
      expect(intents.first.speakerId, 'b');
    });

    test('topic interest uses role, tags, and persona growth', () {
      final artist = character('a', '阿月', '插画师', tags: ['审美']);
      final engineer = character('b', '小林', '程序员', tags: ['后端']);
      final memory = CharacterMemory(
        groupId: 'group-1',
        characterId: 'a',
        personaGrowth: ['我最近对配色和构图特别较真'],
      );

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [artist, engineer],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'user',
            senderType: 'user',
            content: '这个海报配色怎么调？',
          ),
        ],
        groupId: 'group-1',
        groupTheme: '日常聊天',
        userMessage: '这个海报配色怎么调？',
        mentionedIds: const [],
        memories: [memory],
        relationships: const [],
        isEligible: (_) => true,
        random: Random(5),
      );

      expect(intents, isNotEmpty);
      expect(intents.first.speakerId, 'a');
      expect(intents.first.reason, contains('topic-interest'));
    });

    test('dating scene actively targets another character', () {
      final alice = character('a', '阿月', '插画师');
      final bob = character('b', '小林', '程序员');

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'b',
            senderType: 'ai',
            content: '我周末一般会去爬山。',
          ),
        ],
        groupId: 'group-1',
        groupTheme: '相亲群',
        userMessage: null,
        mentionedIds: const [],
        memories: const [],
        relationships: const [],
        isEligible: (c) => c.id == 'a',
        random: Random(6),
        isAutoChat: true,
      );

      expect(intents, hasLength(1));
      expect(intents.first.speakerId, 'a');
      expect(intents.first.targetId, 'b');
      expect(
        [ReplyAction.askBack, ReplyAction.callOut],
        contains(intents.first.action),
      );
      expect(intents.first.reason, contains('dating-approach'));
    });

    test('meeting scene also targets a member with scene-specific reason', () {
      final pm = character('a', '阿月', '产品经理');
      final engineer = character('b', '小林', '程序员');

      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [pm, engineer],
        recentMessages: [
          Message(
            groupId: 'group-1',
            senderId: 'b',
            senderType: 'ai',
            content: '接口今天可能联调不完。',
          ),
        ],
        groupId: 'group-1',
        groupTheme: '项目会议',
        userMessage: null,
        mentionedIds: const [],
        memories: const [],
        relationships: const [],
        isEligible: (c) => c.id == 'a',
        random: Random(7),
        isAutoChat: true,
      );

      expect(intents, hasLength(1));
      expect(intents.first.targetId, 'b');
      expect(intents.first.reason, contains('meeting-handoff'));
      expect(intents.first.toneHint, contains('会议现场感'));
    });
  });
}
