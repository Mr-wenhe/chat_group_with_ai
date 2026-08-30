import 'dart:async';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/agent_progress_meta.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resumed runtime preserves completed operations at next checkpoint',
      () async {
    const completed = ToolRequest(
      tool: AgentToolName.workspaceRead,
      reason: '已读取需求',
      args: {'path': 'requirements.md'},
    );
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {
        'success': true,
        'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"继续生成页面","args":{"path":"page.html","content":"<html></html>"}}
```
''',
      },
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '继续完成页面',
      priorExecutedRequests: [completed],
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(result.executedToolRequests, contains(completed));
    expect(result.pendingToolRequest?.tool, AgentToolName.workspacePatch);
  });

  test('default runtime lets the model generate requested file content',
      () async {
    var completionCalls = 0;
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {
        'path': 'page.html',
        'content': '<!doctype html><title>文和先生</title>',
      },
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 42},
    );
    final runtime = AgentRuntime(
      complete: (_) async {
        completionCalls++;
        if (completionCalls == 1) {
          return {
            'success': true,
            'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成完整个人主页","args":{"path":"page.html","content":"<!doctype html><html><head><title>文和先生</title></head><body><h1>灵魂收集者</h1><p>亡灵服务 · 鬼魂街大佬</p><nav>音乐 · 菜单</nav></body></html>"}}
```
''',
          };
        }
        return {'success': true, 'message': '完整个人主页已生成。'};
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '帮我写一个 HTML 个人主页，姓名文和先生，职业灵魂收集者，包含音乐和菜单',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(completionCalls, 1);
    expect(fakeTool.lastWriteContent, contains('文和先生'));
    expect(fakeTool.lastWriteContent, contains('灵魂收集者'));
    expect(fakeTool.lastWriteContent, contains('音乐 · 菜单'));
    expect(fakeTool.lastWriteContent, isNot(contains('内容由 AI 根据用户请求生成')));
  });

  test('direct file generation sends the shared role-play prompt', () async {
    late List<Map<String, dynamic>> capturedMessages;
    final character = _character(
      toolPermissions: const [ToolPermission.workspacePatch],
    );
    final runtime = AgentRuntime(
      complete: (messages) async {
        capturedMessages = messages;
        return const {
          'success': true,
          'message': '<!doctype html><html><body><h1>交付</h1></body></html>',
        };
      },
      workspaceFileTool: _FakeWorkspaceFileTool(
        patchResult: {'ok': true, 'path': 'page.html', 'bytes': 48},
      ),
    );

    final result = await runtime.run(
      character: character,
      skills: [_skill()],
      userRequest: '生成一个 HTML 个人主页',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(capturedMessages.first['role'], 'system');
    expect(
      capturedMessages.first['content']
              .toString()
              .split(character.rolePlaySystemPrompt)
              .length -
          1,
      1,
    );
    expect(capturedMessages.first['content'],
        contains(character.rolePlaySystemPrompt));
  });

  test('work-mode tool result prompt keeps the shared role identity', () async {
    final character = _character(
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    final capturedMessages = <List<Map<String, dynamic>>>[];
    var calls = 0;
    final runtime = AgentRuntime(
      complete: (messages) async {
        capturedMessages.add(messages);
        calls++;
        if (calls == 1) {
          return const {
            'success': true,
            'message': '```agent_tool\n'
                '{"tool":"workspace.read","reason":"读取需求",'
                '"args":{"path":"requirements.md"}}\n```',
          };
        }
        return const {'success': true, 'message': '已完成。'};
      },
      workspaceFileTool: _FakeWorkspaceFileTool(
        readResult: {'ok': true, 'path': 'requirements.md', 'content': '需求'},
      ),
    );

    final result = await runtime.run(
      character: character,
      skills: [_skill()],
      userRequest: '读取需求并总结',
      approved: true,
      workModeContext: WorkModePolicy.planningContext(character),
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(capturedMessages, hasLength(2));
    expect(
      capturedMessages[0]
              .first['content']
              .toString()
              .split(character.rolePlaySystemPrompt)
              .length -
          1,
      1,
    );
    expect(
      capturedMessages[1]
              .first['content']
              .toString()
              .split(character.rolePlaySystemPrompt)
              .length -
          1,
      1,
    );
    expect(capturedMessages[1].first['content'],
        contains(character.rolePlaySystemPrompt));
  });

  test('raw HTML from planner is recovered into a file instead of chat text',
      () async {
    var completionCalls = 0;
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {
        'path': 'page.html',
        'content': '<!doctype html><html><body>完整主页</body></html>',
      },
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 53},
    );
    final runtime = AgentRuntime(
      complete: (_) async {
        completionCalls++;
        if (completionCalls == 1) {
          return {
            'success': true,
            'message': '''```html
<!doctype html>
<html lang="zh-CN"><body><h1>文和先生</h1><p>灵魂收集者</p></body></html>
```''',
          };
        }
        return {'success': true, 'message': '个人主页已经写入文件。'};
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '帮我写一个 HTML 个人介绍页',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'page.html');
    expect(fakeTool.lastWriteContent, contains('<h1>文和先生</h1>'));
    expect(result.message, isNot(contains('<!doctype html>')));
    expect(result.message, isNot(contains('<h1>')));
  });

  test('鬼魂街个人首页裸 HTML 回复会被写成可交付文件', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {
        'path': 'page.html',
        'content': '<!doctype html><html><body><h1>鬼魂街大佬</h1></body></html>',
      },
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 76},
    );
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message': '''
这是完整的可直接运行的鬼魂街大佬专属个人首页代码，直接复制保存为 `.html` 文件打开即可体验：
```html
<!doctype html><html><body><h1>鬼魂街大佬</h1><div>万魂幡吸魂</div><button>桃心彩蛋</button></body></html>
```
''',
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '帮我设计一个鬼魂街大佬专属个人首页，要有万魂幡吸魂和桃心彩蛋特效',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'page.html');
    expect(fakeTool.lastWriteContent, contains('万魂幡吸魂'));
    expect(result.executedToolRequests, isNotEmpty);
    expect(result.message, isNot(contains('直接复制保存')));
    expect(result.message, contains('文件已生成'));
  });

  test('file intent reprompts narration and still writes a real file',
      () async {
    var completionCalls = 0;
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {'path': 'page.html', 'content': '<html>完整主页</html>'},
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 22},
    );
    final runtime = AgentRuntime(
      complete: (_) async {
        completionCalls++;
        if (completionCalls == 1) {
          return {'success': true, 'message': '好的，我马上帮你制作这个个人主页。'};
        }
        if (completionCalls == 2) {
          return {
            'success': true,
            'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成主页","args":{"path":"page.html","content":"<html><body><h1>文和先生</h1></body></html>"}}
```
''',
          };
        }
        return {'success': true, 'message': '个人主页已生成。'};
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '帮我写一个 HTML 个人主页',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(completionCalls, 2);
    expect(fakeTool.lastWritePath, 'page.html');
    expect(fakeTool.lastWriteContent, contains('文和先生'));
    expect(result.message, isNot(contains('我马上帮你制作')));
  });

  test('tool format correction is attempted up to three times', () async {
    var calls = 0;
    final runtime = AgentRuntime(
      complete: (_) async {
        calls++;
        if (calls < 4) {
          return {'success': true, 'message': 'workspace.patch 格式仍不正确'};
        }
        return {
          'success': true,
          'message':
              '```agent_tool\n{"tool":"workspace.patch","reason":"生成页面","args":{"path":"page.html","content":"<html></html>"}}\n```',
        };
      },
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '生成 page.html',
    );

    expect(calls, 4);
    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(result.pendingToolRequest?.tool, AgentToolName.workspacePatch);
  });

  test('planning retries once after a transient 503 response', () async {
    var completionCalls = 0;
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {'path': 'page.html', 'content': '<html>重试成功</html>'},
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 20},
    );
    final runtime = AgentRuntime(
      complete: (_) async {
        completionCalls++;
        if (completionCalls == 1) {
          return {
            'success': false,
            'message': 'HTTP 503: upstream unavailable'
          };
        }
        if (completionCalls == 2) {
          return {
            'success': true,
            'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成主页","args":{"path":"page.html","content":"<html><body>重试成功</body></html>"}}
```
''',
          };
        }
        return {'success': true, 'message': '主页已生成。'};
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '帮我写一个 HTML 个人主页',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(completionCalls, 2);
    expect(fakeTool.lastWriteContent, contains('重试成功'));
    expect(result.message, isNot(contains('503')));
  });

  test('planning timeout falls back to deterministic C++ file generation',
      () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {
        'ok': true,
        'path': 'system_resource_monitor.cpp',
        'bytes': 256,
      },
    );
    final runtime = AgentRuntime(
      complete: (_) async => throw TimeoutException('planning stalled'),
      workspaceFileTool: fakeTool,
      retrySleep: (_) async {},
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '帮我写个 C++ 程序，作用是获取当前系统的信息，然后生成文件贴给我',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'system_resource_monitor.cpp');
    expect(fakeTool.lastWriteContent, contains('#include <sys/sysctl.h>'));
    expect(result.message, isNot(contains('工具任务失败')));
  });

  test('model timeout never writes a generic placeholder as Python code',
      () async {
    final fakeTool = _FakeWorkspaceFileTool();
    final runtime = AgentRuntime(
      complete: (_) async => throw TimeoutException('generation stalled'),
      workspaceFileTool: fakeTool,
      retrySleep: (_) async {},
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: 'Create validated_sales.py with sales statistics.',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.failed);
    expect(fakeTool.lastWritePath, isNull);
    expect(fakeTool.lastWriteContent, isNull);
  });

  test('explicit rich HTML request skips tool planning and generates once',
      () async {
    var completionCalls = 0;
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 512},
      readResult: {
        'path': 'page.html',
        'content': '<!doctype html><title>宇宙遐游</title><canvas></canvas>',
      },
    );
    final runtime = AgentRuntime(
      complete: (messages) async {
        completionCalls++;
        final systemPrompt = messages.first['content']?.toString() ?? '';
        if (!systemPrompt.contains('用户要你生成一个文件')) {
          throw TimeoutException('tool planning streamed a huge JSON payload');
        }
        return {
          'success': true,
          'message': '<!doctype html>\n'
              '<html lang="zh-CN"><head><title>宇宙遐游</title></head>'
              '<body><canvas id="space"></canvas></body></html>',
        };
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '前面聊天都无视掉，现在 我要你生成 我要你使用 前端最新的架构 '
          '和 视觉冲击，去生成一个在 宇宙遨游的前端html页面',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(completionCalls, 1, reason: '明确的新建文件请求不应先让模型把全文塞进工具计划 JSON');
    expect(fakeTool.lastWritePath, 'page.html');
    expect(fakeTool.lastWriteContent, contains('<canvas id="space">'));
  });

  test('truncated rich HTML is continued before the file is written', () async {
    var completionCalls = 0;
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 1024},
      readResult: {
        'path': 'page.html',
        'content': '<!doctype html><html><body><script>'
            'for (let i = 0; i < positions.length; i++) {}'
            '</script></body></html>',
      },
    );
    final runtime = AgentRuntime(
      complete: (messages) async {
        completionCalls++;
        if (completionCalls == 1) {
          return {
            'success': true,
            'message': '<!doctype html><html><body><script>'
                'for (let i = 0; i < positions.length; i++) {',
            'completionTokens': 8192,
          };
        }
        expect(
          messages.last['content'],
          contains('从上一条末尾的下一个字符开始'),
        );
        return {
          'success': true,
          'message': '}}</script></body></html>',
          'completionTokens': 16,
        };
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '生成一个在宇宙遨游的前端 html 页面',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(completionCalls, 2);
    expect(fakeTool.lastWriteContent, endsWith('</script></body></html>'));
    expect(fakeTool.lastWriteContent, contains('positions.length'));
  });

  test('fallback recovers unclosed fenced source into a file', () async {
    var calls = 0;
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'main.cpp', 'bytes': 64},
      readResult: {
        'path': 'main.cpp',
        'content': '#include <iostream>\nint main() { return 0; }\n',
      },
    );
    final runtime = AgentRuntime(
      complete: (_) async {
        calls++;
        if (calls == 1) {
          return {'success': true, 'message': '我来生成这个文件。'};
        }
        return {
          'success': true,
          'message': '```cpp\n#include <iostream>\nint main() { return 0; }\n',
        };
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '帮我生成一个 C++ 程序文件',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'main.cpp');
    expect(fakeTool.lastWriteContent, contains('int main()'));
    expect(result.message, isNot(contains('#include <iostream>')));
  });

  test('planning retries a receive timeout five times before failing',
      () async {
    var completionCalls = 0;
    final runtime = AgentRuntime(
      complete: (_) async {
        completionCalls++;
        return {'success': false, 'message': '连接超时'};
      },
      retrySleep: (_) async {},
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const []),
      skills: [_skill()],
      userRequest: '帮我写一个 HTML 个人主页',
    );

    expect(result.status, AgentRuntimeStatus.failed);
    expect(completionCalls, 6);
    expect(result.message, contains('连接超时'));
  });

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

  test('runtime emits durable progress after every completed tool step',
      () async {
    final progress = <AgentRuntimeProgress>[];
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message':
            '```agent_tool\n{"tool":"workspace.patch","reason":"写文件","args":{"path":"page.html","content":"<html></html>"}}\n```',
      },
      workspaceFileTool: _FakeWorkspaceFileTool(
        patchResult: const {'ok': true, 'path': 'page.html'},
      ),
      onProgress: (value) async => progress.add(value),
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '生成页面',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(progress, isNotEmpty);
    expect(progress.last.stage, AgentRuntimeProgressStage.toolCompleted);
    expect(progress.last.executedRequests.single.tool,
        AgentToolName.workspacePatch);
  });

  test(
      'runtime rejects a redacted write checkpoint instead of writing empty content',
      () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: const {'ok': true, 'path': 'missing-content.txt'},
    );
    final runtime = AgentRuntime(
      complete: (_) async => const {'success': true, 'message': '不应调用总结'},
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '恢复写入',
        args: {
          'path': 'missing-content.txt',
          'contentLength': 42,
        },
      ),
      userRequest: '继续上次写入',
    );

    expect(result.status, AgentRuntimeStatus.failed);
    expect(result.message, contains('缺少完整内容'));
    expect(fakeTool.lastWriteContent, isNull);
  });

  test('runtime routes an exact patch through the workspace patch adapter',
      () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: const {'ok': true, 'path': 'note.txt'},
      readResult: const {
        'path': 'note.txt',
        'content': 'after',
      },
      allowReadBeforeWrite: true,
    );
    final runtime = AgentRuntime(
      complete: (_) async => const {'success': true, 'message': '不应调用总结'},
      workspaceFileTool: fakeTool,
    );
    const sha =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '精确修改',
        args: {
          'path': 'note.txt',
          'expectedSha256': sha,
          'expectedFragment': 'before',
          'replacement': 'after',
        },
      ),
      userRequest: '修改 note.txt',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWriteContent, isNull);
    expect(fakeTool.lastPatch, isNotNull);
    expect(fakeTool.lastPatch, contains('expectedSha256'));
  });

  test('sensitive writes never echo readback content or create an attachment',
      () async {
    const secret = 'TOKEN=do-not-echo';
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: const {'ok': true, 'path': '.env'},
      sensitivePaths: const {'.env'},
    );
    final runtime = AgentRuntime(
      complete: (_) async => const {'success': true, 'message': '不应调用总结'},
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '更新配置',
        args: {'path': '.env', 'content': secret},
      ),
      userRequest: '更新 .env',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.toolResult?['sensitive'], isTrue);
    expect(result.toolResult?['readbackContent'], isNull);
    expect(result.message, isNot(contains(secret)));
  });

  test('sensitive writes fail closed when local readback cannot be verified',
      () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: const {'ok': true, 'path': '.env'},
      sensitivePaths: const {'.env'},
      throwOnRead: true,
    );
    final runtime = AgentRuntime(
      complete: (_) async => const {'success': true, 'message': '不应调用总结'},
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '更新配置',
        args: {'path': '.env', 'content': 'TOKEN=secret'},
      ),
      userRequest: '更新 .env',
    );

    expect(result.toolResult?['ok'], isFalse);
    expect(result.toolResult?['error'], 'readback_unverified');
    expect(result.toolResult?['readbackContent'], isNull);
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

  test('runtime proactively requests skill.create when no skill matches',
      () async {
    var completionCalls = 0;
    final runtime = AgentRuntime(
      complete: (_) async {
        completionCalls++;
        return {'success': true, 'message': '不应先调用模型'};
      },
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.skillCreate],
      ),
      skills: [_skill()],
      userRequest: '建立门店咖啡杯测流程',
      forceSkillCreation: true,
    );

    expect(completionCalls, 0);
    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(result.pendingToolRequest?.tool, AgentToolName.skillCreate);
    expect(result.pendingToolRequest?.args['instructions'], isA<List>());
    expect(result.pendingToolRequest?.args['description'], contains('咖啡杯测'));
  });

  test('创建技能后返回的裸 HTML 仍会继续转成文件写入', () async {
    const request = '帮我设计一个鬼魂街大佬专属个人首页，要有万魂幡吸魂和桃心彩蛋特效';
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {
        'path': 'page.html',
        'content': '<!doctype html><html><body>万魂幡吸魂·桃心彩蛋</body></html>',
      },
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 72},
    );
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message': '''
这是完整的可直接运行代码，直接复制保存为 `.html` 文件：
```html
<!doctype html><html><body>万魂幡吸魂·桃心彩蛋</body></html>
```
''',
      },
      workspaceFileTool: fakeTool,
      skillCreateHandler: (_) async => {
        'ok': true,
        'skillId': 'ghost-page-skill',
        'name': '鬼魂街首页生成',
      },
    );
    final character = _character(
      name: '鬼魂街大佬',
      toolPermissions: const [
        ToolPermission.skillCreate,
        ToolPermission.workspacePatch,
      ],
    );

    final skillApproval = await runtime.run(
      character: character,
      skills: [_skill()],
      userRequest: request,
      forceSkillCreation: true,
    );
    expect(skillApproval.status, AgentRuntimeStatus.waitingForApproval);

    final writeApproval = await runtime.executeApprovedTool(
      character: character,
      request: skillApproval.pendingToolRequest!,
      userRequest: request,
    );
    expect(writeApproval.status, AgentRuntimeStatus.waitingForApproval);
    expect(
        writeApproval.pendingToolRequest?.tool, AgentToolName.workspacePatch);
    expect(writeApproval.pendingToolRequest?.args['path'], 'page.html');

    final completed = await runtime.executeApprovedTool(
      character: character,
      request: writeApproval.pendingToolRequest!,
      userRequest: request,
      priorExecutedRequests: writeApproval.executedToolRequests,
    );
    expect(completed.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'page.html');
    expect(fakeTool.lastWriteContent, contains('万魂幡吸魂'));
    expect(completed.message, contains('文件已生成'));
  });

  test('创建技能后口头声称已交付不能跳过真实文件写入', () async {
    const userRequest = '使用前端最新架构和视觉冲击，生成一个宇宙邀游 HTML 页面';
    var completionCalls = 0;
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {
        'path': 'page.html',
        'content':
            '<!doctype html><html><body><canvas id="space"></canvas></body></html>',
      },
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 78},
    );
    final runtime = AgentRuntime(
      complete: (_) async {
        completionCalls++;
        if (completionCalls == 1) {
          return {
            'success': true,
            'message': '专属的“宇宙邀游”前端页面已生成完毕，请查看附件。',
          };
        }
        return {
          'success': true,
          'message':
              '<!doctype html><html><body><canvas id="space"></canvas></body></html>',
        };
      },
      workspaceFileTool: fakeTool,
      skillCreateHandler: (_) async => {
        'ok': true,
        'skillId': 'space-page-skill',
        'name': '宇宙页面生成',
      },
    );
    final character = _character(
      toolPermissions: const [
        ToolPermission.skillCreate,
        ToolPermission.workspacePatch,
      ],
    );

    final skillApproval = await runtime.run(
      character: character,
      skills: [_skill()],
      userRequest: userRequest,
      forceSkillCreation: true,
    );
    final writeApproval = await runtime.executeApprovedTool(
      character: character,
      request: skillApproval.pendingToolRequest!,
      userRequest: userRequest,
    );

    expect(writeApproval.status, AgentRuntimeStatus.waitingForApproval);
    expect(
        writeApproval.pendingToolRequest?.tool, AgentToolName.workspacePatch);
    expect(writeApproval.pendingToolRequest?.args['content'],
        contains('canvas id="space"'));

    final completed = await runtime.executeApprovedTool(
      character: character,
      request: writeApproval.pendingToolRequest!,
      userRequest: userRequest,
      priorExecutedRequests: writeApproval.executedToolRequests,
    );

    expect(completed.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'page.html');
    expect(fakeTool.lastWriteContent, contains('canvas id="space"'));
    expect(completed.message, contains('文件已生成'));
  });

  test('文件写入失败后口头声称已生成仍必须返回失败', () async {
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message': '页面已生成，请查看附件。',
      },
      workspaceFileTool: _FakeWorkspaceFileTool(
        patchResult: const {
          'ok': false,
          'error': 'write_failed',
          'message': '工作区不可写',
        },
      ),
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '生成宇宙页面',
        args: {
          'path': 'space.html',
          'content': '<!doctype html><html></html>',
        },
      ),
      userRequest: '生成宇宙邀游 space.html',
    );

    expect(result.status, AgentRuntimeStatus.failed);
    expect(result.message, contains('工作区不可写'));
    expect(result.message, isNot(contains('请查看附件')));
  });

  test('请求生成 PDF 报告时二进制文档优雅降级为 Markdown 而非失败', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'report.md', 'bytes': 12},
    );
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message': '报告已生成，请查看附件。',
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '生成 PDF 报告',
        args: {
          'path': 'report.pdf',
          'content': '# 月度报告\n\n一些内容。',
        },
      ),
      userRequest: '帮我生成一份 PDF 格式的项目总结报告',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    // 实际落盘为降级后的 Markdown 路径，而非原始二进制路径。
    expect(fakeTool.lastWritePath, 'report.md');
    expect(result.message, contains('report.md'));
    // 交付信息应明确标注已降级，而不是假装真的生成了 PDF 二进制。
    expect(result.message, contains('降级'));
  });

  test('请求生成 Excel 表格被识别为文件意图并降级为 Markdown 真实写入', () async {
    // 回归：修复前 _inferGeneratedFilePath 不认识 excel，导致请求落入规划路径，
    // LLM 可能用 skill.create 等非写入工具“空口声称已作为附件发送”（虚假附件）。
    // 现在 excel 应被识别，走文件生成路径，二进制 xlsx 优雅降级为真实可写的 .md。
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'report.md', 'bytes': 20},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成工资报表","args":{"path":"report.xlsx","content":"# 工资报表\\n\\n| 姓名 | 工资 |\\n| --- | --- |\\n| 张三 | 8000 |"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '我要一份工资报表excel文件',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    // 请求应被识别为文件意图，从而进入“直接生成文件”路径（生成 prompt 会带上
    // 推断出的文件名 report.xlsx），而不是落入规划路径让 LLM 自由发挥。
    expect(firstSystemPrompt, contains('report.xlsx'));
    // 真实落盘为降级后的 Markdown 文件，而非伪造附件或空口承诺。
    expect(fakeTool.lastWritePath, 'report.md');
    expect(result.message, contains('report.md'));
    // 交付信息应明确标注已降级，而不是假装真的生成了 xlsx 二进制。
    expect(result.message, contains('降级'));
  });

  test('请求生成 PPT 演示文稿被识别为文件意图并降级为 Markdown 真实写入', () async {
    // 补全 ppt/pptx 识别后，应被识别为文件意图走“直接生成”路径，
    // 二进制 pptx 优雅降级为真实可写的 .md（与 Excel/PDF/DOCX 一致）。
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'slides.md', 'bytes': 20},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成演示文稿","args":{"path":"slides.pptx","content":"# 演示文稿\\n\\n幻灯片内容"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '我要一份ppt演示文稿',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(firstSystemPrompt, contains('slides.pptx'));
    // 实际落盘为降级后的 Markdown，而非伪造 pptx 二进制附件。
    expect(fakeTool.lastWritePath, 'slides.md');
    expect(result.message, contains('slides.md'));
    expect(result.message, contains('降级'));
  });

  test('请求生成 CSV 表格数据被识别为 data.csv 文件意图', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'data.csv', 'bytes': 20},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成表格","args":{"path":"data.csv","content":"name,score\\nAlice,90"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '生成csv表格数据',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    // csv 分支必须在 excel 之前，因此“表格数据”命中 csv 而非 xlsx。
    expect(firstSystemPrompt, contains('data.csv'));
    expect(fakeTool.lastWritePath, 'data.csv');
    expect(result.message, contains('data.csv'));
  });

  test('请求生成 TXT 文本被识别为 note.txt 文件意图', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'note.txt', 'bytes': 12},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成文本","args":{"path":"note.txt","content":"一些纯文本内容"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '写个txt文本',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(firstSystemPrompt, contains('note.txt'));
    expect(fakeTool.lastWritePath, 'note.txt');
    expect(result.message, contains('note.txt'));
  });

  test('请求生成 JSON 配置被识别为 data.json 文件意图', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'data.json', 'bytes': 24},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成配置","args":{"path":"data.json","content":"{\\"name\\":\\"demo\\"}"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '来个json配置',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(firstSystemPrompt, contains('data.json'));
    expect(fakeTool.lastWritePath, 'data.json');
    expect(result.message, contains('data.json'));
  });

  test('请求生成 SQL 建表脚本被识别为 script.sql 文件意图', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'script.sql', 'bytes': 30},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成建表脚本","args":{"path":"script.sql","content":"CREATE TABLE t (id INT);"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '创建sql建表脚本',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(firstSystemPrompt, contains('script.sql'));
    expect(fakeTool.lastWritePath, 'script.sql');
    expect(result.message, contains('script.sql'));
  });

  test('doc 文档请求被识别为 docx 而非 md', () async {
    // 回归：doc/docx/文档 都应导向 docx 分支（在 md 之前）。docx 是二进制，
    // 运行时降级为 .md 真实写入，而不是落入 md 分支或伪造 docx 附件。
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'report.md', 'bytes': 16},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成文档","args":{"path":"report.docx","content":"# 文档\\n\\n正文"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '我要一份doc文档',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    // 推断路径命中 docx 分支（doc文档 → report.docx），而不是被 md 分支抢走。
    expect(firstSystemPrompt, contains('report.docx'));
    // 实际落盘为降级后的 Markdown，而非伪造 docx 二进制。
    expect(fakeTool.lastWritePath, 'report.md');
    expect(result.message, contains('report.md'));
    expect(result.message, contains('降级'));
  });

  test('写一份技术文档被识别为 report.md（文档关键词在 md 分支）', () async {
    // 回归：docx 分支仅匹配带 doc/word 前缀的"文档"，裸"技术文档"应由
    // md 分支（含「文档」关键词）承接为 report.md。
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'report.md', 'bytes': 20},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        // _generateFileContentRequest 期望模型直接返回文件内容文本，
        // 而非工具请求 JSON。直接返回 Markdown 正文即可。
        return {
          'success': true,
          'message': '# 技术文档\n\n这是一份技术文档的正文内容。\n',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '写一份技术文档',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(firstSystemPrompt, contains('report.md'));
    expect(fakeTool.lastWritePath, 'report.md');
    expect(fakeTool.lastWritePath, 'report.md');
  });

  test('展示一个表格不被误判为文件生成意图', () async {
    // "展示"属于 readModifyVerb，且"一个表格"已从 wishNewFile 移除，
    // 因此展示类请求不应进入文件生成路径。
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '这是一个表格示例：...',
        };
      },
    );
    final result = await runtime.run(
      character: _character(toolPermissions: const []),
      skills: [_skill()],
      userRequest: '展示一个表格',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.pendingToolRequest, isNull);
    expect(firstSystemPrompt, isNot(contains('report.xlsx')));
  });

  test('读取意图（读一下 ppt 文件）不误判为文件生成', () async {
    // 读取/查看类请求必须让 _inferGeneratedFilePath 返回 null，不能进入
    // “直接生成”路径，否则会凭空声称已生成文件（虚假附件 Bug 同类风险）。
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '这是该 PPT 文件的内容概要，我并没有新建文件。',
        };
      },
    );
    final result = await runtime.run(
      character: _character(toolPermissions: const []),
      skills: [_skill()],
      userRequest: '读一下这个ppt文件',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.pendingToolRequest, isNull);
    // 系统提示中不应出现 slides.pptx，说明 _inferGeneratedFilePath 返回了 null。
    expect(firstSystemPrompt, isNot(contains('slides.pptx')));
    expect(result.message, contains('内容概要'));
  });

  test('skill.create 后 Markdown Java C++ 都必须继续为真实写入请求', () async {
    final cases = <({String request, String path, String content})>[
      (
        request: '生成一份 Markdown 技术文档',
        path: 'report.md',
        content: '# 技术文档\n\n## 架构\n\n内容',
      ),
      (
        request: '生成一个 Java 命令行程序',
        path: 'Main.java',
        content:
            'public class Main { public static void main(String[] args) { System.out.println("ok"); } }',
      ),
      (
        request: '生成一个 C++ 命令行程序',
        path: 'main.cpp',
        content:
            '#include <iostream>\nint main() { std::cout << "ok"; return 0; }',
      ),
    ];

    for (final testCase in cases) {
      var completionCalls = 0;
      final fakeTool = _FakeWorkspaceFileTool(
        readResult: {
          'path': testCase.path,
          'content': testCase.content,
        },
        patchResult: {
          'ok': true,
          'path': testCase.path,
          'bytes': testCase.content.length,
        },
      );
      final runtime = AgentRuntime(
        complete: (_) async {
          completionCalls++;
          return {
            'success': true,
            'message': completionCalls == 1 ? '已生成，请查看附件。' : testCase.content,
          };
        },
        workspaceFileTool: fakeTool,
        skillCreateHandler: (_) async => {
          'ok': true,
          'skillId': 'generated-skill',
          'name': '产物生成',
        },
      );
      final character = _character(
        toolPermissions: const [
          ToolPermission.skillCreate,
          ToolPermission.workspacePatch,
        ],
      );

      final skillApproval = await runtime.run(
        character: character,
        skills: [_skill()],
        userRequest: testCase.request,
        forceSkillCreation: true,
      );
      final writeApproval = await runtime.executeApprovedTool(
        character: character,
        request: skillApproval.pendingToolRequest!,
        userRequest: testCase.request,
      );

      expect(writeApproval.status, AgentRuntimeStatus.waitingForApproval,
          reason: testCase.request);
      expect(
          writeApproval.pendingToolRequest?.tool, AgentToolName.workspacePatch,
          reason: testCase.request);
      expect(writeApproval.pendingToolRequest?.args['path'], testCase.path,
          reason: testCase.request);

      final completed = await runtime.executeApprovedTool(
        character: character,
        request: writeApproval.pendingToolRequest!,
        userRequest: testCase.request,
        priorExecutedRequests: writeApproval.executedToolRequests,
      );
      expect(completed.status, AgentRuntimeStatus.completed,
          reason: testCase.request);
      expect(fakeTool.lastWriteContent, testCase.content,
          reason: testCase.request);
    }
  });

  test('PDF DOCX 二进制产物不得通过文本 patch 伪造附件', () async {
    for (final path in const ['report.pdf', 'report.docx']) {
      final fakeTool = _FakeWorkspaceFileTool(
        patchResult: {'ok': true, 'path': path, 'bytes': 12},
      );
      final runtime = AgentRuntime(
        complete: (_) async => {
          'success': true,
          'message': '文档已生成，请查看附件。',
        },
        workspaceFileTool: fakeTool,
      );

      final result = await runtime.executeApprovedTool(
        character: _character(
          toolPermissions: const [ToolPermission.workspacePatch],
        ),
        request: ToolRequest(
          tool: AgentToolName.workspacePatch,
          reason: '生成二进制文档',
          args: {'path': path, 'content': '# fake binary'},
        ),
        userRequest: '生成 $path',
      );

      expect(result.status, AgentRuntimeStatus.completed, reason: path);
      // 二进制文档被优雅降级为 Markdown 文本，而不是伪造 PDF/DOCX 附件或 failed。
      expect(
          fakeTool.lastWritePath, path.replaceAll(RegExp(r'\.[^.]+$'), '.md'),
          reason: path);
      expect(result.message, contains('降级'), reason: path);
    }
  });

  test('skill.create 后口头声称 PDF DOCX 完成也不得通过完成门禁', () async {
    for (final format in const ['PDF', 'DOCX']) {
      final runtime = AgentRuntime(
        complete: (_) async => {
          'success': true,
          'message': '$format 文档已生成，请查看附件。',
        },
        workspaceFileTool: _FakeWorkspaceFileTool(),
        skillCreateHandler: (_) async => {
          'ok': true,
          'skillId': 'binary-doc-skill',
          'name': '$format 生成',
        },
      );
      final character = _character(
        toolPermissions: const [
          ToolPermission.skillCreate,
          ToolPermission.workspacePatch,
        ],
      );
      final request = '生成一份 $format 项目报告';

      final skillApproval = await runtime.run(
        character: character,
        skills: [_skill()],
        userRequest: request,
        forceSkillCreation: true,
      );
      final result = await runtime.executeApprovedTool(
        character: character,
        request: skillApproval.pendingToolRequest!,
        userRequest: request,
      );

      expect(result.status, AgentRuntimeStatus.failed, reason: format);
      expect(result.message, contains('没有可交付附件'), reason: format);
      expect(result.message, isNot(contains('请查看附件')), reason: format);
    }
  });

  test('用户拒绝 workspacePatch 不应被文件交付门禁误判为失败', () async {
    // 用户请求含文件意图（使 _inferGeneratedFilePath 能推断出路径），
    // 但用户在审批弹窗拒绝了写文件。skip 后任务应以非文件方式完成，
    // 而非被新增的文件交付门禁误判为 AgentRuntimeStatus.failed，
    // 也与 skipRejectedTool「拒绝后可继续完成安全剩余工作」的契约一致。
    final runtime = AgentRuntime(
      complete: (_) async => {'success': true, 'message': '已跳过文件写入，其余工作已完成。'},
      workspaceFileTool: _FakeWorkspaceFileTool(),
    );

    final result = await runtime.skipRejectedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '生成宇宙页面',
        args: {
          'path': 'space.html',
          'content': '<!doctype html><html></html>',
        },
      ),
      userRequest: '生成宇宙邀游 space.html',
    );

    expect(result.status, isNot(AgentRuntimeStatus.failed));
    expect(result.message, isNot(contains('未能生成文件')));
    expect(result.message, isNot(contains('未能写入')));
  });

  test('failed workspace rename/delete cannot be reported as completed',
      () async {
    final cases = <({AgentToolName tool, Map<String, dynamic> args})>[
      (
        tool: AgentToolName.workspaceRename,
        args: {'path': 'old.txt', 'destinationPath': 'new.txt'},
      ),
      (
        tool: AgentToolName.workspaceDelete,
        args: {'path': 'old.txt'},
      ),
    ];

    for (final scenario in cases) {
      final runtime = AgentRuntime(
        complete: (_) async => {
          'success': true,
          'message': '操作已完成。',
        },
        workspaceFileTool: _FakeWorkspaceFileTool(
          renameResult: {
            'ok': false,
            'exitCode': 0,
            'error': 'mutation_failed',
          },
          deleteResult: {
            'ok': false,
            'exitCode': 0,
            'error': 'mutation_failed',
          },
        ),
      );

      final result = await runtime.executeApprovedTool(
        character: _character(
          toolPermissions: const [ToolPermission.workspacePatch],
        ),
        request: ToolRequest(
          tool: scenario.tool,
          reason: '执行文件变更',
          args: scenario.args,
        ),
        userRequest: '整理工作区文件',
      );

      expect(result.status, AgentRuntimeStatus.failed,
          reason: scenario.tool.wireName);
      expect(result.message, contains('变更未成功'), reason: scenario.tool.wireName);
    }
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
        allowReadBeforeWrite: true,
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

  test('runtime preserves conversation history across chained tools', () async {
    var calls = 0;
    final receivedMessages = <List<Map<String, dynamic>>>[];
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (messages) async {
        receivedMessages.add(messages);
        calls++;
        if (calls == 1) {
          return {
            'success': true,
            'message': '''
