import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// @ 面板只能列**当前群成员**。
///
/// 加载器刻意把"发过言但已被移出群"的历史发言人一起放进 `allCharacters`
/// （消息回显要用他们的名字和头像），直接用那份列表当候选会摆出点不出结果的
/// @ 项：普通聊天按活跃成员解析 @，工作模式路由只认群成员名单，两边都认不出他们。
void main() {
  AICharacter characterOf(
    String id,
    String name,
    String role, {
    bool isActive = true,
  }) =>
      AICharacter(
        id: id,
        name: name,
        avatar: '🤖',
        age: 30,
        role: role,
        personalityTags: const [],
        systemPrompt: '负责$role相关工作',
        apiKey: 'test-key',
        apiProvider: 'deepseek',
        apiConfigId: 'test-config',
        isActive: isActive,
      );

  test('已被移出群的历史发言人不进候选，仍在群的照旧列出', () {
    final candidates = mentionCandidatesForGroup(
      [
        characterOf('m1', '程序媛', '前端工程师'),
        characterOf('ex', '陈雨薇', '前端开发'),
        characterOf('m2', '孙梦琪', '测试工程师'),
      ],
      ['m1', 'm2'],
    );

    expect(candidates.map((character) => character.id), ['m1', 'm2']);
  });

  test('未启用的当前群成员仍在候选里，交给路由给出精确原因', () {
    final candidates = mentionCandidatesForGroup(
      [characterOf('m3', '小停', '前端工程师', isActive: false)],
      ['m3'],
    );

    expect(candidates.map((character) => character.id), ['m3']);
  });

  test('群成员名单为空时不回退到全量角色', () {
    final candidates = mentionCandidatesForGroup(
      [characterOf('x', '小X', '开发工程师')],
      const <String>[],
    );

    expect(candidates, isEmpty);
  });
}
