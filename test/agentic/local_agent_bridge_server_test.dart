// 本地桥接服务进程内启动冒烟测试 + /workspace/write 端点回归测试。
//
// 关键目的：
// 1. 证明桥接 HTTP 服务可以在 App 进程内直接 bind 端口并正常响应（不依赖子进程 / Dart SDK）。
// 2. 覆盖本次修复新增的 /workspace/write 端点：新建写文件、覆盖已存在文件、空路径与越界路径校验。
// 3. 通过真实 client + WorkspaceFileTool 做端到端往返，复现「已存在文件被覆盖写」的原 Bug 场景。
//
// 注：所有测试均使用 port:0（系统分配空闲端口）启动服务，避免与运行中的 App 已占用的
// 统一端口 54263 冲突，使测试可独立、可重复地运行。

import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_server.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:flutter_test/flutter_test.dart';

/// 启动监听在临时端口（port:0 => 由系统分配空闲端口）的桥接服务，
/// 避免与运行中的 App 已占用的 54263 端口冲突，使测试可独立运行。
Future<HttpServer> _startTestServer(Directory workspace) =>
    startBridgeServer(workspace: workspace, port: 0);

/// 向桥接服务发起 JSON POST 请求，返回 (statusCode, 解码后的 body)。
Future<({int statusCode, Map<String, dynamic> body})> _postJson(
  int port,
  String path,
  Map<String, dynamic> body,
) async {
  final client = HttpClient();
  final request = await client.openUrl(
    'POST',
    Uri.parse('http://127.0.0.1:$port$path'),
  );
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode(body));
  final response = await request.close();
  final raw = await utf8.decoder.bind(response).join();
  client.close(force: true);
  final decoded = raw.trim().isEmpty
      ? <String, dynamic>{}
      : jsonDecode(raw) as Map<String, dynamic>;
  return (statusCode: response.statusCode, body: decoded);
}

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('bridge_test_');
  });

  tearDown(() async {
    try {
      await workspace.delete(recursive: true);
    } catch (_) {}
  });

  test('startBridgeServer binds a port and responds /health', () async {
    final server = await _startTestServer(workspace);
    addTearDown(() async {
      try {
        await server.close(force: true);
      } catch (_) {}
    });

    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/health'),
    );
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    client.close(force: true);

    expect(response.statusCode, 200);
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    expect(decoded['ok'], isTrue);
    expect(decoded['workspace'], isNotEmpty);
  });

  test('/workspace/write creates a new file and returns ok', () async {
    final server = await _startTestServer(workspace);
    addTearDown(() async {
      try {
        await server.close(force: true);
      } catch (_) {}
    });

    const content = 'hello from bridge';
    final res = await _postJson(server.port, '/workspace/write', {
      'path': 'generated.md',
      'content': content,
    });

    expect(res.statusCode, 200);
    expect(res.body['ok'], isTrue);
    expect(res.body['path'], 'generated.md');
    expect(res.body['bytes'], content.length);

    final file = File('${workspace.path}/generated.md');
    expect(file.existsSync(), isTrue);
    expect(await file.readAsString(), content);
  });

  test('/workspace/write overwrites an existing file (bug repro)', () async {
    final server = await _startTestServer(workspace);
    addTearDown(() async {
      try {
        await server.close(force: true);
      } catch (_) {}
    });

    // 预置一个已存在文件——这正是原 Bug 的触发条件：
    // 旧实现把生成文件编码成 new-file git diff 交给 `git apply --check`，
    // 目标文件已存在时 git apply 因 "already exists" 失败 → 400。
    final existing = File('${workspace.path}/note.txt');
    await existing.writeAsString('OLD CONTENT THAT MUST BE REPLACED');

    const newContent = 'NEW CONTENT';
    final res = await _postJson(server.port, '/workspace/write', {
      'path': 'note.txt',
      'content': newContent,
    });

    expect(res.statusCode, 200);
    expect(res.body['ok'], isTrue);
    // 内容被整体替换，而非追加或保留旧内容（这正是本次修复要保证的行为）。
    expect(await existing.readAsString(), newContent);
  });

  test('/workspace/write rejects empty path with 400 empty_path', () async {
    final server = await _startTestServer(workspace);
    addTearDown(() async {
      try {
        await server.close(force: true);
      } catch (_) {}
    });

    final res = await _postJson(server.port, '/workspace/write', {
      'path': '',
      'content': 'x',
    });

    expect(res.statusCode, 400);
    expect(res.body['error'], 'empty_path');
  });

  test('/workspace/write rejects path traversal with 400 unsafe_path', () async {
    final server = await _startTestServer(workspace);
    addTearDown(() async {
      try {
        await server.close(force: true);
      } catch (_) {}
    });

    final res = await _postJson(server.port, '/workspace/write', {
      'path': '../escape.txt',
      'content': 'x',
    });

    expect(res.statusCode, 400);
    expect(res.body['error'], 'unsafe_path');

    // 确保越界文件未被写出到工作区之外。
    final escaped = File('${workspace.parent.path}/escape.txt');
    expect(escaped.existsSync(), isFalse);
  });

  test('/workspace/write rejects absolute path with 400 unsafe_path', () async {
    final server = await _startTestServer(workspace);
    addTearDown(() async {
      try {
        await server.close(force: true);
      } catch (_) {}
    });

    final res = await _postJson(server.port, '/workspace/write', {
      'path': '/etc/passwd',
      'content': 'x',
    });

    expect(res.statusCode, 400);
    expect(res.body['error'], 'unsafe_path');
  });

  test('WorkspaceFileTool.write round-trips through the bridge client', () async {
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

    const content = 'client generated content';
    final result = await tool.write('via_client.md', content);

    expect(result['ok'], isTrue);
    final file = File('${workspace.path}/via_client.md');
    expect(file.existsSync(), isTrue);
    expect(await file.readAsString(), content);
  });

  test('WorkspaceFileTool.write throws ArgumentError on unsafe path', () async {
    // 客户端侧 [WorkspacePathGuard] 应在发出请求前拦截越界路径。
    final client = LocalAgentBridgeClient(baseUrl: 'http://127.0.0.1:1');
    final tool = WorkspaceFileTool(client);
    expect(() => tool.write('../escape.txt', 'x'), throwsArgumentError);
  });
}