```agent_tool
{"tool":"workspace.read","reason":"读取上下文","args":{"path":"notes.md"}}
```
''',
          };
        }
        if (calls == 2) {
          return {
            'success': true,
            'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成新文件","args":{"path":"result.md","content":"done"}}
```
''',
          };
        }
        return {'success': true, 'message': '完成'};
      },
      workspaceFileTool: _FakeWorkspaceFileTool(
        readResult: {'path': 'notes.md', 'content': 'context'},
        patchResult: {'ok': true, 'exitCode': 0},
        allowReadBeforeWrite: true,
      ),
    );
    const history = [
      {'role': 'user', 'content': '历史上下文标记'},
    ];

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '继续处理',
      approved: true,
      conversationHistory: history,
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    final approvedResult = await runtime.executeApprovedTool(
      character: _character(toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ]),
      request: result.pendingToolRequest!,
      userRequest: '继续处理',
      priorExecutedRequests: result.executedToolRequests,
      conversationHistory: history,
    );
    expect(approvedResult.status, AgentRuntimeStatus.completed);
    expect(receivedMessages, hasLength(2));
    for (final messages in receivedMessages) {
      expect(messages, containsAll(history));
    }
  });

  test(
      'runtime compacts oversized intermediate tool context and reports summary',
      () async {
    var calls = 0;
    final summaries = <ContextSummary>[];
    final secondCallMessages = <Map<String, dynamic>>[];
    final runtime = AgentRuntime(
      complete: (messages) async {
        calls++;
        if (calls == 1) {
          return {
            'success': true,
            'message':
                '```agent_tool\n{"tool":"workspace.read","reason":"读取大文件","args":{"path":"large.txt"}}\n```',
          };
        }
        secondCallMessages.addAll(messages);
        return {'success': true, 'message': '已完成分析'};
      },
      workspaceFileTool: _FakeWorkspaceFileTool(
        allowReadBeforeWrite: true,
        readResult: {'content': 'x' * 1000},
      ),
      contextWindowManager: ContextWindowManager(
        thresholdTokens: 1,
        retrySleep: (_) async {},
        complete: (_) async => {
          'success': true,
          'message':
              '{"summary":"工具读取了大文件","facts":["large.txt 已读取"],"relationshipNotes":[],"personaGrowth":[]}',
        },
      ),
      onContextSummary: (_, summary) async => summaries.add(summary),
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspaceRead],
      ),
      skills: [_skill()],
      userRequest: '分析 large.txt',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(summaries.single.summary, '工具读取了大文件');
    expect(
      secondCallMessages.first['content'],
      contains('已压缩的长期上下文'),
    );
  });

  test('runtime keeps original tool context when compaction fails', () async {
    var calls = 0;
    final runtime = AgentRuntime(
      complete: (_) async {
        calls++;
        if (calls == 1) {
          return {
            'success': true,
            'message':
                '```agent_tool\n{"tool":"workspace.read","reason":"读取","args":{"path":"large.txt"}}\n```',
          };
        }
        return {'success': true, 'message': '仍然完成'};
      },
      workspaceFileTool: _FakeWorkspaceFileTool(
        allowReadBeforeWrite: true,
        readResult: {'content': 'x' * 1000},
      ),
      contextWindowManager: ContextWindowManager(
        thresholdTokens: 1,
        maxRetries: 0,
        complete: (_) async => {
          'success': false,
          'message': 'HTTP 400: context unsupported',
        },
      ),
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspaceRead],
      ),
      skills: [_skill()],
      userRequest: '分析 large.txt',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.message, '仍然完成');
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
        args: {'path': 'a.md', 'content': 'new content for a.md'},
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
{"tool":"workspace.patch","reason":"写入生成的 Markdown","args":{"path":"docs/ai_work_test_new.md","content":"hello from tool test\\n"}}
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
        allowReadBeforeWrite: true,
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
      priorExecutedRequests: needsPatchApproval.executedToolRequests,
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
      priorExecutedRequests: needsCommandApproval.executedToolRequests,
    );
    expect(completed.status, AgentRuntimeStatus.completed);
    expect(completed.message, contains('验证通过'));
  });

  test('local file planner requests patch approval for explicit file creation',
      () async {
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
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
    // 本地文件规划器现直接产出 (path, content) 交给 /workspace/write 端点，
    // 不再生成 git diff（new-file diff 在目标已存在时会被 git apply --check 拒掉）。
    expect(
      result.pendingToolRequest?.args['path'],
      'docs/agentic_live_test.md',
    );
    expect(
      result.pendingToolRequest?.args['content'],
      allOf(
        contains('# Agentic Live Test'),
        contains('## 用户请求'),
      ),
    );
  });

  test('local planner infers filename from type hint when no explicit path',
      () async {
    // Bug 1 修复验收：用户说“帮我生成一个html文件”但没给具体文件名时，
    // 本地文件规划器应能推断出 .html 文件名并创建 patch 工具请求。
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
      complete: (_) async => {'success': true, 'message': '不应调用模型'},
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '我要一个画面，漫天的流星滑落、头顶有月亮、下面有平静的湖面，'
          '我和你2个人在湖中划船，帮我生成一个html文件，放到工作目录。',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(result.pendingToolRequest?.tool, AgentToolName.workspacePatch);
    expect(
      result.pendingToolRequest?.args['path'],
      'meteor_shower.html',
    );
  });

  test('local planner can auto-approve and write meteor shower html', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'meteor_shower.html', 'bytes': 42},
      readResult: {
        'path': 'meteor_shower.html',
        'content': '<!doctype html><title>流星雨划过夜空</title>',
      },
    );
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
      complete: (_) async => {
        'success': true,
        'message': 'meteor_shower.html 已生成并贴回聊天。',
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '帮我生成一个流星雨划过夜空的动态效果html',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'meteor_shower.html');
    // 本地快速路径生成的是通用 HTML 骨架（不含具体视觉内容），不再硬编码流星雨。
    expect(fakeTool.lastWriteContent, contains('<!doctype html>'));
    expect(fakeTool.lastWriteContent, contains('<title>页面</title>'));
    // 消息中应包含简洁的文件确认行（不含大段内容预览）。
    expect(result.message, contains('✅ 文件已生成'));
    expect(result.message, contains('meteor_shower.html'));
  });

  test('local planner handles 实现 + 使用html wording from private chat', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'meteor_shower.html', 'bytes': 42},
      readResult: {
        'path': 'meteor_shower.html',
        'content': '<!doctype html><title>流星雨划过夜空</title>',
      },
    );
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
      complete: (_) async => {'success': true, 'message': '文件已生成。'},
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '那你帮我实现一个 流星雨的特效给我 使用html',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'meteor_shower.html');
    // HTML 模板是通用骨架（不含具体特效内容），不再硬编码流星雨。
    expect(fakeTool.lastWriteContent, contains('<!doctype html>'));
    expect(result.message, isNot(contains('<tool_call')));
  });

  test('local planner keeps backward-compatible exact path matching', () async {
    // 用户明确给出 star.html 时，仍走原有精确匹配路径，而非模糊推断。
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
      complete: (_) async => {'success': true, 'message': '不应调用模型'},
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '帮我生成一个 star.html，放到工作目录。',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(
      result.pendingToolRequest?.args['path'],
      'star.html',
    );
  });

  test('local planner does not misfire for non-file intents', () async {
    // 用户只是聊天/问代码，没有生成文件意图时，不应触发工具请求。
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
      complete: (_) async => {
        'success': true,
        'message': '好的，我们来看看这段代码。',
      },
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '帮我看一下这段代码有什么问题',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.pendingToolRequest, isNull);
    expect(result.message, contains('这段代码'));
  });

  test('local planner infers report.md for 报告-like md intent', () async {
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
      complete: (_) async => {'success': true, 'message': '不应调用模型'},
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '生成一份 MD 验收报告给我',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(
      result.pendingToolRequest?.args['path'],
      'report.md',
    );
  });

  test('local planner infers technical_documentation.md for project docs',
      () async {
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
      complete: (_) async => {'success': true, 'message': '不应调用模型'},
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '根据这个项目写一份简单的技术文档，以MD格式输出到工程目录下',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(
      result.pendingToolRequest?.args['path'],
      'technical_documentation.md',
    );
    expect(
      result.pendingToolRequest?.args['content'],
      allOf(
        contains('AI Group Chat Simulator 技术文档'),
        contains('AgentRuntime'),
        contains('Hive'),
      ),
    );
  });

  test('local planner auto-renames inferred file when target exists', () async {
    // 行为变更：推断文件名已存在时自动改名（不再拒绝/不再静默产生 _2 副本），
    // 改为带序号递增改名（technical_documentation.md → technical_documentation_1.md 等），
    // 确保写入成功且用户能收到文件附件。
    final fakeTool = _FakeWorkspaceFileTool(
      existingFiles: const {
        'technical_documentation.md': 'existing doc',
      },
      patchResult: {
        'ok': true,
        'path': 'technical_documentation_1.md',
        'bytes': 128,
      },
    );
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
      complete: (_) async => {'success': true, 'message': '文档已生成。'},
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '根据这个项目写一份简单的技术文档，以MD格式输出到工程目录下',
      approved: true,
    );

    // 自动改名后写入成功，流程走完。
    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, isNotNull);
    expect(fakeTool.lastWritePath, isNot(equals('technical_documentation.md')));
    // 不含拒绝/错误文本。
    expect(result.message, isNot(contains('已拒绝')));
    expect(result.message, isNot(contains('已存在')));
  });

  test('local planner escapes character name in generated html and markdown',
      () async {
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
      complete: (_) async => {'success': true, 'message': '不应调用模型'},
    );
    final character = _character(
      name: '<script>alert(1)</script> & me',
      toolPermissions: const [ToolPermission.workspacePatch],
    );

    final htmlResult = await runtime.run(
      character: character,
      skills: [_skill()],
      userRequest: '帮我生成一个流星雨特效 html',
    );
    final htmlContent =
        htmlResult.pendingToolRequest?.args['content'] as String? ?? '';

    // 模板不再包含角色名称（彻底消除 XSS 风险，无需转义）。
    expect(htmlContent, isNot(contains('script')));
    expect(htmlContent, contains('<!doctype html>'));
    expect(htmlContent, contains('<title>页面</title>'));

    final mdResult = await runtime.run(
      character: character,
      skills: [_skill()],
      userRequest: '根据这个项目写一份简单的技术文档，以MD格式输出到工程目录下',
    );
    final mdContent =
        mdResult.pendingToolRequest?.args['content'] as String? ?? '';

    // Markdown 模板同样不含角色名称。
    expect(mdContent, isNot(contains('script')));
    expect(mdContent, contains('#'));
  });

  test('local planner can auto-approve and write project check script',
      () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'run_checks.sh', 'bytes': 160},
      readResult: {
        'path': 'run_checks.sh',
        'content': '#!/usr/bin/env bash\nflutter analyze\nflutter test\n',
      },
    );
    final runtime = AgentRuntime(
      enableLocalFilePlanner: true,
      complete: (_) async => {'success': true, 'message': '脚本已生成。'},
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '帮我写一个检查项目的脚本',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'run_checks.sh');
    expect(fakeTool.lastWriteContent, contains('#!/usr/bin/env bash'));
    expect(fakeTool.lastWriteContent, contains('flutter analyze'));
    expect(fakeTool.lastWriteContent, contains('flutter test'));
    // Shell 模板不再含 "Generated by" 签名。
    expect(fakeTool.lastWriteContent, isNot(contains('Generated by')));
    expect(result.message, contains('✅ 文件已生成'));
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
    // 关沙盒后桥接由桌面端 App 进程内自动启动，错误提示已改为桌面端自动启动说明。
    expect(result.message, contains('本地工具桥接服务未连接'));
    expect(result.message, contains('进程内自动启动并监听 54263'));
  });

  test('workspace.patch appends concise file confirmation on success',
      () async {
    // 验收：写文件成功且读回内容后，最终消息只追加一行简洁确认信息，
    // 不再将文件正文注入聊天文本（避免截断和阅读体验差的问题）。
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {'success': true, 'message': '文件已生成完成。'},
      workspaceFileTool: _FakeWorkspaceFileTool(
        readResult: {
          'path': 'star.html',
          'content': '<html>hello from preview</html>',
        },
        patchResult: {'ok': true, 'path': 'star.html', 'bytes': 123},
      ),
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '写入生成的 HTML',
        args: {
          'path': 'star.html',
          'content': '<html>hello from preview</html>',
        },
      ),
      userRequest: '生成 star.html',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.message, contains('已生成文件'));
    // 关键断言：消息中包含简洁确认行（含文件名和大小），不含文件正文。
    expect(result.message, contains('✅ 文件已生成'));
    expect(result.message, contains('star.html'));
    expect(result.message, contains('HTML 验证通过'));
    expect(result.message, contains('结论'));
    expect(result.message, contains('交付物'));
    expect(result.message, contains('验证'));
    expect(result.message, contains('自检'));
    expect(result.message, contains('风险'));
    // 文件内容不应出现在消息中。
    expect(result.message, isNot(contains('hello from preview')));
    expect(result.message, isNot(contains('文件内容预览')));
    expect(result.message, isNot(contains('预览结束')));
  });

  test('workspace.patch degrades gracefully when readback fails', () async {
    // 写成功但读回失败（如文件被删/桥接异常）应降级：原样返回摘要文案，
    // 不加预览块，也不暴露任何异常堆栈。
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {'success': true, 'message': '文件已写入。'},
      workspaceFileTool: _FakeWorkspaceFileTool(
        patchResult: {'ok': true, 'path': 'star.html', 'bytes': 123},
        throwOnRead: true,
      ),
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '写入文件',
        args: {
          'path': 'star.html',
          'content': '<html>should-not-appear</html>',
        },
      ),
      userRequest: '生成文件',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.message, contains('已生成文件'));
    // 降级成功：无预览块、无异常泄露、无被读回失败而暴露的内容。
    expect(result.message, isNot(contains('文件内容预览')));
    expect(result.message, isNot(contains('Exception')));
    expect(result.message, isNot(contains('SocketException')));
    expect(result.message, isNot(contains('should-not-appear')));
  });

  test('workspace.patch auto-renames when target file already exists',
      () async {
    // 行为变更（修复"拒绝覆盖"导致工具失败→LLM 回退到代码泄漏路径）：
    // 文件冲突时自动改名（如 technical_documentation.md → technical_documentation_1.md），
    // 不再返回 target_exists 错误。确保写入成功且使用了新文件名。
    final fakeTool = _FakeWorkspaceFileTool(
      existingFiles: const {'technical_documentation.md': 'existing doc'},
      patchResult: {
        'ok': true,
        'path': 'technical_documentation_1.md',
        'bytes': 12,
      },
    );
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {'success': true, 'message': '文件已生成，请查看附件。'},
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '写入技术文档',
        args: {
          'path': 'technical_documentation.md',
          'content': '# new doc',
        },
      ),
      userRequest: '写一份技术文档',
    );

    // 工具执行成功（自动改名后写入新路径），走完了完整流程。
    expect(result.status, AgentRuntimeStatus.completed);
    // 确认实际写入了文件（路径是改名后的新名，不是原始的冲突路径）。
    expect(fakeTool.lastWritePath, isNotNull);
    expect(fakeTool.lastWritePath, isNot(equals('technical_documentation.md')));
    // 消息不含「拒绝覆盖」错误文本。
    expect(result.message, isNot(contains('已拒绝覆盖')));
    expect(result.message, isNot(contains('目标文件已存在')));
  });

  test('修复上一个附件时原地覆盖并写入修复内容', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      existingFiles: const {'page_6.html': '<html>无法点击</html>'},
      patchResult: const {
        'ok': true,
        'path': 'page_6.html',
        'bytes': 31,
      },
    );
    final runtime = AgentRuntime(
      complete: (_) async => const {
        'success': true,
        'message':
            '<!doctype html><html><body><button>可点击</button></body></html>',
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '无法行动，界面无法点击，你帮我修复它\n\n'
          '【持续可用的附件上下文】\n'
          '- problem.png；类型=image；位置=/tmp/problem.png',
      conversationHistory: const [
        {
          'role': 'assistant',
          'content': '已生成页面。\n\n【持续可用的附件上下文】\n'
              '- page_6.html；类型=file；位置=/tmp/page_6.html\n'
              '【page_6.html 内容】\n<html>无法点击</html>',
        },
        {
          'role': 'user',
          'content': '无法点击\n\n【持续可用的附件上下文】\n'
              '- problem.png；类型=image；位置=/tmp/problem.png',
        },
      ],
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'page_6.html');
    expect(fakeTool.lastWriteContent, contains('可点击'));
  });

  test('旧产物存在时阅读和泛化新建请求不应覆盖旧文件', () async {
    const history = [
      {
        'role': 'assistant',
        'content': '已生成页面。\n\n【持续可用的附件上下文】\n'
            '- page_6.html；类型=file；位置=/tmp/page_6.html',
      },
    ];
    for (final request in ['看一下附件', '优化一下', '基于刚才聊的，帮我写个新东西']) {
      final fakeTool = _FakeWorkspaceFileTool(
        existingFiles: const {'page_6.html': '<html>原内容</html>'},
      );
      final runtime = AgentRuntime(
        complete: (_) async => const {'success': true, 'message': '收到。'},
        workspaceFileTool: fakeTool,
      );

      final result = await runtime.run(
        character: _character(
          toolPermissions: const [ToolPermission.workspacePatch],
        ),
        skills: [_skill()],
        userRequest: request,
        conversationHistory: history,
        approved: true,
      );

      expect(result.status, AgentRuntimeStatus.completed);
      expect(fakeTool.lastWritePath, isNull, reason: request);
    }
  });

  test('正常 workspace.patch 修订请求也原地覆盖旧附件', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      existingFiles: const {'page_6.html': '<html>无法点击</html>'},
      patchResult: const {'ok': true, 'path': 'page_6.html', 'bytes': 31},
    );
    final runtime = AgentRuntime(
      complete: (_) async => const {
        'success': true,
        'message': '```agent_tool\n'
            '{"tool":"workspace.patch","reason":"修复页面",'
            '"args":{"path":"page_6.html",'
            '"content":"<html><button>可点击</button></html>"}}\n```',
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '无法行动，界面无法点击，你帮我修复它',
      conversationHistory: const [
        {
          'role': 'assistant',
          'content': '已生成页面。\n\n【持续可用的附件上下文】\n'
              '- page_6.html；类型=file；位置=/tmp/page_6.html',
        },
      ],
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'page_6.html');
    expect(fakeTool.lastWriteContent, contains('可点击'));
  });

  test('English same-file revision overwrites the existing artifact', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      existingFiles: const {
        'interactive_counter.html': '<html>original</html>',
      },
      patchResult: const {
        'ok': true,
        'path': 'interactive_counter.html',
        'bytes': 48,
      },
    );
    final runtime = AgentRuntime(
      complete: (_) async => const {
        'success': true,
        'message': '<!doctype html><html><head><title>Counter</title></head>'
            '<body><button>+10</button></body></html>',
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: 'Modify the same interactive_counter.html and add +10.',
      approved: true,
    );

    expect(
      result.status,
      AgentRuntimeStatus.completed,
      reason: result.message,
    );
    expect(fakeTool.lastWritePath, 'interactive_counter.html');
    expect(fakeTool.lastWriteContent, contains('+10'));
  });

  test('direct file generation keeps the current request as the last turn',
      () async {
    late List<Map<String, dynamic>> capturedMessages;
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: const {
        'ok': true,
        'path': 'role_task_board.html',
        'bytes': 96,
      },
    );
    final runtime = AgentRuntime(
      complete: (messages) async {
        capturedMessages = messages;
        return const {
          'success': true,
          'message': '<!doctype html><html><body><h1>Task Board</h1>'
              '<input><button>Add</button><button>Complete</button>'
              '</body></html>',
        };
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: 'Create role_task_board.html with Add and Complete buttons.',
      conversationHistory: const [
        {
          'role': 'assistant',
          'content': '<html><body>stale counter output</body></html>',
        },
      ],
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(capturedMessages.last['role'], 'user');
    expect(capturedMessages.last['content'], contains('role_task_board.html'));
    expect(fakeTool.lastWriteContent, contains('Task Board'));
  });

  test('non-write tools (workspace.list) do not append file preview', () async {
    // 回归保护：workspace.list / read / command.run 等非写工具的结果不含
    // readbackContent，最终消息应原样返回，不拼接预览块。
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {'success': true, 'message': '已列出目录。'},
      workspaceFileTool: _FakeWorkspaceFileTool(
        listResult: {'ok': true, 'entries': []},
      ),
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspaceRead],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspaceList,
        reason: '列出目录',
        args: {'path': '.'},
      ),
      userRequest: '列出目录',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.message, contains('已列出目录'));
    expect(result.message, isNot(contains('文件内容预览')));
  });

  test('file confirmation is concise regardless of content size', () async {
    // 验收：无论文件多大，消息中只追加一行简洁确认（含文件名和 KB 大小），
    // 不注入文件正文，不存在截断逻辑。
    final longContent = 'x' * 2500;
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {'success': true, 'message': '长文件已生成。'},
      workspaceFileTool: _FakeWorkspaceFileTool(
        readResult: {'path': 'big.txt', 'content': longContent},
        patchResult: {'ok': true, 'path': 'big.txt', 'bytes': 2500},
      ),
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '写入长文件',
        args: {'path': 'big.txt', 'content': 'x' * 2500},
      ),
      userRequest: '生成长文件',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    // 只有一行简洁确认，不含任何文件正文。
    expect(result.message, contains('✅ 文件已生成'));
    expect(result.message, contains('big.txt'));
    // 2500 字符的 'x' 不应出现在消息中（无论多少都不注入）。
    expect(result.message, isNot(contains('xxx')));
    expect(result.message, isNot(contains('文件内容预览')));
    expect(result.message, isNot(contains('已截断')));
  });

  test('runtime guards leaked file content in final message (Bug A)', () async {
    // 复现：模型在第二次 LLM（整理结果）阶段把生成的 HTML 全文贴进回复。
    // 修复后该全文应被收敛为简洁确认，绝不出现在可见消息中。
    var calls = 0;
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {
        'path': 'page.html',
        'content': '<!doctype html><title>页面</title>'
      },
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 50},
    );
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async {
        calls++;
        if (calls == 1) {
          return {
            'success': true,
            'message':
                '```agent_tool\n{"tool":"workspace.patch","reason":"生成主页","args":{"path":"page.html","content":"<!doctype html><title>页面</title>"}}\n```',
          };
        }
        // 第二次 LLM：模型把文件全文贴进回复（Bug A 复现）。
        return {
          'success': true,
          'message':
              '已生成文件：\n<!doctype html>\n<html lang="zh-CN">\n<head><title>页面</title></head>\n<body><h1>你好</h1></body>\n</html>',
        };
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character:
          _character(toolPermissions: const [ToolPermission.workspacePatch]),
      skills: [_skill()],
      userRequest: '生成个人主页',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    // 不应泄漏文件全文（HTML 标签 / 正文）。
    expect(result.message, isNot(contains('<!doctype html>')));
    expect(result.message, isNot(contains('<h1>你好</h1>')));
    // 仍包含简洁确认（来自 _appendFilePreview）。
    expect(result.message, contains('文件已生成'));
  });

  test(
      'runtime returns concise fallback for unparseable planning trace (Bug B-b1)',
      () async {
    // 复现：规划阶段输出"我直接现在就为你写入文件" + 残缺工具标记，
    // tryParse 失败。修复后绝不把这段规划 narration 当作用户可见消息返回。
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {
        'success': true,
        'message':
            '我直接现在就为你写入文件：\n<tool_call agent_tool>\nbroken not valid json\n</tool_call>',
      },
    );

    final result = await runtime.run(
      character:
          _character(toolPermissions: const [ToolPermission.workspacePatch]),
      skills: [_skill()],
      userRequest: '生成个人主页',
    );

    // 两次解析都失败时不得构造 content 为空的写入请求；明确提示重试，
    // 避免生成一个空文件却显示成功附件。
    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.pendingToolRequest, isNull);
    expect(result.message, contains('未能生成可写入的完整文件内容'));
    // 不应把原始规划文本泄漏为可见消息。
    expect(result.message, isNot(contains('我直接现在就为你写入文件')));
  });

  test('runtime loosely parses <function=tool> trace and requests approval',
      () async {
    // 宽松兜底：模型用 <function=workspace.patch> 变体（未被 tryParse 识别），
    // 修复后应能提取并执行，而非退化成失败提示。
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {
        'success': true,
        'message':
            '<function=workspace.patch>\n{"tool":"workspace.patch","reason":"生成主页","args":{"path":"page.html","content":"<html>hi</html>"}}\n</function>',
      },
    );

    final result = await runtime.run(
      character:
          _character(toolPermissions: const [ToolPermission.workspacePatch]),
      skills: [_skill()],
      userRequest: '生成个人主页',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    expect(result.pendingToolRequest?.tool, AgentToolName.workspacePatch);
    expect(result.pendingToolRequest?.args['path'], 'page.html');
  });

  test('simple file write skips the redundant final model summary', () async {
    // 文件写入已经成功时直接完成，避免第二次模型调用再次卡住。
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {
        'path': 'page.html',
        'content': '<!doctype html><title>页面</title>'
      },
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 50},
    );
    var calls = 0;
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async {
        calls++;
        if (calls == 1) {
          return {
            'success': true,
            'message':
                '```agent_tool\n{"tool":"workspace.patch","reason":"生成主页","args":{"path":"page.html","content":"<!doctype html><title>页面</title>"}}\n```',
          };
        }
        // 正常 1-2 句总结，无代码/HTML 泄漏。
        return {
          'success': true,
          'message': '已为你生成个人主页，请查收附件，有需要可继续让我调整。',
        };
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character:
          _character(toolPermissions: const [ToolPermission.workspacePatch]),
      skills: [_skill()],
      userRequest: '生成个人主页',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(calls, 1);
    expect(result.message, contains('已生成文件'));
    expect(result.message, isNot(contains('已为你生成个人主页')));
  });

  test('simple file write does not ask the model to repeat short code',
      () async {
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {'path': 'page.html', 'content': 'x'},
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 1},
    );
    var calls = 0;
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async {
        calls++;
        if (calls == 1) {
          return {
            'success': true,
            'message':
                '```agent_tool\n{"tool":"workspace.patch","reason":"生成主页","args":{"path":"page.html","content":"x"}}\n```',
          };
        }
        return {
          'success': true,
          'message': '这是生成的函数：\n```dart\nvoid f() { print(1); }\n```',
        };
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character:
          _character(toolPermissions: const [ToolPermission.workspacePatch]),
      skills: [_skill()],
      userRequest: '生成个人主页',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(calls, 1);
    expect(result.message, contains('已生成文件'));
    expect(result.message, isNot(contains('void f()')));
  });

  test('Bug A: 长代码围栏（>80 字符）在 final 文本中被护栏收敛', () async {
    // 反向锁定：即便文件已写入，final 文本里贴出的长代码块也应被收敛为确认语，
    // 绝不把大段代码泄漏到聊天 UI。
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {'path': 'page.html', 'content': 'x'},
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 1},
    );
    final longCode = '```dart\n'
        '${List.filled(20, "  final x = 1;").join("\n")}\n'
        '```';
    var calls = 0;
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async {
        calls++;
        if (calls == 1) {
          return {
            'success': true,
            'message':
                '```agent_tool\n{"tool":"workspace.patch","reason":"生成主页","args":{"path":"page.html","content":"x"}}\n```',
          };
        }
        return {
          'success': true,
          'message': '生成完成：\n$longCode',
        };
      },
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character:
          _character(toolPermissions: const [ToolPermission.workspacePatch]),
      skills: [_skill()],
      userRequest: '生成个人主页',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    // 大段代码不应出现在可见消息中。
    expect(result.message, isNot(contains('final x')));
    // 仍包含简洁确认（来自护栏或 _appendFilePreview）。
    expect(result.message, contains('文件已生成'));
  });

  test('Bug B-b1: 含 workspace.patch 痕迹的规划 narration 被收敛为兜底（非空）', () async {
    // 用另一种工具痕迹关键字（workspace.patch）复现：规划阶段输出"我直接现在
    // 就为你写入文件" + 残缺内容，tryParse 失败。修复后绝不把规划 narration 当
    // 作可见消息返回，而是返回非空兜底文案。
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {
        'success': true,
        'message': '我直接现在就为你写入文件：workspace.patch 路径 page.html\n一些无法解析的内容',
      },
    );

    final result = await runtime.run(
      character:
          _character(toolPermissions: const [ToolPermission.workspacePatch]),
      skills: [_skill()],
      userRequest: '生成个人主页',
    );

    // 两次解析都失败时不得构造空文件请求，返回明确、非空的重试提示。
    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.pendingToolRequest, isNull);
    expect(result.message, contains('未能生成可写入的完整文件内容'));
    // 不应把原始规划 narration 泄漏为可见消息。
    expect(result.message, isNot(contains('我直接现在就为你写入文件')));
  });

  test('consecutive identical thinking reports are de-duplicated', () async {
    // 验收：生成文件内容时，首轮与续写前各上报一次 thinking('生成文件内容：page.html')，
    // 二者 stage + label 完全相同；_reportProgress 去抖后应只触发一次气泡重写。
    var completionCalls = 0;
    final progress = <AgentRuntimeProgress>[];
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {
        'path': 'page.html',
        'content': '<!doctype html><html><body><h1>宇宙</h1></body></html>',
      },
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 64},
    );
    final runtime = AgentRuntime(
      complete: (messages) async {
        completionCalls++;
        if (completionCalls == 1) {
          // 不完整的 HTML（缺 </body></html>），触发续写循环。
          return {
            'success': true,
            'message': '<!doctype html><html><body><h1>宇宙</h1>',
          };
        }
        // 续写补全剩余内容。
        return {
          'success': true,
          'message': '</body></html>',
        };
      },
      workspaceFileTool: fakeTool,
      onProgress: (value) async => progress.add(value),
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '生成一个宇宙遨游的 html 页面',
      approved: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    final generationThinking = progress
        .where((p) =>
            p.stage == AgentRuntimeProgressStage.thinking &&
            p.currentStepLabel == thinkingLabel('生成文件内容：page.html'))
        .toList();
    expect(generationThinking, hasLength(1),
        reason: '连续同 stage 同 label 的 thinking 上报必须被去抖去重');
  });

  test('waitingForApproval progress label includes the target path', () async {
    // 修复2（waitingForApproval 补 path）验收：运行时在等待批准阶段上报的
    // currentStepLabel 必须带 path（request.args['path']），形如
    // 「等待批准：workspace.patch（page.html）」。
    final progress = <AgentRuntimeProgress>[];
    final runtime = AgentRuntime(
      complete: (_) async => {
        'success': true,
        'message':
            '```agent_tool\n{"tool":"workspace.patch","reason":"写页面","args":{"path":"page.html","content":"<html></html>"}}\n```',
      },
      onProgress: (value) async => progress.add(value),
    );

    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '生成 page.html',
    );

    expect(result.status, AgentRuntimeStatus.waitingForApproval);
    final approval = progress.firstWhere(
      (p) => p.stage == AgentRuntimeProgressStage.waitingForApproval,
    );
    expect(approval.currentStepLabel, '等待批准：workspace.patch（page.html）');
  });

  test(
      'workspace.patch reports fileCreated -> readingFile -> validating in order',
      () async {
    // 修复3（读回补 readingFile）验收：写文件成功后上报顺序必须为
    // fileCreated → readingFile（读回）→ validating（校验），不再跳变。
    final progress = <AgentRuntimeProgress>[];
    final fakeTool = _FakeWorkspaceFileTool(
      readResult: {
        'path': 'page.html',
        'content': '<!doctype html><html></html>',
      },
      patchResult: {'ok': true, 'path': 'page.html', 'bytes': 32},
    );
    final runtime = AgentRuntime(
      complete: (_) async => {'success': true, 'message': '页面已生成。'},
      workspaceFileTool: fakeTool,
      onProgress: (value) async => progress.add(value),
    );

    final result = await runtime.executeApprovedTool(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      request: const ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '写页面',
        args: {'path': 'page.html', 'content': '<!doctype html><html></html>'},
      ),
      userRequest: '生成 page.html',
    );

    expect(result.status, AgentRuntimeStatus.completed);
    final stages = progress.map((p) => p.stage).toList();
    final idxFileCreated =
        stages.indexOf(AgentRuntimeProgressStage.fileCreated);
    final idxReading = stages.indexOf(AgentRuntimeProgressStage.readingFile);
    final idxValidating = stages.indexOf(AgentRuntimeProgressStage.validating);
    expect(idxFileCreated, isNot(equals(-1)), reason: '应有 fileCreated 上报');
    expect(idxReading, isNot(equals(-1)), reason: '应有 readback readingFile 上报');
    expect(idxValidating, isNot(equals(-1)), reason: '应有 validating 上报');
    expect(idxFileCreated, lessThan(idxReading),
        reason: 'fileCreated 必须先于 readback readingFile');
    expect(idxReading, lessThan(idxValidating),
        reason: 'readback readingFile 必须先于 validating');
  });
}

