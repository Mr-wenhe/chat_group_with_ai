/// 传输层断言：`User-Agent` 只来自调用方显式传入的**当前配置**值。
///
/// 这条链路以前是按 Base URL 反查配置箱的，于是同一中转地址上的两条配置会互相
/// 顶掉身份（B 配了白名单 UA、A 为空，B 的普通请求仍带默认 UA）。现在 UA 跟着
/// `ApiConfig.userAgent` 一层层传下来，这里钉住三种取值：
/// `null`（不覆盖）、`''`（明确不覆盖）、非空（覆盖）。
library;
import 'dart:convert';

import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _baseUrl = 'https://relay.example.test/v1';
const _relayUserAgent = 'claude-cli/2.0.0 (external, cli)';

Dio _capturingDio(List<RequestOptions> requests) {
  final dio = Dio()
    ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      if (options.uri.path.endsWith('/models')) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: ResponseBody.fromString(
            jsonEncode({
              'data': [
                {'id': 'opaque-model'}
              ]
            }),
            200,
          ),
        ));
        return;
      }
      final body = jsonEncode({
        'choices': [
          {
            'message': {'content': 'OK'}
          }
        ]
      });
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: options.responseType == ResponseType.stream
            ? ResponseBody.fromString(body, 200)
            : jsonDecode(body),
      ));
    }));
  return dio;
}

Future<Map<String, dynamic>> _send(
  ChatApiService client, {
  String? userAgent,
}) =>
    client.sendChatMessage(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: _baseUrl,
      model: 'opaque-model',
      messages: const [
        {'role': 'user', 'content': 'OK'}
      ],
      userAgent: userAgent,
      maxRetries: 0,
    );

void main() {
  test('配置里的 UA 直接进入请求头', () async {
    final requests = <RequestOptions>[];
    final dio = _capturingDio(requests);
    addTearDown(dio.close);

    final result =
        await _send(ChatApiService(dio: dio), userAgent: _relayUserAgent);

    expect(result['success'], isTrue, reason: '$result');
    expect(requests.single.headers['User-Agent'], _relayUserAgent);
  });

  test('没有覆盖值时不发送 User-Agent（不再按地址猜别的配置）', () async {
    final requests = <RequestOptions>[];
    final dio = _capturingDio(requests);
    addTearDown(dio.close);

    await _send(ChatApiService(dio: dio));

    expect(requests.single.headers.containsKey('User-Agent'), isFalse);
  });

  test('空串表示明确不覆盖，同样不发送该头', () async {
    final requests = <RequestOptions>[];
    final dio = _capturingDio(requests);
    addTearDown(dio.close);

    await _send(ChatApiService(dio: dio), userAgent: '   ');

    expect(requests.single.headers.containsKey('User-Agent'), isFalse);
  });

  test('模型清单请求使用同一个 UA 参数', () async {
    final requests = <RequestOptions>[];
    final dio = _capturingDio(requests);
    addTearDown(dio.close);

    final catalog = await ChatApiService(dio: dio).fetchModels(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.openAiChatCompletions,
      customBaseUrl: _baseUrl,
      userAgent: _relayUserAgent,
    );

    expect(catalog.ok, isTrue);
    expect(requests.single.headers['User-Agent'], _relayUserAgent);
  });

  test('流式回复把 UA 带到 SSE 请求上', () async {
    final requests = <RequestOptions>[];
    final dio = _capturingDio(requests);
    addTearDown(dio.close);

    final events = await ChatApiService(dio: dio)
        .streamChatMessage(
          apiKey: 'test-key',
          provider: ApiProvider.custom,
          customBaseUrl: _baseUrl,
          userAgent: _relayUserAgent,
          model: 'opaque-model',
          messages: const [
            {'role': 'user', 'content': 'OK'}
          ],
          maxTokens: 16,
        )
        .toList();

    expect(events, isNotEmpty);
    expect(requests.single.headers['User-Agent'], _relayUserAgent);
  });
}
