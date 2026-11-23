import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/features/web_search/desktop/desktop_web_service.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';

class FixtureWorker extends WebWorkerClient {
  FixtureWorker({this.complete = true, this.contentType = 'text/plain'})
      : super(executable: '/unused', entryPoint: '/unused');
  final bool complete;
  final String contentType;
  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) async* {
    yield {
      'status': 'headers',
      'url': 'https://example.com/file.txt',
      'contentType': contentType
    };
    yield {'status': 'chunk', 'data': base64Encode(utf8.encode('evidence'))};
    if (complete) yield {'status': 'done', 'byteLength': 8};
  }
}

class PendingWorker extends WebWorkerClient {
  PendingWorker() : super(executable: '/unused', entryPoint: '/unused');
  final started = Completer<void>();
  bool cancelled = false;
  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) {
    late StreamController<Map<String, dynamic>> controller;
    controller = StreamController(onListen: () {
      controller.add({
        'status': 'chunk',
        'data': base64Encode([1, 2, 3])
      });
      started.complete();
    }, onCancel: () {
      cancelled = true;
    });
    return controller.stream;
  }
}

class CompleteThenCancelWorker extends FixtureWorker {
  CompleteThenCancelWorker(this.cancellation);
  final Completer<void> cancellation;
  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) {
    final controller = StreamController<Map<String, dynamic>>();
    unawaited(controller.done.then((_) => cancellation.complete()));
    unawaited(() async {
      await for (final frame in super.request(arguments)) {
        controller.add(frame);
      }
      await controller.close();
    }());
    return controller.stream;
  }
}

void main() {
  test('cancellation after the network closes cannot commit a file', () async {
    final root = await Directory.systemTemp.createTemp('web_cancel_commit_');
    addTearDown(() => root.delete(recursive: true));
    final cancellation = Completer<void>();
    final service = DesktopWebService(CompleteThenCancelWorker(cancellation));
    final id = service.registerSource('https://example.com/file.txt');
    await expectLater(
        service.download(id, root, cancellation: cancellation.future),
        throwsStateError);
    expect(await root.list().toList(), isEmpty);
    expect(service.snapshot().hasResults, isFalse);
  });
  test('portable filenames reject Windows device names before creating files',
      () async {
    final root = await Directory.systemTemp.createTemp('web_portable_name_');
    addTearDown(() => root.delete(recursive: true));
    final service = DesktopWebService(FixtureWorker());
    final id = service.registerSource('https://example.com/file.txt');
    for (final name in [
      'CON',
      'aux.txt',
      'NUL.pdf',
      'COM1.log',
      'lpt9.txt',
      'report.'
    ]) {
      await expectLater(
          service.download(id, root, fileName: name), throwsStateError);
    }
    expect(await root.list().toList(), isEmpty);
  });
  test('HTML pages cannot be delivered under a raw document filename',
      () async {
    final root = await Directory.systemTemp.createTemp('web_download_mime_');
    addTearDown(() => root.delete(recursive: true));
    final service = DesktopWebService(
      FixtureWorker(contentType: 'text/html; charset=utf-8'),
    );
    final id = service.registerSource('https://example.com/');
    await expectLater(
      service.download(id, root, fileName: 'README.md'),
      throwsA(
        isA<DesktopWebToolFailure>().having(
          (error) => error.safeCode,
          'safeCode',
          'CONTENT_TYPE_MISMATCH',
        ),
      ),
    );
    expect(await root.list().toList(), isEmpty);
  });
  test(
      'download stores exact bytes and digest without overwriting another download',
      () async {
    final root = await Directory.systemTemp.createTemp('web_download_test_');
    addTearDown(() => root.delete(recursive: true));
    final service = DesktopWebService(FixtureWorker());
    final id = service.registerSource('https://example.com/file.txt');
    final first = await service.download(id, root, fileName: '../report.txt');
    final second = await service.download(id, root, fileName: '../report.txt');
    expect(first['path'], isNot(second['path']));
    expect(await File(first['path'] as String).readAsString(), 'evidence');
    expect(first['sha256'], sha256.convert(utf8.encode('evidence')).toString());
    expect(first['byteLength'], 8);
    expect(service.snapshot().results.single.sourceId, id);
    expect(File(first['path'] as String).parent.parent.path,
        await root.resolveSymbolicLinks());
  });
  test('interrupted response leaves no partial download', () async {
    final root = await Directory.systemTemp.createTemp('web_download_failure_');
    addTearDown(() => root.delete(recursive: true));
    final service = DesktopWebService(FixtureWorker(complete: false));
    final id = service.registerSource('https://example.com/file.txt');
    await expectLater(service.download(id, root), throwsStateError);
    expect(await root.list().toList(), isEmpty);
  });
  test('cancellation aborts network subscription and removes partial files',
      () async {
    final root = await Directory.systemTemp.createTemp('web_cancel_');
    addTearDown(() => root.delete(recursive: true));
    final worker = PendingWorker();
    final service = DesktopWebService(worker);
    final id = service.registerSource('https://example.com/file.txt');
    final cancellation = Completer<void>();
    final result =
        service.download(id, root, cancellation: cancellation.future);
    final expectation = expectLater(result, throwsStateError);
    await worker.started.future;
    cancellation.complete();
    await expectation;
    expect(worker.cancelled, isTrue);
    expect(await root.list().toList(), isEmpty);
  });
}
