// 本地桥接服务（共享库，纯 dart:io，不依赖 Flutter）。
//
// 本文件把原本位于 bin/local_agent_bridge.dart 的 HTTP 路由逻辑抽离为
// 可复用的库函数 [startBridgeServer]，供两处使用：
//   1. 桌面端 App 进程内直接 bind 端口启动（release 桌面版开箱即用，
//      无需 Dart SDK 或外部二进制，生命周期与 App 一致）；
//   2. 开发者仍可通过 `dart run bin/local_agent_bridge.dart` 作为独立进程启动。
//
// 注意：本文件依赖 dart:io，只能被 _io 条件分支（桌面/移动端）引入。
// Web 端通过条件导出使用 _web stub，不会引入本文件，从而保证 Web 编译安全。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';

/// 最近一次上报的浏览器上下文（由 /browser/update 写入，供 /browser/current-tab 读取）。
Map<String, dynamic>? _lastBrowserContext;

/// 在给定工作区启动本地桥接 HTTP 服务并监听 [port]。
///
/// 返回已绑定的 [HttpServer]，调用方负责在适当时机调用 [HttpServer.close] 释放端口
/// （例如 App 退出时）。请求处理过程中的异常会被捕获并降级为 500 响应，
/// 不会让整个服务因单条请求失败而中断。
Future<HttpServer> startBridgeServer({
  required Directory workspace,
  int port = kLocalAgentBridgePort,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  server.listen((request) async {
    try {
      await _route(request, workspace);
    } catch (e, st) {
      stderr.writeln('[bridge] $e\n$st');
      try {
        await _json(request, {'error': 'internal_error'}, statusCode: 500);
      } catch (_) {}
    }
  });
  return server;
}

Future<void> _route(HttpRequest request, Directory workspace) async {
  if (request.method == 'OPTIONS') {
    _writeCors(request.response);
    await request.response.close();
    return;
  }

  if (request.uri.path == '/health') {
    await _json(request, {'ok': true, 'workspace': workspace.path});
    return;
  }

  if (request.uri.path == '/workspace/list') {
    final body = await _readJson(request);
    final relativePath = body['path'] as String? ?? '.';
    final dir = _resolveWorkspaceDir(workspace, relativePath);
    if (!dir.existsSync()) {
      await _json(request, {'error': 'not_found'}, statusCode: 404);
      return;
    }
    final entries = dir
        .listSync()
        .map((e) => {
              'name': _fileNameOf(e.path),
              'path': _relativeToWorkspace(workspace, e.path),
              'type': e is Directory ? 'directory' : 'file',
            })
        .toList()
      ..sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    await _json(request, {'entries': entries});
    return;
  }

  if (request.uri.path == '/workspace/read') {
    final body = await _readJson(request);
    final path = body['path'] as String? ?? '';
    final file = _resolveWorkspaceFile(workspace, path);
    if (!file.existsSync()) {
      await _json(request, {'error': 'not_found'}, statusCode: 404);
      return;
    }
    await _json(request, {
      'path': path,
      'content': await file.readAsString(),
    });
    return;
  }

  if (request.uri.path == '/workspace/apply-patch') {
    final body = await _readJson(request);
    final patch = body['patch'] as String? ?? '';
    if (patch.trim().isEmpty) {
      await _json(request, {'error': 'empty_patch'}, statusCode: 400);
      return;
    }
    final check = await _runProcess(
      'git',
      ['apply', '--check'],
      workspace,
      stdinText: patch,
    );
    if (check.exitCode != 0) {
      await _json(
        request,
        {'error': 'patch_check_failed', 'stderr': check.stderr},
        statusCode: 400,
      );
      return;
    }
    final apply = await _runProcess(
      'git',
      ['apply'],
      workspace,
      stdinText: patch,
    );
    await _json(request, {
      'ok': apply.exitCode == 0,
      'stdout': apply.stdout,
      'stderr': apply.stderr,
      'exitCode': apply.exitCode,
    }, statusCode: apply.exitCode == 0 ? 200 : 400);
    return;
  }

  if (request.uri.path == '/command/run') {
    final body = await _readJson(request);
    final command = (body['command'] as String? ?? '').trim();
    final args = _allowedCommand(command);
    if (args == null) {
      await _json(request, {'error': 'command_not_allowed'}, statusCode: 403);
      return;
    }
    final result = await _runProcess(args.first, args.sublist(1), workspace);
    await _json(request, {
      'stdout': result.stdout,
      'stderr': result.stderr,
      'exitCode': result.exitCode,
    }, statusCode: result.exitCode == 0 ? 200 : 400);
    return;
  }

  if (request.uri.path == '/browser/update') {
    final body = await _readJson(request);
    _lastBrowserContext = {
      'url': body['url'] as String? ?? '',
      'title': body['title'] as String? ?? '',
      'selectedText': body['selectedText'] as String? ?? '',
      'pageText': body['pageText'] as String? ?? '',
      'capturedAt': body['capturedAt'] as String? ??
          DateTime.now().toUtc().toIso8601String(),
    };
    await _json(request, {'ok': true});
    return;
  }

  if (request.uri.path == '/browser/current-tab') {
    final context = _lastBrowserContext;
    if (context == null) {
      await _json(
        request,
        {'error': 'browser_context_missing'},
        statusCode: 409,
      );
      return;
    }
    await _json(request, context);
    return;
  }

  await _json(request, {'error': 'not_found'}, statusCode: 404);
}

Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
  final raw = await utf8.decoder.bind(request).join();
  if (raw.trim().isEmpty) return {};
  final decoded = jsonDecode(raw);
  if (decoded is Map<String, dynamic>) return decoded;
  throw const FormatException('Expected JSON object');
}

