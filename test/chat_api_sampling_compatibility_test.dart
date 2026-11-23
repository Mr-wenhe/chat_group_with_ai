import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/services/ai_providers/ai_api_service.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_governance_store.dart';

part 'chat_api_sampling_compatibility_test_helpers.dart';
part 'chat_api_sampling_compatibility_test_part_01.dart';
part 'chat_api_sampling_compatibility_test_part_02.dart';

const _fixedTemperatureError = {
  'error': {
    'message':
        "Unsupported value: 'temperature' does not support 0.85 with this model. Only the default (1) value is supported.",
    'type': 'invalid_request_error',
    'param': 'temperature',
    'code': 'unsupported_value',
  },
};
const _usage = {'prompt_tokens': 12, 'completion_tokens': 2};

/// agentrouter 的形状：`param` 是空串而不是省略，`code` 为 null。
const _blankParamTemperatureError = {
  'error': {
    'message':
        "Unsupported parameter: 'temperature' is not supported with this model. [trace_id=6e01307d76a9da66]",
    'type': 'invalid_request_error',
    'param': '',
    'code': null,
  },
};

void main() {
  // 「模型不接受 temperature」是进程内记忆，跨用例生效，必须逐例清空。
  setUp(forgetTemperatureCompatibility);
  _registerHttpErrorBoundaryTests();
  for (final protocol in ApiProtocol.values) {
    for (final streaming in [false, true]) {
      test(
          'fixed temperature retries once at the same source ${protocol.name} streaming=$streaming',
          () async {
        final requests = <RequestOptions>[];
        final bodies = <Map<String, dynamic>>[];
        final dio = _fixtureDio(requests, bodies, protocol: protocol);
        addTearDown(dio.close);
        final client = ChatApiService(dio: dio);
        final send =
            streaming ? client.sendChatMessageStreamed : client.sendChatMessage;
        final result = await send(
          apiKey: 'test-key',
          provider: ApiProvider.custom,
          apiProtocol: protocol,
          customBaseUrl: 'https://relay.example.test/v1',
          model: 'opaque-model',
          messages: const [
            {'role': 'user', 'content': 'OK'}
          ],
          maxRetries: 0,
        );
        expect(result['success'], isTrue, reason: '$result');
        expect(result['message'], 'OK');
        expect(requests, hasLength(2));
        expect(requests.map((r) => r.uri).toSet(), hasLength(1));
        expect(requests.every((r) => !r.followRedirects), isTrue);
        final original = Map<String, dynamic>.from(bodies.first);
        final retry = Map<String, dynamic>.from(bodies.last);
        if (protocol == ApiProtocol.geminiGenerateContent) {
          expect((original['generationConfig'] as Map).remove('temperature'),
              0.85);
          expect((retry['generationConfig'] as Map).containsKey('temperature'),
              isFalse);
        } else {
          expect(original.remove('temperature'), 0.85);
          expect(retry.containsKey('temperature'), isFalse);
        }
        expect(retry, original);
        expect(result['usageAttempts'], hasLength(2));
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  }

  // 兼容重试的记忆必须跨请求生效：模型级的能力事实如果每条回复都重新试一次，
  // 用户看到的就是「发出消息后十几秒没有任何输出」。
  for (final streaming in [false, true]) {
    test(
        'later requests skip temperature once the model rejected it streaming=$streaming',
        () async {
      final requests = <RequestOptions>[];
      final bodies = <Map<String, dynamic>>[];
      final dio = _fixtureDio(requests, bodies, rejectWhenTemperaturePresent: true);
      addTearDown(dio.close);
      final client = ChatApiService(dio: dio);
      final send =
          streaming ? client.sendChatMessageStreamed : client.sendChatMessage;

      Future<Map<String, dynamic>> call() => send(
            apiKey: 'test-key',
            provider: ApiProvider.custom,
            apiProtocol: ApiProtocol.openAiChatCompletions,
            customBaseUrl: 'https://relay.example.test/v1',
            model: 'opaque-model',
            messages: const [
              {'role': 'user', 'content': 'OK'}
            ],
            maxRetries: 0,
          );

      expect((await call())['success'], isTrue);
      expect(requests, hasLength(2), reason: '首次仍要先失败一次再兼容重发');

      requests.clear();
      bodies.clear();
      expect((await call())['success'], isTrue);
      expect(requests, hasLength(1), reason: '记住之后不该再吃一次 400');
      expect(bodies.single.containsKey('temperature'), isFalse);
    });
  }

  // 有的中转把「参数不适用」写进空串 param（agentrouter 就是这样），判据必须把
  // 空串当成「未指定参数」，否则这条 400 会原样丢给用户，而模型其实只是不接受
  // temperature——去掉它重试一次就能成功。
  for (final protocol in [
    ApiProtocol.openAiChatCompletions,
    ApiProtocol.openAiResponses,
  ]) {
    test(
        'empty param temperature rejection retries without temperature ${protocol.name}',
        () async {
      final requests = <RequestOptions>[];
      final bodies = <Map<String, dynamic>>[];
      final dio = _fixtureDio(
        requests,
        bodies,
        protocol: protocol,
        error: _blankParamTemperatureError,
      );
      addTearDown(dio.close);
      final result = await ChatApiService(dio: dio).sendChatMessage(
        apiKey: 'test-key',
        provider: ApiProvider.custom,
        apiProtocol: protocol,
        customBaseUrl: 'https://relay.example.test/v1',
        model: 'opaque-model',
        messages: const [
          {'role': 'user', 'content': 'OK'}
        ],
        maxRetries: 0,
      );
      expect(result['success'], isTrue, reason: '$result');
      expect(requests, hasLength(2));
      expect(bodies.first.containsKey('temperature'), isTrue);
      expect(bodies.last.containsKey('temperature'), isFalse);
      expect(result['usageAttempts'], hasLength(2));
    });
  }

  for (final streaming in [false, true]) {
    test(
        'repeated default-temperature rejection is terminal streaming=$streaming',
        () async {
      final requests = <RequestOptions>[];
      final bodies = <Map<String, dynamic>>[];
      final dio = _fixtureDio(requests, bodies, alwaysReject: true);
      addTearDown(dio.close);
      final client = ChatApiService(dio: dio);
      final send =
          streaming ? client.sendChatMessageStreamed : client.sendChatMessage;
      final result = await send(
          apiKey: 'test-key',
          provider: ApiProvider.custom,
          customBaseUrl: 'https://relay.example.test/v1',
          model: 'opaque-model',
          messages: const [],
          maxRetries: 0);
      expect(result['success'], isFalse);
      expect(requests, hasLength(2));
      expect(result['usageAttempts'], hasLength(2));
    });

    for (final error in [
      {
        'error': {
          'message': 'temperature must be between 0 and 2',
          'param': 'temperature',
          'code': 'unsupported_value'
        }
      },
      {
        'error': {
          'message': 'Only the default value is supported.',
          'param': 'top_p',
          'code': 'unsupported_value'
        }
      },
      {
        'error': {
          'message': 'prompt_cache_key is unsupported',
          'param': 'prompt_cache_key',
          'code': 'unsupported_parameter'
        }
      },
      {
        'error': {
          'message': 'temperature and top_p cannot both be specified',
          'param': 'temperature',
          'code': 'unsupported_value'
        }
      },
    ]) {
      test(
          'unrelated parameter rejection does not retry ${jsonEncode(error)} streaming=$streaming',
          () async {
        final requests = <RequestOptions>[];
        final dio = _fixtureDio(requests, [], error: error, alwaysReject: true);
        addTearDown(dio.close);
        final client = ChatApiService(dio: dio);
        final send =
            streaming ? client.sendChatMessageStreamed : client.sendChatMessage;
        final result = await send(
            apiKey: 'test-key',
            provider: ApiProvider.custom,
            customBaseUrl: 'https://relay.example.test/v1',
            model: 'opaque-model',
            messages: const [],
            maxRetries: 0,
            promptCacheKey: 'stable-task');
        expect(result['success'], isFalse);
        expect(requests, hasLength(1));
      });
    }
  }

  for (final mode in ['connection', 'collected', 'raw']) {
    test('compatibility requests have separate ledger entries mode=$mode',
        () async {
      final requests = <RequestOptions>[];
      final dio = _fixtureDio(requests, []);
      addTearDown(dio.close);
      final store = MemoryGovernanceStore();
      final gateway =
          AiRequestGateway(store: store, client: ChatApiService(dio: dio));
      if (mode == 'connection') {
        final result = await AiApiService(gateway).testApiKey(
            apiKey: 'test-key',
            provider: ApiProvider.custom,
            customBaseUrl: 'https://relay.example.test/v1',
            model: 'opaque-model');
        expect(result['success'], isTrue, reason: '$result');
      } else if (mode == 'collected') {
        final result = await gateway.sendChatMessageStreamed(
            apiKey: 'test-key',
            provider: ApiProvider.custom,
            customBaseUrl: 'https://relay.example.test/v1',
            model: 'opaque-model',
            messages: const [],
            purpose: AiRequestPurpose.agent,
            conversationId: 'room',
            characterId: 'worker',
            taskId: 'task',
            maxRetries: 0);
        expect(result['success'], isTrue, reason: '$result');
      } else {
        final events = await gateway
            .streamChatMessage(
                apiKey: 'test-key',
                provider: ApiProvider.custom,
                customBaseUrl: 'https://relay.example.test/v1',
                model: 'opaque-model',
                messages: const [],
                purpose: AiRequestPurpose.reply,
                conversationId: 'room',
                characterId: 'worker')
            .toList();
        expect(
            events.where((e) => e.type == ChatStreamEventType.error), isEmpty);
        expect(events.last.content, 'OK');
      }
      expect(requests, hasLength(2));
      expect(store.ledgerEntries, hasLength(2));
      expect(store.diagnostics.map((d) => d.status), ['failed', 'success']);
      expect(store.diagnostics.first.failureType, 'http_400');
      expect(store.ledgerEntries.first.reportedUsage?.inputTokens, isNull);
      expect(store.ledgerEntries.last.reportedUsage?.inputTokens, 12);
      expect(store.ledgerEntries.last.reportedUsage?.outputTokens, 2);
      expect(store.ledgerEntries.map((e) => e.requestId).toSet(), hasLength(2));
    });
  }

  for (final streaming in [false, true]) {
    test(
        'client authorization denial stays terminal and actionable streaming=$streaming',
        () async {
      final requests = <RequestOptions>[];
      final dio = _fixtureDio(requests, [],
          status: 401,
          alwaysReject: true,
          error: const {
            'error': {
              'message':
                  'unauthorized client detected, contact support for assistance'
            }
          });
      addTearDown(dio.close);
      final client = ChatApiService(dio: dio);
      final send =
          streaming ? client.sendChatMessageStreamed : client.sendChatMessage;
      final result = await send(
          apiKey: 'test-key',
          provider: ApiProvider.custom,
          apiProtocol: ApiProtocol.openAiResponses,
          customBaseUrl: 'https://relay.example.test/v1',
          model: 'opaque-model',
          messages: const [],
          maxRetries: 0);
      expect(result['success'], isFalse);
      expect(result['message'], contains('服务端拒绝当前客户端'));
      expect(result['message'], contains('服务商'));
      expect(result['message'], isNot(contains('Key 无效')));
      expect(requests, hasLength(1));
      expect(requests.single.headers['Authorization'], 'Bearer test-key');
    });
  }

  for (final protocol in ApiProtocol.values) {
    for (final structured in [false, true]) {
      test(
          'empty stream fallback retains default temperature and counts all requests ${protocol.name} structured=$structured',
          () async {
        final requests = <RequestOptions>[];
        final bodies = <Map<String, dynamic>>[];
        final dio = Dio()
          ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
            requests.add(options);
            final body =
                jsonDecode(jsonEncode(options.data)) as Map<String, dynamic>;
            bodies.add(body);
            final sampling = protocol == ApiProtocol.geminiGenerateContent
                ? body['generationConfig'] as Map
                : body;
            final rejected = sampling.containsKey('temperature');
            final streaming = protocol == ApiProtocol.geminiGenerateContent
                ? options.uri.path.endsWith(':streamGenerateContent')
                : body['stream'] == true;
            handler.resolve(Response(
                requestOptions: options,
                statusCode: rejected ? 400 : 200,
                data: ResponseBody.fromString(
                    rejected
                        ? jsonEncode(_fixedTemperatureError)
                        : streaming
                            ? ''
                            : jsonEncode(_successBody(protocol)),
                    rejected ? 400 : 200)));
          }));
        addTearDown(dio.close);
        final store = MemoryGovernanceStore();
        final gateway =
            AiRequestGateway(store: store, client: ChatApiService(dio: dio));
        final events = <ChatStreamEvent>[];
        final result = await gateway.sendChatMessageStreamed(
            apiKey: 'test-key',
            provider: ApiProvider.custom,
            apiProtocol: protocol,
            customBaseUrl: 'https://relay.example.test/v1',
            model: 'opaque-model',
            messages: const [],
            purpose: AiRequestPurpose.agent,
            conversationId: 'room',
            characterId: 'worker',
            taskId: 'task',
            requiresTools: structured,
            maxRetries: 0,
            promptCacheKey: 'stable-task',
            onEvent: events.add);
        expect(result['success'], isTrue, reason: '$result');
        expect(requests, hasLength(3));
        expect(requests.every((r) => !r.followRedirects), isTrue);
        final lastSampling = protocol == ApiProtocol.geminiGenerateContent
            ? bodies.last['generationConfig'] as Map
            : bodies.last;
        expect(lastSampling.containsKey('temperature'), isFalse);
        if (protocol == ApiProtocol.openAiChatCompletions ||
            protocol == ApiProtocol.openAiResponses) {
          expect(bodies.every((b) => b['prompt_cache_key'] == 'stable-task'),
              isTrue);
        }
        if (protocol == ApiProtocol.openAiChatCompletions && structured) {
          expect(bodies.every((b) => b['response_format'] is Map), isTrue);
        }
        expect(events.every((e) => e.transportFailure == null), isTrue);
        expect(store.diagnostics.map((d) => d.status),
            ['failed', 'failed', 'success']);
        expect(
            store.ledgerEntries.map((e) => e.requestId).toSet(), hasLength(3));
        expect(store.ledgerEntries.every((e) => e.taskId == 'task'), isTrue);
      });
    }
  }

  for (final status in [401, 403]) {
    for (final body in [
      '{"error":{"message":"unauthorized client detected"}}',
      'not JSON',
      'x' * (ChatApiService.defaultMaxResponseBytes + 1),
    ]) {
      test(
          'catalog authentication rejection never falls back status=$status bytes=${body.length}',
          () async {
        final requests = <RequestOptions>[];
        final dio = Dio()
          ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
            requests.add(options);
            handler.resolve(Response(
                requestOptions: options,
                statusCode: status,
                data: ResponseBody.fromString(body, status)));
          }));
        addTearDown(dio.close);
        final result = await ChatApiService(dio: dio).fetchModels(
            apiKey: 'test-key',
            provider: ApiProvider.custom,
            customBaseUrl: 'https://api.deepseek.com/anthropic');
        expect(result.ok, isFalse);
        expect(requests, hasLength(1));
      });
    }
  }

  for (final mode in ['raw', 'collected', 'structured']) {
    test('HTTP error body cancellation is terminal mode=$mode', () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 429,
              data: ResponseBody(
                  Stream<Uint8List>.error(DioException(
                      requestOptions: options, type: DioExceptionType.cancel)),
                  429)));
        }));
      addTearDown(dio.close);
      final store = MemoryGovernanceStore();
      final gateway =
          AiRequestGateway(store: store, client: ChatApiService(dio: dio));
      if (mode == 'raw') {
        final events = await gateway
            .streamChatMessage(
                apiKey: 'test-key',
                provider: ApiProvider.custom,
                customBaseUrl: 'https://relay.example.test/v1',
                model: 'opaque-model',
                messages: const [],
                purpose: AiRequestPurpose.reply,
                conversationId: 'room',
                characterId: 'worker')
            .toList();
        expect(events.last.message, ChatApiService.cancelledResultMessage);
      } else {
        final result = await gateway.sendChatMessageStreamed(
            apiKey: 'test-key',
            provider: ApiProvider.custom,
            customBaseUrl: 'https://relay.example.test/v1',
            model: 'opaque-model',
            messages: const [],
            purpose: AiRequestPurpose.agent,
            conversationId: 'room',
            characterId: 'worker',
            requiresTools: mode == 'structured',
            maxRetries: 0);
        expect(result['message'], ChatApiService.cancelledResultMessage);
        expect(result['statusCode'], isNull);
      }
      expect(requests, hasLength(1));
      expect(store.ledgerEntries, hasLength(1));
      expect(store.diagnostics.single.failureType, 'cancelled');
    });
  }

  for (final mode in ['raw', 'collected', 'structured']) {
    test(
        'cancellation while reading a completed HTTP error body is terminal mode=$mode',
        () async {
      final token = CancelToken();
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          requests.add(options);
          Stream<Uint8List> body() async* {
            token.cancel();
            yield Uint8List.fromList(utf8.encode('{}'));
          }

          handler.resolve(Response(
              requestOptions: options,
              statusCode: 429,
              data: ResponseBody(body(), 429)));
        }));
      addTearDown(dio.close);
      final client = ChatApiService(dio: dio);
      if (mode == 'raw') {
        final events = await client
            .streamChatMessage(
                apiKey: 'test-key',
                provider: ApiProvider.custom,
                customBaseUrl: 'https://relay.example.test/v1',
                model: 'opaque-model',
                messages: const [],
                cancelToken: token)
            .toList();
        expect(events.last.message, ChatApiService.cancelledResultMessage);
      } else {
        final send = mode == 'structured'
            ? client.sendStructuredChatMessageStreamed
            : client.sendChatMessageStreamed;
        final result = await send(
            apiKey: 'test-key',
            provider: ApiProvider.custom,
            customBaseUrl: 'https://relay.example.test/v1',
            model: 'opaque-model',
            messages: const [],
            cancelToken: token,
            maxRetries: 0);
        expect(result['message'], ChatApiService.cancelledResultMessage);
        expect(result['statusCode'], isNull);
      }
      expect(requests, hasLength(1));
    });
  }

  test('model catalog client restriction is not mislabeled as an invalid Key',
      () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests.add(options);
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 401,
            data: ResponseBody.fromString(
                '{"error":{"message":"unauthorized client detected"}}', 401)));
      }));
    addTearDown(dio.close);
    final result = await ChatApiService(dio: dio).fetchModels(
        apiKey: 'test-key',
        provider: ApiProvider.custom,
        customBaseUrl: 'https://relay.example.test/v1');
    expect(result.ok, isFalse);
    expect(result.message, contains('服务端拒绝当前客户端'));
    expect(result.message, isNot(contains('Key 无效')));
    expect(requests, hasLength(1));
  });

  test('provider diagnostics never echo the supplied credential', () async {
    final requests = <RequestOptions>[];
    final dio = _fixtureDio(requests, [],
        status: 401,
        alwaysReject: true,
        error: const {
          'error': {
            'message': 'credential opaque-secret rejected',
            'code': 'opaque-secret'
          }
        });
    addTearDown(dio.close);
    final result = await AiApiService(AiRequestGateway(
            store: MemoryGovernanceStore(), client: ChatApiService(dio: dio)))
        .testApiKey(
            apiKey: 'opaque-secret',
            provider: ApiProvider.custom,
            customBaseUrl: 'https://relay.example.test/v1',
            model: 'opaque-model');
    expect(result.toString(), isNot(contains('opaque-secret')));
  });
}
