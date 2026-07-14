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

  test('联合用户意图和角色职业选择最匹配技能', () {
    final character = AICharacter(
      name: '架构师',
      avatar: '🧭',
      age: 35,
      role: 'Flutter 工程师',
      personalityTags: const ['代码'],
      systemPrompt: '负责复杂工程交付。',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

    final bundle = CharacterSkillResolver.resolveFor(
      character,
      '请先把实施计划和进度写入文件，再逐步开发',
    );

    expect(
      bundle.skills.map((skill) => skill.id),
      contains('planning.planning-with-files'),
    );
    expect(bundle.needsSkillCreation, isFalse);
    expect(bundle.permissions, contains(ToolPermission.workspacePatch));
  });

  test('无匹配技能时建议创建并自动补充 skillCreate 权限', () {
    final character = AICharacter(
      name: '小林',
      avatar: '☕',
      age: 26,
      role: '咖啡师',
      personalityTags: const ['温和'],
      systemPrompt: '喜欢研究咖啡风味。',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

    final bundle = CharacterSkillResolver.resolveFor(
      character,
      '请建立一套门店咖啡杯测和校准流程',
    );

    expect(bundle.needsSkillCreation, isTrue);
    expect(bundle.permissions, contains(ToolPermission.skillCreate));
    expect(bundle.skillCreationHint, contains('咖啡杯测'));
  });

  test('HTML 页面意图自动补充后续文件读写权限', () {
    final character = AICharacter(
      name: '通用助理',
      avatar: '🤖',
      age: 25,
      role: '助理',
      personalityTags: const [],
      systemPrompt: '帮助用户完成任务。',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

    final bundle = CharacterSkillResolver.resolveFor(
      character,
      '帮我写一个简单的 HTML 页面',
    );

    expect(bundle.permissions, contains(ToolPermission.workspaceRead));
    expect(bundle.permissions, contains(ToolPermission.workspacePatch));
    expect(bundle.permissions, contains(ToolPermission.skillCreate));
  });

  test('前端 HTML 交付直接命中内置技能而不强制创建技能', () {
    final character = AICharacter(
      name: '通用助理',
      avatar: '🤖',
      age: 25,
      role: '助理',
      personalityTags: const [],
      systemPrompt: '帮助用户完成任务。',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

    final bundle = CharacterSkillResolver.resolveFor(
      character,
      '使用前端最新架构和视觉冲击，生成宇宙邀游 HTML 页面',
    );

    expect(bundle.skills.map((skill) => skill.id),
        contains('frontend.interactive-artifact'));
    expect(bundle.needsSkillCreation, isFalse);
    expect(bundle.permissions, contains(ToolPermission.workspacePatch));
  });

  test('附件追问会沿用对话上下文而不新建无关技能', () {
    final character = AICharacter(
      name: '通用助理',
      avatar: '🤖',
      age: 25,
      role: '助理',
      personalityTags: const [],
      systemPrompt: '帮助用户完成任务。',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

    for (final followUp in const ['你卡了吗', '附件呢', '继续']) {
      final bundle = CharacterSkillResolver.resolveFor(character, followUp);
      expect(bundle.needsSkillCreation, isFalse, reason: followUp);
    }
  });

  test('个人首页设计对所有角色自动补充文件写入权限', () {
    final character = AICharacter(
      name: '鬼魂街大佬',
      avatar: '👻',
      age: 30,
      role: '灵魂收集者',
      personalityTags: const ['神秘'],
      systemPrompt: '用幽默又神秘的方式回答。',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

    final bundle = CharacterSkillResolver.resolveFor(
      character,
      '帮我设计一个鬼魂街大佬专属个人首页，要有万魂幡吸魂和桃心彩蛋特效',
    );

    expect(bundle.permissions, contains(ToolPermission.workspaceRead));
    expect(bundle.permissions, contains(ToolPermission.workspacePatch));
  });
}
