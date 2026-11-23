import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';

class FakeClient extends WebWorkerClient {
  FakeClient() : super(executable: '/unused', entryPoint: '/unused');
  int closes = 0;
  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) async* {
    yield {'status': 'ok', 'version': 1};
  }
  @override
  void close() { closes++; }
}

void main() {
  test('concurrent feature leases share one client and close independently', () async {
    final client = FakeClient();
    var creations = 0;
    final pool = WebWorkerPool(() { creations++; return client; });
    final chat = pool.acquire();
    final task = pool.acquire();
    await chat.handshake();
    chat.close();
    expect(client.closes, 0);
    await task.handshake();
    expect(creations, 1);
    task.close();
    task.close();
    expect(client.closes, 1);
    await expectLater(chat.handshake(), throwsStateError);
  });
}
