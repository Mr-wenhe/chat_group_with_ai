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
import 'dart:typed_data';

import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';

part 'local_agent_bridge_server_support.dart';

/// 最近一次上报的浏览器上下文（由 /browser/update 写入，供 /browser/current-tab 读取）。
Map<String, dynamic>? _lastBrowserContext;

/// Runtime limits for one bridge server.
///
/// The defaults are finite so a local client cannot keep a request, a file
/// read, a directory listing, or a child process alive indefinitely. Tests can
/// use smaller values to exercise failure paths deterministically.
/// Limits for the legacy ordinary-agentic localhost service. Production work
/// mode uses in-process services and never starts this server.
class LocalAgentBridgeLimits {
  final Duration requestTimeout;
  final Duration processTimeout;
  final int maxRequestBytes;
  final int maxResponseBytes;
  final int maxProcessOutputBytes;
  final int maxWorkspaceReadBytes;
  final int maxWorkspaceEntries;

  const LocalAgentBridgeLimits({
    this.requestTimeout = kLocalAgentBridgeRequestTimeout,
    this.processTimeout = kLocalAgentBridgeProcessTimeout,
    this.maxRequestBytes = kLocalAgentBridgeMaxRequestBytes,
    this.maxResponseBytes = kLocalAgentBridgeMaxResponseBytes,
    this.maxProcessOutputBytes = kLocalAgentBridgeMaxProcessOutputBytes,
    this.maxWorkspaceReadBytes = kLocalAgentBridgeMaxWorkspaceReadBytes,
    this.maxWorkspaceEntries = kLocalAgentBridgeMaxWorkspaceEntries,
  });
}

/// 在给定工作区启动本地桥接 HTTP 服务并监听 [port]。
///
/// 返回已绑定的 [HttpServer]，调用方负责在适当时机调用 [HttpServer.close] 释放端口
/// （例如 App 退出时）。请求处理过程中的异常会被捕获并转换为结构化的 4xx/5xx
/// 响应，不会让整个服务因单条请求失败而中断。
/// 运行中的桥接服务句柄：封装 [HttpServer] 与按 conversationId 分区的
/// workspace 映射。调用方通过 [registerWorkspace] 把「对话 id -> 工作目录」
/// 注册进来；之后所有 /workspace/* 与 /command/run 请求都会按请求体里的
/// `conversationId` 路由到对应目录。缺省 conversationId（空串）使用启动时
/// 的默认 workspace，保证历史调用与测试无需改动即可工作。
class RunningBridgeServer {
  final HttpServer server;
  final Map<String, Directory> _workspaces;

  RunningBridgeServer(this.server, this._workspaces);

  int get port => server.port;

  /// 注册（或覆盖）某个对话的 workspace 目录。
  void registerWorkspace(String conversationId, Directory dir) {
    final id = conversationId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(
        conversationId,
        'conversationId',
        'conversationId must not be empty',
      );
    }
    _workspaces[id] = dir.absolute;
  }

  /// 删除某个对话的 workspace 映射，不影响默认目录或其他对话。
  bool unregisterWorkspace(String conversationId) {
    final id = conversationId.trim();
    if (id.isEmpty) return false;
    return _workspaces.remove(id) != null;
  }

  Future<void> close({bool force = false}) => server.close(force: force);
}

Future<RunningBridgeServer> startBridgeServer({
  required Directory workspace,
  required String token,
  int port = kLocalAgentBridgePort,
  LocalAgentBridgeLimits limits = const LocalAgentBridgeLimits(),
}) async {
  if (token.length < 32) {
    throw ArgumentError.value(token, 'token', 'Bridge token is too short');
  }
  _validateLimits(limits);
  // 以默认空串 key 承载启动时的 workspace，保证未携带 conversationId 的
  // 请求（如单工作区旧调用 / 测试）仍有正确的落盘目录。
  final workspaces = <String, Directory>{'': workspace.absolute};
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  server.listen((request) async {
    try {
      await _route(request, workspaces, token, limits);
    } on _BridgeRequestFailure catch (error) {
      try {
        await _json(
          request,
          error.body,
          statusCode: error.statusCode,
          maxResponseBytes: limits.maxResponseBytes,
        );
      } catch (_) {}
    } on FormatException {
      try {
        await _json(
          request,
          {'error': 'invalid_json'},
          statusCode: HttpStatus.badRequest,
          maxResponseBytes: limits.maxResponseBytes,
        );
      } catch (_) {}
    } catch (_) {
      try {
        await _json(
          request,
          {'error': 'internal_error'},
          statusCode: HttpStatus.internalServerError,
          maxResponseBytes: limits.maxResponseBytes,
        );
      } catch (_) {}
    }
  });
  return RunningBridgeServer(server, workspaces);
}

