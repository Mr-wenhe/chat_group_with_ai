import 'dart:convert';

import 'package:dio/dio.dart';

import 'local_agent_bridge_client.dart';

class WorkspacePathGuard {
  static bool isSafeRelativePath(String path) {
    if (path.trim().isEmpty) return false;
    if (RegExp(r'[\u0000-\u001f\u007f]').hasMatch(path)) return false;
    if (path.startsWith('/') || path.startsWith('\\')) return false;
    final segments = path.split(RegExp(r'[/\\]+'));
    return !segments.contains('..');
  }

  /// 将任意路径归一化为相对工作区的相对路径。
  /// 绝对路径（Unix `/a/b/c` 或 Windows `C:\\a\\b`）取最后一段（basename），
  /// 这样模型即使输出 `/Users/.../Library/.../star.html` 也只会落到工作区根目录下的 `star.html`，
  /// 而不是抛错中断写文件。相对路径（含子目录如 `docs/report.md`）原样返回。空串返回空串。
  static String normalizeToRelative(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('/') ||
        trimmed.startsWith('\\') ||
        RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(trimmed)) {
      final segments =
          trimmed.split(RegExp(r'[/\\]+')).where((s) => s.isNotEmpty).toList();
      return segments.isEmpty ? '' : segments.last;
    }
    return trimmed.replaceAll('\\', '/');
  }
}

/// Legacy workspace tool owned by ordinary/compatibility agentic callers.
///
/// Production work mode uses the grant-backed Stage 02 tool directly and does
/// not instantiate this bridge-backed type.
class WorkspaceFileTool {
  final LocalAgentBridgeClient? bridge;

  /// Whether the backing tool can authorize and resolve absolute paths on its
  /// own. The legacy bridge intentionally receives only workspace-relative
  /// basenames; in-process Stage 02 services override this so an explicitly
  /// authorized absolute path is not silently rewritten to another file.
  bool get acceptsAbsolutePaths => false;

  /// Filename classification is optional for the legacy bridge. Stage 02
  /// overrides it so the runtime can avoid echoing sensitive file contents
  /// during post-write verification.
  bool isSensitivePath(String path) => false;

  /// 当前工具实例归属的对话 id；发出的每个桥接请求都会带上它，
  /// 使服务端能按 conversationId 路由到正确的 workspace 目录。
  /// 留空（历史调用 / 测试）时服务端回退到默认 workspace。
  final String conversationId;

  WorkspaceFileTool(
    this.bridge, {
    this.conversationId = '',
  });

  WorkspaceFileTool.withoutBridge({this.conversationId = ''}) : bridge = null;

  /// 把 conversationId 并入请求体（空串时省略，保持旧接口兼容）。
  Map<String, dynamic> _body(Map<String, dynamic> body) {
    if (conversationId.isEmpty) return body;
    return {...body, 'conversationId': conversationId};
  }

