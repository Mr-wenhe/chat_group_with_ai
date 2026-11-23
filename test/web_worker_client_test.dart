import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';

void main() {
  final node = Platform.environment['NODE_TEST_EXECUTABLE'];
  final skipNode = node == null
      ? 'Set NODE_TEST_EXECUTABLE to an absolute Node path.'
      : false;

  Future<File> fixture(String contents) async {
    final directory = await Directory.systemTemp.createTemp('web_worker_test_');
    addTearDown(() => directory.delete(recursive: true));
    return File('${directory.path}/worker.mjs').writeAsString(contents);
  }

  test(
      'concurrent requests share startup; a crash fails without replay and the next request restarts',
      () async {
    final script = await fixture('''
import {createInterface} from 'node:readline';
createInterface({input:process.stdin}).on('line',line=>{
  const request=JSON.parse(line);
  if(request.operation==='cancel')return;
  if(request.operation==='crash')process.exit(7);
  console.log(JSON.stringify({id:request.id,status:'ok',version:1,pid:process.pid}));
});
''');
    final client = WebWorkerClient(executable: node!, entryPoint: script.path);
    addTearDown(client.close);
    final replies = await Future.wait([
      client.request({'operation': 'probe'}).first,
      client.request({'operation': 'probe'}).first,
    ]);
    expect(replies[0]['pid'], replies[1]['pid']);
    await expectLater(
        client.request({'operation': 'crash'}).toList(), throwsStateError);
    final recovered = await client.request({'operation': 'probe'}).first;
    expect(recovered['pid'], isNot(replies[0]['pid']));
  }, skip: skipNode);

  test(
      'startup checks protocol before sending work and retries a failed launch',
      () async {
    final script = await fixture('''
import {createInterface} from 'node:readline';
createInterface({input:process.stdin}).on('line',line=>{
  const request=JSON.parse(line);
  if(request.operation==='cancel')return;
  console.log(JSON.stringify({id:request.id,status:'ok',version:2}));
});
''');
    final client = WebWorkerClient(executable: node!, entryPoint: script.path);
    addTearDown(client.close);
    await expectLater(
        client.request({'operation': 'probe'}).first,
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', '联网工具版本不兼容。')));
    await script.writeAsString(
        (await script.readAsString()).replaceAll('version:2', 'version:1'));
    expect((await client.request({'operation': 'probe'}).first)['version'], 1);
  }, skip: skipNode);
  test('private worker handshakes and rejects a local source', () async {
    final client = WebWorkerClient(
      executable: node!,
      entryPoint: File('gateway/src/desktop_worker.ts').absolute.path,
    );
    addTearDown(client.close);
    await client.handshake();
    final frames = await client.request({
      'operation': 'fetch',
      'url': 'https://127.0.0.1/',
      'maxBytes': 1024,
    }).toList();
    expect(frames.single['status'], 'error');
    expect(frames.single['code'], 'SOURCE_URL_BLOCKED');
    client.close();
    await expectLater(client.handshake(), throwsStateError);
  }, skip: skipNode);
}
