// 本地桥接服务配置常量（单一真相源）。
//
// 本文件**绝不** import dart:io，可在 Web / 移动端安全引入。
// 客户端（local_agent_bridge_client.dart）与服务端
// （local_agent_bridge_server.dart）均从这里读取端口与基础地址，
// 避免出现端口值多份定义、相互不一致的问题。

/// 本地桥接服务统一监听端口（客户端与服务端共享的单一真相源）。
const int kLocalAgentBridgePort = 54263;

/// 本地桥接服务默认基础地址（loopback + 统一端口）。
const String kLocalAgentBridgeDefaultBaseUrl =
    'http://127.0.0.1:$kLocalAgentBridgePort';
