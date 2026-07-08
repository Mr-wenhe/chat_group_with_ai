import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/direct_chat/direct_chat_inbox.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DirectChatInbox', () {
    test('builds direct chat summaries sorted by latest message', () {
      final alice = _character(id: 'alice', name: '小夏');
      final bob = _character(id: 'bob', name: '阿哲');
      final oldTime = DateTime(2026, 7, 8, 9);
      final newTime = DateTime(2026, 7, 8, 10);

      final summaries = DirectChatInbox.buildSummaries(
        characters: [alice, bob],
        messages: [
          Message(
            groupId: DirectChatSession.conversationIdFor('alice'),
            senderId: 'user',
            senderType: 'user',
            content: '早',
            timestamp: oldTime,
          ),
          Message(
            groupId: DirectChatSession.conversationIdFor('bob'),
            senderId: 'bob',
            senderType: 'ai',
            content: '我想单独补一句',
            timestamp: newTime,
          ),
          Message(
            groupId: 'group_1',
            senderId: 'alice',
            senderType: 'ai',
            content: '群聊消息不进入私聊列表',
            timestamp: newTime.add(const Duration(minutes: 1)),
          ),
        ],
        readAtByConversation: const {},
        sourceByConversation: const {},
      );

      expect(summaries.map((s) => s.character.name), ['阿哲', '小夏']);
      expect(summaries.first.lastMessage.content, '我想单独补一句');
      expect(summaries.first.unreadCount, 1);
    });

    test('unread count only includes ai messages after read time', () {
      final alice = _character(id: 'alice', name: '小夏');
      final conversationId = DirectChatSession.conversationIdFor('alice');
      final readAt = DateTime(2026, 7, 8, 10);

      final summaries = DirectChatInbox.buildSummaries(
        characters: [alice],
        messages: [
          Message(
            groupId: conversationId,
            senderId: 'alice',
            senderType: 'ai',
            content: '旧消息',
            timestamp: readAt.subtract(const Duration(minutes: 1)),
          ),
          Message(
            groupId: conversationId,
            senderId: 'user',
            senderType: 'user',
            content: '我的消息不算未读',
            timestamp: readAt.add(const Duration(minutes: 1)),
          ),
          Message(
            groupId: conversationId,
            senderId: 'alice',
            senderType: 'ai',
            content: '新消息',
            timestamp: readAt.add(const Duration(minutes: 2)),
          ),
        ],
        readAtByConversation: {conversationId: readAt},
        sourceByConversation: {conversationId: DirectChatSource.group},
      );

      expect(summaries.single.unreadCount, 1);
      expect(summaries.single.source, DirectChatSource.group);
      expect(summaries.single.hasUnread, isTrue);
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
