part of 'chat_api_sampling_compatibility_test.dart';

void _registerHttpErrorBoundaryTests() {
  _registerSamplingNegotiationTests();
  for (final mode in [
    'raw',
    'collected',
    'structured',
    'catalog',
    'bounded',
    'boundedStructured'
  ]) {
    test('HTTP error body has a total read deadline mode=$mode', () async {
      Timer? timer;
      var cancelled = false;
      late StreamController<Uint8List> source;
      source = StreamController<Uint8List>(onListen: () {
        timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
          source.add(Uint8List.fromList([32]));
        });
      }, onCancel: () {
        cancelled = true;
        timer?.cancel();
      });
      final requests = <RequestOptions>[];
      final dio = _errorStreamDio(requests, source.stream, 401);
      addTearDown(() async {
        timer?.cancel();
        await source.close();
        dio.close();
      });
      final client = ChatApiService(dio: dio);
      if (mode == 'catalog') {
        final result = await client
            .fetchModels(
                apiKey: 'test-key',
                provider: ApiProvider.custom,
                customBaseUrl: 'https://api.deepseek.com/anthropic')
            .timeout(const Duration(seconds: 4));
        expect(result.statusCode, 401);
      } else {
        final result = await _callErrorStream(client, mode)
            .timeout(const Duration(seconds: 4));
        expect(result['message'], contains('HTTP 401'));
      }
      expect(requests, hasLength(1));
      expect(cancelled, isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  for (final structured in [false, true]) {
    test(
        'non-streaming completed error body preserves cancellation structured=$structured',
        () async {
      final token = CancelToken();
      Stream<Uint8List> body() async* {
        token.cancel();
        yield Uint8List.fromList(utf8.encode('{}'));
      }

      final requests = <RequestOptions>[];
      final dio = _errorStreamDio(requests, body(), 429);
      addTearDown(dio.close);
      final result = await ChatApiService(dio: dio)
          .sendChatMessageWithResponseLimit(
              apiKey: 'test-key',
              provider: ApiProvider.custom,
              customBaseUrl: 'https://relay.example.test/v1',
              model: 'opaque-model',
              messages: const [],
              cancelToken: token,
              maxRetries: 0,
              structuredJson: structured,
              maxResponseBytes: ChatApiService.defaultMaxResponseBytes);
      expect(result['message'], ChatApiService.cancelledResultMessage);
      expect(result['statusCode'], isNull);
      expect(requests, hasLength(1));
    });
  }
}

Dio _errorStreamDio(
    List<RequestOptions> requests, Stream<Uint8List> source, int status) {
  return Dio()
    ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(options);
      handler.resolve(Response(
          requestOptions: options,
          statusCode: status,
          data: ResponseBody(source, status)));
    }));
}

Future<Map<String, dynamic>> _callErrorStream(
    ChatApiService client, String mode) async {
  if (mode == 'raw') {
    final events = await client.streamChatMessage(
        apiKey: 'test-key',
        provider: ApiProvider.custom,
        customBaseUrl: 'https://relay.example.test/v1',
        model: 'opaque-model',
        messages: const []).toList();
    return {'message': events.single.message};
  }
  if (mode == 'bounded' || mode == 'boundedStructured') {
    return client.sendChatMessageWithResponseLimit(
        apiKey: 'test-key',
        provider: ApiProvider.custom,
        customBaseUrl: 'https://relay.example.test/v1',
        model: 'opaque-model',
        messages: const [],
        maxRetries: 0,
        structuredJson: mode == 'boundedStructured',
        maxResponseBytes: ChatApiService.defaultMaxResponseBytes);
  }
  final send = mode == 'structured'
      ? client.sendStructuredChatMessageStreamed
      : client.sendChatMessageStreamed;
  return send(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'https://relay.example.test/v1',
      model: 'opaque-model',
      messages: const [],
      maxRetries: 0);
}
