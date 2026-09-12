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
        groupCandidates: [
          _groupCandidate(
            character: bob,
            groupId: 'group_1',
            at: now.subtract(const Duration(minutes: 20)),
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
        groupCandidates: [
          _groupCandidate(
            character: bob,
            groupId: 'group_1',
            at: now.subtract(const Duration(minutes: 10)),
          ),
        ],
        lastProactiveAtByCharacter: const {},
        now: now,
      );

      expect(candidate?.character.id, 'bob');
      expect(candidate?.source, DirectChatSource.group);
      expect(candidate?.sourceGroupId, 'group_1');
    });

    test('allows proactive DM from group context when user was recently active',
        () {
      final bob = _character(id: 'bob', name: '阿哲');
      final now = DateTime(2026, 7, 8, 12);
      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: const [],
        groupCandidates: [
          _groupCandidate(
            character: bob,
            groupId: 'g1',
            at: now.subtract(const Duration(minutes: 5)),
          ),
        ],
        lastProactiveAtByCharacter: const {},
        now: now,
      );

      expect(candidate?.character.id, 'bob');
      expect(candidate?.source, DirectChatSource.group);
      expect(candidate?.reason, '从群聊话题延伸');
    });

    test('continues unread direct chat below burst limit after delay', () {
      final alice = _character(id: 'alice', name: '小夏');
      final now = DateTime(2026, 7, 8, 12);

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: [
          DirectChatSummary(
            conversationId: DirectChatSession.conversationIdFor('alice'),
            character: alice,
            lastMessage: Message(
              groupId: DirectChatSession.conversationIdFor('alice'),
              senderId: 'alice',
              senderType: 'ai',
              content: '先看这条',
              timestamp: now.subtract(
                DirectChatProactivePolicy.unreadFollowUpDelay +
                    const Duration(minutes: 1),
              ),
            ),
            unreadCount: 1,
            source: DirectChatSource.group,
            hasUserMessage: true,
            lastUserMessageAt: now.subtract(const Duration(hours: 2)),
          ),
        ],
        groupCandidates: [
          _groupCandidate(
            character: alice,
            groupId: 'g1',
            at: now.subtract(const Duration(minutes: 5)),
          ),
        ],
        lastProactiveAtByCharacter: const {},
        now: now,
      );

      expect(candidate?.character.id, 'alice');
      expect(candidate?.source, DirectChatSource.direct);
    });

    test('does not continue unread direct chat at burst limit', () {
      final alice = _character(id: 'alice', name: '小夏');
      final now = DateTime(2026, 7, 8, 12);

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: [
          DirectChatSummary(
            conversationId: DirectChatSession.conversationIdFor('alice'),
            character: alice,
            lastMessage: Message(
              groupId: DirectChatSession.conversationIdFor('alice'),
              senderId: 'alice',
              senderType: 'ai',
              content: '第三条了',
              timestamp: now.subtract(const Duration(minutes: 30)),
            ),
            unreadCount: DirectChatProactivePolicy.maxUnreadBurstMessages,
            source: DirectChatSource.group,
            hasUserMessage: true,
            lastUserMessageAt: now.subtract(const Duration(hours: 2)),
          ),
        ],
        groupCandidates: const [],
        lastProactiveAtByCharacter: const {},
        now: now,
      );

      expect(candidate, isNull);
    });

    test('prioritizes the direct chat the user just left for handoff', () {
      final alice = _character(id: 'alice', name: '小夏');
      final bob = _character(id: 'bob', name: '阿哲');
      final now = DateTime(2026, 7, 8, 12);
      final aliceConversationId = DirectChatSession.conversationIdFor('alice');

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: [
          DirectChatSummary(
            conversationId: aliceConversationId,
            character: alice,
            lastMessage: Message(
              groupId: aliceConversationId,
              senderId: 'user',
              senderType: 'user',
              content: '你继续说',
              timestamp: now.subtract(const Duration(seconds: 5)),
            ),
            unreadCount: 0,
            source: DirectChatSource.direct,
            hasUserMessage: true,
            lastUserMessageAt: now.subtract(const Duration(seconds: 5)),
          ),
        ],
        groupCandidates: [
          _groupCandidate(
            character: bob,
            groupId: 'group_1',
            at: now.subtract(const Duration(minutes: 10)),
          ),
        ],
        lastProactiveAtByCharacter: const {},
        now: now,
        preferredConversationId: aliceConversationId,
      );

      expect(candidate?.character.id, 'alice');
      expect(candidate?.reason, '用户离开后继续私聊');
    });

    test('preferred direct handoff still respects unread burst limit', () {
      final alice = _character(id: 'alice', name: '小夏');
      final now = DateTime(2026, 7, 8, 12);
      final aliceConversationId = DirectChatSession.conversationIdFor('alice');

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: [
          DirectChatSummary(
            conversationId: aliceConversationId,
            character: alice,
            lastMessage: Message(
              groupId: aliceConversationId,
              senderId: 'alice',
              senderType: 'ai',
              content: '第三条了',
              timestamp: now.subtract(const Duration(minutes: 1)),
            ),
            unreadCount: DirectChatProactivePolicy.maxUnreadBurstMessages,
            source: DirectChatSource.direct,
            hasUserMessage: true,
            lastUserMessageAt: now.subtract(const Duration(minutes: 10)),
          ),
        ],
        groupCandidates: const [],
        lastProactiveAtByCharacter: const {},
        now: now,
        preferredConversationId: aliceConversationId,
      );

      expect(candidate, isNull);
    });

    test('does not proactively start idle direct chat inside cooldown', () {
      final bob = _character(id: 'bob', name: '阿哲');
      final now = DateTime(2026, 7, 8, 12);

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: const [],
        groupCandidates: [
          _groupCandidate(
            character: bob,
            groupId: 'g1',
            at: now.subtract(const Duration(minutes: 10)),
          ),
        ],
        lastProactiveAtByCharacter: {
          'bob': now.subtract(const Duration(minutes: 30)),
        },
        now: now,
      );

      expect(candidate, isNull);
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
            hasUserMessage: true,
            lastUserMessageAt: now.subtract(const Duration(hours: 8)),
          ),
        ],
        groupCandidates: const [],
        lastProactiveAtByCharacter: {
          'alice': now.subtract(const Duration(minutes: 20)),
        },
        now: now,
      );

      expect(candidate, isNull);
    });

    test('does not continue a direct chat where user never spoke', () {
      final alice = _character(id: 'alice', name: '小夏');
      final now = DateTime(2026, 7, 8, 12);

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: [
          DirectChatSummary(
            conversationId: DirectChatSession.conversationIdFor('alice'),
            character: alice,
            lastMessage: Message(
              groupId: DirectChatSession.conversationIdFor('alice'),
              senderId: 'alice',
              senderType: 'ai',
              content: '我先来打个招呼',
              timestamp: now.subtract(const Duration(hours: 8)),
            ),
            unreadCount: 0,
            source: DirectChatSource.group,
          ),
        ],
        groupCandidates: const [],
        lastProactiveAtByCharacter: const {},
        now: now,
      );

      expect(candidate, isNull);
    });

    test(
        'uses only group candidates from groups where user was recently active',
        () {
      final alice = _character(id: 'alice', name: '小夏');
      final bob = _character(id: 'bob', name: '阿哲');
      final now = DateTime(2026, 7, 8, 12);

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: const [],
        groupCandidates: [
          _groupCandidate(
            character: alice,
            groupId: 'old_group',
            at: now.subtract(const Duration(hours: 2)),
          ),
          _groupCandidate(
            character: bob,
            groupId: 'fresh_group',
            at: now.subtract(const Duration(minutes: 10)),
          ),
        ],
        lastProactiveAtByCharacter: const {},
        now: now,
      );

      expect(candidate?.character.id, 'bob');
      expect(candidate?.sourceGroupId, 'fresh_group');
    });

    test('does not extend from group context older than one hour', () {
      final bob = _character(id: 'bob', name: '阿哲');
      final now = DateTime(2026, 7, 8, 12);

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: const [],
        groupCandidates: [
          _groupCandidate(
            character: bob,
            groupId: 'g1',
            at: now.subtract(const Duration(hours: 1, minutes: 1)),
          ),
        ],
        lastProactiveAtByCharacter: const {},
        now: now,
      );

      expect(candidate, isNull);
    });

    test('allows an active character to initiate a first friendly greeting',
        () {
      final alice = _character(id: 'alice', name: '小夏');
      final now = DateTime(2026, 7, 8, 12);

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: const [],
        groupCandidates: const [],
        idleCharacters: [alice],
        lastProactiveAtByCharacter: const {},
        now: now,
      );

      expect(candidate?.character.id, 'alice');
      expect(candidate?.reason, '主动问候');
    });

    test('disabled character never becomes a proactive DM candidate', () {
      final alice = _character(id: 'alice', name: '小夏')
        ..proactiveChatEnabled = false;
      final now = DateTime(2026, 7, 8, 12);
      final conversationId = DirectChatSession.conversationIdFor('alice');
      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: [
          DirectChatSummary(
            conversationId: conversationId,
            character: alice,
            lastMessage: Message(
              groupId: conversationId,
              senderId: 'user',
              senderType: 'user',
              content: '晚点聊',
              timestamp: now.subtract(const Duration(hours: 8)),
            ),
            unreadCount: 0,
            source: DirectChatSource.direct,
            hasUserMessage: true,
          ),
        ],
        groupCandidates: [
          _groupCandidate(
            character: alice,
            groupId: 'g1',
            at: now.subtract(const Duration(minutes: 5)),
          ),
        ],
        idleCharacters: [alice],
        lastProactiveAtByCharacter: const {},
        now: now,
        preferredConversationId: conversationId,
      );

      expect(candidate, isNull);
    });

    test('idle greeting still respects the proactive cooldown', () {
      final alice = _character(id: 'alice', name: '小夏');
      final now = DateTime(2026, 7, 8, 12);

      final candidate = DirectChatProactivePolicy.selectCandidate(
        directSummaries: const [],
        groupCandidates: const [],
        idleCharacters: [alice],
        lastProactiveAtByCharacter: {
          'alice': now.subtract(const Duration(minutes: 10)),
        },
        now: now,
      );

      expect(candidate, isNull);
    });

    test('foreground schedule checks soon enough to feel proactive', () {
      expect(ProactiveContactSchedule.initialDelay,
          lessThanOrEqualTo(const Duration(seconds: 10)));
      expect(ProactiveContactSchedule.interval,
          lessThanOrEqualTo(const Duration(seconds: 60)));
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

DirectChatGroupCandidate _groupCandidate({
  required AICharacter character,
  required String groupId,
  required DateTime at,
}) {
  return DirectChatGroupCandidate(
    character: character,
    groupId: groupId,
    lastUserMessageAt: at,
  );
}
