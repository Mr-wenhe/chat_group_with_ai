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
// 仍然仅桌面端（macOS / Windows / Linux）生效；Web / 移动端通过条件导出
// 使用 _web stub，不引入本文件（及 dart:io），保证 Web 编译安全。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_server.dart';

class LocalAgentBridgeLauncher {
  /// 当前进程内持有的桥接服务器；为 null 表示未运行。
  HttpServer? _server;

  /// 是否在桌面端（自动启动仅在桌面端生效）。
  bool get _isDesktop =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  /// 在 App 进程内启动本地桥接服务（幂等：已运行则直接返回）。
  ///
  /// [workspace] 为目标工作区绝对路径；缺省时使用当前进程工作目录。
  /// 注意：release 桌面版缺省时 workspace 即 App 运行目录（cwd），
  /// 如需指向用户项目目录可后续增强。
  Future<void> start({String? workspace}) async {
    // 仅桌面端自动启动；非桌面端（含 Web/移动端）保持现有手动提示行为。
    if (!_isDesktop) return;

    final ws = workspace ?? Directory.current.path;

    try {
      // 进程内直接 bind 端口启动，无需外部 dart 子进程或源码文件。
      _server = await startBridgeServer(
        workspace: Directory(ws),
        port: kLocalAgentBridgePort,
      );
      debugPrint(
        '[桥接] 本地 agent 桥接服务已启动：http://127.0.0.1:$kLocalAgentBridgePort',
      );
    } catch (e) {
      // 启动失败不应 crash App，仅打印提示；旧方案依赖的 bin 脚本在 release 下
      // 本就不存在，此处改为进程内启动后，失败通常是端口被占用等偶发情况。
      debugPrint('[桥接] 启动本地 agent 桥接服务失败：$e');
      _server = null;
    }
  }

  /// 停止进程内桥接服务（幂等：未运行则直接返回）。
  Future<void> stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    try {
      // force: true 立即关闭监听并断开已建立的连接。
      await server.close(force: true);
    } catch (_) {
      // 忽略关闭过程中的异常。
    }
  }

  /// 当前桥接服务是否正在运行。
  bool get isRunning => _server != null;
}
