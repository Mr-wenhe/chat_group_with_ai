import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/direct_chat/direct_chat_inbox.dart';
import 'package:chat_group/features/direct_chat/direct_chat_proactive_policy.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DirectChatProactivePolicy', () {
    test('selects a stale direct chat character before group-only candidates',
        () {
      final alice = _character(id: 'alice', name: '小夏');
      final bob = _character(id: 'bob', name: '阿哲');
      final now = DateTime(2026, 7, 8, 12);
      final aliceConversationId = DirectChatSession.conversationIdFor('alice');
      final summaries = DirectChatInbox.buildSummaries(
        characters: [alice, bob],
        messages: [
          Message(
            groupId: aliceConversationId,
            senderId: 'user',
            senderType: 'user',
            content: '晚点聊',
            timestamp: now.subtract(const Duration(hours: 7)),
          ),
        ],
        readAtByConversation: const {},
        sourceByConversation: const {},
      );

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: summaries,
        groupCharacters: [bob],
        recentGroupMessages: [
          Message(
            groupId: 'group_1',
            senderId: 'user',
            senderType: 'user',
            content: '群里刚聊完产品',
            timestamp: now.subtract(const Duration(minutes: 20)),
          ),
        ],
        lastProactiveAtByCharacter: const {},
        now: now,
      );

      expect(candidate?.character.id, 'alice');
      expect(candidate?.source, DirectChatSource.direct);
    });

    test('allows a group character to initiate a first direct chat', () {
      final bob = _character(id: 'bob', name: '阿哲');
      final now = DateTime(2026, 7, 8, 12);

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: const [],
        groupCharacters: [bob],
        recentGroupMessages: [
          Message(
            groupId: 'group_1',
            senderId: 'user',
            senderType: 'user',
            content: '这个话题谁懂？',
            timestamp: now.subtract(const Duration(minutes: 10)),
          ),
        ],
        lastProactiveAtByCharacter: const {},
        now: now,
      );

      expect(candidate?.character.id, 'bob');
      expect(candidate?.source, DirectChatSource.group);
    });

    test('does not select candidates inside proactive cooldown', () {
      final alice = _character(id: 'alice', name: '小夏');
      final now = DateTime(2026, 7, 8, 12);

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: [
          DirectChatSummary(
            conversationId: DirectChatSession.conversationIdFor('alice'),
            character: alice,
            lastMessage: Message(
              groupId: DirectChatSession.conversationIdFor('alice'),
              senderId: 'user',
              senderType: 'user',
              content: '晚点聊',
              timestamp: now.subtract(const Duration(hours: 8)),
            ),
            unreadCount: 0,
            source: DirectChatSource.direct,
          ),
        ],
        groupCharacters: const [],
        recentGroupMessages: const [],
        lastProactiveAtByCharacter: {
          'alice': now.subtract(const Duration(minutes: 20)),
        },
        now: now,
      );

      expect(candidate, isNull);
    });
  });
}

AICharacter _character({required String id, required String name}) {
  return AICharacter(
    id: id,
    name: name,
    avatar: name.substring(0, 1),
    age: 24,
    role: '测试角色',
    personalityTags: const ['主动'],
    systemPrompt: '保持角色口吻。',
    apiKey: 'key',
    apiProvider: 'deepseek',
    apiConfigId: '',
  );
}
