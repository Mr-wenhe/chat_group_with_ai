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
    // 本地文件规划器现直接产出 (path, content) 交给 /workspace/write 端点，
    // 不再生成 git diff（new-file diff 在目标已存在时会被 git apply --check 拒掉）。
    expect(
      result.pendingToolRequest?.args['path'],
      'docs/agentic_live_test.md',
    );
    expect(
      result.pendingToolRequest?.args['content'],
      allOf(
        contains('```dart'),
        contains("print('hello from 代码大神')"),
      ),
    );
  });

  test('local planner infers filename from type hint when no explicit path',
      () async {
    // Bug 1 修复验收：用户说“帮我生成一个html文件”但没给具体文件名时，
    // 本地文件规划器应能推断出 .html 文件名并创建 patch 工具请求。
    final runtime = AgentRuntime(
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
      autoApproveWriteTools: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'meteor_shower.html');
    expect(fakeTool.lastWriteContent, contains('流星雨划过夜空'));
    expect(fakeTool.lastWriteContent, contains('@keyframes shoot'));
    expect(result.message, contains('文件内容预览'));
    expect(result.message, contains('流星雨划过夜空'));
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
      complete: (_) async => {'success': true, 'message': '文件已生成。'},
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '那你帮我实现一个 流星雨的特效给我 使用html',
      autoApproveWriteTools: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'meteor_shower.html');
    expect(fakeTool.lastWriteContent, contains('流星雨划过夜空'));
    expect(result.message, isNot(contains('<tool_call')));
  });

  test('local planner keeps backward-compatible exact path matching', () async {
    // 用户明确给出 star.html 时，仍走原有精确匹配路径，而非模糊推断。
    final runtime = AgentRuntime(
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

  test('local planner renames inferred file when target exists', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      existingFiles: const {
        'technical_documentation.md': 'existing doc',
      },
      patchResult: {
        'ok': true,
        'path': 'technical_documentation_2.md',
        'bytes': 128,
      },
    );
    final runtime = AgentRuntime(
      complete: (_) async => {'success': true, 'message': '文档已生成。'},
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '根据这个项目写一份简单的技术文档，以MD格式输出到工程目录下',
      autoApproveWriteTools: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'technical_documentation_2.md');
    expect(fakeTool.lastWriteContent, contains('AI Group Chat Simulator 技术文档'));
  });

  test('local planner escapes character name in generated html and markdown',
      () async {
    final runtime = AgentRuntime(
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

    expect(htmlContent, contains('&lt;script&gt;alert(1)&lt;'));
    expect(htmlContent, contains('&amp; me'));
    expect(htmlContent, isNot(contains('<script>alert(1)</script>')));

    final mdResult = await runtime.run(
      character: character,
      skills: [_skill()],
      userRequest: '根据这个项目写一份简单的技术文档，以MD格式输出到工程目录下',
    );
    final mdContent =
        mdResult.pendingToolRequest?.args['content'] as String? ?? '';

    expect(mdContent, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
    expect(mdContent, contains('&amp; me'));
    expect(mdContent, isNot(contains('<script>alert(1)</script>')));
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
      complete: (_) async => {'success': true, 'message': '脚本已生成。'},
      workspaceFileTool: fakeTool,
    );

    final result = await runtime.run(
      character: _character(toolPermissions: const [
        ToolPermission.workspacePatch,
      ]),
      skills: [_skill()],
      userRequest: '帮我写一个检查项目的脚本',
      autoApproveWriteTools: true,
    );

    expect(result.status, AgentRuntimeStatus.completed);
    expect(fakeTool.lastWritePath, 'run_checks.sh');
    expect(fakeTool.lastWriteContent, contains('#!/usr/bin/env bash'));
    expect(fakeTool.lastWriteContent, contains('flutter analyze'));
    expect(fakeTool.lastWriteContent, contains('flutter test'));
    expect(result.message, contains('文件内容预览'));
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

  test('workspace.patch appends read-back file preview on success', () async {
    // 增量验收：写文件成功且读回内容后，最终消息应拼上「文件内容预览」块，
    // 而非仅输出"已生成 xxx 文件"的摘要。
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
    expect(result.message, contains('文件已生成完成'));
    // 关键断言：写后回读预览真的生效。
    expect(result.message, contains('文件内容预览'));
    expect(result.message, contains('hello from preview'));
    expect(result.message, contains('预览结束'));
    // 短内容不应进入截断分支。
    expect(result.message, isNot(contains('已截断显示前')));
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
    expect(result.message, contains('文件已写入'));
    // 降级成功：无预览块、无异常泄露、无被读回失败而暴露的内容。
    expect(result.message, isNot(contains('文件内容预览')));
    expect(result.message, isNot(contains('Exception')));
    expect(result.message, isNot(contains('SocketException')));
    expect(result.message, isNot(contains('should-not-appear')));
  });

  test('workspace.patch refuses to overwrite existing files', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      existingFiles: const {'technical_documentation.md': 'existing doc'},
      patchResult: {
        'ok': true,
        'path': 'technical_documentation.md',
        'bytes': 12,
      },
    );
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {'success': true, 'message': '不应调用模型'},
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

    expect(result.status, AgentRuntimeStatus.failed);
    expect(result.message, contains('已拒绝覆盖'));
    expect(fakeTool.lastWritePath, isNull);
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

  test('file preview truncates content longer than 2000 chars', () async {
    // 验收 _appendFilePreview 的截断分支：>2000 字符时只显示前 2000 并提示
    // 查看完整文件，且完整内容不应全部出现在消息中。
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
    expect(result.message, contains('文件内容预览'));
    expect(result.message, contains('已截断显示前 2000 字符'));
    expect(result.message, contains('big.txt'));
    // 完整 2500 字符内容不应被完整拼入（超过 2000 的部分已被截断）。
    expect(result.message, isNot(contains('x' * 2500)));
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
  final Map<String, String> existingFiles;
  final bool throwOnRead;
  final bool allowReadBeforeWrite;
  String? lastWritePath;
  String? lastWriteContent;

  _FakeWorkspaceFileTool({
    this.readResult = const {},
    this.patchResult = const {},
    this.commandResult = const {},
    this.listResult = const {},
    this.existingFiles = const {},
    this.throwOnRead = false,
    this.allowReadBeforeWrite = false,
  }) : super(LocalAgentBridgeClient());

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