  Future<Map<String, dynamic>> list({String path = '.'}) {
    final safe = WorkspacePathGuard.normalizeToRelative(path);
    if (path != '.' && !WorkspacePathGuard.isSafeRelativePath(safe)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    return _requireBridge().postJson('/workspace/list', _body({'path': safe}));
  }

  Future<Map<String, dynamic>> listWithOptions({
    String path = '.',
    int page = 0,
    int pageSize = 200,
    bool recursive = false,
  }) =>
      list(path: path);

  Future<Map<String, dynamic>> read(String path) {
    final safe = WorkspacePathGuard.normalizeToRelative(path);
    if (!WorkspacePathGuard.isSafeRelativePath(safe)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    return _requireBridge().postJson('/workspace/read', _body({'path': safe}));
  }

  Future<Map<String, dynamic>> readWithOptions(
    String path, {
    int startByte = 0,
    int? byteLength,
    bool allowSensitive = false,
  }) =>
      read(path);

  Future<Map<String, dynamic>> search(
    String path,
    String query, {
    bool recursive = false,
    bool caseSensitive = true,
    bool allowSensitive = false,
  }) {
    final safe = WorkspacePathGuard.normalizeToRelative(path);
    if (!WorkspacePathGuard.isSafeRelativePath(safe)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    return _requireBridge().postJson(
        '/workspace/search',
        _body({
          'path': safe,
          'query': query,
          'recursive': recursive,
          'caseSensitive': caseSensitive,
          'allowSensitive': allowSensitive,
        }));
  }

  Future<Map<String, dynamic>> applyPatch(String patch) {
    if (patch.trim().isEmpty) {
      throw ArgumentError('Patch cannot be empty.');
    }
    return _requireBridge()
        .postJson('/workspace/apply-patch', _body({'patch': patch}));
  }

  /// 直接写文件（方案 A）。
  ///
  /// 把 [content] 写入工作区相对路径 [path]：已存在则覆盖，不存在则创建。
  /// [content] 允许为空（写入空文件）。路径需为安全的相对路径，否则抛
  /// [ArgumentError]。实际写盘由桥接服务端的 `/workspace/write` 端点完成。
  Future<Map<String, dynamic>> write(String path, String content) async {
    final safe = WorkspacePathGuard.normalizeToRelative(path);
    if (!WorkspacePathGuard.isSafeRelativePath(safe)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    try {
      return await _requireBridge().postJson(
        '/workspace/write',
        _body({'path': safe, 'content': content}),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
      return _writeThroughLegacyPatch(safe, content);
    }
  }

  /// 兼容旧版桥接：旧服务没有 `/workspace/write`，但支持 read + apply-patch。
  /// 客户端遇到 write 404 时自动把“完整内容写入”转换为整文件补丁，用户无需
  /// 退出 App、清理残留进程或手动重试。
  Future<Map<String, dynamic>> _writeThroughLegacyPatch(
    String path,
    String content,
  ) async {
    String? oldContent;
    try {
      final result = await read(path);
      oldContent = result['content'] as String?;
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
    }
    final patch = _fullFilePatch(
      path: path,
      oldContent: oldContent,
      newContent: content,
    );
    final result = await applyPatch(patch); // 已带 conversationId
    return {
      ...result,
      'ok': result['ok'] == true || result['exitCode'] == 0,
      'path': path,
      'bytes': utf8.encode(content).length,
      'legacyFallback': true,
    };
  }

  static String _fullFilePatch({
    required String path,
    required String? oldContent,
    required String newContent,
  }) {
    final oldLines = _patchLines(oldContent ?? '');
    final newLines = _patchLines(newContent);
    final buffer = StringBuffer()..writeln('diff --git a/$path b/$path');
    if (oldContent == null) {
      buffer.writeln('new file mode 100644');
      buffer.writeln('--- /dev/null');
    } else {
      buffer.writeln('--- a/$path');
    }
    buffer
      ..writeln('+++ b/$path')
      ..writeln(
        '@@ ${_range('-', oldLines.length)} ${_range('+', newLines.length)} @@',
      );
    for (final line in oldLines) {
      buffer.writeln('-$line');
    }
    if (oldContent != null &&
        oldContent.isNotEmpty &&
        !oldContent.endsWith('\n')) {
      buffer.writeln(r'\ No newline at end of file');
    }
    for (final line in newLines) {
      buffer.writeln('+$line');
    }
    if (newContent.isNotEmpty && !newContent.endsWith('\n')) {
      buffer.writeln(r'\ No newline at end of file');
    }
    return buffer.toString();
  }

  static List<String> _patchLines(String content) {
    if (content.isEmpty) return const [];
    final lines = content.split('\n');
    if (content.endsWith('\n')) lines.removeLast();
    return lines;
  }

  static String _range(String prefix, int count) =>
      count == 0 ? '${prefix}0,0' : '${prefix}1,$count';

  Future<Map<String, dynamic>> runCommand(String command) {
    if (command.trim().isEmpty) {
      throw ArgumentError('Command cannot be empty.');
    }
    return _requireBridge()
        .postJson('/command/run', _body({'command': command}));
  }

  Future<Map<String, dynamic>> rename(
    String path,
    String destinationPath,
  ) {
    final safePath = WorkspacePathGuard.normalizeToRelative(path);
    final safeDestination =
        WorkspacePathGuard.normalizeToRelative(destinationPath);
    if (!WorkspacePathGuard.isSafeRelativePath(safePath) ||
        !WorkspacePathGuard.isSafeRelativePath(safeDestination)) {
      throw ArgumentError('Unsafe workspace rename path.');
    }
    return _requireBridge().postJson(
      '/workspace/rename',
      _body({
        'path': safePath,
        'destinationPath': safeDestination,
      }),
    );
  }

  Future<Map<String, dynamic>> delete(String path) {
    final safePath = WorkspacePathGuard.normalizeToRelative(path);
    if (!WorkspacePathGuard.isSafeRelativePath(safePath)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    return _requireBridge().postJson(
      '/workspace/delete',
      _body({'path': safePath}),
    );
  }

  LocalAgentBridgeClient _requireBridge() =>
      bridge ?? (throw StateError('Workspace bridge is not configured.'));
}
