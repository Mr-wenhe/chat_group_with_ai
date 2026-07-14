import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:flutter_test/flutter_test.dart';

AICharacter _character(String id, String name, String role) => AICharacter(
      id: id,
      name: name,
      avatar: '',
      age: 24,
      role: role,
      personalityTags: const [],
      systemPrompt: '你是$name',
      apiKey: 'test-key',
      apiProvider: 'deepseek',
      memorySummary: '【事实】用户使用 Windows，喜欢简洁回复',
    );

void main() {
  test('群聊操作一次：点名回复与 agentic 单执行者', () {
    final developer = _character('dev', '阿哲', '开发');
    final tester = _character('qa', '林溪', '测试');
    final user = Message(
      groupId: 'group-smoke',
      senderId: 'user',
      senderType: 'user',
      content: '@阿哲 生成 report.md，@林溪 帮忙看看',
      isMention: true,
      mentionedAiIds: const ['dev', 'qa'],
    );

    final intents = HumanizedChatOrchestrator.selectReplyIntents(
      characters: [developer, tester],
      recentMessages: [user],
      groupId: 'group-smoke',
      groupTheme: '工作协作',
      userMessage: user.content,
      mentionedIds: user.mentionedAiIds,
      memories: const [],
      relationships: const [],
      isEligible: (_) => true,
      random: Random(1),
    );
    expect(intents.map((item) => item.speakerId), contains('dev'));

    final executor = WorkModePolicy.selectExecutor(
      characters: [developer, tester],
      mentionedIds: user.mentionedAiIds,
    );
    expect(executor?.id, 'dev');
  });

  test('私聊操作一次：只有目标角色回复且携带跨聊天记忆', () {
    final target = _character('target', '小夏', '设计师');
    final other = _character('other', '阿哲', '开发');
    final selected = DirectChatSession.selectReplyCharacters(
      characters: [other, target],
      directCharacterId: target.id,
      isEligible: (_) => true,
    );

    expect(DirectChatSession.conversationIdFor(target.id), 'dm:target');
    expect(selected.map((item) => item.id), ['target']);
    expect(
      DirectChatSession.persistentMemoryPrompt(target),
      allOf(contains('Windows'), contains('简洁回复')),
    );
  });
}
