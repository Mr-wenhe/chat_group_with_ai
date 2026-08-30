import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workspace paths cannot escape root', () {
    expect(WorkspacePathGuard.isSafeRelativePath('lib/main.dart'), isTrue);
    expect(WorkspacePathGuard.isSafeRelativePath('../secret.txt'), isFalse);
    expect(WorkspacePathGuard.isSafeRelativePath('/etc/passwd'), isFalse);
    expect(WorkspacePathGuard.isSafeRelativePath('lib/a\n.dart'), isFalse);
  });

  test('runCommand forwards the conversation id to the bridge', () async {
    Map<String, dynamic>? receivedBody;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final bodyText = await utf8.decoder.bind(request).join();
      receivedBody = jsonDecode(bodyText) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'ok': true, 'exitCode': 0}));
      await request.response.close();
    });
    final tool = WorkspaceFileTool(
      LocalAgentBridgeClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'test-token',
      ),
      conversationId: 'conv-b',
    );

    await tool.runCommand('flutter analyze sample.dart');

    expect(receivedBody, {
      'command': 'flutter analyze sample.dart',
      'conversationId': 'conv-b',
    });
  });

  test('write falls back to legacy apply-patch endpoint when write is 404',
      () async {
    final requests = <String>[];
    Map<String, dynamic>? receivedPatchBody;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests.add(request.uri.path);
      final bodyText = await utf8.decoder.bind(request).join();
      final body = bodyText.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(bodyText) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/workspace/write') {
        request.response.statusCode = 404;
        request.response.write(jsonEncode({'error': 'not_found'}));
      } else if (request.uri.path == '/workspace/read') {
        request.response.statusCode = 404;
        request.response.write(jsonEncode({'error': 'not_found'}));
      } else if (request.uri.path == '/workspace/apply-patch') {
        receivedPatchBody = body;
        request.response.write(jsonEncode({'ok': true, 'exitCode': 0}));
      } else {
        request.response.statusCode = 404;
        request.response.write(jsonEncode({'error': 'not_found'}));
      }
      await request.response.close();
    });
    final tool = WorkspaceFileTool(LocalAgentBridgeClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'test-token',
    ));

    final result = await tool.write(
      'page.html',
      '<!doctype html>\n<title>完整主页</title>\n',
    );

    expect(result['ok'], isTrue);
    expect(requests, [
      '/workspace/write',
      '/workspace/read',
      '/workspace/apply-patch',
    ]);
    final patch = receivedPatchBody?['patch'] as String? ?? '';
    expect(patch, contains('diff --git a/page.html b/page.html'));
    expect(patch, contains('+<!doctype html>'));
    expect(patch, contains('+<title>完整主页</title>'));
  });

  test('legacy fallback replaces an existing file without a 404 or refusal',
      () async {
    final workspace = await Directory.systemTemp.createTemp('legacy_bridge_');
    addTearDown(() => workspace.delete(recursive: true));
    expect(
      (await Process.run('git', ['init'], workingDirectory: workspace.path))
          .exitCode,
      0,
    );
    final page = File('${workspace.path}/page.html');
    await page.writeAsString('<!doctype html>\n<title>旧页面</title>\n');
    await Process.run('git', ['add', 'page.html'],
        workingDirectory: workspace.path);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final bodyText = await utf8.decoder.bind(request).join();
      final body = bodyText.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(bodyText) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path == '/workspace/write') {
        request.response.statusCode = 404;
        request.response.write(jsonEncode({'error': 'not_found'}));
      } else if (request.uri.path == '/workspace/read') {
        request.response.write(jsonEncode({
          'path': 'page.html',
          'content': await page.readAsString(),
        }));
      } else if (request.uri.path == '/workspace/apply-patch') {
        final patchFile = File('${workspace.path}/legacy.patch');
        await patchFile.writeAsString(body['patch'] as String);
        final applied = await Process.run(
          'git',
          ['apply', 'legacy.patch'],
          workingDirectory: workspace.path,
        );
        request.response.statusCode = applied.exitCode == 0 ? 200 : 400;
        request.response.write(jsonEncode({
          'ok': applied.exitCode == 0,
          'exitCode': applied.exitCode,
          'stderr': applied.stderr,
        }));
      }
      await request.response.close();
    });
    final tool = WorkspaceFileTool(LocalAgentBridgeClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'test-token',
    ));

    final result = await tool.write(
      'page.html',
      '<!doctype html>\n<title>新页面</title>\n',
    );

    expect(result['ok'], isTrue);
    expect(result['legacyFallback'], isTrue);
    expect(await page.readAsString(), '<!doctype html>\n<title>新页面</title>\n');
  });
}
