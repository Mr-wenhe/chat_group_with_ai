// 本地桥接服务进程内启动冒烟测试。
//
// 关键目的：证明桥接 HTTP 服务可以在 App 进程内直接 bind 端口并正常响应，
// 而不依赖 `dart run bin/local_agent_bridge.dart` 子进程 / Dart SDK——
// 这正是 release 桌面版“开箱即用”的基石。

import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startBridgeServer binds the unified port and responds /health', () async {
    // 在系统临时目录作为工作区启动进程内桥接服务。
    final server = await startBridgeServer(
      workspace: Directory.systemTemp,
      port: kLocalAgentBridgePort,
    );
    // 确保无论测试是否通过都会释放端口。
    addTearDown(() async {
      try {
        await server.close(force: true);
      } catch (_) {}
    });

    // 用原生 HttpClient 直接请求 /health，验证进程内 server 正常响应。
    final httpClient = HttpClient();
    final request = await httpClient.get(
      InternetAddress.loopbackIPv4.address,
      kLocalAgentBridgePort,
      '/health',
    );
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    httpClient.close(force: true);

    expect(response.statusCode, 200);
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    expect(decoded['ok'], isTrue);
    expect(decoded['workspace'], isNotEmpty);
  });
}
