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
  });
}
