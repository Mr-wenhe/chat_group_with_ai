import 'local_agent_bridge_client.dart';

class WorkspacePathGuard {
  static bool isSafeRelativePath(String path) {
    if (path.trim().isEmpty) return false;
    if (path.startsWith('/') || path.startsWith('\\')) return false;
    final segments = path.split(RegExp(r'[/\\]+'));
    return !segments.contains('..');
  }
}

class WorkspaceFileTool {
  final LocalAgentBridgeClient bridge;

  WorkspaceFileTool(this.bridge);

  Future<Map<String, dynamic>> list({String path = '.'}) {
    if (path != '.' && !WorkspacePathGuard.isSafeRelativePath(path)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    return bridge.postJson('/workspace/list', {'path': path});
  }

  Future<Map<String, dynamic>> read(String path) {
    if (!WorkspacePathGuard.isSafeRelativePath(path)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    return bridge.postJson('/workspace/read', {'path': path});
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
    if (!WorkspacePathGuard.isSafeRelativePath(path)) {
      throw ArgumentError('Unsafe workspace path: $path');
    }
    return bridge.postJson('/workspace/write', {'path': path, 'content': content});
  }

  Future<Map<String, dynamic>> runCommand(String command) {
    if (command.trim().isEmpty) {
      throw ArgumentError('Command cannot be empty.');
    }
    return bridge.postJson('/command/run', {'command': command});
  }
}
