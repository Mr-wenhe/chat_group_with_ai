import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// 圆桌会议的 @ 规则：新闻角色（幕后检索助手，见 `RoundtableNewsRoleService`）
/// 不是讨论成员。
///
/// 1. AI 回复即使输出了「@新闻角色」，也不产生协议效果（不进 mentionedAiIds、
///    不标 isMention）——判据是 [stripRoundtableNewsRoleMentions]；
/// 2. @ 弹窗不把新闻角色列为候选——判据是 [roundtableMentionCandidates]。
///    可见文本里的「@新闻角色」字样按设计保留，两个函数都不改文本。
void main() {
  AICharacter member(String id, String name) => AICharacter(
        id: id,
        name: name,
        avatar: '🤖',
        age: 30,
        role: '测试角色',
        personalityTags: const [],
        systemPrompt: '测试',
        apiKey: 'test-key',
        apiProvider: 'deepseek',
        apiConfigId: 'test-config',
      );

  AICharacter newsRole() => AICharacter(
        id: 'builtin-roundtable-news',
        name: '新闻角色',
        avatar: '📰',
        age: 30,
        role: '圆桌会议联网搜索助手',
        personalityTags: const [],
        systemPrompt: '幕后检索助手',
        apiKey: '',
        apiProvider: 'zhipu',
        apiConfigId: '',
        zhipuSearchAnswerOnly: true,
      );

  group('stripRoundtableNewsRoleMentions', () {
    test('剥离新闻角色，其余提及按原顺序保留', () {
      final stripped = stripRoundtableNewsRoleMentions(
        ['m1', 'builtin-roundtable-news', 'm2'],
        [member('m1', '甲'), member('m2', '乙'), newsRole()],
      );

      expect(stripped, ['m1', 'm2']);
    });

    test('成员里没有新闻角色时原样返回', () {
      final ids = ['m1', 'm2'];

      expect(
        stripRoundtableNewsRoleMentions(ids, [member('m1', '甲')]),
        same(ids),
      );
    });

    test('提及为空时返回空', () {
      expect(
        stripRoundtableNewsRoleMentions(const [], [newsRole()]),
        isEmpty,
      );
    });

    test('重复提及中的新闻角色同样被剥掉', () {
      final stripped = stripRoundtableNewsRoleMentions(
        ['builtin-roundtable-news', 'm1', 'builtin-roundtable-news'],
        [member('m1', '甲'), newsRole()],
      );

      expect(stripped, ['m1']);
    });
  });

  group('roundtableMentionCandidates', () {
    test('圆桌候选不含新闻角色，普通成员照旧', () {
      final candidates = roundtableMentionCandidates(
        [member('m1', '甲'), newsRole(), member('m2', '乙')],
        ['m1', 'builtin-roundtable-news', 'm2'],
      );

      expect(candidates.map((c) => c.id), ['m1', 'm2']);
    });

    test('新闻角色被过滤后，非成员不会因此入选', () {
      final candidates = roundtableMentionCandidates(
        [member('ex', '历史发言人'), newsRole()],
        ['builtin-roundtable-news'],
      );

      expect(candidates, isEmpty);
    });
  });
}
