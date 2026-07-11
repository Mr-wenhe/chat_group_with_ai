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
  final origin = request.headers.value('origin');
  if (origin != null && !_isAllowedBrowserOrigin(origin)) {
    request.response.statusCode = HttpStatus.forbidden;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'error': 'origin_not_allowed'}));
    await request.response.close();
    return;
  }

  if (request.method == 'OPTIONS') {
    _writeCors(request);
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
    await _json(
        request,
        {
          'ok': apply.exitCode == 0,
          'stdout': apply.stdout,
          'stderr': apply.stderr,
          'exitCode': apply.exitCode,
        },
        statusCode: apply.exitCode == 0 ? 200 : 400);
    return;
  }

  // 直接写文件端点（方案 A）。
  //
  // 语义：把「生成/覆盖文件」从脆弱的 `git apply` 路径中剥离出来，
  // 直接以 [{path}, {content}] 写盘。已存在文件会被覆盖（符合「覆盖写」需求），
  // 不存在则创建。沿用 [_resolveWorkspaceFile] 的安全校验（含 WorkspacePathGuard
  // 与 workspace 边界校验），不破坏原有 /workspace/apply-patch 端点。
  // content 允许为空（写入空文件），路径为空或不安全则返回 400。
  if (request.uri.path == '/workspace/write') {
    final body = await _readJson(request);
    final path = body['path'] as String? ?? '';
    final content = body['content'] as String? ?? '';
    if (path.trim().isEmpty) {
      await _json(request, {'error': 'empty_path'}, statusCode: 400);
      return;
    }
    File file;
    try {
      file = _resolveWorkspaceFile(workspace, path);
    } on ArgumentError catch (e) {
      await _json(
        request,
        {'error': 'unsafe_path', 'message': e.toString()},
        statusCode: 400,
      );
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    await _json(request, {
      'ok': true,
      'path': path,
      'bytes': content.length,
    });
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
    await _json(
        request,
        {
          'stdout': result.stdout,
          'stderr': result.stderr,
          'exitCode': result.exitCode,
        },
        statusCode: result.exitCode == 0 ? 200 : 400);
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

String _normalizeWorkspacePath(Directory workspace, String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return trimmed;
  final isAbs = trimmed.startsWith('/') ||
      trimmed.startsWith('\\') ||
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(trimmed);
  final normalized = trimmed.replaceAll('\\', '/');
  if (!isAbs) return normalized; // 已是相对路径
  final wsPath = workspace.absolute.path.replaceAll('\\', '/');
  final comparablePath =
      Platform.isWindows ? normalized.toLowerCase() : normalized;
  final comparableWorkspace =
      Platform.isWindows ? wsPath.toLowerCase() : wsPath;
  if (comparablePath == comparableWorkspace ||
      comparablePath.startsWith('$comparableWorkspace/')) {
    final rel = normalized.substring(wsPath.length);
    return rel.startsWith('/') ? rel.substring(1) : rel;
  }
  final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? '' : segments.last;
}

File _resolveWorkspaceFile(Directory workspace, String relativePath) {
  final normalized = _normalizeWorkspacePath(workspace, relativePath);
  _rejectUnsafeRelativePath(normalized);
  final file = File('${workspace.path}/$normalized').absolute;
  _ensureInsideWorkspace(workspace, file.path);
  return file;
}

Directory _resolveWorkspaceDir(Directory workspace, String relativePath) {
  final normalized = relativePath == '.'
      ? ''
      : _normalizeWorkspacePath(workspace, relativePath);
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
  var workspacePath = workspace.absolute.path.replaceAll('\\', '/');
  var candidatePath = path.replaceAll('\\', '/');
  if (Platform.isWindows) {
    workspacePath = workspacePath.toLowerCase();
    candidatePath = candidatePath.toLowerCase();
  }
  if (candidatePath != workspacePath &&
      !candidatePath.startsWith('$workspacePath/')) {
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
  final exact = allowed[command];
  if (exact != null) return exact;

  const analyzePrefix = 'flutter analyze ';
  if (!command.startsWith(analyzePrefix)) return null;
  final path = _decodeCommandPath(command.substring(analyzePrefix.length));
  if (path == null || !path.toLowerCase().endsWith('.dart')) return null;
  try {
    _rejectUnsafeRelativePath(path);
  } on ArgumentError {
    return null;
  }
  return ['flutter', 'analyze', path];
}

String? _decodeCommandPath(String raw) {
  var path = raw.trim();
  if (path.startsWith("'") || path.endsWith("'")) {
    if (!(path.startsWith("'") && path.endsWith("'"))) return null;
    path = path.substring(1, path.length - 1).replaceAll(r"'\''", "'");
  }
  if (path.isEmpty || path.startsWith('-')) return null;
  if (RegExp(r'''[;&|`$<>\r\n]''').hasMatch(path)) return null;
  return path;
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
  _writeCors(request);
  request.response.write(jsonEncode(body));
  await request.response.close();
}

void _writeCors(HttpRequest request) {
  final origin = request.headers.value('origin');
  if (origin == null || origin.isEmpty) return;
  request.response.headers.set('access-control-allow-origin', origin);
  request.response.headers.set('vary', 'origin');
  request.response.headers
      .set('access-control-allow-methods', 'GET, POST, OPTIONS');
  request.response.headers.set('access-control-allow-headers', 'content-type');
}

bool _isAllowedBrowserOrigin(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  return uri.host == 'localhost' ||
      uri.host == '127.0.0.1' ||
      uri.host == '::1';
}

String _fileNameOf(String path) {
  final segments = path.split(RegExp(r'[/\\]'));
  return segments.isEmpty ? path : segments.last;
}

String _relativeToWorkspace(Directory workspace, String path) {
  final root = workspace.absolute.path.replaceAll('\\', '/');
  final candidate = path.replaceAll('\\', '/');
  final comparableRoot = Platform.isWindows ? root.toLowerCase() : root;
  final comparableCandidate =
      Platform.isWindows ? candidate.toLowerCase() : candidate;
  final prefix = '$comparableRoot/';
  return comparableCandidate.startsWith(prefix)
      ? candidate.substring(root.length + 1)
      : candidate;
}

class _ProcessResultText {
  final String stdout;
  final String stderr;
  final int exitCode;

  const _ProcessResultText(this.stdout, this.stderr, this.exitCode);
}
