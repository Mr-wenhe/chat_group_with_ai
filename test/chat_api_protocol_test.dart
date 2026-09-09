import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SenseNova built-in config resolves the documented endpoint', () async {
    late RequestOptions request;
    final dio = _respondingDio((options) {
      request = options;
      return {
        'choices': [
          {
            'message': {'content': 'OK'}
          }
        ]
      };
    });

    final result = await ChatApiService(dio: dio).sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.sensenova,
      model: '',
      messages: const [
        {'role': 'user', 'content': 'hello'},
      ],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(request.uri.toString(),
        'https://token.sensenova.cn/v1/chat/completions');
    expect((request.data as Map<String, dynamic>)['model'],
        'sensenova-6.8-flash-lite');
  });

  test('custom Base URL keeps its user-provided version path', () async {
    late RequestOptions request;
    final dio = _respondingDio((options) {
      request = options;
      return {
        'choices': [
          {
            'message': {'content': 'OK'}
          }
        ]
      };
    });

    final result = await ChatApiService(dio: dio).sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'https://gateway.example.test/v1',
      model: 'user-configured-model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(request.uri.toString(),
        'https://gateway.example.test/v1/chat/completions');
  });

  test('Anthropic appends its path to the configured versioned Base URL',
      () async {
    late RequestOptions request;
    final result = await ChatApiService(dio: _respondingDio((options) {
      request = options;
      return {
        'model': 'user-configured-model',
        'content': [
          {'type': 'text', 'text': 'OK'},
        ],
      };
    })).sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.anthropicMessages,
      customBaseUrl: 'https://gateway.example.test/v1',
      model: 'user-configured-model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(request.uri.toString(), 'https://gateway.example.test/v1/messages');
  });

  test('custom protocol is controlled by the configured endpoint', () async {
    late RequestOptions request;
    final result = await ChatApiService(dio: _respondingDio((options) {
      request = options;
      return {'output_text': 'OK'};
    })).sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.openAiResponses,
      customBaseUrl: 'https://gateway.example.test/v1',
      model: 'user-configured-model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(request.uri.toString(), 'https://gateway.example.test/v1/responses');
    expect((request.data as Map<String, dynamic>)['model'],
        'user-configured-model');
  });

  test('custom requests reject empty model without using a provider preset',
      () async {
    final result = await ChatApiService(dio: _respondingDio((_) {
      fail('An empty custom model must be rejected before the network call.');
    })).sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'https://gateway.example.test/v1',
      model: '',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isFalse);
    expect(result['message'], '模型名称不能为空');
  });

  test('connection diagnostics expose provider error and final request path',
      () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 404,
          data: {
            'error': {
              'message': 'model is not found',
              'type': 'not_found_error',
              'code': 5,
            },
          },
        ));
      },
    ));

    final result = await ChatApiService(dio: dio).sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'https://gateway.example.test/v1',
      model: 'user-configured-model',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['message'], 'HTTP 404 请求失败');
    expect(
        result['providerError'], 'model is not found；not_found_error；code=5');
    expect(result['requestPath'], '/v1/chat/completions');
    expect(result['requestModel'], 'user-configured-model');
  });

  test('custom protocol modes translate URL, headers, and request body',
      () async {
    final cases = <_ProtocolCase>[
      const _ProtocolCase(
        protocol: ApiProtocol.anthropicMessages,
        baseUrl: 'https://api.anthropic.com/v1',
        expectedUrl: 'https://api.anthropic.com/v1/messages',
        expectedHeader: 'x-api-key',
        expectedHeaderValue: 'test-key',
        response: {
          'model': 'claude-test',
          'content': [
            {'type': 'text', 'text': 'anthropic ok'},
          ],
        },
      ),
      const _ProtocolCase(
        protocol: ApiProtocol.openAiResponses,
        baseUrl: 'https://api.openai.com/v1',
        expectedUrl: 'https://api.openai.com/v1/responses',
        expectedHeader: 'Authorization',
        expectedHeaderValue: 'Bearer test-key',
        response: {
          'model': 'gpt-test',
          'output_text': 'responses ok',
        },
      ),
      const _ProtocolCase(
        protocol: ApiProtocol.geminiGenerateContent,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        expectedUrl:
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent',
        expectedHeader: 'x-goog-api-key',
        expectedHeaderValue: 'test-key',
        response: {
          'modelVersion': 'gemini-test',
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {'text': 'gemini ok'}
                ],
              },
            },
          ],
        },
      ),
    ];

    for (final testCase in cases) {
      late RequestOptions request;
      final dio = _respondingDio((options) {
        request = options;
        return testCase.response;
      });

      final result = await ChatApiService(dio: dio).sendChatMessage(
        apiKey: 'test-key',
        provider: ApiProvider.custom,
        apiProtocol: testCase.protocol,
        customBaseUrl: testCase.baseUrl,
        model: 'gemini-test',
        messages: const [
          {'role': 'system', 'content': 'be concise'},
          {'role': 'user', 'content': 'hello'},
        ],
        maxTokens: 128,
        maxRetries: 0,
      );

      expect(result['success'], isTrue, reason: testCase.protocol.name);
      expect(request.uri.toString(), testCase.expectedUrl,
          reason: testCase.protocol.name);
      expect(request.headers[testCase.expectedHeader],
          testCase.expectedHeaderValue,
          reason: testCase.protocol.name);
      final body = request.data as Map<String, dynamic>;
      switch (testCase.protocol) {
        case ApiProtocol.anthropicMessages:
          expect(body['system'], 'be concise');
          expect(body['messages'], hasLength(1));
          expect(body['max_tokens'], 128);
          break;
        case ApiProtocol.openAiResponses:
          expect(body['input'], hasLength(2));
          expect(body['max_output_tokens'], 128);
          break;
        case ApiProtocol.geminiGenerateContent:
          expect(body['systemInstruction'], isNotNull);
          expect(body['contents'], hasLength(1));
          expect((body['contents'] as List).single['role'], 'user');
          break;
        case ApiProtocol.openAiChatCompletions:
          fail('This case is intentionally covered by existing tests.');
      }
    }
  });

  test('native Anthropic SSE is collected into the common result shape',
      () async {
    late RequestOptions request;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        request = options;
        final lines = [
          'event: message_start\n',
          'data: {"type":"message_start","message":{"model":"claude-test"}}\n',
          'event: content_block_delta\n',
          'data: {"type":"content_block_delta","delta":{"text":"native"}}\n',
          'event: message_stop\n',
          'data: {"type":"message_stop"}\n',
        ].map((line) => Uint8List.fromList(utf8.encode(line)));
        handler.resolve(Response<ResponseBody>(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody(Stream.fromIterable(lines), 200),
        ));
      },
    ));

    final result = await ChatApiService(dio: dio).sendChatMessageStreamed(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.anthropicMessages,
      customBaseUrl: 'https://api.anthropic.com/v1',
      model: 'claude-test',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(result['message'], 'native');
    expect(request.uri.toString(), 'https://api.anthropic.com/v1/messages');
  });

  test('Gemini streaming route requests SSE explicitly', () async {
    late RequestOptions request;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        request = options;
        final line = Uint8List.fromList(utf8.encode(
          'data: {"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}\n',
        ));
        handler.resolve(Response<ResponseBody>(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody(Stream.value(line), 200),
        ));
      },
    ));

    final result = await ChatApiService(dio: dio).sendChatMessageStreamed(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.geminiGenerateContent,
      customBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      model: 'gemini-test',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(result['message'], 'ok');
    expect(request.uri.queryParameters['alt'], 'sse');
  });
}

class _ProtocolCase {
  const _ProtocolCase({
    required this.protocol,
    required this.baseUrl,
    required this.expectedUrl,
    required this.expectedHeader,
    required this.expectedHeaderValue,
    required this.response,
  });

  final ApiProtocol protocol;
  final String baseUrl;
  final String expectedUrl;
  final String expectedHeader;
  final String expectedHeaderValue;
  final Map<String, dynamic> response;
}

Dio _respondingDio(Map<String, dynamic> Function(RequestOptions) response) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: response(options),
      ));
    },
  ));
  return dio;
}
