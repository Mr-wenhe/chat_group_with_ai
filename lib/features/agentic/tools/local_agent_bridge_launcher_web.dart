// 本地 agent 桥接服务启动器（Web / 移动端 stub 实现）。
//
// Web / 移动端无法运行本地 dart 进程，也不应引入 dart:io。
// 此处提供与 _io 实现一致的接口，但 start/stop 均为空 no-op，
// 保持现有“手动启动本地桥接服务”的提示行为不变。

class LocalAgentBridgeLauncher {
  LocalAgentBridgeLauncher({int? preferredPort});

  /// 启动：Web / 移动端不真正启动本地服务，空操作。
  Future<void> start({String? workspace}) async {}

  /// 停止：Web / 移动端无子进程可关闭，空操作。
  Future<void> stop() async {}

  Future<void> restart({required String workspace}) async {}

  /// Web / 移动端始终视为未运行。
  bool get isRunning => false;
}
