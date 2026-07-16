// 本地桥接服务（独立进程入口，可选）。
//
// 本脚本仅作为“可选的开发者入口”保留：开发者仍可用
//   dart run bin/local_agent_bridge.dart --workspace=/absolute/path
// 在 App 之外独立拉起桥接服务用于调试。
//
// 真实产品在桌面端的桥接服务改由 App 进程内直接启动
// （见 lib/features/agentic/tools/local_agent_bridge_launcher_io.dart 调
// 用 local_agent_bridge_server.dart 的 startBridgeServer），
// 因此 release 桌面版不再依赖本脚本或 Dart SDK。

import 'dart:io';

import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_server.dart';

Future<void> main(List<String> args) async {
  final workspaceArg = args.firstWhere(
    (a) => a.startsWith('--workspace='),
    orElse: () => '',
  );
  final tokenArg = args.firstWhere(
    (a) => a.startsWith('--token='),
    orElse: () => '',
  );
  if (workspaceArg.isEmpty || tokenArg.isEmpty) {
    stderr.writeln(
      'Usage: dart run bin/local_agent_bridge.dart --workspace=/absolute/path --token=<session-token>',
    );
    exitCode = 64;
    return;
  }

  final workspace =
      Directory(workspaceArg.substring('--workspace='.length)).absolute;
  if (!workspace.existsSync()) {
    stderr.writeln('Workspace does not exist.');
    exitCode = 66;
    return;
  }

  final server = await startBridgeServer(
    workspace: workspace,
    token: tokenArg.substring('--token='.length),
    port: kLocalAgentBridgePort,
  );
  stdout.writeln(
    'Local agent bridge listening on http://127.0.0.1:$kLocalAgentBridgePort',
  );

  // 保持进程运行，直到收到终止信号后优雅关闭服务。
  await _keepAlive(server);
}

/// 阻塞直到收到 SIGINT/SIGTERM，随后关闭桥接服务并退出。
///
/// 独立进程入口用：桌面端 App 走进程内启动，无需此逻辑。
Future<void> _keepAlive(RunningBridgeServer server) async {
  final signals = <Future<Object?>>[ProcessSignal.sigint.watch().first];
  // Windows 不支持监听 SIGTERM，需单独处理。
  if (!Platform.isWindows) {
    signals.add(ProcessSignal.sigterm.watch().first);
  }
  await Future.any(signals);
  await server.close(force: true);
}
