import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(LocalAgentBridgeEndpoint.reset);
  tearDown(LocalAgentBridgeEndpoint.reset);

  test('client rejects non-localhost bridge urls', () {
    expect(
      () => LocalAgentBridgeClient(baseUrl: 'https://example.com'),
      throwsArgumentError,
    );
  });

  test('client accepts localhost bridge urls', () {
    final client = LocalAgentBridgeClient();
    expect(client.baseUrl, 'http://127.0.0.1:54263');
  });

  test('new clients follow the active in-process bridge endpoint', () {
    LocalAgentBridgeEndpoint.usePort(61234);
    final client = LocalAgentBridgeClient();
    expect(client.baseUrl, 'http://127.0.0.1:61234');
  });
}
