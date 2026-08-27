import 'dart:convert';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('non-stream completion retries transient 503 and then succeeds',
      () async {
    var calls = 0;
    final temperatures = <double>[];
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        calls++;
        temperatures.add((options.data as Map)['temperature'] as double);
        if (calls < 3) {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 503,
            data: {'error': 'busy'},
          ));
          return;
        }
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {'content': 'recovered'}
              }
            ]
          },
        ));
      },
    ));
    final service = ChatApiService(dio: dio, retrySleep: (_) async {});

    final result = await service.sendChatMessage(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [
        {'role': 'user', 'content': 'hello'}
      ],
      temperature: 0.9,
    );

    expect(result['success'], isTrue);
    expect(result['message'], 'recovered');
    expect(calls, 3);
    expect(temperatures, [0.9, 0.9, 0.9]);
  });

  test('DeepSeek v4 model names are forwarded unchanged to the request payload',
      () async {
    final capturedModels = <String>[];
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        capturedModels.add(
          ((options.data as Map<String, dynamic>)['model'] as String),
        );
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {'content': 'ok'}
              }
            ]
          },
        ));
      },
    ));
    final service = ChatApiService(dio: dio, retrySleep: (_) async {});

    for (final model in const ['deepseek-v4-pro', 'deepseek-v4-flash']) {
      final result = await service.sendChatMessage(
        apiKey: 'key',
        provider: ApiProvider.deepseek,
        model: model,
        messages: const [
          {'role': 'user', 'content': 'hello'}
        ],
        maxRetries: 0,
      );
      expect(result['success'], isTrue, reason: model);
    }

    expect(capturedModels, const ['deepseek-v4-pro', 'deepseek-v4-flash']);
  });

  test('non-stream completion does not retry HTTP 400', () async {
    var calls = 0;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        calls++;
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 400,
          data: {'error': 'invalid'},
        ));
      },
    ));
    final service = ChatApiService(dio: dio, retrySleep: (_) async {});

    final result = await service.sendChatMessage(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [],
    );

    expect(result['success'], isFalse);
    expect(calls, 1);
  });

  test('non-stream provider error body is never exposed to callers', () async {
    const secretProviderBody = 'provider-internal-secret-42';
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 502,
          data: {
            'error': secretProviderBody,
            'prompt': 'sensitive upstream diagnostics',
          },
        ));
      },
    ));

    final result = await ChatApiService(dio: dio).sendChatMessage(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isFalse);
    expect(result['message'], 'HTTP 502 请求失败');
    expect(result['message'], isNot(contains(secretProviderBody)));
    expect(result['message'], isNot(contains('sensitive upstream')));
  });

  test('retry exhaustion returns a friendly actionable failure', () async {
    var calls = 0;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        calls++;
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 503,
          data: {'error': 'busy'},
        ));
      },
    ));
    final service = ChatApiService(dio: dio, retrySleep: (_) async {});

    final result = await service.sendChatMessage(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [],
    );

    expect(calls, 6);
    expect(result['success'], isFalse);
    expect(result['message'], contains('已重试 5 次'));
    expect(result['message'], contains('HTTP 503'));
    expect(result['message'], contains('API 配置'));
  });

  test('agent callers can request a longer timeout and larger output budget',
      () async {
    late RequestOptions captured;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        captured = options;
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {'content': 'ok'}
              }
            ]
          },
        ));
      },
    ));
    final service = ChatApiService(dio: dio);

    final result = await service.sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'test-model',
      messages: const [
        {'role': 'user', 'content': '生成完整 HTML'}
      ],
      maxTokens: 4096,
      receiveTimeout: const Duration(seconds: 120),
    );

    expect(result['success'], isTrue);
    expect((captured.data as Map<String, dynamic>)['max_tokens'], 4096);
    expect(captured.receiveTimeout, const Duration(seconds: 120));
  });

  test('custom completion endpoint is not appended a second time', () async {
    late RequestOptions captured;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        captured = options;
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {'content': 'ok'}
              }
            ]
          },
        ));
      },
    ));

    final result = await ChatApiService(dio: dio).sendChatMessage(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'https://llm.example/v1/llm/completions',
      model: 'model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(captured.uri.path, '/v1/llm/completions');
  });

  test('bounded completion rejects an oversized response before JSON decode',
      () async {
    var calls = 0;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        calls++;
        final oversizedReply = 'x' * 2048;
        final body = jsonEncode({
          'choices': [
            {
              'message': {'content': oversizedReply}
            }
          ]
        });
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody.fromString(body, 200),
        ));
      },
    ));
    final service = ChatApiService(dio: dio, retrySleep: (_) async {});

    final result = await service.sendChatMessageWithResponseLimit(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [
        {'role': 'user', 'content': 'hello'}
      ],
      maxRetries: 0,
      maxResponseBytes: 256,
    );

    expect(result['success'], isFalse);
    expect(result['message'], contains('响应超过安全大小限制'));
    expect(calls, 1);
  });

  test('ordinary completion also rejects an oversized response before decode',
      () async {
    var calls = 0;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        calls++;
        handler.resolve(Response<ResponseBody>(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody.fromString(
            'x' * (ChatApiService.defaultMaxResponseBytes + 1),
            200,
          ),
        ));
      },
    ));

    final result = await ChatApiService(dio: dio).sendChatMessage(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isFalse);
    expect(result['message'], '模型响应超过安全大小限制');
    expect(calls, 1);
  });

  test('ordinary oversized error response is bounded before error mapping',
      () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(Response<ResponseBody>(
          requestOptions: options,
          statusCode: 502,
          data: ResponseBody.fromString(
            'x' * (ChatApiService.defaultMaxResponseBytes + 1),
            502,
          ),
        ));
      },
    ));

    final result = await ChatApiService(dio: dio).sendChatMessage(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isFalse);
    expect(result['message'], '模型响应超过安全大小限制');
  });
}
