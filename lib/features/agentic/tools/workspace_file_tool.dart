import 'local_agent_bridge_client.dart';

class WorkspacePathGuard {
  static bool isSafeRelativePath(String path) {
    if (path.trim().isEmpty) return false;
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
      final segments = trimmed
          .split(RegExp(r'[/\\]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      return segments.isEmpty ? '' : segments.last;
    }
    return trimmed;
  }
}

class WorkspaceFileTool {
  final LocalAgentBridgeClient bridge;

  WorkspaceFileTool(this.bridge);

  Future<Map<String, dynamic>> list({String path = '.'}) {
    final safe = WorkspacePathGuard.normalizeToRelative(path);
    if (path != '.' && !WorkspacePathGuard.isSafeRelativePath(safe)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    return bridge.postJson('/workspace/list', {'path': safe});
  }

  Future<Map<String, dynamic>> read(String path) {
    final safe = WorkspacePathGuard.normalizeToRelative(path);
    if (!WorkspacePathGuard.isSafeRelativePath(safe)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    return bridge.postJson('/workspace/read', {'path': safe});
  }

  Future<Map<String, dynamic>> applyPatch(String patch) {
    if (patch.trim().isEmpty) {
      throw ArgumentError('Patch cannot be empty.');
    }
    return bridge.postJson('/workspace/apply-patch', {'patch': patch});
  }

  /// 直接写文件（方案 A）。
  ///
  /// 把 [content] 写入工作区相对路径 [path]：已存在则覆盖，不存在则创建。
  /// [content] 允许为空（写入空文件）。路径需为安全的相对路径，否则抛
  /// [ArgumentError]。实际写盘由桥接服务端的 `/workspace/write` 端点完成。
  Future<Map<String, dynamic>> write(String path, String content) {
    final safe = WorkspacePathGuard.normalizeToRelative(path);
    if (!WorkspacePathGuard.isSafeRelativePath(safe)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    return bridge.postJson('/workspace/write', {'path': safe, 'content': content});
  }

  Future<Map<String, dynamic>> runCommand(String command) {
    if (command.trim().isEmpty) {
      throw ArgumentError('Command cannot be empty.');
    }
    return bridge.postJson('/command/run', {'command': command});
  }
}
