import 'package:chat_group/features/agentic/agent_prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {

  test('Stage 03 prompt describes one strict JSON decision object', () {
    final prompt = AgentPromptBuilder.buildAgentDecisionPrompt(
      rolePlaySystemPrompt: '你是工作助手。',
      skills: const [],
      userRequest: '读取并检查 lib/main.dart',
    );

    expect(prompt, contains('固定顶层字段'));
    expect(prompt, contains('禁止复制到 tool.arguments'));
    expect(prompt, contains('不要在 arguments 中添加 action'));
    expect(prompt, contains('action 只能是 plan、tool、clarify、handoff、finish'));
    expect(prompt, contains('public_update'));
    expect(prompt, contains('只写用户可见的动作、依据或结论'));
    expect(prompt, contains('workspace.read'));
    expect(prompt, contains('workspace.document'));
    expect(prompt, contains('PDF、DOCX、XLSX'));
    expect(prompt, contains('workspace.read 仅适用于 UTF-8 文本或代码'));
    expect(prompt, contains('arguments 必须是 JSON 字符串数组'));
    expect(prompt, contains('"arguments":["generate_report.py"]'));
    expect(prompt, contains('"declaredImpact":["reports/economy.xlsx"]'));
    expect(prompt, isNot(contains('```agent_tool')));
    expect(prompt, isNot(contains('<tool_call>')));
  });

  test('Stage 03 prompt steers the model away from inline command bodies', () {
    // 回归：模型用 `python3 -c "..."` 内联一行流时，引号转义极易报语法错误，
    // 且内联代码会被判为“影响范围不确定”而每次都要重新审批。提示词必须要求
    // 先写脚本文件再执行，并限制产物登记范围。
    final prompt = AgentPromptBuilder.buildAgentDecisionPrompt(
      rolePlaySystemPrompt: '你是工作助手。',
      skills: const [],
      userRequest: '从网上取数并生成一份 Excel 排名表',
    );

    expect(prompt, contains('先用 workspace.patch 写出一个可运行的脚本文件'));
    expect(prompt, contains('python3 -c'));
    expect(prompt, contains('bash -c'));
    expect(prompt, contains('引号转义'));
    expect(prompt, contains('影响范围不确定'));
    expect(prompt, contains('不要登记中间脚本'));
    expect(prompt, contains('重复登记'));
    expect(prompt, contains('直接 finish'));
  });

  test('Stage 03 prompt requires chunked writes for long content', () {
    // 回归：用户要 5000+ 字报告时，模型把整篇正文塞进一次 workspace.patch 必然
    // 撞输出上限（实测 8192 token），动作 JSON 被截断、任务失败。提示词必须给出
    // 分块写法：每个分段各写独立文件 + 一次合并，并明确"不要反复写目标文件"
    // （workspace.patch 是整文件覆盖写，第二次写会把前一段冲掉）。
    final prompt = AgentPromptBuilder.buildAgentDecisionPrompt(
      rolePlaySystemPrompt: '你是工作助手。',
      skills: const [],
      userRequest: '生成一份 5000 字以上的量子力学研究报告 Word 文档',
    );

    expect(prompt, contains('单次决策的输出有上限'));
    expect(prompt, contains('3000 字以内'));
    expect(prompt, contains('report.part1.md'));
    expect(prompt, contains('整文件覆盖写、没有追加'));
    expect(prompt, contains('pandoc'));
    expect(prompt, contains('declaredImpact'));
    // 触发条件写成可观察的单位，而不是"明显短于上限"这类无法据以决策的说法。
    expect(prompt, isNot(contains('明显短于上限')));
    // 旧的"一次写完"说法必须消失，否则模型仍会一次塞满。
    expect(prompt, isNot(contains('文件的完整内容**直接放进')));
  });

  test('Stage 03 prompt documents the workspace.list root default', () {
    final prompt = AgentPromptBuilder.buildAgentDecisionPrompt(
      rolePlaySystemPrompt: '你是工作助手。',
      skills: const [],
      userRequest: '看看工作区里有哪些文件',
    );

    expect(prompt, contains('workspace.list'));
    expect(prompt, contains('省略、留空或写 "."'));
    expect(prompt, contains('不要为了列目录而调用 command.run'));
  });

  test('Stage 03 weather tasks use the structured forecast tool', () {
    final prompt = AgentPromptBuilder.buildAgentDecisionPrompt(
      rolePlaySystemPrompt: '你是工作助手。',
      skills: const [],
      userRequest: '帮我生成一份MD文档，记录未来7天的天气',
    );

    expect(prompt, contains('weather.forecast'));
    expect(prompt, contains('不要读取 weather_location.json'));
    expect(prompt, contains('没有城市时使用默认查询地点'));
    expect(prompt, contains('未指定文件名时使用 未来7天天气.md'));
    expect(prompt, contains('禁止使用 MD7.md'));
  });

  test(
      'Stage 03 prompt explains the authorized command working directory default',
      () {
    final prompt = AgentPromptBuilder.buildAgentDecisionPrompt(
      rolePlaySystemPrompt: '你是工作助手。',
      skills: const [],
      userRequest: '检查一个本机命令是否可用',
    );

    expect(prompt, contains('command.run'));
    expect(prompt, contains('workingDirectory'));
    expect(prompt, contains('当前授权工作区根目录'));
    expect(prompt, isNot(contains('默认使用 "."')));
    expect(prompt, contains('declaredImpact'));
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
