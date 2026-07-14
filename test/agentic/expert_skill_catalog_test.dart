import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('目录包含三个 Agentic 基础工作流模板', () {
    final ids = ExpertSkillCatalog.templates.map((template) => template.id);

    expect(
        ids,
        containsAll(const [
          'meta.create-skills',
          'general.superpowers',
          'planning.planning-with-files',
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
  });
}
