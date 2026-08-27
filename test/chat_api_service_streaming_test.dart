import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('streamed completion rejects an unterminated oversized frame', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final oversized = Uint8List.fromList(
          List<int>.filled(ChatApiService.maxSseLineBytes + 1, 0x61),
        );
        handler.resolve(Response<ResponseBody>(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody(Stream.value(oversized), 200),
        ));
      },
    ));

    final events = await ChatApiService(dio: dio).streamChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'test-model',
      messages: const [
        {'role': 'user', 'content': 'hello'}
      ],
    ).toList();

    expect(events, hasLength(1));
    expect(events.single.type, ChatStreamEventType.error);
    expect(events.single.message, '流式响应超过安全大小限制');
  });

  test('DeepSeek v4 model names are forwarded unchanged to streaming payload',
      () async {
    final capturedModels = <String>[];
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        capturedModels.add(
          ((options.data as Map<String, dynamic>)['model'] as String),
        );
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

    for (final model in const ['deepseek-v4-pro', 'deepseek-v4-flash']) {
      final events = await service.streamChatMessage(
        apiKey: 'key',
        provider: ApiProvider.deepseek,
        model: model,
        messages: const [
          {'role': 'user', 'content': 'hello'}
        ],
      ).toList();
      expect(events.last.type, ChatStreamEventType.done, reason: model);
    }

    expect(capturedModels, const ['deepseek-v4-pro', 'deepseek-v4-flash']);
  });

  test('empty streamed completion falls back to one non-stream request',
      () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        final requestData = options.data as Map<String, dynamic>;
        if (requestData['stream'] == true) {
          handler.resolve(Response<ResponseBody>(
            requestOptions: options,
            statusCode: 200,
            data: ResponseBody(
              Stream.value(
                Uint8List.fromList(utf8.encode('data: [DONE]\n')),
              ),
              200,
            ),
          ));
          return;
        }
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {'content': '<html>fallback</html>'}
              }
            ]
          },
        ));
      },
    ));
    final service = ChatApiService(dio: dio);

    final result = await service.sendChatMessageStreamed(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(result['message'], '<html>fallback</html>');
    expect(requests, hasLength(2));
    expect((requests.first.data as Map)['stream'], isTrue);
    expect((requests.last.data as Map)['stream'], isNull);
  });

  test('empty non-stream completion is rejected instead of being accepted',
      () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {'content': '   '}
              }
            ]
          },
        ));
      },
    ));
    final service = ChatApiService(dio: dio);

    final result = await service.sendChatMessage(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isFalse);
    expect(result['message'], '模型返回了空内容');
  });

  test('non-stream completion accepts reasoning content when content is empty',
      () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {
                  'content': '',
                  'reasoning_content': '<html>reasoning fallback</html>',
                }
              }
            ]
          },
        ));
      },
    ));
    final service = ChatApiService(dio: dio);

    final result = await service.sendChatMessage(
      apiKey: 'key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(result['message'], '<html>reasoning fallback</html>');
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
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'http://127.0.0.1:12345',
      model: 'test-model',
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

  test('streamed error followed by DONE does not report success', () async {
    var sourceCancelled = false;
    final controller = StreamController<Uint8List>(
      onCancel: () {
        sourceCancelled = true;
      },
    );
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
        {'role': 'user', 'content': '触发错误'}
      ],
    );
    controller
      ..add(Uint8List.fromList(utf8.encode(
        'data: {"error":{"message":"rate limit exceeded"}}\n',
      )))
      ..add(Uint8List.fromList(utf8.encode('data: [DONE]\n')));

    final result = await future.timeout(const Duration(milliseconds: 500));

    expect(result['success'], isFalse);
    expect(result['message'], contains('流式请求失败'));
    expect(result['message'], isNot(contains('rate limit exceeded')));
    expect(sourceCancelled, isTrue);
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
