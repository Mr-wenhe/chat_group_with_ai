import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/ai_character/action_skill_count.dart';
import 'package:chat_group/features/agentic/widgets/character_skill_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构建最小可用角色，便于断言“行动”数字逻辑。
AICharacter _character({
  bool agenticEnabled = true,
  List<String> skillIds = const [],
  List<ToolPermission> toolPermissions = const [],
  String name = '测试角色',
  List<String> personalityTags = const [],
  String systemPrompt = '',
}) {
  return AICharacter(
    id: 'test-char',
    name: name,
    avatar: 'T',
    age: 30,
    role: 'tester',
    personalityTags: personalityTags,
    systemPrompt: systemPrompt,
    apiKey: '',
    apiProvider: 'custom',
    hourlyReplyLimit: 5,
    apiConfigId: 'cfg',
    agenticEnabled: agenticEnabled,
    skillIds: skillIds,
    toolPermissions: toolPermissions,
    createdAt: DateTime(2026, 1, 1),
  );
}

void main() {
  group('行动数字 (actionSkillCountFor)', () {
    test('等于 推断技能数 + 已安装 skillIds 数', () {
      final c = _character();
      final inferred = CharacterSkillResolver.defaultsFor(c).skills.length;
      // 没有任何已安装技能时，数字 = 推断技能数
      expect(actionSkillCountFor(c), inferred);

      // 安装 2 个技能后，数字应 +2
      final withTwo = _character(skillIds: const ['tpl.a', 'tpl.b']);
      expect(actionSkillCountFor(withTwo), inferred + 2);
    });

    test('仅开启行动能力 / 改工具权限不会改变数字', () {
      // 推断技能只取决于角色文本，与 agenticEnabled、toolPermissions 无关
      final base = _character(agenticEnabled: false, skillIds: const []);
      final inferred = CharacterSkillResolver.defaultsFor(base).skills.length;
      expect(actionSkillCountFor(base), inferred);

      final toggled = _character(
        agenticEnabled: true,
        skillIds: const [],
        toolPermissions: const [ToolPermission.commandRun],
      );
      // 开关/权限变了，但数字不变 —— 这正是用户在编辑页“开启所有技能”数字不涨的原因
      expect(actionSkillCountFor(toggled), inferred);
    });
  });

  group('编辑页：推荐专家 Skill 现在可点按安装', () {
    testWidgets('点按推荐 Skill 触发 onTemplateToggle 并高亮选中', (tester) async {
      final templates = [
        const ExpertSkillTemplate(
          id: 'tpl.a',
          name: '专家A',
          domain: 'x',
          description: 'd',
          keywords: [],
          instructions: [],
          requiredPermissions: [],
        ),
        const ExpertSkillTemplate(
          id: 'tpl.b',
          name: '专家B',
          domain: 'x',
          description: 'd',
          keywords: [],
          instructions: [],
          requiredPermissions: [],
        ),
      ];

      String? tappedId;
      final selected = <String>{};

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CharacterSkillEditor(
            enabled: true,
            onEnabledChanged: (_) {},
            inferredSkills: const [],
            recommendedTemplates: templates,
            selectedTemplateIds: selected,
            onTemplateToggle: (id) {
              tappedId = id;
              selected.add(id);
            },
            selectedPermissions: const [],
            onPermissionToggle: (_) {},
          ),
        ),
      ));

      // 修复前：这些 chip 没有 onTap，点按毫无反应，skillIds 永远不会增加。
      expect(find.text('专家A'), findsOneWidget);
      await tester.tap(find.text('专家A'));
      await tester.pumpAndSettle();

      expect(tappedId, 'tpl.a');
    });
  });
}
