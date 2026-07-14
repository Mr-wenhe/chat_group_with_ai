import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('work mode has enough budget for multi-step delivery pipelines', () {
    expect(AgentRuntime.maxToolSteps, greaterThanOrEqualTo(12));
  });

  test('work mode pauses before reading a workspace file', () async {
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message': '''
```agent_tool
{"tool":"workspace.read","reason":"读取需求","args":{"path":"requirements.md"}}
```
''',
      },
      approvalPolicy: WorkModePolicy.requiresApproval,
    );

    final result = await runtime.run(
      character: _character(const [ToolPermission.workspaceRead]),
      skills: [_skill()],
      userRequest: '根据需求继续工作',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(result.pendingToolRequest?.tool, AgentToolName.workspaceRead);
  });

  test('work mode can create app-local skill metadata without approval',
      () async {
    var completions = 0;
    var created = false;
    final runtime = AgentRuntime(
      complete: (_) async {
        completions++;
        if (completions == 1) {
          return {
            'success': true,
            'message': '''
```agent_tool
{"tool":"skill.create","reason":"补充周报能力","args":{"name":"Weekly Report","domain":"writing","description":"生成周报","instructions":["整理进展"],"permissions":[]}}
```
''',
          };
        }
        return {'success': true, 'message': '技能准备完成。'};
      },
      skillCreateHandler: (_) async {
        created = true;
        return {'ok': true, 'skillId': 'weekly-report'};
      },
      approvalPolicy: WorkModePolicy.requiresApproval,
    );

    final result = await runtime.run(
      character: _character(const [ToolPermission.skillCreate]),
      skills: [_skill()],
      userRequest: '整理本周周报',
    );

    expect(created, isTrue);
    expect(result.status, AgentRuntimeStatus.completed);
  });

  test('rejecting a sensitive step replans instead of cancelling the task',
      () async {
    final runtime = AgentRuntime(
      complete: (_) async => {'success': true, 'message': '已跳过读取，其余工作已完成。'},
      approvalPolicy: WorkModePolicy.requiresApproval,
      grantedPermissions: ToolPermission.values.toSet(),
    );
    const rejected = ToolRequest(
      tool: AgentToolName.workspaceRead,
      reason: '读取需求',
      args: {'path': 'requirements.md'},
    );

    final result = await runtime.skipRejectedTool(
      character: _character(ToolPermission.values),
      request: rejected,
      userRequest: '完成项目',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.message, contains('已跳过'));
  });

  test('closing work mode stops before planning or another tool call',
      () async {
    var completionCalled = false;
    final runtime = AgentRuntime(
      complete: (_) async {
        completionCalled = true;
        return {'success': true, 'message': '不应执行'};
      },
      shouldCancel: () => true,
      approvalPolicy: WorkModePolicy.requiresApproval,
    );

    final result = await runtime.run(
      character: _character(ToolPermission.values),
      skills: [_skill()],
      userRequest: '继续工作',
    );

    expect(completionCalled, isFalse);
    expect(result.status, AgentRuntimeStatus.failed);
    expect(result.message, contains('工作模式已关闭'));
  });
}

AICharacter _character(List<ToolPermission> permissions) => AICharacter(
      id: 'worker',
      name: 'Worker',
      avatar: '🤖',
      age: 20,
      role: '工作助理',
      personalityTags: const [],
      systemPrompt: '完成交付',
      apiKey: 'key',
      apiProvider: 'deepseek',
      toolPermissions: permissions,
    )..agenticEnabled = true;

CharacterSkill _skill() => CharacterSkill(
      characterId: 'worker',
      name: 'General Work',
      domain: 'general',
      description: '完成任务',
      instructions: const ['规划并执行'],
      requiredPermissions: const [],
    );
