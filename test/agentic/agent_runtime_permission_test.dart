import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runtime returns normal content when no tool request is present', () async {
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
