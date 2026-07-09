// 本地 agent 桥接服务启动器（条件导出入口）。
//
// 由于项目同时支持 Web 构建，而 dart:io（进程管理）在 Web 平台无法编译，
// 这里通过条件导出隔离平台差异：
//   - 非 Web（桌面/移动）平台使用 _io 实现，真正管理子进程；
//   - Web 平台使用 _web 实现，start/stop 均为空 no-op，保持行为不变。
export 'local_agent_bridge_launcher_io.dart'
    if (dart.library.html) 'local_agent_bridge_launcher_web.dart';
