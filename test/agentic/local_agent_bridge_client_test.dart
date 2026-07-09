import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('client rejects non-localhost bridge urls', () {
    expect(
      () => LocalAgentBridgeClient(baseUrl: 'https://example.com'),
      throwsArgumentError,
    );
  });

  test('client accepts localhost bridge urls', () {
    final client = LocalAgentBridgeClient(baseUrl: 'http://127.0.0.1:8765');
    expect(client.baseUrl, 'http://127.0.0.1:8765');
  });
}
