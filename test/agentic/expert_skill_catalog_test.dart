import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('内置模板只复用来源和完整内容都匹配的已安装技能', () {
    final template = ExpertSkillCatalog.findById('meta.create-skills')!;
    final trusted = template.instantiateFor('character-a');
    final draft = CharacterSkill(
      characterId: 'character-a',
      name: template.name,
      domain: template.domain,
      description: '同名但未经验证的草稿',
      instructions: const ['任意指令'],
      requiredPermissions: const [],
    );

    expect(
      ExpertSkillCatalog.isInstalledTemplate(trusted, template, 'character-a'),
      isTrue,
    );
    expect(
      ExpertSkillCatalog.isInstalledTemplate(draft, template, 'character-a'),
      isFalse,
    );
  });

  test('目录包含基础、元技能、Ponytail 和文档工作流模板', () {
    final ids = ExpertSkillCatalog.templates.map((template) => template.id);

    expect(
        ids,
        containsAll(const [
          'meta.create-skills',
          'meta.find-skills',
          'meta.grill-me',
          'coding.ponytail',
          'general.superpowers',
          'planning.planning-with-files',
          'document.markdown-artifact',
          'document.word',
          'document.pdf',
          'document.presentations',
          'document.spreadsheets',
        ]));
    final planning =
        ExpertSkillCatalog.findById('planning.planning-with-files')!;
    expect(planning.domain, 'planning');
    expect(
      planning.requiredPermissions,
      containsAll(const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ]),
    );
    expect(planning.instructions.length, greaterThanOrEqualTo(4));
  });

  test('技能沉淀先去重并要求真实方法缺口或成功复用证据', () {
    final create = ExpertSkillCatalog.findById('meta.create-skills')!;
    final find = ExpertSkillCatalog.findById('meta.find-skills')!;

    expect(create.instructions.join('\n'), contains('用户明确要求创建'));
    expect(create.instructions.join('\n'), contains('网络失败'));
    expect(create.instructions.join('\n'), contains('代表性任务中真实执行并复测'));
    expect(create.instructions.join('\n'), contains('用户指定 GitHub 来源'));
    expect(create.instructions.join('\n'), contains('不可信资料'));
    expect(find.instructions.join('\n'), contains('生产搜索 Gateway'));
    expect(find.instructions.join('\n'), contains('固定 commit'));
    expect(find.instructions.join('\n'), contains('只加载当前任务需要'));
    expect(find.instructions.join('\n'), contains('不能单独触发 skill.create'));
  });

  test('目录按用户意图推荐最具体的基础工作流', () {
    expect(
      ExpertSkillCatalog.recommendForText('帮我创建一个可复用的新技能').first.id,
      'meta.create-skills',
    );
    expect(
      ExpertSkillCatalog.recommendForText('把计划和执行进度写进文件').first.id,
      'planning.planning-with-files',
    );
    expect(
      ExpertSkillCatalog.recommendForText('严格按测试驱动完成这个复杂任务').first.id,
      'general.superpowers',
    );
    expect(
      ExpertSkillCatalog.recommendForText('用前端最新架构生成有视觉冲击的 HTML 页面').first.id,
      'frontend.interactive-artifact',
    );
    expect(
      ExpertSkillCatalog.recommendForText('生成 Markdown 技术文档').first.id,
      'document.markdown-artifact',
    );
    expect(
      ExpertSkillCatalog.recommendForText('生成 Java 命令行程序').first.id,
      'coding.flutter-reviewer',
    );
    final fallback = ExpertSkillCatalog.recommendForText('建立一套门店咖啡杯测流程').single;
    expect(fallback.id, 'general.workbuddy-expert-builder');
    expect(fallback.instructions.join('\n'), contains('真实方法缺口'));
    expect(fallback.instructions.join('\n'), isNot(contains('没有模板时创建')));
  });

  test('元技能和文档格式都能直接命中对应模板', () {
    expect(
      ExpertSkillCatalog.recommendForText('帮我 find skill').first.id,
      'meta.find-skills',
    );
    expect(
      ExpertSkillCatalog.recommendForText('grill me on this plan').first.id,
      'meta.grill-me',
    );
    expect(
      ExpertSkillCatalog.recommendForText('请用 ponytail 做最小实现').first.id,
      'coding.ponytail',
    );

    const documentRequests = <String, String>{
      '生成一份 Word DOCX 文档': 'document.word',
      '生成一份 PDF 报告': 'document.pdf',
      '生成 PPTX 演示文稿': 'document.presentations',
      '生成一个 Excel XLSX 表格': 'document.spreadsheets',
    };
    for (final entry in documentRequests.entries) {
      expect(
        ExpertSkillCatalog.recommendForText(entry.key).first.id,
        entry.value,
        reason: entry.key,
      );
    }
  });

  test('Ponytail 会自动附带到代码请求', () {
    final ids = ExpertSkillCatalog.recommendForText('修复 Dart bug').map(
      (template) => template.id,
    );

    expect(ids, contains('coding.flutter-reviewer'));
    expect(ids, contains('coding.ponytail'));
  });
}