Future<void> _route(
  HttpRequest request,
  Map<String, Directory> workspaces,
  String token,
  LocalAgentBridgeLimits limits,
) async {
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

  final isHealth = request.uri.path == '/health';
  if ((isHealth && request.method != 'GET') ||
      (!isHealth && request.method != 'POST')) {
    await _json(
      request,
      {'error': 'method_not_allowed'},
      statusCode: HttpStatus.methodNotAllowed,
      maxResponseBytes: limits.maxResponseBytes,
    );
    return;
  }
  if (request.headers.value(HttpHeaders.authorizationHeader) !=
      'Bearer $token') {
    await _json(
      request,
      {'error': 'unauthorized'},
      statusCode: HttpStatus.unauthorized,
      maxResponseBytes: limits.maxResponseBytes,
    );
    return;
  }

  if (isHealth) {
    await _json(
        request,
        {
          'ok': true,
          'session': token.substring(0, 8),
        },
        maxResponseBytes: limits.maxResponseBytes);
    return;
  }

  if (request.headers.contentType?.mimeType != ContentType.json.mimeType ||
      request.contentLength > limits.maxRequestBytes) {
    await _json(
      request,
      {'error': 'invalid_request'},
      statusCode: HttpStatus.requestEntityTooLarge,
      maxResponseBytes: limits.maxResponseBytes,
    );
    return;
  }

  // 其余路由都依赖 workspace：从请求体读取 conversationId 做分区路由。
  final body = await _readJson(request, limits);
  final ws = _workspaceFor(
    workspaces,
    _optionalString(body, 'conversationId'),
  );
  if (ws == null) {
    await _json(
      request,
      {'error': 'workspace_not_registered'},
      statusCode: HttpStatus.notFound,
      maxResponseBytes: limits.maxResponseBytes,
    );
    return;
  }

  if (request.uri.path == '/workspace/list') {
    final relativePath = _optionalString(body, 'path') ?? '.';
    final dir = _resolveWorkspaceDir(ws, relativePath);
    if (!dir.existsSync()) {
      await _json(
        request,
        {'error': 'not_found'},
        statusCode: HttpStatus.notFound,
        maxResponseBytes: limits.maxResponseBytes,
      );
      return;
    }
    final entries = await _listWorkspaceEntries(dir, ws, limits);
    await _json(
      request,
      {'entries': entries},
      maxResponseBytes: limits.maxResponseBytes,
    );
    return;
  }

  if (request.uri.path == '/workspace/read') {
    final path = _optionalString(body, 'path') ?? '';
    final file = _resolveWorkspaceFile(ws, path);
    if (!file.existsSync()) {
      await _json(
        request,
        {'error': 'not_found'},
        statusCode: HttpStatus.notFound,
        maxResponseBytes: limits.maxResponseBytes,
      );
      return;
    }
    final content = await _readWorkspaceText(file, limits);
    await _json(
      request,
      {'path': path, 'content': content},
      maxResponseBytes: limits.maxResponseBytes,
    );
    return;
  }

  if (request.uri.path == '/workspace/apply-patch') {
    final patch = _optionalString(body, 'patch') ?? '';
    if (patch.trim().isEmpty) {
      await _json(
        request,
        {'error': 'empty_patch'},
        statusCode: HttpStatus.badRequest,
        maxResponseBytes: limits.maxResponseBytes,
      );
      return;
    }
    final check = await _runProcess(
      'git',
      ['apply', '--check'],
      ws,
      stdinText: patch,
      limits: limits,
    );
    if (check.exitCode != 0) {
      await _json(
        request,
        {'error': 'patch_check_failed', 'stderr': check.stderr},
        statusCode: HttpStatus.badRequest,
        maxResponseBytes: limits.maxResponseBytes,
      );
      return;
    }
    final apply = await _runProcess(
      'git',
      ['apply'],
      ws,
      stdinText: patch,
      limits: limits,
    );
    await _json(
      request,
      {
        'ok': apply.exitCode == 0,
        'stdout': apply.stdout,
        'stderr': apply.stderr,
        'exitCode': apply.exitCode,
      },
      statusCode: apply.exitCode == 0 ? HttpStatus.ok : HttpStatus.badRequest,
      maxResponseBytes: limits.maxResponseBytes,
    );
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
    final path = _optionalString(body, 'path') ?? '';
    final content = _optionalString(body, 'content') ?? '';
    if (path.trim().isEmpty) {
      await _json(
        request,
        {'error': 'empty_path'},
        statusCode: HttpStatus.badRequest,
        maxResponseBytes: limits.maxResponseBytes,
      );
      return;
    }
    File file;
    try {
      file = _resolveWorkspaceFile(ws, path);
    } on ArgumentError {
      await _json(
        request,
        {'error': 'unsafe_path'},
        statusCode: HttpStatus.badRequest,
        maxResponseBytes: limits.maxResponseBytes,
      );
      return;
    }
    try {
      await file.parent.create(recursive: true).timeout(limits.requestTimeout);
      await file.writeAsString(content).timeout(limits.requestTimeout);
    } on TimeoutException {
      throw const _BridgeRequestFailure(
        'request_timeout',
        HttpStatus.requestTimeout,
      );
    }
    await _json(
        request,
        {
          'ok': true,
          'path': path,
          'bytes': utf8.encode(content).length,
        },
        maxResponseBytes: limits.maxResponseBytes);
    return;
  }

  if (request.uri.path == '/command/run') {
    final command = (_optionalString(body, 'command') ?? '').trim();
    final args = _allowedCommand(command);
    if (args == null) {
      await _json(
        request,
        {'error': 'command_not_allowed'},
        statusCode: HttpStatus.forbidden,
        maxResponseBytes: limits.maxResponseBytes,
      );
      return;
    }
    final result = await _runProcess(
      args.first,
      args.sublist(1),
      ws,
      limits: limits,
    );
    await _json(
      request,
      {
        'stdout': result.stdout,
        'stderr': result.stderr,
        'exitCode': result.exitCode,
      },
      statusCode: result.exitCode == 0 ? HttpStatus.ok : HttpStatus.badRequest,
      maxResponseBytes: limits.maxResponseBytes,
    );
    return;
  }

  if (request.uri.path == '/browser/update') {
    _lastBrowserContext = {
      'url': _optionalString(body, 'url') ?? '',
      'title': _optionalString(body, 'title') ?? '',
      'selectedText': _optionalString(body, 'selectedText') ?? '',
      'pageText': _optionalString(body, 'pageText') ?? '',
      'capturedAt': _optionalString(body, 'capturedAt') ??
          DateTime.now().toUtc().toIso8601String(),
    };
    await _json(
      request,
      {'ok': true},
      maxResponseBytes: limits.maxResponseBytes,
    );
    return;
  }

  if (request.uri.path == '/browser/current-tab') {
    final context = _lastBrowserContext;
    if (context == null) {
      await _json(
        request,
        {'error': 'browser_context_missing'},
        statusCode: HttpStatus.conflict,
        maxResponseBytes: limits.maxResponseBytes,
      );
      return;
    }
    await _json(request, context, maxResponseBytes: limits.maxResponseBytes);
    return;
  }

  await _json(
    request,
    {'error': 'not_found'},
    statusCode: HttpStatus.notFound,
    maxResponseBytes: limits.maxResponseBytes,
  );
}
