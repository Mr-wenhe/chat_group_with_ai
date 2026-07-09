import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all characters can receive at least one downloadable expert skill', () {
    final character = AICharacter(
      name: '老干部',
      avatar: 'O',
      age: 58,
      role: '老干部',
      personalityTags: const ['稳重'],
      systemPrompt: '循循善诱',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

    final templates = SkillDownloadService.recommendedTemplatesFor(character);

    expect(templates, isNotEmpty);
    expect(
      templates.first.requiredPermissions,
      contains(ToolPermission.skillDownload),
    );
  });

  test('coding characters are recommended coding expert skills', () {
    final character = AICharacter(
      name: '代码大神',
      avatar: 'C',
      age: 30,
      role: 'Flutter 工程师',
      personalityTags: const ['代码', 'debug'],
      systemPrompt: 'review 代码',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

    final templates = SkillDownloadService.recommendedTemplatesFor(character);

    expect(templates.map((t) => t.id), contains('coding.flutter-reviewer'));
  });

  test('template can be instantiated as character-owned skill', () {
    final character = AICharacter(
      name: '网页研究员',
      avatar: 'R',
      age: 28,
      role: '网页研究员',
      personalityTags: const ['research'],
      systemPrompt: '阅读网页',
      apiKey: 'k',
      apiProvider: 'qwen',
    );

    final skill = SkillDownloadService.instantiateForCharacter(
      templateId: 'research.browser-analyst',
      character: character,
    );

    expect(skill, isNotNull);
    expect(skill!.characterId, character.id);
    expect(skill.requiredPermissions, contains(ToolPermission.browserContext));
  });
}
