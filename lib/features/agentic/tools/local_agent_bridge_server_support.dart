part of 'local_agent_bridge_server.dart';

/// 按请求体里的 conversationId 选择对应 workspace 目录。
///
/// - 命中已注册 id 直接返回该目录；
/// - 未携带 conversationId 时回退默认空串 workspace（启动时注册）；
/// - 带有未知非空 conversationId 时返回 null，让调用方明确拒绝请求；
/// - 极端情况（默认也不存在）才回落到任意第一个已注册目录，兼容旧的
///   无 conversationId 调用。
Directory? _workspaceFor(
    Map<String, Directory> workspaces, String? conversationId) {
  final id = (conversationId ?? '').trim();
  if (id.isNotEmpty) return workspaces[id];
  return workspaces[''] ??
      (workspaces.isEmpty ? null : workspaces.values.first);
}

Future<List<Map<String, dynamic>>> _listWorkspaceEntries(
  Directory dir,
  Directory workspace,
  LocalAgentBridgeLimits limits,
) async {
  final entries = <Map<String, dynamic>>[];
  try {
    await for (final entity in dir.list().timeout(limits.requestTimeout)) {
      if (entries.length >= limits.maxWorkspaceEntries) {
        throw const _OutputTooLarge();
      }
      entries.add({
        'name': _fileNameOf(entity.path),
        'path': _relativeToWorkspace(workspace, entity.path),
        'type': entity is Directory ? 'directory' : 'file',
      });
    }
  } on TimeoutException {
    throw const _BridgeRequestFailure(
      'request_timeout',
      HttpStatus.requestTimeout,
    );
  }
  entries.sort(
    (a, b) => (a['path'] as String).compareTo(b['path'] as String),
  );
  return entries;
}

Future<String> _readWorkspaceText(
  File file,
  LocalAgentBridgeLimits limits,
) async {
  final bytes = BytesBuilder(copy: false);
  var totalBytes = 0;
  try {
    await for (final chunk in file.openRead().timeout(limits.requestTimeout)) {
      totalBytes += chunk.length;
      if (totalBytes > limits.maxWorkspaceReadBytes) {
        throw const _OutputTooLarge();
      }
      bytes.add(chunk);
    }
  } on TimeoutException {
    throw const _BridgeRequestFailure(
      'request_timeout',
      HttpStatus.requestTimeout,
    );
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}

Future<Map<String, dynamic>> _readJson(
  HttpRequest request,
  LocalAgentBridgeLimits limits,
) async {
  final bytes = BytesBuilder(copy: false);
  var totalBytes = 0;
  var tooLarge = false;
  try {
    await for (final chunk in request.timeout(limits.requestTimeout)) {
      if (tooLarge) continue;
      totalBytes += chunk.length;
      if (totalBytes > limits.maxRequestBytes) {
        // Drain the already-uploaded chunked body so the client can receive a
        // normal 413 response. The stream timeout still prevents an oversized
        // or malicious client from holding this drain open indefinitely.
        tooLarge = true;
        continue;
      }
      bytes.add(chunk);
    }
  } on TimeoutException {
    throw const _BridgeRequestFailure(
      'request_timeout',
      HttpStatus.requestTimeout,
    );
  }
  if (tooLarge) throw const _RequestBodyTooLarge();
  final raw = utf8.decode(bytes.takeBytes());
  if (raw.trim().isEmpty) return {};
  final decoded = jsonDecode(raw);
  if (decoded is Map<String, dynamic>) return decoded;
  throw const FormatException('Expected JSON object');
}

String? _optionalString(Map<String, dynamic> body, String field) {
  final value = body[field];
  if (value == null) return null;
  if (value is! String) throw _InvalidField(field);
  return value;
}

class _BridgeRequestFailure implements Exception {
  final String code;
  final int statusCode;
  final String? field;

  const _BridgeRequestFailure(
    this.code,
    this.statusCode, {
    this.field,
  });

  Map<String, dynamic> get body => {
        'error': code,
        if (field != null) 'field': field,
      };
}

class _InvalidField extends _BridgeRequestFailure {
  _InvalidField(String field)
      : super('invalid_field', HttpStatus.badRequest, field: field);
}

class _RequestBodyTooLarge extends _BridgeRequestFailure {
  const _RequestBodyTooLarge()
      : super('invalid_request', HttpStatus.requestEntityTooLarge);
}

class _ProcessTimeout extends _BridgeRequestFailure {
  const _ProcessTimeout() : super('process_timeout', HttpStatus.gatewayTimeout);
}

class _OutputTooLarge extends _BridgeRequestFailure {
  const _OutputTooLarge()
      : super('output_too_large', HttpStatus.requestEntityTooLarge);
}

void _validateLimits(LocalAgentBridgeLimits limits) {
  if (limits.requestTimeout <= Duration.zero) {
    throw ArgumentError.value(
      limits.requestTimeout,
      'requestTimeout',
      'must be positive',
    );
  }
  if (limits.processTimeout <= Duration.zero) {
    throw ArgumentError.value(
      limits.processTimeout,
      'processTimeout',
      'must be positive',
    );
  }
  if (limits.maxRequestBytes <= 0 ||
      limits.maxResponseBytes <= 0 ||
      limits.maxProcessOutputBytes <= 0 ||
      limits.maxWorkspaceReadBytes <= 0 ||
      limits.maxWorkspaceEntries <= 0) {
    throw ArgumentError('Bridge size limits must be positive');
  }
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
  _ensureResolvedInsideWorkspace(workspace, file.path);
  return file;
}

Directory _resolveWorkspaceDir(Directory workspace, String relativePath) {
  final normalized = relativePath == '.'
      ? ''
      : _normalizeWorkspacePath(workspace, relativePath);
  if (normalized.isNotEmpty) _rejectUnsafeRelativePath(normalized);
  final dir = Directory('${workspace.path}/$normalized').absolute;
  _ensureInsideWorkspace(workspace, dir.path);
  _ensureResolvedInsideWorkspace(workspace, dir.path);
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

/// Rejects paths whose nearest existing ancestor resolves through a symbolic
/// link outside [workspace]. Lexical `..` checks alone cannot prevent that
/// escape when a link inside the workspace points elsewhere.
void _ensureResolvedInsideWorkspace(Directory workspace, String path) {
  final resolvedWorkspace = workspace.resolveSymbolicLinksSync();
  var probe = File(path).absolute.path;
  while (FileSystemEntity.typeSync(probe, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = FileSystemEntity.parentOf(probe);
    if (parent == probe) break;
    probe = parent;
  }
  final resolvedProbe = File(probe).resolveSymbolicLinksSync();
  _ensureInsideWorkspace(Directory(resolvedWorkspace), resolvedProbe);
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
  if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path)) return null;
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
  required LocalAgentBridgeLimits limits,
}) async {
  late final Process process;
  final startFuture = Process.start(
    executable,
    arguments,
    workingDirectory: workspace.path,
  );
  try {
    process = await startFuture.timeout(limits.processTimeout);
  } on TimeoutException {
    // Process.start itself cannot be cancelled. If the OS completes the
    // launch after our timeout, terminate that late process immediately so a
    // slow spawn cannot leak a child outside the request lifecycle.
    unawaited(
      startFuture.then<void>((started) => started.kill()).catchError((_) {}),
    );
    throw const _ProcessTimeout();
  }

  final budget = _ByteBudget(limits.maxProcessOutputBytes);
  final stdoutFuture = _collectProcessOutput(process.stdout, budget);
  final stderrFuture = _collectProcessOutput(process.stderr, budget);
  final stopwatch = Stopwatch()..start();

  Duration remaining() {
    final value = limits.processTimeout - stopwatch.elapsed;
    return value <= Duration.zero ? const Duration(microseconds: 1) : value;
  }

  try {
    if (stdinText != null) {
      process.stdin.write(stdinText);
    }
    await process.stdin.close().timeout(remaining());
    final output = await Future.wait<String>([stdoutFuture, stderrFuture])
        .timeout(remaining());
    final exitCode = await process.exitCode.timeout(remaining());
    return _ProcessResultText(output[0], output[1], exitCode);
  } on TimeoutException {
    await _terminateProcess(process, stdoutFuture, stderrFuture);
    throw const _ProcessTimeout();
  } on _OutputTooLarge {
    await _terminateProcess(process, stdoutFuture, stderrFuture);
    rethrow;
  } catch (_) {
    await _terminateProcess(process, stdoutFuture, stderrFuture);
    rethrow;
  }
}