File _resolveWorkspaceFile(Directory workspace, String relativePath) {
  _rejectUnsafeRelativePath(relativePath);
  final file = File('${workspace.path}/$relativePath').absolute;
  _ensureInsideWorkspace(workspace, file.path);
  return file;
}

Directory _resolveWorkspaceDir(Directory workspace, String relativePath) {
  final normalized = relativePath == '.' ? '' : relativePath;
  if (normalized.isNotEmpty) _rejectUnsafeRelativePath(normalized);
  final dir = Directory('${workspace.path}/$normalized').absolute;
  _ensureInsideWorkspace(workspace, dir.path);
  return dir;
}

void _rejectUnsafeRelativePath(String path) {
  if (path.trim().isEmpty ||
      path.startsWith('/') ||
      path.startsWith('\\') ||
      path.split(RegExp(r'[/\\]+')).contains('..')) {
    throw ArgumentError('Unsafe workspace path: $path');
  }
}

void _ensureInsideWorkspace(Directory workspace, String path) {
  final workspacePath = workspace.absolute.path;
  if (path != workspacePath && !path.startsWith('$workspacePath/')) {
    throw ArgumentError('Path escapes workspace: $path');
  }
}

List<String>? _allowedCommand(String command) {
  const allowed = {
    'flutter analyze': ['flutter', 'analyze'],
    'flutter test': ['flutter', 'test'],
    'dart run build_runner build --delete-conflicting-outputs': [
      'dart',
      'run',
      'build_runner',
      'build',
      '--delete-conflicting-outputs',
    ],
  };
  return allowed[command];
}

Future<_ProcessResultText> _runProcess(
  String executable,
  List<String> arguments,
  Directory workspace, {
  String? stdinText,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workspace.path,
  );
  if (stdinText != null) {
    process.stdin.write(stdinText);
  }
  await process.stdin.close();
  final stdoutText = await utf8.decoder.bind(process.stdout).join();
  final stderrText = await utf8.decoder.bind(process.stderr).join();
  final exitCode = await process.exitCode;
  return _ProcessResultText(stdoutText, stderrText, exitCode);
}

Future<void> _json(
  HttpRequest request,
  Map<String, dynamic> body, {
  int statusCode = 200,
}) async {
  request.response.statusCode = statusCode;
  request.response.headers.contentType = ContentType.json;
  _writeCors(request.response);
  request.response.write(jsonEncode(body));
  await request.response.close();
}

void _writeCors(HttpResponse response) {
  response.headers.set('access-control-allow-origin', '*');
  response.headers.set('access-control-allow-methods', 'GET, POST, OPTIONS');
  response.headers.set('access-control-allow-headers', 'content-type');
}

String _fileNameOf(String path) {
  final segments = path.split(RegExp(r'[/\\]'));
  return segments.isEmpty ? path : segments.last;
}

String _relativeToWorkspace(Directory workspace, String path) {
  final prefix = '${workspace.absolute.path}/';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}

class _ProcessResultText {
  final String stdout;
  final String stderr;
  final int exitCode;

  const _ProcessResultText(this.stdout, this.stderr, this.exitCode);
}