AICharacter _character({
  String name = '代码大神',
  required List<ToolPermission> toolPermissions,
}) {
  return AICharacter(
    name: name,
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
  final Map<String, dynamic> listResult;
  final Map<String, dynamic> renameResult;
  final Map<String, dynamic> deleteResult;
  final Map<String, String> existingFiles;
  final Set<String> sensitivePaths;
  final bool throwOnRead;
  final bool allowReadBeforeWrite;
  String? lastWritePath;
  String? lastWriteContent;
  String? lastPatch;

  _FakeWorkspaceFileTool({
    this.readResult = const {},
    this.patchResult = const {},
    this.commandResult = const {},
    this.listResult = const {},
    this.renameResult = const {},
    this.deleteResult = const {},
    this.existingFiles = const {},
    this.sensitivePaths = const {},
    this.throwOnRead = false,
    this.allowReadBeforeWrite = false,
  }) : super(LocalAgentBridgeClient());

  @override
  bool isSensitivePath(String path) => sensitivePaths.contains(path);

  @override
  Future<Map<String, dynamic>> read(String path) async {
    if (throwOnRead) {
      throw Exception('SocketException: Connection refused');
    }
    if (existingFiles.containsKey(path)) {
      return {'path': path, 'content': existingFiles[path]};
    }
    if (lastWritePath == path) {
      if (readResult.isNotEmpty) return readResult;
      return {'path': path, 'content': lastWriteContent ?? ''};
    }
    if (allowReadBeforeWrite && readResult['path'] == path) {
      return readResult;
    }
    return const {};
  }

  @override
  Future<Map<String, dynamic>> applyPatch(String patch) async {
    lastPatch = patch;
    return patchResult;
  }

  // 桥接改为 /workspace/write 端点（path + content），不再走 git diff 的
  // applyPatch。这里复用 patchResult 作为写操作的回包，保持测试聚焦在
  // 权限/审批流转而非真实落盘。
  @override
  Future<Map<String, dynamic>> write(String path, String content) async {
    lastWritePath = path;
    lastWriteContent = content;
    return patchResult;
  }

  @override
  Future<Map<String, dynamic>> runCommand(String command) async {
    return commandResult;
  }

  // 新增：mock 目录列举，使 workspace.list 测试也不依赖真实桥接端口。
  @override
  Future<Map<String, dynamic>> list({String path = '.'}) async {
    return listResult;
  }

  @override
  Future<Map<String, dynamic>> rename(
    String path,
    String destinationPath,
  ) async {
    return renameResult;
  }

  @override
  Future<Map<String, dynamic>> delete(String path) async {
    return deleteResult;
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
