import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/group_chat_inbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GroupChatInbox', () {
    test('counts unread ai messages after read time for each group', () {
      final group = _group(id: 'g1', name: '脑暴群');
      final readAt = DateTime(2026, 7, 8, 10);

      final summaries = GroupChatInbox.buildSummaries(
        groups: [group],
        messages: [
          Message(
            groupId: 'g1',
            senderId: 'ai_1',
            senderType: 'ai',
            content: '旧消息',
            timestamp: readAt.subtract(const Duration(minutes: 1)),
          ),
          Message(
            groupId: 'g1',
            senderId: 'user',
            senderType: 'user',
            content: '我的消息不算未读',
            timestamp: readAt.add(const Duration(minutes: 1)),
          ),
          Message(
            groupId: 'g1',
            senderId: 'ai_2',
            senderType: 'ai',
            content: '新消息 @我',
            timestamp: readAt.add(const Duration(minutes: 2)),
          ),
        ],
        readAtByGroup: {'g1': readAt},
        pinnedIds: const {},
      );

      expect(summaries.single.unreadCount, 1);
      expect(summaries.single.mentionCount, 1);
      expect(summaries.single.hasUnread, isTrue);
    });

    test('sorts pinned groups before recently active groups', () {
      final a = _group(id: 'a', name: 'A');
      final b = _group(id: 'b', name: 'B');
      final now = DateTime(2026, 7, 8, 10);

      final summaries = GroupChatInbox.buildSummaries(
        groups: [a, b],
        messages: [
          Message(
            groupId: 'a',
            senderId: 'ai',
            senderType: 'ai',
            content: 'older',
            timestamp: now,
          ),
          Message(
            groupId: 'b',
            senderId: 'ai',
            senderType: 'ai',
            content: 'newer',
            timestamp: now.add(const Duration(minutes: 5)),
          ),
        ],
        readAtByGroup: const {},
        pinnedIds: {'a'},
      );

      expect(summaries.map((s) => s.group.id), ['a', 'b']);
      expect(summaries.first.isPinned, isTrue);
    });

    test('unread count is cleared when read time passes latest message', () {
      final group = _group(id: 'g1', name: '脑暴群');
      final lastMessageAt = DateTime(2026, 7, 8, 10);

      final summaries = GroupChatInbox.buildSummaries(
        groups: [group],
        messages: [
          Message(
            groupId: 'g1',
            senderId: 'ai_1',
            senderType: 'ai',
            content: '@我 点进去之后应该清掉',
            timestamp: lastMessageAt,
          ),
        ],
        readAtByGroup: {
          'g1': lastMessageAt.add(const Duration(milliseconds: 1)),
        },
        pinnedIds: const {},
      );

      expect(summaries.single.unreadCount, 0);
      expect(summaries.single.mentionCount, 0);
      expect(summaries.single.hasUnread, isFalse);
    });

    test('ignores direct chat conversations when building group summaries', () {
      final group = _group(id: 'g1', name: '脑暴群');
      final now = DateTime(2026, 7, 8, 10);

      final summaries = GroupChatInbox.buildSummaries(
        groups: [group],
        messages: [
          Message(
            groupId: 'dm:ai_1',
            senderId: 'ai_1',
            senderType: 'ai',
            content: '私聊消息不应该进群未读',
            timestamp: now,
          ),
        ],
        readAtByGroup: const {},
        pinnedIds: const {},
      );

      expect(summaries.single.lastMessage, isNull);
      expect(summaries.single.unreadCount, 0);
    });
  });
}

ChatGroup _group({required String id, required String name}) {
  return ChatGroup(
    id: id,
    name: name,
    theme: '测试',
    aiCharacterIds: const [],
    ownerName: '我',
  );
}
