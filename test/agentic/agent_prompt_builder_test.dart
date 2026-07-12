import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/agent_prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prompt includes tool protocol and character skills', () {
    final prompt = AgentPromptBuilder.buildToolPlanningPrompt(
      characterName: '代码大神',
      skills: [
        CharacterSkill(
          characterId: 'c1',
          name: 'Code Review',
          domain: 'coding',
          description: 'Review code.',
          instructions: const ['Read files', 'Report risks'],
          requiredPermissions: const [ToolPermission.workspaceRead],
        )
      ],
      userRequest: 'review lib/main.dart',
    );

    expect(prompt, contains('代码大神'));
    expect(prompt, contains('```agent_tool'));
    expect(prompt, contains('workspace.read'));
    expect(prompt, contains('Read files'));
    expect(prompt, contains('没有任何已安装技能匹配'));
    expect(prompt, contains('必须先调用 skill.create'));
    expect(prompt, contains('意图判断'));
    expect(prompt, contains('拆解执行步骤'));
    expect(prompt, contains('调用最少必要工具'));
    expect(prompt, contains('产出可交付物'));
    expect(prompt, contains('交付前自检'));
    expect(prompt, contains('先给结论'));
  });

  test('result prompt requires evidence-led delivery and self-check', () {
    final prompt = AgentPromptBuilder.buildToolResultPrompt(
      characterName: '工作助手',
      userRequest: '生成 report.md 并检查',
      toolName: 'workspace.patch',
      toolResult: const {
        'ok': true,
        'path': 'report.md',
        'validation': {'message': 'Markdown 验证通过'},
      },
    );

    expect(prompt, contains('先给结论'));
    expect(prompt, contains('可交付物'));
    expect(prompt, contains('验证证据'));
    expect(prompt, contains('自检'));
    expect(prompt, contains('未完成项或风险'));
  });
}
