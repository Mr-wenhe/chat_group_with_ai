import 'dart:convert';

import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录每次请求的 URL 与头部，并按请求逐次给出响应。
class _RecordingDio {
  _RecordingDio(this.respond);

  final Response<dynamic> Function(RequestOptions options) respond;
  final List<RequestOptions> requests = [];

  Dio build() {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        handler.resolve(respond(options));
      },
    ));
    return dio;
  }
}

Response<dynamic> _json(Object body, int statusCode) => Response<ResponseBody>(
      requestOptions: RequestOptions(path: '/'),
      statusCode: statusCode,
      data: ResponseBody.fromString(jsonEncode(body), statusCode),
    );

void main() {
  test('解析模型清单，兼容两种能力字段拼写', () async {
    final recorder = _RecordingDio((options) => _json({
          'object': 'list',
          'data': [
            {
              'id': 'deepseek-flash',
              'name': 'DeepSeek-V4.1-Flash',
              'context_window': 1048576,
              'max_output_tokens': 393216,
              'input_modalities': ['text', 'image'],
            },
            {
              'id': 'deepseek-v4-pro',
              'context_length': 1048576,
              'max_output_length': 393216,
              'input_modalities': ['text'],
            },
          ],
        }, 200));
    final catalog = await ChatApiService(dio: recorder.build()).fetchModels(
      apiKey: 'k',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.openAiChatCompletions,
      customBaseUrl: 'https://api.deepseek.com',
    );

    expect(catalog.ok, isTrue, reason: catalog.message);
    expect(
        catalog.models.map((m) => m.id), ['deepseek-flash', 'deepseek-v4-pro']);
    final flash = catalog.models.first;
    expect(flash.displayName, 'DeepSeek-V4.1-Flash');
    expect(flash.contextWindow, 1048576);
    expect(flash.maxOutputTokens, 393216);
    expect(flash.supportsVision, isTrue);
    expect(catalog.models.last.supportsVision, isFalse);
    expect(recorder.requests.single.uri.toString(),
        'https://api.deepseek.com/models');
  });

  test('鉴权头按协议给：Anthropic 用 x-api-key，OpenAI 用 Bearer', () async {
    final anthropic = _RecordingDio((options) => _json({'data': []}, 200));
    await ChatApiService(dio: anthropic.build()).fetchModels(
      apiKey: 'secret-key',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.anthropicMessages,
      customBaseUrl: 'https://api.deepseek.com/anthropic',
    );
    final headers = anthropic.requests.first.headers;
    expect(headers['x-api-key'], 'secret-key');
    expect(headers['anthropic-version'], '2023-06-01');
    expect(headers['Authorization'], isNull);

    final openai = _RecordingDio((options) => _json({'data': []}, 200));
    await ChatApiService(dio: openai.build()).fetchModels(
      apiKey: 'secret-key',
      provider: ApiProvider.qwen,
      apiProtocol: ApiProtocol.openAiChatCompletions,
    );
    expect(openai.requests.first.headers['Authorization'], 'Bearer secret-key');
    expect(openai.requests.first.uri.toString(),
        'https://dashscope.aliyuncs.com/compatible-mode/v1/models');
  });

  test('协议子路径下没有模型接口时，回落提供商规范基址', () async {
    final recorder = _RecordingDio(
        (options) => options.uri.path.endsWith('/anthropic/models')
            ? _json({'error': 'not found'}, 404)
            : _json({
                'data': [
                  {'id': 'deepseek-flash'}
                ],
              }, 200));
    final catalog = await ChatApiService(dio: recorder.build()).fetchModels(
      apiKey: 'k',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.anthropicMessages,
      customBaseUrl: 'https://api.deepseek.com/anthropic',
    );

    expect(catalog.ok, isTrue, reason: catalog.message);
    expect(recorder.requests, hasLength(2));
    expect(recorder.requests.last.uri.toString(),
        'https://api.deepseek.com/models');
    expect(catalog.models.single.id, 'deepseek-flash');
  });

  test('内置提供商填了自定义地址时，回落不得把同一把 Key 转发到官方地址', () async {
    final recorder =
        _RecordingDio((options) => _json({'error': 'not found'}, 404));
    final catalog = await ChatApiService(dio: recorder.build()).fetchModels(
      apiKey: 'proxy-key',
      provider: ApiProvider.deepseek,
      apiProtocol: ApiProtocol.openAiChatCompletions,
      customBaseUrl: 'https://llm-proxy.example.internal/v1',
    );

    expect(catalog.ok, isFalse);
    expect(recorder.requests, hasLength(1),
        reason: 'Key 属于用户填的那个地址，不能自动发往用户没配置的主机');
    expect(recorder.requests.single.uri.toString(),
        'https://llm-proxy.example.internal/v1/models');
    expect(
        recorder.requests.single.headers['Authorization'], 'Bearer proxy-key');
  });

  for (final configuredBase in [
    'https://api.deepseek.com:8443/v1',
    'http://api.deepseek.com/v1',
  ]) {
    test('同主机但来源不同不携带 Key 回落：$configuredBase', () async {
      final recorder =
          _RecordingDio((options) => _json({'error': 'not found'}, 404));
      final catalog = await ChatApiService(dio: recorder.build()).fetchModels(
        apiKey: 'proxy-key',
        provider: ApiProvider.deepseek,
        apiProtocol: ApiProtocol.openAiChatCompletions,
        customBaseUrl: configuredBase,
      );

      expect(catalog.ok, isFalse);
      expect(recorder.requests, hasLength(1));
      expect(recorder.requests.single.headers['Authorization'],
          'Bearer proxy-key');
    });
  }

  test('显式默认端口与省略端口属于同一来源，可回落到规范路径', () async {
    final recorder = _RecordingDio(
        (options) => options.uri.path.endsWith('/anthropic/models')
            ? _json({'error': 'not found'}, 404)
            : _json({
                'data': [
                  {'id': 'deepseek-flash'}
                ],
              }, 200));
    final catalog = await ChatApiService(dio: recorder.build()).fetchModels(
      apiKey: 'k',
      provider: ApiProvider.deepseek,
      apiProtocol: ApiProtocol.anthropicMessages,
      customBaseUrl: 'https://api.deepseek.com:443/anthropic',
    );

    expect(catalog.ok, isTrue, reason: catalog.message);
    expect(recorder.requests, hasLength(2));
    expect(recorder.requests.last.uri.toString(),
        'https://api.deepseek.com/models');
  });

  test('内置提供商在同一主机上换路径时仍回落', () async {
    final recorder = _RecordingDio(
        (options) => options.uri.path.endsWith('/anthropic/models')
            ? _json({'error': 'not found'}, 404)
            : _json({
                'data': [
                  {'id': 'deepseek-flash'}
                ],
              }, 200));
    final catalog = await ChatApiService(dio: recorder.build()).fetchModels(
      apiKey: 'k',
      provider: ApiProvider.deepseek,
      apiProtocol: ApiProtocol.anthropicMessages,
      customBaseUrl: 'https://api.deepseek.com/anthropic',
    );

    expect(catalog.ok, isTrue, reason: catalog.message);
    expect(recorder.requests.map((request) => request.uri.toString()), [
      'https://api.deepseek.com/anthropic/models',
      'https://api.deepseek.com/models',
    ]);
  });

  test('Gemini 原生清单按 name 与驼峰能力字段解析，并去掉 models/ 前缀', () async {
    final recorder = _RecordingDio((options) => _json({
          'models': [
            {
              'name': 'models/gemini-2.5-flash',
              'displayName': 'Gemini 2.5 Flash',
              'inputTokenLimit': 1048576,
              'outputTokenLimit': 65536,
              'supportedGenerationMethods': ['generateContent'],
            },
          ],
        }, 200));
    final catalog = await ChatApiService(dio: recorder.build()).fetchModels(
      apiKey: 'k',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.geminiGenerateContent,
      customBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    );

    expect(catalog.ok, isTrue, reason: catalog.message);
    final model = catalog.models.single;
    expect(model.id, 'gemini-2.5-flash',
        reason: '资源前缀由请求路径补，留在 id 里会变成 models/models%2F…');
    expect(model.displayName, 'Gemini 2.5 Flash');
    expect(model.contextWindow, 1048576);
    expect(model.maxOutputTokens, 65536);
    expect(recorder.requests.single.headers['x-goog-api-key'], 'k');
  });

  test('Key 无效时给出可读文案，且不回显上游正文', () async {
    final recorder = _RecordingDio((options) => _json({
          'error': {
            'message':
                'Authentication Fails, Your api key: sk-leaked-000 is invalid'
          }
        }, 401));
    final catalog = await ChatApiService(dio: recorder.build()).fetchModels(
      apiKey: 'k',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.openAiChatCompletions,
      customBaseUrl: 'https://api.deepseek.com',
    );

    expect(catalog.ok, isFalse);
    expect(catalog.models, isEmpty);
    expect(catalog.message, contains('API Key'));
    expect(catalog.message, isNot(contains('sk-leaked-000')));
  });

  test('响应不是模型清单时明确失败，不猜内容', () async {
    final recorder =
        _RecordingDio((options) => _json({'unexpected': true}, 200));
    final catalog = await ChatApiService(dio: recorder.build()).fetchModels(
      apiKey: 'k',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.openAiChatCompletions,
      customBaseUrl: 'https://api.deepseek.com',
    );

    expect(catalog.ok, isFalse);
    expect(catalog.message, contains('模型列表'));
  });

  test('返回空清单算失败，避免把空下拉当成可用结果', () async {
    final recorder =
        _RecordingDio((options) => _json({'data': <dynamic>[]}, 200));
    final catalog = await ChatApiService(dio: recorder.build()).fetchModels(
      apiKey: 'k',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.openAiChatCompletions,
      customBaseUrl: 'https://api.deepseek.com',
    );

    expect(catalog.ok, isFalse);
    expect(catalog.models, isEmpty);
  });
}
