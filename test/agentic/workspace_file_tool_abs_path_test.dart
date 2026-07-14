// 客户端侧绝对路径写文件端到端回归测试。
//
// 本文件补齐服务端 `/workspace/write` 绝对路径归一化（已被
// local_agent_bridge_server_test.dart 覆盖）之外的 GAP：证明 [WorkspaceFileTool.write]
// 在「模型输出对话上下文里的绝对路径」（如
// `/Users/fengye/Library/Application Support/chat_group/star_scene.html`）时：
//   1. 不抛异常（修复前会抛 `Unsafe workspace path: ...`，导致文件永远写不出来）；
//   2. 返回 ok == true；
//   3. 文件以 basename 落到工作区根目录（star_scene.html 出现在 temp workspace 内）；
//   4. 该绝对路径本身绝不会被创建到磁盘上（归一化在客户端侧已完成）。
//
// 同时证明修复没有「矫枉过正」：
//   - 相对子目录路径 docs/report.md 被原样保留并写到 <workspace>/docs/ 下；
//   - `..` 越界路径仍被客户端 [WorkspacePathGuard] 拦截（抛 ArgumentError）。
//
// 复用与 local_agent_bridge_server_test.dart 相同的端口分配策略（port:0），
// 避免与运行中 App 占用的 54263 端口冲突。

import 'dart:io';

import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_server.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:flutter_test/flutter_test.dart';

/// 启动监听在临时端口（port:0）的桥接服务，与现有机房测试保持一致。
Future<RunningBridgeServer> _startTestServer(Directory workspace) =>
    startBridgeServer(workspace: workspace, port: 0);

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('wft_abs_test_');
  });

  tearDown(() async {
    try {
      await workspace.delete(recursive: true);
    } catch (_) {}
  });

  test('WorkspaceFileTool.write with absolute path writes basename to workspace '
      'root and does NOT create the absolute path on disk', () async {
    final server = await _startTestServer(workspace);
    addTearDown(() async {
      try {
        await server.close(force: true);
      } catch (_) {}
    });

    final client = LocalAgentBridgeClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    final tool = WorkspaceFileTool(client);

    // 用户实际遇到的场景：模型从对话上下文复制了一个绝对路径。
    const absolutePath =
        '/Users/fengye/Library/Application Support/chat_group/star_scene.html';
    const content = '<html>hi</html>';

    // (a) 不应抛异常（这是修复前直接失败的点）。
    Map<String, dynamic> result;
    result = await tool.write(absolutePath, content);

    // (b) 返回 ok == true。
    expect(result['ok'], isTrue);

    // (c) 以 basename 落到工作区根目录。
    final written = File('${workspace.path}/star_scene.html');
    expect(written.existsSync(), isTrue,
        reason: 'file must land in workspace root as basename');
    expect(await written.readAsString(), content);

    // (d) 绝对路径本身绝不能被创建到磁盘上（客户端归一化已将其剥离）。
    final escaped = File(absolutePath);
    expect(escaped.existsSync(), isFalse,
        reason: 'absolute path must NOT be created on disk');
  });

  test('WorkspaceFileTool.write preserves a relative subdir path (docs/report.md)',
      () async {
    final server = await _startTestServer(workspace);
    addTearDown(() async {
      try {
        await server.close(force: true);
      } catch (_) {}
    });

    final client = LocalAgentBridgeClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    final tool = WorkspaceFileTool(client);

    // 预置子目录，隔离「路径保留」与「父目录自动创建」两个关注点，
    // 本用例仅验证归一化不把 docs/report.md 折叠成 report.md。
    final docsDir = Directory('${workspace.path}/docs');
    await docsDir.create(recursive: true);

    const content = '# report';
    final result = await tool.write('docs/report.md', content);

    expect(result['ok'], isTrue);
    // 路径被原样保留（对比绝对路径会被折叠为 basename）。
    final written = File('${workspace.path}/docs/report.md');
    expect(written.existsSync(), isTrue);
    expect(await written.readAsString(), content);
  });

  test('WorkspaceFileTool.write still rejects .. traversal with ArgumentError',
      () async {
    // `..` 越界路径应在客户端侧 [WorkspacePathGuard] 被拦截，根本不会发请求。
    // 使用一个未绑定真实服务的 client 即可证明这是客户端守卫行为。
    final client = LocalAgentBridgeClient(baseUrl: 'http://127.0.0.1:1');
    final tool = WorkspaceFileTool(client);

    expect(
      () => tool.write('../evil.txt', 'x'),
      throwsArgumentError,
    );
  });
}
