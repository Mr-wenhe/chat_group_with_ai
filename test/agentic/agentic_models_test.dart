import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new characters default to agentic skill creation and download', () {
    final character = AICharacter(
      name: '代码大神',
      avatar: '💻',
      age: 30,
      role: 'Flutter 架构师',
      personalityTags: const ['代码', 'review'],
      systemPrompt: '帮我写代码。',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

    expect(character.agenticEnabled, isTrue);
    expect(character.skillIds, isEmpty);
    expect(character.toolPermissions, contains(ToolPermission.skillCreate));
    expect(character.toolPermissions, contains(ToolPermission.skillDownload));
  });

  test('character skill stores reusable workflow instructions', () {
    final skill = CharacterSkill(
      characterId: 'c1',
      name: 'Flutter Bug Fixer',
      domain: 'coding',
      description: '定位并修复 Flutter/Riverpod/Hive 问题。',
      instructions: const [
        '先复现或读取错误信息',
        '定位最小相关文件',
        '写测试或静态检查',
        '应用补丁并验证',
      ],
      requiredPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
        ToolPermission.commandRun,
      ],
    );

    expect(skill.isGlobal, isFalse);
    expect(skill.requiredPermissions, contains(ToolPermission.workspacePatch));
  });
}
