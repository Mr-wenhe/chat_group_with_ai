import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本地的假服务地址，记录收到的路径与凭据头，用于验证凭据有没有被跟到别处。
class _RecordingServer {
  _RecordingServer._(this._server);

  final HttpServer _server;
  final List<String> paths = [];
  final List<String> credentialHeaders = [];

  int get port => _server.port;
  String get origin => 'http://127.0.0.1:$port';

  static Future<_RecordingServer> start({
    required int statusCode,
    String? location,
    String body = '{"ok":true}',
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final recording = _RecordingServer._(server);
    unawaited(() async {
      await for (final request in server) {
        recording.paths.add(request.uri.path);
        final credential = request.headers.value('x-api-key') ??
            request.headers.value('authorization') ??
            request.headers.value('x-goog-api-key');
        if (credential != null) {
          recording.credentialHeaders.add(credential);
        }
        request.response.statusCode = statusCode;
        if (location != null) {
          request.response.headers.set('location', location);
        }
        request.response.write(body);
        await request.response.close();
      }
    }());
    return recording;
  }

  Future<void> stop() => _server.close(force: true);
}

/// 一个「源地址 + 它把自己指向的别处」的现场：[source] 返回 302，[target] 等着
/// 接收被跟过去的请求。
Future<({_RecordingServer source, _RecordingServer target})> _redirectTrapSetup(
  String redirectPath,
) async {
  final target = await _RecordingServer.start(statusCode: 200);
  final source = await _RecordingServer.start(
    statusCode: 302,
    location: 'http://127.0.0.1:${target.port}$redirectPath',
  );
  addTearDown(() async {
    await source.stop();
    await target.stop();
  });
  return (source: source, target: target);
}

const String _apiKey = 'top-secret-key';

void main() {
  test('模型清单请求不跟跨来源重定向，Key 只发给配置里的地址', () async {
    final trap = await _redirectTrapSetup('/models');
    final catalog = await ChatApiService(dio: Dio()).fetchModels(
      apiKey: _apiKey,
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.anthropicMessages,
      customBaseUrl: '${trap.source.origin}/v1',
    );

    expect(trap.source.credentialHeaders, [_apiKey],
        reason: '凭据本来就该发给用户配置的地址，否则这条用例是空跑');
    expect(trap.target.paths, isEmpty, reason: '跟过去就等于把 Key 交给用户没配置过的来源');
    expect(catalog.ok, isFalse);
    expect(catalog.message, contains('跳转'));
  });

  test('非流式聊天请求不跟跨来源重定向', () async {
    final trap = await _redirectTrapSetup('/chat/completions');
    final result = await ChatApiService(dio: Dio()).sendChatMessage(
      apiKey: _apiKey,
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.openAiChatCompletions,
      customBaseUrl: trap.source.origin,
      model: 'm',
      messages: const [
        {'role': 'user', 'content': 'hi'}
      ],
    );

    expect(trap.source.credentialHeaders, ['Bearer $_apiKey']);
    expect(trap.target.paths, isEmpty,
        reason: '跨来源重定向必须停住，不能带着 Authorization 跟过去');
    expect(result['success'], isFalse);
    expect('${result['message']}', contains('跳转'));
  });

  test('流式聊天请求不跟跨来源重定向', () async {
    final trap = await _redirectTrapSetup('/chat/completions');
    final events = await ChatApiService(dio: Dio()).streamChatMessage(
      apiKey: _apiKey,
      provider: ApiProvider.custom,
      apiProtocol: ApiProtocol.geminiGenerateContent,
      customBaseUrl: trap.source.origin,
      model: 'm',
      messages: const [
        {'role': 'user', 'content': 'hi'}
      ],
    ).toList();

    expect(trap.source.credentialHeaders, [_apiKey]);
    expect(trap.target.paths, isEmpty,
        reason: '跨来源重定向必须停住，不能带着 x-goog-api-key 跟过去');
    expect(events.where((event) => event.message != null), isNotEmpty);
  });
}