Future<String> _collectProcessOutput(
  Stream<List<int>> stream,
  _ByteBudget budget,
) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    budget.add(chunk.length);
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes(), allowMalformed: true);
}

Future<void> _terminateProcess(
  Process process,
  Future<String> stdoutFuture,
  Future<String> stderrFuture,
) async {
  try {
    process.kill();
  } catch (_) {}
  try {
    await process.exitCode.timeout(const Duration(seconds: 1));
  } catch (_) {}
  try {
    await Future.wait<String>([stdoutFuture, stderrFuture])
        .timeout(const Duration(seconds: 1));
  } catch (_) {}
}

class _ByteBudget {
  final int maxBytes;
  int _used = 0;

  _ByteBudget(this.maxBytes);

  void add(int bytes) {
    _used += bytes;
    if (_used > maxBytes) throw const _OutputTooLarge();
  }
}

Future<void> _json(
  HttpRequest request,
  Map<String, dynamic> body, {
  int statusCode = 200,
  int maxResponseBytes = kLocalAgentBridgeMaxResponseBytes,
}) async {
  var payload = utf8.encode(jsonEncode(body));
  if (payload.length > maxResponseBytes) {
    statusCode = HttpStatus.requestEntityTooLarge;
    payload = utf8.encode(jsonEncode({'error': 'response_too_large'}));
  }
  request.response.statusCode = statusCode;
  request.response.headers.contentType = ContentType.json;
  request.response.headers.contentLength = payload.length;
  _writeCors(request);
  request.response.add(payload);
  await request.response.close();
}

void _writeCors(HttpRequest request) {
  final origin = request.headers.value('origin');
  if (origin == null || origin.isEmpty) return;
  request.response.headers.set('access-control-allow-origin', origin);
  request.response.headers.set('vary', 'origin');
  request.response.headers
      .set('access-control-allow-methods', 'GET, POST, OPTIONS');
  request.response.headers
      .set('access-control-allow-headers', 'content-type, authorization');
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
