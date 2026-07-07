import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/chat_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatOrchestrator.isEligibleToReply', () {
    test('inactive character is not eligible', () {
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
      )..isActive = false;
      expect(ChatOrchestrator.isEligibleToReply(c), false);
    });

    test('character without apiKey is not eligible', () {
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: '',
        apiProvider: 'deepseek', apiConfigId: '',
      );
      expect(ChatOrchestrator.isEligibleToReply(c), false);
    });

    test('character with apiKey and no previous reply is eligible', () {
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
      );
      expect(ChatOrchestrator.isEligibleToReply(c), true);
    });

    test('character under hourly limit is eligible', () {
      final now = DateTime.now();
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
        hourlyReplyCount: 5,
        hourlyReplyLimit: 10,
        lastReplyTimestamp: now,
      );
      expect(ChatOrchestrator.isEligibleToReply(c), true);
    });

    test('character at hourly limit is not eligible', () {
      final now = DateTime.now();
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
        hourlyReplyCount: 10,
        hourlyReplyLimit: 10,
        lastReplyTimestamp: now,
      );
      expect(ChatOrchestrator.isEligibleToReply(c), false);
    });

    test('character becomes eligible after 60 minutes', () {
      final twoHoursAgo = DateTime.now().subtract(const Duration(hours: 2));
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
        hourlyReplyCount: 10,
        hourlyReplyLimit: 10,
        lastReplyTimestamp: twoHoursAgo,
      );
      expect(ChatOrchestrator.isEligibleToReply(c), true);
    });
  });

  group('ChatOrchestrator.blockReasonFor', () {
    test('inactive returns inactive', () {
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
      )..isActive = false;
      expect(ChatOrchestrator.blockReasonFor(c), 'inactive');
    });

    test('no apiKey returns noApiConfig', () {
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: '',
        apiProvider: 'deepseek', apiConfigId: '',
      );
      expect(ChatOrchestrator.blockReasonFor(c), 'noApiConfig');
    });

    test('at hourly limit returns hourlyLimit', () {
      final now = DateTime.now();
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
        hourlyReplyCount: 10,
        hourlyReplyLimit: 10,
        lastReplyTimestamp: now,
      );
      expect(ChatOrchestrator.blockReasonFor(c), 'hourlyLimit');
    });

    test('under limit returns null (no block)', () {
      final now = DateTime.now();
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
        hourlyReplyCount: 5,
        hourlyReplyLimit: 10,
        lastReplyTimestamp: now,
      );
      expect(ChatOrchestrator.blockReasonFor(c), null);
    });
  });

  group('ChatOrchestrator.recordReplyUsage', () {
    test('first reply sets count to 1', () {
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
      );
      ChatOrchestrator.recordReplyUsage(c);
      expect(c.hourlyReplyCount, 1);
      expect(c.lastReplyTimestamp, isNotNull);
    });

    test('second reply increments count', () {
      final now = DateTime.now();
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
        hourlyReplyCount: 1,
        hourlyReplyLimit: 10,
        lastReplyTimestamp: now,
      );
      ChatOrchestrator.recordReplyUsage(c);
      expect(c.hourlyReplyCount, 2);
    });

    test('reply after hour gap resets count', () {
      final twoHoursAgo = DateTime.now().subtract(const Duration(hours: 2));
      final c = AICharacter(
        name: 'A', avatar: 'A', age: 25, role: 'tester',
        personalityTags: [], systemPrompt: '', apiKey: 'k',
        apiProvider: 'deepseek', apiConfigId: '',
        hourlyReplyCount: 10,
        hourlyReplyLimit: 10,
        lastReplyTimestamp: twoHoursAgo,
      );
      ChatOrchestrator.recordReplyUsage(c);
      expect(c.hourlyReplyCount, 1);
    });
  });

  group('ChatOrchestrator.extractRecentFocus', () {
    test('empty list returns empty', () {
      expect(ChatOrchestrator.extractRecentFocus([]), '');
    });

    test('returns last 3 messages with arrow separator', () {
      final msgs = List.generate(5, (i) => Message(
        groupId: 'g', senderId: 'u', senderType: 'user',
        content: 'm$i',
      ));
      final focus = ChatOrchestrator.extractRecentFocus(msgs);
      expect(focus, contains('m2 → m3 → m4'));
      expect(focus, isNot(contains('m0')));
    });

    test('single message returns focus prefix', () {
      final msgs = [Message(
        groupId: 'g', senderId: 'u', senderType: 'user',
        content: 'hello',
      )];
      final focus = ChatOrchestrator.extractRecentFocus(msgs);
      expect(focus, contains('【当前对话焦点】最近大家在聊：hello'));
      expect(focus.startsWith('\n\n'), true);
    });

    test('truncates long focus to 200 chars with ellipsis', () {
      final msgs = [Message(
        groupId: 'g', senderId: 'u', senderType: 'user',
        content: 'A' * 201,
      )];
      final focus = ChatOrchestrator.extractRecentFocus(msgs);
      expect(focus.endsWith('...'), true);
      expect(focus.length, greaterThanOrEqualTo(216));
      expect(focus.length, lessThanOrEqualTo(220));
    });
  });

  group('ChatOrchestrator.stripNamePrefix', () {
    test('removes Chinese colon prefix', () {
      expect(ChatOrchestrator.stripNamePrefix('张三：你好', '张三'), '你好');
    });

    test('removes ASCII colon prefix', () {
      expect(ChatOrchestrator.stripNamePrefix('张三:hello', '张三'), 'hello');
    });

    test('removes bracket prefix', () {
      expect(ChatOrchestrator.stripNamePrefix('【张三】内容', '张三'), '内容');
    });

    test('returns original when no prefix', () {
      expect(ChatOrchestrator.stripNamePrefix('hello world', '张三'), 'hello world');
    });
  });
}
