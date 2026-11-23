import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser rejects desktop networking before reading dart:io platform', () {
    expect(
      WebWorkerClient.bundled,
      throwsA(isA<UnsupportedError>().having(
        (error) => error.message,
        'message',
        '此平台联网工具未实现。',
      )),
    );
  }, skip: !kIsWeb);
}
