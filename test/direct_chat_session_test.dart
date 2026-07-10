import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DirectChatSession', () {
    test('builds and parses stable direct chat conversation ids', () {
      final conversationId = DirectChatSession.conversationIdFor('char_1');

      expect(conversationId, 'dm:char_1');
      expect(DirectChatSession.isDirectConversationId(conversationId), isTrue);
      expect(DirectChatSession.characterIdFrom(conversationId), 'char_1');
      expect(DirectChatSession.characterIdFrom('group_1'), isNull);
    });

    test('selects only the direct chat target when eligible', () {
      final target = _character(id: 'target', name: '目标');
      final other = _character(id: 'other', name: '旁观者');

      final selected = DirectChatSession.selectReplyCharacters(
        characters: [target, other],
        directCharacterId: 'target',
        isEligible: (character) => character.id == 'target',
      );

      expect(selected, [target]);
    });

    test('does not select another character when direct target is blocked', () {
      final target = _character(id: 'target', name: '目标');
      final other = _character(id: 'other', name: '旁观者');

      final selected = DirectChatSession.selectReplyCharacters(
        characters: [target, other],
        directCharacterId: 'target',
        isEligible: (_) => false,
      );

      expect(selected, isEmpty);
    });

  test('builds one-on-one prompt context without group-chat framing', () {
      final character = _character(id: 'target', name: '小夏');

      final prompt = DirectChatSession.buildPromptContext(
        character: character,
        ownerName: '我',
      );

      expect(prompt, contains('一对一私聊'));
      expect(prompt, contains('小夏'));
      expect(prompt, contains('真人用户叫「我」'));
      expect(prompt, isNot(contains('群聊')));
      expect(prompt, isNot(contains('群友')));
    });
  });

  test('builds persistent memory context for proactive and direct chats', () {
    final target = _character(id: 'target', name: '林溪')
      ..memorySummary = '【事实】用户住在上海；用户养猫';

    final prompt = DirectChatSession.persistentMemoryPrompt(target);

    expect(prompt, contains('跨聊天长期记忆'));
    expect(prompt, contains('用户住在上海'));
    expect(prompt, contains('用户养猫'));
  });
}

AICharacter _character({required String id, required String name}) {
  return AICharacter(
    id: id,
    name: name,
    avatar: name.substring(0, 1),
    age: 22,
    role: '测试角色',
    personalityTags: const ['自然'],
    systemPrompt: '保持角色口吻。',
    apiKey: 'key',
    apiProvider: 'deepseek',
    apiConfigId: '',
  );
}
