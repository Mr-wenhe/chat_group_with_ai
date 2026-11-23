import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/agentic/github_skill_service.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _WaitingWorker extends WebWorkerClient {
  _WaitingWorker({this.body})
      : super(executable: '/unused', entryPoint: '/unused');
  final String? body;
  final started = Completer<void>();
  final frames = StreamController<Map<String, dynamic>>();
  var requests = 0;
  var closed = false;
  var closeCalls = 0;

  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) {
    requests++;
    if (!started.isCompleted) started.complete();
    if (body != null) {
      final bytes = utf8.encode(body!);
      return Stream.fromIterable([
        {
          'status': 'headers',
          'url': arguments['url'],
          'contentType': 'text/html'
        },
        {'status': 'chunk', 'data': base64Encode(bytes)},
        {'status': 'done', 'byteLength': bytes.length},
      ]);
    }
    return frames.stream;
  }

  @override
  void close() {
    closeCalls++;
    if (closed) return;
    closed = true;
    if (body == null) unawaited(frames.close());
  }
}

void main() {
  test(
      'successful discovery preserves candidates and ignores late cancellation',
      () async {
    final worker = _WaitingWorker(
        body: '<div class="result"><a class="result__a" '
            'href="https://github.com/example/skills/tree/main/skills/public">'
            'Public skill</a><div class="result__snippet">Skill description</div></div>');
    final cancellation = CancelToken();
    final service = GitHubSkillService(
        database: DatabaseService(), workerFactory: () => worker);
    final results =
        await service.discover('public writing', cancelToken: cancellation);
    expect(results.single, containsPair('path', 'skills/public'));
    expect(results.single, containsPair('title', 'Public skill'));
    expect(worker.closeCalls, 1);
    cancellation.cancel('completed operation');
    await Future<void>.delayed(Duration.zero);
    expect(worker.closeCalls, 1);
  });

  for (final importing in [false, true]) {
    test(
        'cancelling GitHub ${importing ? 'import' : 'discovery'} stops a waiting worker',
        () async {
      final worker = _WaitingWorker();
      addTearDown(worker.close);
      final cancellation = CancelToken();
      final service = GitHubSkillService(
          database: DatabaseService(), workerFactory: () => worker);
      final pending = importing
          ? service.importPublicSkill(
              owner: 'example',
              repo: 'skills',
              path: 'skills/public',
              ref: 'main',
              cancelToken: cancellation)
          : service.discover('public writing', cancelToken: cancellation);
      await worker.started.future.timeout(const Duration(seconds: 1));
      cancellation.cancel('stop test operation');
      await expectLater(
          pending.timeout(const Duration(seconds: 1)),
          throwsA(predicate<Object>((error) =>
              error is DioException && CancelToken.isCancel(error))));
      expect(worker.closed, isTrue);
      expect(worker.requests, 1, reason: '取消后不能继续备用搜索或重放导入');
    });
  }
}
