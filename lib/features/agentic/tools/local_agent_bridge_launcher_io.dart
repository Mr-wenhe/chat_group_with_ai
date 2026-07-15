// 本地 agent 桥接服务启动器（桌面端真实实现）。
//
// 关键变更：桥接 HTTP 服务改为**在 App 桌面端进程内直接启动**
// （调用 local_agent_bridge_server.dart 的 startBridgeServer），
// 不再通过 `dart run bin/local_agent_bridge.dart` 另起子进程。
//
// 这样做的好处：
//   - release 桌面版是打包后的独立 App，运行目录既没有源码也没有 Dart SDK，
//     旧方案会静默跳过；进程内启动则开箱即用，App 启动即自动监听端口。
//   - 端口生命周期与 App 一致：App 进程销毁时端口随进程自动释放，无需回收子进程。
//
// 沙盒（App Sandbox）：
//   - 项目走 GitHub Release 分发（非 App Store），已将 macOS 沙盒关闭
//     （Debug/Release 的 app-sandbox 均为 false，Release 额外保留 network.server）。
//   - 关闭沙盒后，App 进程内的 Directory.current 恢复为真实工作目录，
//     bind(127.0.0.1:54263) 不再被沙盒拦截，release 运行时可正常启动桥接服务。
//
// 工作区（workspace）默认定位：
//   - 关闭沙盒后，缺省 workspace 不再使用被沙盒重定向的容器目录，
//     而是从当前进程工作目录向上逐级查找**最近的含 .git 的 git 仓库根目录**，
//     以确保 apply-patch（内部执行 `git apply`）在真实 git 仓库中可用；
//     若到文件系统根仍未找到 .git，则回退到当前进程工作目录。
//   - 见 [_resolveDefaultWorkspace] 与 [start]。
//
// 仍然仅桌面端（macOS / Windows / Linux）生效；Web / 移动端通过条件导出
// 使用 _web stub，不引入本文件（及 dart:io），保证 Web 编译安全。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_server.dart';

class LocalAgentBridgeLauncher {
  /// 当前进程内持有的桥接服务器；为 null 表示未运行。
  static RunningBridgeServer? _server;
  static String? _workspacePath;
  static String? _sessionToken;
  final int preferredPort;

  LocalAgentBridgeLauncher({this.preferredPort = kLocalAgentBridgePort});

  /// 是否在桌面端（自动启动仅在桌面端生效）。
  bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// 在 App 进程内启动本地桥接服务（幂等：同 workspace 已运行则直接返回）。
  ///
  /// [workspace] 为目标工作区绝对路径；缺省时自动定位到**最近的 git 仓库根目录**
  /// （见 [_resolveDefaultWorkspace]），以使 apply-patch 内部的 git apply 在真实仓库中可用。
  ///
  /// 注意：本方法只负责把桥接服务**首次拉起**并注册一个默认 workspace。
  /// 后续的多对话隔离应由 [registerWorkspace] 完成，**不应**反复 stop/start
  /// 服务——那正是旧实现在切换对话时产生端口竞态、导致 404 的根因。
  Future<void> start({String? workspace}) async {
    // 仅桌面端自动启动；非桌面端（含 Web/移动端）保持现有手动提示行为。
    if (!_isDesktop) return;

    // 缺省 workspace：关闭沙盒后定位到当前进程工作目录向上最近的 git 仓库根目录，
    // 保证 apply-patch 的 git apply 可在真实仓库中生效。
    final ws = workspace ?? _resolveDefaultWorkspace();
    final workspaceDir = Directory(ws).absolute;
    if (!await workspaceDir.exists()) {
      throw ArgumentError('Workspace does not exist: ${workspaceDir.path}');
    }
    if (_server != null && _samePath(_workspacePath, workspaceDir.path)) {
      return;
    }
    if (_server != null) {
      await stop();
    }

    try {
      _sessionToken = _newSessionToken();
      // 进程内直接 bind 端口启动，无需外部 dart 子进程或源码文件。
      try {
        _server = await startBridgeServer(
          workspace: workspaceDir,
          token: _sessionToken!,
          port: preferredPort,
        );
      } on SocketException {
        if (preferredPort == 0) rethrow;
        // A stale bridge can retain the fixed port after an app update. Bind a
        // fresh loopback port and publish it to new in-process clients.
        _server = await startBridgeServer(
          workspace: workspaceDir,
          token: _sessionToken!,
          port: 0,
        );
      }
      _workspacePath = workspaceDir.path;
      LocalAgentBridgeEndpoint.useSession(_server!.port, _sessionToken!);
    } catch (_) {
      // 启动失败不应 crash App；旧方案依赖的 bin 脚本在 release 下
      // 本就不存在，此处改为进程内启动后，失败通常是端口被占用等偶发情况。
      _server = null;
      _workspacePath = null;
      _sessionToken = null;
      LocalAgentBridgeEndpoint.reset();
      rethrow;
    }
  }

