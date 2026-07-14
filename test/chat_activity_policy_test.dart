import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/chat_group/chat_activity_policy.dart';
import 'package:flutter_test/flutter_test.dart';

AICharacter _character(String id, String name) {
  return AICharacter(
    id: id,
    name: name,
    avatar: name.substring(0, 1),
    age: 20,
    role: '测试角色',
    personalityTags: const ['测试'],
    systemPrompt: '你是测试角色',
    apiKey: 'key',
    apiProvider: 'custom',
    apiConfigId: 'config',
  );
}

void main() {
  final characters = [
    _character('c1', '小胖'),
    _character('c2', 'Alice'),
    _character('c3', '马文杰'),
  ];

  test('mentioned characters are selected first for a user message', () {
    final selected = ChatActivityPolicy.selectUserReplyCharacters(
      characters: characters,
      mentionedIds: const ['c2'],
      pendingMentionedIds: const [],
      isEligible: (_) => true,
      random: Random(1),
    );

    expect(selected.first.id, 'c2');
    expect(selected.map((c) => c.id), contains('c2'));
    expect(selected.length, lessThanOrEqualTo(2));
  });

  test('all mentioned characters can reply even when more than default max',
      () {
    final selected = ChatActivityPolicy.selectUserReplyCharacters(
      characters: characters,
      mentionedIds: const ['c1', 'c2', 'c3'],
      pendingMentionedIds: const [],
      isEligible: (_) => true,
      random: Random(1),
    );

    expect(selected.map((c) => c.id), ['c1', 'c2', 'c3']);
  });

  test('active user messages invite a second eligible participant', () {
    final selected = ChatActivityPolicy.selectUserReplyCharacters(
      characters: characters,
      mentionedIds: const [],
      pendingMentionedIds: const [],
      isEligible: (_) => true,
      random: Random(2),
    );

    expect(selected.length, 2);
    expect(selected.map((c) => c.id).toSet().length, 2);
  });

  test('group-addressed user messages invite more participants', () {
    final groupCharacters = [
      ...characters,
      _character('c4', '李雷'),
      _character('c5', '韩梅梅'),
    ];
    final selected = ChatActivityPolicy.selectUserReplyCharacters(
      characters: groupCharacters,
      mentionedIds: const [],
      pendingMentionedIds: const [],
      isEligible: (_) => true,
      random: Random(4),
      isGroupAddressed: true,
    );

    expect(selected.length, ChatActivityPolicy.groupAddressedMaxReplyCount);
    expect(selected.map((c) => c.id).toSet().length, selected.length);
  });

  test('auto chat always chooses at least one eligible speaker', () {
    for (var i = 0; i < 20; i++) {
      final selected = ChatActivityPolicy.selectAutoChatSpeakers(
        characters: characters,
        isEligible: (_) => true,
        random: Random(i),
      );

      expect(selected, isNotEmpty);
      expect(selected.length, lessThanOrEqualTo(2));
    }
  });

  test('work mode blocks auto chat even when auto chat is enabled', () {
    expect(
      ChatActivityPolicy.canStartAutoChat(
        workModeEnabled: true,
        autoChatEnabled: true,
        hasCharacters: true,
        hasApiConfig: true,
      ),
      isFalse,
    );
  });

  test('pending mentions are handled before casual follow-ups', () {
    final selected = ChatActivityPolicy.selectUserReplyCharacters(
      characters: characters,
      mentionedIds: const [],
      pendingMentionedIds: const ['c3'],
      isEligible: (_) => true,
      random: Random(3),
    );

    expect(selected.first.id, 'c3');
  });

  test('empty replies get a visible fallback for active chat feedback', () {
    final fallback = ChatActivityPolicy.emptyReplyFallback(
      characterName: '马小跳',
      role: '初中生',
      groupTheme: '远控软件--向日葵',
      userMessage: '@马小跳 你平时用向日葵远控最常遇到什么问题？',
      random: Random(1),
    );

    expect(fallback, contains('远控软件--向日葵'));
    expect(fallback.trim(), isNotEmpty);
    expect(fallback, isNot(contains('卡')));
  });

  test('reply delay grows with visible reply length', () {
    final shortDelay = ChatActivityPolicy.replyDelayForContent('好');
    final longDelay = ChatActivityPolicy.replyDelayForContent(
      '这段回复会更长一些，因为下一位 AI 需要给用户留出阅读时间，再自然地接上话。',
    );

    expect(longDelay, greaterThan(shortDelay));
  });

  test('reply delay ignores whitespace and is capped', () {
    final emptyDelay = ChatActivityPolicy.replyDelayForContent('   \n\t');
    final hugeDelay = ChatActivityPolicy.replyDelayForContent(
      List.filled(500, '很长').join(),
    );

    expect(emptyDelay.inMilliseconds, ChatActivityPolicy.minReplyDelayMs);
    expect(hugeDelay.inMilliseconds, ChatActivityPolicy.maxReplyDelayMs);
  });

  test('contentMentionsUser detects @me and owner name', () {
    expect(ChatActivityPolicy.contentMentionsUser('@我 你怎么看？', '风野'), isTrue);
    expect(ChatActivityPolicy.contentMentionsUser('@风野 来补一句', '风野'), isTrue);
  });

  test('contentMentionsUser ignores ordinary first-person text', () {
    expect(ChatActivityPolicy.contentMentionsUser('我觉得可以继续聊', '风野'), isFalse);
    expect(ChatActivityPolicy.contentMentionsUser('@小胖 我同意', '风野'), isFalse);
  });

  test('isGroupAddressedMessage detects prompts aimed at everyone', () {
    expect(ChatActivityPolicy.isGroupAddressedMessage('大家分享一下最近的想法'), isTrue);
    expect(ChatActivityPolicy.isGroupAddressedMessage('各位怎么看这个问题？'), isTrue);
    expect(ChatActivityPolicy.isGroupAddressedMessage('@all 都来讲两句'), isTrue);
  });

  test('isGroupAddressedMessage ignores direct single-person phrasing', () {
    expect(ChatActivityPolicy.isGroupAddressedMessage('你怎么看这个问题？'), isFalse);
    expect(ChatActivityPolicy.isGroupAddressedMessage('@小胖 分享一下'), isFalse);
  });
}
