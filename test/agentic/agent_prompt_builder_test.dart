import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/agent_prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prompt includes tool protocol and character skills', () {
    final prompt = AgentPromptBuilder.buildToolPlanningPrompt(
      rolePlaySystemPrompt: '你是代码大神，30岁，性别女，身份是工程师。\n写代码',
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

  test('Stage 03 prompt describes one strict JSON decision object', () {
    final prompt = AgentPromptBuilder.buildAgentDecisionPrompt(
      rolePlaySystemPrompt: '你是工作助手。',
      skills: const [],
      userRequest: '读取并检查 lib/main.dart',
    );

    expect(prompt, contains('固定顶层字段'));
    expect(prompt, contains('action 只能是 plan、tool、clarify、handoff、finish'));
    expect(prompt, contains('public_update'));
    expect(prompt, contains('只写用户可见的动作、依据或结论'));
    expect(prompt, contains('workspace.read'));
    expect(prompt, isNot(contains('```agent_tool')));
    expect(prompt, isNot(contains('<tool_call>')));
  });

  test('result prompt requires evidence-led delivery and self-check', () {
    final prompt = AgentPromptBuilder.buildToolResultPrompt(
      rolePlaySystemPrompt: '你是工作助手，30岁，性别女，身份是助理。\n保持专业。',
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

  test('result prompt forbids claiming attachment for non-file-write tools',
      () {
    // 虚假附件回归：skill.create 等非写入工具不会创建任何用户可见文件，
    // 约束文案必须明确禁止模型声称“已作为附件发送”。
    final prompt = AgentPromptBuilder.buildToolResultPrompt(
      rolePlaySystemPrompt: '你是工作助手，30岁，性别女，身份是助理。\n保持专业。',
      userRequest: '生成一份工资报表 Excel 文件',
      toolName: 'skill.create',
      toolResult: const {'ok': true, 'skillId': 's1'},
    );
    expect(prompt, contains('附件真实性规则'));
    expect(prompt, contains('已作为附件发送'));
    expect(prompt, contains('已通过工作流生成文件'));
    // 应点名 skill.create 并声明其不是文件写入工具、不可能产生附件。
    expect(prompt, contains('skill.create'));
    expect(prompt, contains('不是文件写入工具'));
    expect(prompt, contains('不可能产生任何附件'));
  });

  test('result prompt only allows attachment claim for ok=true write tool', () {
    // 反向：workspace.patch 且 ok=true 是合法写文件，不应出现
    // “当前工具 … 不是文件写入工具”这类禁止话术（否则会误伤正常交付）。
    final prompt = AgentPromptBuilder.buildToolResultPrompt(
      rolePlaySystemPrompt: '你是工作助手，30岁，性别女，身份是助理。\n保持专业。',
      userRequest: '生成 report.md',
      toolName: 'workspace.patch',
      toolResult: const {'ok': true, 'path': 'report.md'},
    );
    expect(prompt, isNot(contains('当前工具 `workspace.patch` 不是文件写入工具')));
  });

  test('result prompt forbids attachment claim when write tool not ok', () {
    // workspace.patch 返回 ok≠true：明确禁止说“请查看附件”。
    final prompt = AgentPromptBuilder.buildToolResultPrompt(
      rolePlaySystemPrompt: '你是工作助手，30岁，性别女，身份是助理。\n保持专业。',
      userRequest: '生成 page.html',
      toolName: 'workspace.patch',
      toolResult: const {'ok': false, 'error': 'write_failed'},
    );
    expect(prompt, contains('不要'));
    expect(prompt, contains('请查看附件'));
  });
}