  /// 注册（或覆盖）某个对话的 workspace 目录到运行中的桥接服务。
  ///
  /// 与旧 [restart] 不同，本方法**不会** stop/start 整个 HTTP 服务：
  /// 服务常驻后，仅向内部的 conversationId -> workspace 映射写入条目，
  /// 之后该对话的 /workspace/* 与 /command/run 请求会按 conversationId 路由
  /// 到正确的目录。这样多个对话可同时处于工作模式而互不干扰，且彻底消除了
  /// 切换对话时的端口竞态（stop 旧服务 → start 新服务之间可能短暂不可用）。
  ///
  /// 若服务尚未启动（例如首次进入工作模式），则以该 workspace 作为默认目录
  /// 拉起服务，再注册 conversationId，行为与旧 [restart] 的首启动一致。
  Future<void> registerWorkspace({
    required String conversationId,
    required String workspacePath,
  }) async {
    if (!_isDesktop) return;
    if (_server == null) {
      await start(workspace: workspacePath);
    }
    _server?.registerWorkspace(
        conversationId, Directory(workspacePath).absolute);
    if (kDebugMode) debugPrint('[桥接] 已注册对话工作区');
  }

  /// 解析默认工作区目录：从当前进程工作目录向上逐级查找最近的含 `.git` 的 git 仓库根目录。
  ///
  /// 关闭沙盒后 [Directory.current] 已是真实工作目录，但为了让桥接的 apply-patch
  /// （内部执行 `git apply`）可用，workspace 必须是一个 git 仓库目录。
  ///
  /// 查找逻辑：
  ///   - 从 `Directory.current.absolute` 开始；
  ///   - 当前目录存在 `.git` 子目录则直接返回该目录（即 git 仓库根）；
  ///   - 否则继续向父目录查找，直到文件系统根（父目录与自身相同时停止）；
  ///   - 若到根仍未找到 `.git`，回退到 `Directory.current.path`。
  String _resolveDefaultWorkspace() {
    var dir = Directory.current.absolute;
    while (true) {
      // 找到最近的含 .git 的目录，即 git 仓库根，作为默认 workspace。
      if (Directory('${dir.path}/.git').existsSync()) return dir.path;
      final parent = dir.parent;
      // 父目录与当前目录相同，说明已到达文件系统根，停止查找。
      if (parent.path == dir.path) break;
      dir = parent;
    }

    // Bug 2 修复：release 桌面构建（如 LaunchPad 启动、Finder 双击 .app）
    // 下 Directory.current 可能是 '/' 或 App 包内路径，向上找不到 .git，
    // 旧逻辑会回退到该目录（实际是 App Support 下的 Hive 数据目录），
    // 导致文件被写到数据库目录而非用户项目目录。
    // 这里在回退前，额外探测一组常见项目目录候选，优先使用其中包含 .git 的目录。
    final candidates = <String>[];

    // 1) 显式环境变量优先。
    final envWorkspace = Platform.environment['WORKSPACE'];
    if (envWorkspace != null && envWorkspace.trim().isNotEmpty) {
      candidates.add(envWorkspace.trim());
    }
    final envProjectRoot = Platform.environment['PROJECT_ROOT'];
    if (envProjectRoot != null && envProjectRoot.trim().isNotEmpty) {
      candidates.add(envProjectRoot.trim());
    }

    // 2) 用户 Home 下的常见开发目录。
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.trim().isNotEmpty) {
      const subDirs = ['Developer', 'Projects', 'code', 'work', 'Documents'];
      for (final sub in subDirs) {
        candidates.add('$home/$sub');
      }
    }

    // 第一遍：优先寻找候选目录（或其祖先）中含 .git 的 git 仓库根目录。
    for (final c in candidates) {
      final candidateDir = Directory(c);
      if (!candidateDir.existsSync()) continue;
      var probe = candidateDir.absolute;
      while (true) {
        if (Directory('${probe.path}/.git').existsSync()) return probe.path;
        final parent = probe.parent;
        if (parent.path == probe.path) break;
        probe = parent;
      }
    }

    // 第二遍：候选里都没 .git 时，返回第一个真实存在的候选目录
    // （优先于 cwd，更贴近用户项目目录）。
    for (final c in candidates) {
      final candidateDir = Directory(c);
      if (candidateDir.existsSync()) return candidateDir.absolute.path;
    }

    // 回退：所有探测都失败，保持原有行为，使用当前进程工作目录。
    return Directory.current.path;
  }

  /// 停止进程内桥接服务（幂等：未运行则直接返回）。
  Future<void> stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    _workspacePath = null;
    _sessionToken = null;
    LocalAgentBridgeEndpoint.reset();
    try {
      // force: true 立即关闭监听并断开已建立的连接。
      await server.close(force: true);
    } catch (_) {
      // 忽略关闭过程中的异常。
    }
  }

  /// 当前桥接服务是否正在运行。
  bool get isRunning => _server != null;

  String _newSessionToken() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  bool _samePath(String? left, String right) {
    if (left == null) return false;
    final a = left.replaceAll('\\', '/');
    final b = right.replaceAll('\\', '/');
    return Platform.isWindows ? a.toLowerCase() == b.toLowerCase() : a == b;
  }
}
