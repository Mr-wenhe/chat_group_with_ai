import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/group_chat_proactive_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GroupChatProactivePolicy', () {
    test('selects an active group character when group is quiet and read', () {
      final alice = _character(id: 'alice', name: '小夏');
      final group = _group(id: 'g1', characterIds: ['alice']);
      final now = DateTime(2026, 7, 9, 10);

      final candidate = GroupChatProactivePolicy.selectCandidate(
        groups: [group],
        charactersById: {'alice': alice},
        messages: const [],
        readAtByGroup: const {},
        lastProactiveAtByGroup: const {},
        now: now,
      );

      expect(candidate?.group.id, 'g1');
      expect(candidate?.character.id, 'alice');
      expect(candidate?.reason, '群聊破冰');
    });

    test('continues groups with unread ai messages below burst limit', () {
      final alice = _character(id: 'alice', name: '小夏');
      final group = _group(id: 'g1', characterIds: ['alice']);
      final now = DateTime(2026, 7, 9, 10);

      final candidate = GroupChatProactivePolicy.selectCandidate(
        groups: [group],
        charactersById: {'alice': alice},
        messages: [
          Message(
            groupId: 'g1',
            senderId: 'alice',
            senderType: 'ai',
            content: '你还没看这条',
            timestamp: now.subtract(const Duration(minutes: 5)),
          ),
        ],
        readAtByGroup: const {},
        lastProactiveAtByGroup: const {},
        now: now,
      );

      expect(candidate?.group.id, 'g1');
    });

    test('skips groups that reached unread burst limit', () {
      final alice = _character(id: 'alice', name: '小夏');
      final group = _group(id: 'g1', characterIds: ['alice']);
      final now = DateTime(2026, 7, 9, 10);

      final messages = List.generate(
        GroupChatProactivePolicy.maxUnreadBurstMessages,
        (index) => Message(
          groupId: 'g1',
          senderId: 'alice',
          senderType: 'ai',
          content: '未读 $index',
          timestamp: now.subtract(Duration(minutes: 10 - index)),
        ),
      );

      final candidate = GroupChatProactivePolicy.selectCandidate(
        groups: [group],
        charactersById: {'alice': alice},
        messages: messages,
        readAtByGroup: const {},
        lastProactiveAtByGroup: const {},
        now: now,
      );

      expect(candidate, isNull);
    });

    test('skips groups inside proactive cooldown', () {
      final alice = _character(id: 'alice', name: '小夏');
      final group = _group(id: 'g1', characterIds: ['alice']);
      final now = DateTime(2026, 7, 9, 10);

      final candidate = GroupChatProactivePolicy.selectCandidate(
        groups: [group],
        charactersById: {'alice': alice},
        messages: const [],
        readAtByGroup: const {},
        lastProactiveAtByGroup: {
          'g1': now.subtract(const Duration(minutes: 1)),
        },
        now: now,
      );

      expect(candidate, isNull);
    });

    test('prioritizes the group the user just left for handoff', () {
      final alice = _character(id: 'alice', name: '小夏');
      final bob = _character(id: 'bob', name: '阿哲');
      final preferred = _group(id: 'g1', characterIds: ['alice']);
      final other = _group(id: 'g2', characterIds: ['bob']);
      final now = DateTime(2026, 7, 9, 10);

      final candidate = GroupChatProactivePolicy.selectCandidate(
        groups: [other, preferred],
        charactersById: {'alice': alice, 'bob': bob},
        messages: const [],
        readAtByGroup: const {},
        lastProactiveAtByGroup: const {},
        now: now,
        preferredGroupId: 'g1',
      );

      expect(candidate?.group.id, 'g1');
      expect(candidate?.reason, '用户离开后继续推进群聊');
    });

    test('preferred handoff still respects unread burst limit', () {
      final alice = _character(id: 'alice', name: '小夏');
      final group = _group(id: 'g1', characterIds: ['alice']);
      final now = DateTime(2026, 7, 9, 10);
      final messages = List.generate(
        GroupChatProactivePolicy.maxUnreadBurstMessages,
        (index) => Message(
          groupId: 'g1',
          senderId: 'alice',
          senderType: 'ai',
          content: '未读 $index',
          timestamp: now.subtract(Duration(minutes: 10 - index)),
        ),
      );

      final candidate = GroupChatProactivePolicy.selectCandidate(
        groups: [group],
        charactersById: {'alice': alice},
        messages: messages,
        readAtByGroup: const {},
        lastProactiveAtByGroup: const {},
        now: now,
        preferredGroupId: 'g1',
      );

      expect(candidate, isNull);
    });

    test('uses a different speaker than the most recent ai when possible', () {
      final alice = _character(id: 'alice', name: '小夏');
      final bob = _character(id: 'bob', name: '阿哲');
      final group = _group(id: 'g1', characterIds: ['alice', 'bob']);
      final now = DateTime(2026, 7, 9, 10);
      final lastAiAt = now.subtract(
        GroupChatProactivePolicy.recentAiQuietPeriod +
            const Duration(minutes: 1),
      );

      final candidate = GroupChatProactivePolicy.selectCandidate(
        groups: [group],
        charactersById: {'alice': alice, 'bob': bob},
        messages: [
          Message(
            groupId: 'g1',
            senderId: 'alice',
            senderType: 'ai',
            content: '刚才我说了',
            timestamp: lastAiAt,
          ),
        ],
        readAtByGroup: {
          'g1': lastAiAt.add(const Duration(milliseconds: 1)),
        },
        lastProactiveAtByGroup: const {},
        now: now,
      );

      expect(candidate?.character.id, 'bob');
      expect(candidate?.reason, '延续群聊话题');
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

ChatGroup _group({required String id, required List<String> characterIds}) {
  return ChatGroup(
    id: id,
    name: '测试群',
    theme: '日常聊天',
    aiCharacterIds: characterIds,
  );
}
