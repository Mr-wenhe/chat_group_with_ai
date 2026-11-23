import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:chat_group/features/web_search/desktop/desktop_web_service.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';

void main() {
  final executable = Platform.environment['NODE_TEST_EXECUTABLE'];
  test('live search read download', () async {
  final arguments = [executable!, File('gateway/src/desktop_worker.ts').absolute.path];
  final worker = WebWorkerClient(executable: arguments[0], entryPoint: arguments[1]);
  final directory = await Directory.systemTemp.createTemp('banban_network_check_');
  try {
    await worker.handshake();
    final service = DesktopWebService(worker);
    final results = await service.search('Flutter documentation');
    if (results.isEmpty) throw StateError('No actual search results');
    final source = service.registerSource('https://raw.githubusercontent.com/flutter/flutter/master/README.md');
    final body = await service.read(source);
    final receipt = await service.download(source, directory);
    if (!(body['text'] as String).contains('Flutter') || (receipt['byteLength'] as int) < 100) {
      throw StateError('Actual source content validation failed');
    }
    stdout.writeln(jsonEncode({'searchProvider': results.first['provider'],
      'searchResults': results.length, 'readCharacters': (body['text'] as String).length,
      'downloadBytes': receipt['byteLength'], 'sha256': receipt['sha256']}));
  } finally {
    worker.close();
    await directory.delete(recursive: true);
  }
  }, skip: executable == null, timeout: const Timeout(Duration(seconds: 30)));
}
