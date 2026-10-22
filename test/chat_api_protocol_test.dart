import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'helpers/memory_governance_store.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final streaming in [false, true]) {
    test('Anthropic cached usage stays exact streaming=$streaming', () async {
      final store = MemoryGovernanceStore();
      await store.saveCustomCapability(
          'custom',
          'cached-test',
          const CustomModelCapability(
              supportsStreaming: true, contextWindow: 200000, maxOutput: 8192));
      final usage = {
        'input_tokens': 50,
        'cache_creation_input_tokens': 2000,
        'cache_read_input_tokens': 10000,
        'output_tokens': 200
      };
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          final body = streaming
              ? ResponseBody.fromString(
                  'data: ${jsonEncode({
                        'type': 'message_start',
                        'message': {
                          'usage': {...usage, 'output_tokens': 0}
                        }
                      })}\n\n'
                  'data: {"type":"content_block_delta","delta":{"text":"OK"}}\n\n'
                  'data: {"type":"message_delta","usage":{"input_tokens":50,"output_tokens":200}}\n\n'
                  'data: {"type":"message_stop"}\n\n',
                  200)
              : {
                  'model': 'cached-test',
                  'content': [
                    {'type': 'text', 'text': 'OK'}
                  ],
                  'usage': usage
                };
          handler.resolve(streaming
              ? Response<ResponseBody>(
                  requestOptions: options,
                  statusCode: 200,
                  data: body as ResponseBody)
              : Response(requestOptions: options, statusCode: 200, data: body));
        }));
      addTearDown(dio.close);
      final gateway =
          AiRequestGateway(store: store, client: ChatApiService(dio: dio));
      final send =
          streaming ? gateway.sendChatMessageStreamed : gateway.sendChatMessage;
      final result = await send(
          apiKey: 'test-key',
          provider: ApiProvider.custom,
          apiProtocol: ApiProtocol.anthropicMessages,
          customBaseUrl: 'https://example.test',
          model: 'cached-test',
          messages: [
            {'role': 'user', 'content': 'hello'}
          ],
          purpose: AiRequestPurpose.reply,
          conversationId: 'cached-usage',
          characterId: 'worker',
          maxRetries: 0);
      expect(result['success'], isTrue);
      final entry = store.ledgerEntries.single;
      expect(entry.exactUsage, isTrue);
      expect(entry.inputTokens, 12050);
      expect(entry.cachedInputTokens, 10000);
      expect(entry.outputTokens, 200);
    });
  }

  for (final protocol in ApiProtocol.values) {
    test('群请求按协议结束帧完成，无需连接关闭：${protocol.name}', () async {
      for (final truncated in [false, true]) {
        if (truncated &&
            protocol != ApiProtocol.openAiChatCompletions &&
            protocol != ApiProtocol.geminiGenerateContent) {
          continue;
        }
        final payload = switch (protocol) {
          ApiProtocol.openAiChatCompletions => 'data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': 'OK'},
                      'finish_reason': truncated ? 'length' : 'stop'
                    }
                  ]
                })}\n\n',
          ApiProtocol.anthropicMessages =>
            'data: {"type":"content_block_delta","delta":{"thinking":"PRIVATE"}}\n\n'
                'data: {"type":"content_block_delta","delta":{"text":"OK"}}\n\ndata: {"type":"message_stop"}\n\n',
          ApiProtocol.openAiResponses =>
            'data: {"type":"response.reasoning_text.delta","delta":"PRIVATE"}\n\n'
                'data: {"type":"response.completed","response":{"output_text":"OK"}}\n\n',
          ApiProtocol.geminiGenerateContent => 'data: ${jsonEncode({
                  'candidates': [
                    {
                      'content': {
                        'parts': [
                          {'text': 'PRIVATE', 'thought': true},
                          {'text': 'OK'}
                        ]
                      },
                      'finishReason': truncated ? 'MAX_TOKENS' : 'STOP'
                    }
                  ]
                })}\n\n',
        };
        var activity = 0;
        final wire = StreamController<Uint8List>();
        wire.add(Uint8List.fromList(utf8.encode(payload)));
        wire.onCancel = () {
          unawaited(wire.close());
        };
        final dio = Dio()
          ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
            handler.resolve(Response<ResponseBody>(
                requestOptions: options,
                statusCode: 200,
                data: ResponseBody(wire.stream, 200)));
          }));
        try {
          final events = await ChatApiService(dio: dio)
              .streamChatMessage(
                apiKey: 'test-key',
                provider: ApiProvider.custom,
                apiProtocol: protocol,
                customBaseUrl: 'https://example.test/v1',
                model: 'arbitrary-model',
                messages: const [],
                finishOnTerminalFrame: true,
                onResponseActivity: () => activity++,
              )
              .toList()
              .timeout(const Duration(seconds: 2));
          expect(events.last.type, ChatStreamEventType.done);
          expect(events.last.content, 'OK');
          expect(events.last.truncated, truncated);
          expect(activity, greaterThan(0));
          expect(events.any((event) => (event.delta ?? '').contains('PRIVATE')),
              isFalse);
        } finally {
          await wire.close();
          dio.close();
        }
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  for (final protocol in ApiProtocol.values) {
    test('群执行汇总按协议结束帧完成，无需连接关闭：${protocol.name}', () async {
      for (final truncated in [false, true]) {
        if (truncated &&
            protocol != ApiProtocol.openAiChatCompletions &&
            protocol != ApiProtocol.geminiGenerateContent) {
          continue;
        }
        final payload = switch (protocol) {
          ApiProtocol.openAiChatCompletions => 'data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': 'OK'},
                      'finish_reason': truncated ? 'length' : 'stop'
                    }
                  ]
                })}\n\n',
          ApiProtocol.anthropicMessages =>
            'data: {"type":"content_block_delta","delta":{"thinking":"PRIVATE"}}\n\n'
                'data: {"type":"content_block_delta","delta":{"text":"OK"}}\n\ndata: {"type":"message_stop"}\n\n',
          ApiProtocol.openAiResponses =>
            'data: {"type":"response.reasoning_text.delta","delta":"PRIVATE"}\n\n'
                'data: {"type":"response.completed","response":{"output_text":"OK"}}\n\n',
          ApiProtocol.geminiGenerateContent => 'data: ${jsonEncode({
                  'candidates': [
                    {
                      'content': {
                        'parts': [
                          {'text': 'PRIVATE', 'thought': true},
                          {'text': 'OK'}
                        ]
                      },
                      'finishReason': truncated ? 'MAX_TOKENS' : 'STOP'
                    }
                  ]
                })}\n\n',
        };
        var activity = 0;
        final wire = StreamController<Uint8List>();
        wire.add(Uint8List.fromList(utf8.encode(payload)));
        wire.onCancel = () {
          unawaited(wire.close());
        };
        final dio = Dio()
          ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
            handler.resolve(Response<ResponseBody>(
                requestOptions: options,
                statusCode: 200,
                data: ResponseBody(wire.stream, 200)));
          }));
        try {
          final result = await ChatApiService(dio: dio)
              .sendStructuredChatMessageStreamed(
                apiKey: 'test-key',
                provider: ApiProvider.custom,
                apiProtocol: protocol,
                customBaseUrl: 'https://example.test/v1',
                model: 'arbitrary-model',
                messages: const [],
                maxRetries: 0,
                finishOnTerminalFrame: true,
                onResponseActivity: () => activity++,
              )
              .timeout(const Duration(seconds: 2));
          expect(result['success'], isTrue);
          expect(result['message'], 'OK');
          expect(result['truncated'] == true, truncated);
          expect(activity, greaterThan(0));
          expect((result['message'] as String).contains('PRIVATE'), isFalse);
        } finally {
          await wire.close();
          dio.close();
        }
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  test('默认流仍接收结束帧之后的用量，不提前结束私聊调用', () async {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.resolve(Response<ResponseBody>(
            requestOptions: options,
            statusCode: 200,
            data: ResponseBody.fromString(
                'data: {"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}\n\n'
                'data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}\n\n'
                'data: [DONE]\n\n',
                200)));
      }));
    final events = await ChatApiService(dio: dio).streamChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'https://example.test/v1',
      model: 'arbitrary-model',
      messages: const [],
    ).toList();
    expect(events.last.content, 'OK');
    expect(events.last.promptTokens, 12);
    expect(events.last.completionTokens, 3);
    dio.close();
  });

  test('Step 5 群讨论显式选择低推理档，默认调用和其它模型不改变', () async {
    for (final model in ['step-5-preview', 'other-model']) {
      for (final effort in <String?>[null, 'low']) {
        late Map body;
        var activity = 0;
        final dio = Dio()
          ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
            body = options.data as Map;
            handler.resolve(Response<ResponseBody>(
                requestOptions: options,
                statusCode: 200,
                data: ResponseBody.fromString(
                    'data: {"choices":[{"delta":{"reasoning":"PRIVATE"}}]}\n\ndata: {"choices":[{"delta":{"content":"OK"}}]}\n\ndata: [DONE]\n\n',
                    200)));
          }));
        final events = await ChatApiService(dio: dio)
            .streamChatMessage(
                apiKey: 'test-key',
                provider: ApiProvider.custom,
                customBaseUrl: 'https://example.com/v1',
                model: model,
                messages: const [],
                maxTokens: 0,
                reasoningEffort: effort,
                onResponseActivity: () => activity++)
            .toList();
        expect(activity, 2);
        expect(events.last.content, 'OK');
        expect(events.any((e) => (e.delta ?? '').contains('PRIVATE')), isFalse);
        expect(body['reasoning_effort'],
            model == 'step-5-preview' ? effort : null);
        expect(body.containsKey('max_tokens'), isFalse);
        dio.close();
      }
    }
  });

  test('工作模式可省略可选协议的输出 token 上限', () async {
    for (final protocol in [
      ApiProtocol.openAiChatCompletions,
      ApiProtocol.openAiResponses,
      ApiProtocol.geminiGenerateContent,
    ]) {
      late RequestOptions request;
      final response = switch (protocol) {
        ApiProtocol.openAiChatCompletions => {
            'choices': [
              {
                'message': {'content': 'OK'}
              }
            ]
          },
        ApiProtocol.openAiResponses => {'output_text': 'OK'},
        ApiProtocol.geminiGenerateContent => {
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'OK'}
                  ]
                }
              }
            ]
          },
        ApiProtocol.anthropicMessages => throw StateError('not optional'),
      };
      final result = await ChatApiService(dio: _respondingDio((options) {
        request = options;
        return response;
      })).sendChatMessage(
        apiKey: 'test-key',
        provider: ApiProvider.custom,
        apiProtocol: protocol,
        customBaseUrl: 'https://gateway.example.test/v1',
        model: 'test-model',
        messages: const [],
        maxTokens: 0,
        maxRetries: 0,
      );

      expect(result['success'], isTrue, reason: protocol.name);
      final body = request.data as Map<String, dynamic>;
      expect(body.containsKey('max_tokens'), isFalse, reason: protocol.name);
      expect(body.containsKey('max_output_tokens'), isFalse,
          reason: protocol.name);
      final generation = body['generationConfig'];
      if (generation is Map) {
        expect(generation.containsKey('maxOutputTokens'), isFalse,
            reason: protocol.name);
      }
    }
  });

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

  test('Oray 预设指向 Anthropic 原生端点，默认协议也是它', () {
    expect(ApiProvider.oray.label, 'Oray');
    expect(ApiProvider.oray.baseUrl, 'https://ai-api.orayer.com/v1');
    expect(ApiProvider.oray.defaultProtocol, ApiProtocol.anthropicMessages);
    // 其余提供商保持 OpenAI 兼容，不能被这一个改变带偏。
    expect(ApiProvider.deepseek.defaultProtocol,
        ApiProtocol.openAiChatCompletions);
    expect(
        ApiProvider.custom.defaultProtocol, ApiProtocol.openAiChatCompletions);
  });

  test('Oray 预设按 Anthropic 协议解析到 /messages', () async {
    late RequestOptions request;
    final dio = _respondingDio((options) {
      request = options;
      return {
        'content': [
          {'type': 'text', 'text': 'OK'}
        ],
      };
    });

    final result = await ChatApiService(dio: dio).sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.oray,
      apiProtocol: ApiProvider.oray.defaultProtocol,
      model: 'deepseek/deepseek-flash',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(request.uri.toString(), 'https://ai-api.orayer.com/v1/messages');
  });

  test('内置提供商也认配置里存的服务地址（协议子路径）', () async {
    late RequestOptions request;
    final dio = _respondingDio((options) {
      request = options;
      return {
        'content': [
          {'type': 'text', 'text': 'OK'}
        ],
      };
    });

    final result = await ChatApiService(dio: dio).sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.deepseek,
      apiProtocol: ApiProtocol.anthropicMessages,
      customBaseUrl: 'https://api.deepseek.com/anthropic',
      model: 'deepseek-flash',
      messages: const [],
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(
        request.uri.toString(), 'https://api.deepseek.com/anthropic/messages');
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
