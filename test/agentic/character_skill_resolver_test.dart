import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('coding character receives coding workflow and file tools', () {
    final character = AICharacter(
      name: '代码大神',
      avatar: '💻',
      age: 32,
      role: '资深 Flutter 工程师',
      personalityTags: const ['代码', 'review', 'debug'],
      systemPrompt: '擅长写代码、review 代码、修复 bug。',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

    final bundle = CharacterSkillResolver.defaultsFor(character);

    expect(bundle.skills.map((s) => s.name), contains('Code Review'));
    expect(bundle.permissions, contains(ToolPermission.workspaceRead));
    expect(bundle.permissions, contains(ToolPermission.workspacePatch));
    expect(bundle.permissions, contains(ToolPermission.commandRun));
    expect(bundle.permissions, contains(ToolPermission.skillCreate));
    expect(bundle.permissions, contains(ToolPermission.skillDownload));
    expect(
      bundle.skills.map((s) => s.name),
      contains('Downloadable Expert Templates'),
    );
  });

  test('research character receives browser context but not file patch', () {
    final character = AICharacter(
      name: '资料猎手',
      avatar: '🔎',
      age: 28,
      role: '网页研究员',
      personalityTags: const ['research', 'browser'],
      systemPrompt: '擅长阅读网页并提炼信息。',
      apiKey: 'k',
      apiProvider: 'qwen',
    );

    final bundle = CharacterSkillResolver.defaultsFor(character);

    expect(bundle.permissions, contains(ToolPermission.browserContext));
    expect(bundle.permissions, isNot(contains(ToolPermission.workspacePatch)));
    expect(bundle.permissions, contains(ToolPermission.skillDownload));
  });
}
