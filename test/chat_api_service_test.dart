import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
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

  test('streamed completion collects long-form agent output', () async {
    late RequestOptions captured;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        captured = options;
        final sse = [
          'data: {"choices":[{"delta":{"content":"<html>"}}]}\n',
          'data: {"choices":[{"delta":{"content":"完整主页"}}]}\n',
          'data: {"choices":[{"delta":{"content":"</html>"}}]}\n',
          'data: [DONE]\n',
        ].map((line) => Uint8List.fromList(utf8.encode(line)));
        handler.resolve(Response<ResponseBody>(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody(
            Stream<Uint8List>.fromIterable(sse),
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream']
            },
          ),
        ));
      },
    ));
    final service = ChatApiService(dio: dio);

    final result = await service.sendChatMessageStreamed(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'test-model',
      messages: const [
        {'role': 'user', 'content': '生成完整 HTML'}
      ],
      maxTokens: 4096,
      receiveTimeout: const Duration(seconds: 60),
    );

    expect(result['success'], isTrue);
    expect(result['message'], '<html>完整主页</html>');
    expect((captured.data as Map<String, dynamic>)['stream'], isTrue);
    expect((captured.data as Map<String, dynamic>)['max_tokens'], 4096);
    expect(captured.receiveTimeout, const Duration(seconds: 60));
  });

  test('streamed agent completion forwards its cancellation token', () async {
    late CancelToken? capturedToken;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        capturedToken = options.cancelToken;
        final sse = [
          Uint8List.fromList(utf8.encode(
            'data: {"choices":[{"delta":{"content":"ok"}}]}\n',
          )),
          Uint8List.fromList(utf8.encode('data: [DONE]\n')),
        ];
        handler.resolve(Response<ResponseBody>(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody(Stream.fromIterable(sse), 200),
        ));
      },
    ));
    final service = ChatApiService(dio: dio);
    final cancelToken = CancelToken();

    final result = await service.sendChatMessageStreamed(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [],
      cancelToken: cancelToken,
    );

    expect(result['success'], isTrue);
    expect(capturedToken, same(cancelToken));
  });

  test('streamed completion finishes on DONE without waiting for socket close',
      () async {
    final controller = StreamController<Uint8List>();
    addTearDown(controller.close);
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(Response<ResponseBody>(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody(controller.stream, 200),
        ));
      },
    ));
    final service = ChatApiService(dio: dio);
    final future = service.sendChatMessageStreamed(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'test-model',
      messages: const [
        {'role': 'user', 'content': '生成 HTML'}
      ],
    );
    controller
      ..add(Uint8List.fromList(utf8.encode(
        'data: {"choices":[{"delta":{"content":"done"}}]}\n',
      )))
      ..add(Uint8List.fromList(utf8.encode('data: [DONE]\n')));

    final result = await future.timeout(const Duration(milliseconds: 500));

    expect(result['success'], isTrue);
    expect(result['message'], 'done');
  });

  test('streamed completion converts stream errors into failure results',
      () async {
    final service = _ThrowingStreamChatApiService();

    final result = await service.sendChatMessageStreamed(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'test-model',
      messages: const [
        {'role': 'user', 'content': '生成 HTML'}
      ],
    );

    expect(result['success'], isFalse);
    expect(result['message'], contains('流式请求失败'));
  });

  test('streamed completion falls back to non-stream on fifth retry', () async {
    late RequestOptions fallbackRequest;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        fallbackRequest = options;
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {'content': 'fallback ok'}
              }
            ]
          },
        ));
      },
    ));
    final service = _AlwaysFailingStreamService(dio);

    final result = await service.sendChatMessageStreamed(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [],
      temperature: 0.9,
    );

    expect(result['success'], isTrue);
    expect(result['message'], 'fallback ok');
    expect(service.streamCalls, 5);
    expect((fallbackRequest.data as Map)['stream'], isNull);
    expect((fallbackRequest.data as Map)['temperature'], 0.4);
  });
}

class _ThrowingStreamChatApiService extends ChatApiService {
  _ThrowingStreamChatApiService() : super(retrySleep: (_) async {});

  @override
  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
  }) {
    return Stream<ChatStreamEvent>.error(Exception('stream exploded'));
  }
}

class _AlwaysFailingStreamService extends ChatApiService {
  int streamCalls = 0;

  _AlwaysFailingStreamService(Dio dio)
      : super(dio: dio, retrySleep: (_) async {});

  @override
  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
  }) async* {
    streamCalls++;
    yield ChatStreamEvent.error('HTTP 503: busy');
  }
}
