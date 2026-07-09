import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/chat_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatOrchestrator.isEligibleToReply', () {
    test('inactive character is not eligible', () {
      final c = AICharacter(
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
      )..isActive = false;
      expect(ChatOrchestrator.isEligibleToReply(c), false);
    });

    test('character without apiKey is not eligible', () {
      final c = AICharacter(
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: '',
        apiProvider: 'deepseek',
        apiConfigId: '',
      );
      expect(ChatOrchestrator.isEligibleToReply(c), false);
    });

    test('character with apiKey and no previous reply is eligible', () {
      final c = AICharacter(
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
      );
      expect(ChatOrchestrator.isEligibleToReply(c), true);
    });

    test('character under hourly limit is eligible', () {
      final now = DateTime.now();
      final c = AICharacter(
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
        hourlyReplyCount: 5,
        hourlyReplyLimit: 10,
        lastReplyTimestamp: now,
      );
      expect(ChatOrchestrator.isEligibleToReply(c), true);
    });

    test('character at hourly limit is not eligible', () {
      final now = DateTime.now();
      final c = AICharacter(
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
        hourlyReplyCount: 10,
        hourlyReplyLimit: 10,
        lastReplyTimestamp: now,
      );
      expect(ChatOrchestrator.isEligibleToReply(c), false);
    });

    test('character becomes eligible after 60 minutes', () {
      final twoHoursAgo = DateTime.now().subtract(const Duration(hours: 2));
      final c = AICharacter(
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
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
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
      )..isActive = false;
      expect(ChatOrchestrator.blockReasonFor(c), 'inactive');
    });

    test('no apiKey returns noApiConfig', () {
      final c = AICharacter(
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: '',
        apiProvider: 'deepseek',
        apiConfigId: '',
      );
      expect(ChatOrchestrator.blockReasonFor(c), 'noApiConfig');
    });

    test('at hourly limit returns hourlyLimit', () {
      final now = DateTime.now();
      final c = AICharacter(
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
        hourlyReplyCount: 10,
        hourlyReplyLimit: 10,
        lastReplyTimestamp: now,
      );
      expect(ChatOrchestrator.blockReasonFor(c), 'hourlyLimit');
    });

    test('under limit returns null (no block)', () {
      final now = DateTime.now();
      final c = AICharacter(
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
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
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
      );
      ChatOrchestrator.recordReplyUsage(c);
      expect(c.hourlyReplyCount, 1);
      expect(c.lastReplyTimestamp, isNotNull);
    });

    test('second reply increments count', () {
      final now = DateTime.now();
      final c = AICharacter(
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
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
        name: 'A',
        avatar: 'A',
        age: 25,
        role: 'tester',
        personalityTags: [],
        systemPrompt: '',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
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
      final msgs = List.generate(
          5,
          (i) => Message(
                groupId: 'g',
                senderId: 'u',
                senderType: 'user',
                content: 'm$i',
              ));
      final focus = ChatOrchestrator.extractRecentFocus(msgs);
      expect(focus, contains('m2 → m3 → m4'));
      expect(focus, isNot(contains('m0')));
    });

    test('single message returns focus prefix', () {
      final msgs = [
        Message(
          groupId: 'g',
          senderId: 'u',
          senderType: 'user',
          content: 'hello',
        )
      ];
      final focus = ChatOrchestrator.extractRecentFocus(msgs);
      expect(focus, contains('【当前对话焦点】最近大家在聊：hello'));
      expect(focus.startsWith('\n\n'), true);
    });

    test('truncates long focus to 200 chars with ellipsis', () {
      final msgs = [
        Message(
          groupId: 'g',
          senderId: 'u',
          senderType: 'user',
          content: 'A' * 201,
        )
      ];
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
      expect(
          ChatOrchestrator.stripNamePrefix('hello world', '张三'), 'hello world');
    });
  });

  group('ChatOrchestrator.recentDialogueTranscript', () {
    test('uses sender names and keeps only recent messages', () {
      final msgs = List.generate(
          4,
          (i) => Message(
                groupId: 'g',
                senderId: i.isEven ? 'user' : 'c1',
                senderType: i.isEven ? 'user' : 'ai',
                content: 'm$i',
              ));

      final transcript = ChatOrchestrator.recentDialogueTranscript(
        messages: msgs,
        senderNames: const {'user': '我', 'c1': '林溪'},
        maxMessages: 2,
      );

      expect(transcript, isNot(contains('m0')));
      expect(transcript, contains('我：m2'));
      expect(transcript, contains('林溪：m3'));
    });

    test('compacts whitespace and limits characters', () {
      final msgs = [
        Message(
          groupId: 'g',
          senderId: 'user',
          senderType: 'user',
          content: 'hello\n\nworld   again',
        )
      ];

      final transcript = ChatOrchestrator.recentDialogueTranscript(
        messages: msgs,
        senderNames: const {'user': '我'},
        maxChars: 8,
      );

      expect(transcript, hasLength(8));
      expect(transcript, isNot(contains('\n\n')));
    });
  });

  group('ChatOrchestrator group memory scheduling', () {
    test('uses ISO week keys around year boundaries', () {
      expect(
        ChatOrchestrator.memoryPeriodKey(DateTime(2026, 1, 1)),
        '2026_W01',
      );
      expect(
        ChatOrchestrator.memoryPeriodKey(DateTime(2027, 1, 1)),
        '2026_W53',
      );
    });

    test('does not update before enough messages', () {
      expect(
        ChatOrchestrator.shouldUpdateGroupMemory(
          messageCount: 7,
          hasExistingSummary: false,
        ),
        false,
      );
    });

    test('updates immediately when enough messages have no summary yet', () {
      expect(
        ChatOrchestrator.shouldUpdateGroupMemory(
          messageCount: 8,
          hasExistingSummary: false,
          lastSummaryAt: DateTime(2026, 7, 8, 12),
          now: DateTime(2026, 7, 8, 12, 1),
        ),
        true,
      );
    });

    test('throttles existing summaries inside the interval', () {
      expect(
        ChatOrchestrator.shouldUpdateGroupMemory(
          messageCount: 12,
          hasExistingSummary: true,
          lastSummaryAt: DateTime(2026, 7, 8, 12),
          now: DateTime(2026, 7, 8, 12, 5),
        ),
        false,
      );
    });

    test('allows existing summaries after the interval', () {
      expect(
        ChatOrchestrator.shouldUpdateGroupMemory(
          messageCount: 12,
          hasExistingSummary: true,
          lastSummaryAt: DateTime(2026, 7, 8, 12),
          now: DateTime(2026, 7, 8, 12, 11),
        ),
        true,
      );
    });
  });

  group('ChatOrchestrator persona growth prompts', () {
    test('persona context combines role, group, tags, and memory', () {
      final c = AICharacter(
        name: '林溪',
        avatar: 'L',
        age: 29,
        role: '心理咨询师',
        personalityTags: const ['温柔', '敏锐'],
        systemPrompt: '保持共情',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
      );

      final context = ChatOrchestrator.buildPersonaGrowthContext(
        character: c,
        groupName: '夜谈会',
        groupTheme: '情绪支持',
        groupDescription: '睡前聊天',
        groupMemory: '大家最近在聊工作压力。',
      );

      expect(context, contains('心理咨询师'));
      expect(context, contains('温柔、敏锐'));
      expect(context, contains('夜谈会'));
      expect(context, contains('大家最近在聊工作压力'));
      expect(context, contains('缓慢形成'));
    });

    test('memory evolution prompt asks for gradual non-fabricated growth', () {
      final c = AICharacter(
        name: '老周',
        avatar: 'Z',
        age: 42,
        role: '项目经理',
        personalityTags: const ['稳重'],
        systemPrompt: '务实',
        apiKey: 'k',
        apiProvider: 'deepseek',
        apiConfigId: '',
      );

      final prompt = ChatOrchestrator.buildMemoryEvolutionPrompt(
        character: c,
        groupName: '产品会',
        groupTheme: '开会',
        currentMemory: '我习惯先问风险。',
        recentTranscript: '我：这个排期紧吗？\n老周：先拆风险。',
        latestReply: '先别急，我们把依赖列出来。',
      );

      expect(prompt, contains('项目经理'));
      expect(prompt, contains('已有角色记忆'));
      expect(prompt, contains('只吸收真正会改变角色的东西'));
      expect(prompt, contains('不要编造'));
      expect(prompt, contains('渐进'));
    });
  });

  group('ChatOrchestrator agentic routing', () {
    test('agentic classifier only routes enabled characters', () {
      final character = AICharacter(
        name: '代码大神',
        avatar: 'C',
        age: 30,
        role: '工程师',
        personalityTags: const ['代码'],
        systemPrompt: 'review 代码',
        apiKey: 'k',
        apiProvider: 'deepseek',
      )..agenticEnabled = true;

      expect(
        ChatOrchestrator.shouldUseAgenticRuntime(
          character: character,
          message: '帮我 review lib/main.dart',
        ),
        isTrue,
      );
    });

    test('normal chat stays normal when agentic disabled', () {
      final character = AICharacter(
        name: '代码大神',
        avatar: 'C',
        age: 30,
        role: '工程师',
        personalityTags: const ['代码'],
        systemPrompt: 'review 代码',
        apiKey: 'k',
        apiProvider: 'deepseek',
      )..agenticEnabled = false;

      expect(
        ChatOrchestrator.shouldUseAgenticRuntime(
          character: character,
          message: '帮我 review lib/main.dart',
        ),
        isFalse,
      );
    });
  });
}
