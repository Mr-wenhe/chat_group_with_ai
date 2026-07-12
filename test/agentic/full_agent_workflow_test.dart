import 'dart:io';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_launcher.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('five real-name roles generate skill files with durable progress',
      () async {
    final workspace = '${Directory.current.path}/agentic_output';
    await Directory(workspace).create(recursive: true);
    final launcher = LocalAgentBridgeLauncher();
    await launcher.start(workspace: workspace);
    addTearDown(launcher.stop);

    final api = ChatApiService();
    final tasks =
        <({AICharacter character, String request, String file, String marker})>[
      (
        character: _character('陈思远', '数据分析师'),
        request: '请生成文件 sales_analysis.py，内容必须是可运行的 Python 销售汇总脚本。',
        file: 'sales_analysis.py',
        marker: 'summarize_sales',
      ),
      (
        character: _character('林雅雯', '产品经理'),
        request: '请生成文件 product_requirement.md，写一份 AI 团队任务看板 PRD。',
        file: 'product_requirement.md',
        marker: '验收标准',
      ),
      (
        character: _character('周启明', '前端工程师'),
        request: '请生成文件 dashboard.html，制作一个可直接打开的中文 AI 团队看板。',
        file: 'dashboard.html',
        marker: 'AI 团队任务看板',
      ),
      (
        character: _character('赵文博', '测试工程师'),
        request: '@赵文博 请生成文件 test_plan.md，编写群聊 @ 文件任务测试计划。',
        file: 'test_plan.md',
        marker: '群聊 @ 路由',
      ),
      (
        character: _character('唐若溪', '安全工程师'),
        request: '@唐若溪 请生成文件 security_checklist.md，编写 AI 工作区安全检查清单。',
        file: 'security_checklist.md',
        marker: 'API Key',
      ),
    ];

    expect(
      parseMentionedCharacterIds(
          tasks[3].request, tasks.map((t) => t.character).toList()),
      ['e2e-赵文博'],
    );
    expect(
      parseMentionedCharacterIds(
          tasks[4].request, tasks.map((t) => t.character).toList()),
      ['e2e-唐若溪'],
    );

    for (final task in tasks) {
      final file = File('$workspace/${task.file}');
      if (await file.exists()) await file.delete();
      final progress = <AgentRuntimeProgress>[];
      final runtime = AgentRuntime(
        complete: (messages) => api.sendChatMessageStreamed(
          apiKey: 'local-test-key',
          provider: ApiProvider.custom,
          customBaseUrl: 'http://127.0.0.1:18080/v1',
          model: 'codex-local-test',
          messages: messages,
          maxRetries: 0,
        ),
        workspaceFileTool: WorkspaceFileTool(LocalAgentBridgeClient()),
        completionMaxRetries: 0,
        onProgress: (value) async => progress.add(value),
      );

      final result = await runtime.run(
        character: task.character,
        skills: const [],
        userRequest: task.request,
        autoApproveWriteTools: true,
      );

      expect(result.status, AgentRuntimeStatus.completed,
          reason: '${task.character.name}: ${result.message}');
      expect(progress.map((item) => item.stage),
          contains(AgentRuntimeProgressStage.toolCompleted));
      expect(await file.exists(), isTrue, reason: task.file);
      expect(await file.readAsString(), contains(task.marker));
    }
  });
}

AICharacter _character(String name, String role) {
  return AICharacter(
    id: 'e2e-$name',
    name: name,
    avatar: name.substring(0, 1),
    age: 30,
    role: role,
    personalityTags: const ['专业', '可靠', '主动汇报'],
    systemPrompt: '你是$name，职业是$role。你必须生成内容完整的文件，并持续汇报任务进度。',
    apiKey: '',
    apiProvider: 'custom',
    modelName: 'codex-local-test',
    customBaseUrl: 'http://127.0.0.1:18080/v1',
    agenticEnabled: true,
    toolPermissions: const [
      ToolPermission.workspaceRead,
      ToolPermission.workspacePatch,
    ],
  );
}
