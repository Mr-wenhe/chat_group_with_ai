import 'dart:io';
import 'dart:async';
import 'package:dio/dio.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:chat_group/features/web_search/desktop/desktop_web_service.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';
import 'package:chat_group/features/web_search/desktop/network_reply_stream.dart';
import '../tool/web_search_demo/model_client.dart';

void main() {
  final enabled = Platform.environment['BANBAN_LIVE_MODELS'] == '1';
  final node = Platform.environment['NODE_TEST_EXECUTABLE'];
  SavedModels? saved;
  if (enabled) {
    setUpAll(() async {
      saved = await SavedModels.load();
    });
  }
  for (var index = 0; index < 5; index++) {
    test('saved chat model ${index + 1} drives network tools', () async {
      if (index >= saved!.configs.length) {
        fail('Saved configuration is missing');
      }
      final config = saved!.configs[index];
      final key = await saved!.keyFor(config);
      final worker = WebWorkerClient(
          executable: node!,
          entryPoint: File('gateway/src/desktop_worker.ts').absolute.path);
      final directory =
          await Directory.systemTemp.createTemp('banban_model_acceptance_');
      final receipts = <Map<String, dynamic>>[];
      var active = true;
      final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 10),
          followRedirects: false));
      final api = ChatApiService(dio: dio, retrySleep: (_) async {});
      final cancellation = CancelToken();
      final deadline = Timer(const Duration(seconds: 25), () {
        active = false;
        cancellation.cancel('acceptance deadline');
      });
      final service = DesktopWebService(worker);
      var finished = false;
      var requests = 0;
      try {
        await for (final event in networkReplyStream(
          messages: [
            {
              'role': 'user',
              'content':
                  '搜索 Flutter 官方文档，然后读取并下载 Flutter 仓库 README。必须真实调用搜索、读取和下载工具，完成后说明结果。'
            }
          ],
          generate: (messages) {
            requests++;
            return api.streamChatMessage(
              apiKey: key,
              provider: ApiProvider.values.byName(config.field(2)),
              apiProtocol: ApiProtocol.values.byName(config.field(9)),
              customBaseUrl: config.field(5),
              model: config.model,
              messages: messages,
              receiveTimeout: const Duration(seconds: 10),
              cancelToken: cancellation,
              maxTokens: 2048);
          },
          service: service,
          downloadDirectory: () async => directory,
          isActive: () => active,
          onDownload: receipts.add,
        )) {
          if (event.type == ChatStreamEventType.error) {
            fail(event.message ?? 'Model call failed');
          }
          if (event.type == ChatStreamEventType.done) finished = true;
        }
        expect(finished, isTrue);
        expect(receipts, isNotEmpty);
        expect(service.snapshot().results, isNotEmpty);
      } finally {
        stdout.writeln(jsonEncode({
          ...config.publicInfo,
          'requests': requests,
          'finished': finished,
          'downloaded': receipts.length,
          'sources': service.snapshot().results.length
        }));
        deadline.cancel();
        dio.close(force: true);
        worker.close();
        await directory.delete(recursive: true);
      }
    },
        skip: !enabled || node == null,
        timeout: const Timeout(Duration(seconds: 30)));
  }
}
