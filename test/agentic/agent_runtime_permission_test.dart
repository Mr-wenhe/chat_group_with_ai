import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime returns normal content when no tool request is present',
      () async {
    final runtime = AgentRuntime(
      complete: (_) async => {'success': true, 'message': '直接回答'},
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const []),
      skills: [_skill()],
      userRequest: '聊聊',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.message, '直接回答');
  });

  test('runtime blocks tool request when permission is missing', () async {
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message': '''
```agent_tool
{"tool":"workspace.read","reason":"检查入口","args":{"path":"lib/main.dart"}}
```
''',
      },
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const []),
      skills: [_skill()],
      userRequest: 'review lib/main.dart',
    );

    expect(result.status, AgentRuntimeStatus.permissionMissing);
    expect(result.message, contains('workspaceRead'));
  });

  test('runtime waits for approval for write-like tools', () async {
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message': '''
```agent_tool
{"tool":"command.run","reason":"运行测试","args":{"command":"flutter test"}}
```
''',
      },
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.commandRun],
      ),
      skills: [_skill()],
      userRequest: '运行测试',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(result.pendingToolRequest, isNotNull);
  });

  test('runtime executes approved skill create tool', () async {
    var toolCalled = false;
    final runtime = AgentRuntime(
      complete: (_) async => {'success': true, 'message': '技能已保存'},
      skillCreateHandler: (args) async {
        toolCalled = true;
        return {'ok': true, 'skillId': 's1', 'name': args['name']};
      },
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.skillCreate],
      ),
      request: const ToolRequest(
        tool: AgentToolName.skillCreate,
        reason: '沉淀工作流',
        args: {
          'name': 'Flutter Reviewer',
          'instructions': ['Read code']
        },
      ),
      userRequest: '生成 skill',
    );

    expect(toolCalled, isTrue);
    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.message, '技能已保存');
  });

  test('runtime executes approved skill download tool', () async {
    var toolCalled = false;
    final runtime = AgentRuntime(
      complete: (_) async => {'success': true, 'message': '专家 skill 已安装'},
      skillDownloadHandler: (args) async {
        toolCalled = true;
        return {'ok': true, 'templateId': args['templateId']};
      },
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.skillDownload],
      ),
      request: const ToolRequest(
        tool: AgentToolName.skillDownload,
        reason: '安装职业专家能力',
        args: {'templateId': 'coding.flutter-reviewer'},
      ),
      userRequest: '下载代码专家 skill',
    );

    expect(toolCalled, isTrue);
    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.message, '专家 skill 已安装');
  });

  test('runtime can chain read result into a write approval request', () async {
    var calls = 0;
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async {
        calls++;
        if (calls == 1) {
          return {
            'success': true,
            'message': '''
```agent_tool
{"tool":"workspace.read","reason":"先读取目标文件","args":{"path":"README.md"}}
```
''',
          };
        }
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"写入生成的 Markdown","args":{"patch":"diff --git a/README.md b/README.md\\n--- a/README.md\\n+++ b/README.md\\n@@\\n-old\\n+new\\n"}}
```
''',
        };
      },
      workspaceFileTool: _FakeWorkspaceFileTool(
        readResult: {'path': 'README.md', 'content': 'old'},
      ),
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '帮我写 README.md',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(result.pendingToolRequest?.tool, AgentToolName.workspacePatch);
    expect(result.message, contains('workspace.patch'));
  });

  test('approved tool continues until the next write-like approval', () async {
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message': '''
```agent_tool
{"tool":"command.run","reason":"运行测试验证结果","args":{"command":"flutter test"}}
```
''',
      },
      workspaceFileTool: _FakeWorkspaceFileTool(
        patchResult: {'ok': true, 'exitCode': 0},
      ),
    );

    final result = await runtime.executeApprovedTool(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
        ToolPermission.commandRun,
      ]),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '写入文件',
        args: {'patch': 'diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md'},
      ),
      userRequest: '生成文件并测试',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(result.pendingToolRequest?.tool, AgentToolName.commandRun);
  });

  test('runtime can complete read -> patch approval -> command approval',
      () async {
    var calls = 0;
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async {
        calls++;
        if (calls == 1) {
          return {
            'success': true,
            'message': '''
```agent_tool
{"tool":"workspace.read","reason":"读取现有文档","args":{"path":"docs/ai_work_test.md"}}
```
''',
          };
        }
        if (calls == 2) {
          return {
            'success': true,
            'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"写入生成的 Markdown","args":{"patch":"diff --git a/docs/ai_work_test.md b/docs/ai_work_test.md\\n--- a/docs/ai_work_test.md\\n+++ b/docs/ai_work_test.md\\n@@\\n-old\\n+hello from tool test\\n"}}
```
''',
          };
        }
        if (calls == 3) {
          return {
            'success': true,
            'message': '''
```agent_tool
{"tool":"command.run","reason":"验证文件存在","args":{"command":"test -f docs/ai_work_test.md"}}
```
''',
          };
        }
        return {'success': true, 'message': '文件已生成并验证通过。'};
      },
      workspaceFileTool: _FakeWorkspaceFileTool(
        readResult: {'path': 'docs/ai_work_test.md', 'content': 'old'},
        patchResult: {'ok': true, 'exitCode': 0},
        commandResult: {'ok': true, 'exitCode': 0, 'stdout': ''},
      ),
    );

    final character = _character(toolPermissions: const [
      ToolPermission.workspaceRead,
      ToolPermission.workspacePatch,
      ToolPermission.commandRun,
    ]);

    final needsPatchApproval = await runtime.run(
      character: character,
      skills: [_skill()],
      userRequest: '生成 docs/ai_work_test.md 并验证',
    );
    expect(needsPatchApproval.status, AgentRuntimeStatus.waitingForApproval);
    expect(
      needsPatchApproval.pendingToolRequest?.tool,
      AgentToolName.workspacePatch,
    );

    final needsCommandApproval = await runtime.executeApprovedTool(
      character: character,
      request: needsPatchApproval.pendingToolRequest!,
      userRequest: '生成 docs/ai_work_test.md 并验证',
    );
    expect(needsCommandApproval.status, AgentRuntimeStatus.waitingForApproval);
    expect(
      needsCommandApproval.pendingToolRequest?.tool,
      AgentToolName.commandRun,
    );

    final completed = await runtime.executeApprovedTool(
      character: character,
      request: needsCommandApproval.pendingToolRequest!,
      userRequest: '生成 docs/ai_work_test.md 并验证',
    );
    expect(completed.status, AgentRuntimeStatus.completed);
    expect(completed.message, contains('验证通过'));
  });

  test('local file planner requests patch approval for explicit file creation',
      () async {
    final runtime = AgentRuntime(
      complete: (_) async => {'success': true, 'message': '不应调用模型'},
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '请在 docs/agentic_live_test.md 生成 Markdown，包含 Dart hello 程序。',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(result.pendingToolRequest?.tool, AgentToolName.workspacePatch);
    expect(
      result.pendingToolRequest?.args['patch'],
      allOf(
        contains('diff --git a/docs/agentic_live_test.md'),
        contains('@@ -0,0 +1,'),
        contains('```dart'),
        contains("print('hello from 代码大神')"),
      ),
    );
  });

  test('runtime explains when local bridge is unavailable', () async {
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message': '''
```agent_tool
{"tool":"workspace.read","reason":"读取文件","args":{"path":"README.md"}}
```
''',
      },
      workspaceFileTool: _FakeWorkspaceFileTool(throwOnRead: true),
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspaceRead],
      ),
      skills: [_skill()],
      userRequest: '读取 README.md',
    );

    expect(result.status, AgentRuntimeStatus.failed);
    expect(result.message, contains('本地工具桥接服务未启动'));
    expect(result.message, contains('dart run bin/local_agent_bridge.dart'));
  });
}

AICharacter _character({required List<ToolPermission> toolPermissions}) {
  return AICharacter(
    name: '代码大神',
    avatar: '💻',
    age: 30,
    role: '工程师',
    personalityTags: const ['代码'],
    systemPrompt: '写代码',
    apiKey: 'k',
    apiProvider: 'deepseek',
    toolPermissions: toolPermissions,
  )..agenticEnabled = true;
}

class _FakeWorkspaceFileTool extends WorkspaceFileTool {
  final Map<String, dynamic> readResult;
  final Map<String, dynamic> patchResult;
  final Map<String, dynamic> commandResult;
  final bool throwOnRead;

  _FakeWorkspaceFileTool({
    this.readResult = const {},
    this.patchResult = const {},
    this.commandResult = const {},
    this.throwOnRead = false,
  }) : super(LocalAgentBridgeClient());

  @override
  Future<Map<String, dynamic>> read(String path) async {
    if (throwOnRead) {
      throw Exception('SocketException: Connection refused');
    }
    return readResult;
  }

  @override
  Future<Map<String, dynamic>> applyPatch(String patch) async {
    return patchResult;
  }

  @override
  Future<Map<String, dynamic>> runCommand(String command) async {
    return commandResult;
  }
}

CharacterSkill _skill() {
  return CharacterSkill(
    characterId: 'c1',
    name: 'Code Review',
    domain: 'coding',
    description: 'Review code.',
    instructions: const ['Read files'],
    requiredPermissions: const [ToolPermission.workspaceRead],
  );
}
