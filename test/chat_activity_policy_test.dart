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
}
