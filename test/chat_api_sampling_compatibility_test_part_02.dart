part of 'chat_api_sampling_compatibility_test.dart';

void _registerSamplingNegotiationTests() {
  _registerNativeSamplingErrorTests();
  _registerConcurrentSamplingTest();
  for (final mode in [
    'direct',
    'bounded',
    'collected',
    'structured',
    'gateway',
    'gatewayBounded',
    'gatewayCollected',
    'gatewayStructured'
  ]) {
    test('temperature negotiation survives network retries mode=$mode',
        () async {
      final requests = <RequestOptions>[];
      final bodies = <Map<String, dynamic>>[];
      var accepted = 0;
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          requests.add(options);
          final body = Map<String, dynamic>.from(options.data as Map);
          bodies.add(body);
          final rejected = body.containsKey('temperature');
          final int status;
          if (rejected) {
            status = 400;
          } else {
            accepted++;
            status = accepted == 1 ? 429 : 200;
          }
          String text;
          if (rejected) {
            text = jsonEncode({..._fixedTemperatureError, 'usage': _usage});
          } else if (status == 429) {
            text = '{}';
          } else if (body['stream'] == true) {
            text = _successStream(ApiProtocol.openAiChatCompletions);
          } else {
            text = jsonEncode(_successBody(ApiProtocol.openAiChatCompletions));
          }
          handler.resolve(Response(
              requestOptions: options,
              statusCode: status,
              data: ResponseBody.fromString(text, status)));
        }));
      addTearDown(dio.close);
      final store = MemoryGovernanceStore();
      final client = ChatApiService(dio: dio, retrySleep: (_) async {});
      final result = await _callSamplingRetry(client, store, mode);
      expect(result['success'], isTrue, reason: '$result');
      expect(requests, hasLength(3));
      expect(bodies.first['temperature'], 0.85);
      expect(
          bodies.skip(1).every((b) => !b.containsKey('temperature')), isTrue);
      if (mode.startsWith('gateway')) {
        expect(store.ledgerEntries, hasLength(3));
        expect(store.ledgerEntries.first.reportedUsage?.inputTokens, 12);
        expect(store.ledgerEntries.map((e) => e.rootRequestId).toSet(),
            hasLength(1));
        expect(store.ledgerEntries.every((e) => e.taskId == 'task'), isTrue);
      }
    });
  }

  // 「这个模型不接受 temperature」是模型级的能力事实：只记在一次请求里，代价是
  // **每条**回复都要先吃一次 400 再重发（现场：单次 14 秒失败 + 19 秒重试，
  // 用户看到的就是发出消息后三十多秒毫无输出）。因此进程内记住它，同一模型后续
  // 请求直接不带 temperature；不同模型之间仍然互相隔离（见并发用例）。
  test('temperature incompatibility is remembered for the same model', () async {
    final bodies = <Map<String, dynamic>>[];
    final dio = _fixtureDio([], bodies, rejectWhenTemperaturePresent: true);
    addTearDown(dio.close);
    final client = ChatApiService(dio: dio);
    for (var i = 0; i < 2; i++) {
      final result = await client.sendChatMessage(
          apiKey: 'test-key',
          provider: ApiProvider.custom,
          customBaseUrl: 'https://relay.example.test/v1',
          model: 'opaque-model',
          messages: const [],
          maxRetries: 0);
      expect(result['success'], isTrue);
    }
    expect(bodies, hasLength(3));
    expect(bodies.first['temperature'], 0.85, reason: '首次仍要按用户配置协商一次');
    expect(bodies[1].containsKey('temperature'), isFalse);
    expect(bodies.last.containsKey('temperature'), isFalse,
        reason: '记住之后不该再为同一个模型吃一次 400');
  });
}

void _registerConcurrentSamplingTest() {
  test('temperature negotiation is isolated during concurrent requests',
      () async {
    final compatibilityStarted = Completer<void>();
    final releaseCompatibility = Completer<void>();
    final bodies = <Map<String, dynamic>>[];
    final dio = Dio()
      ..interceptors
          .add(InterceptorsWrapper(onRequest: (options, handler) async {
        final body = Map<String, dynamic>.from(options.data as Map);
        bodies.add(body);
        final needsDefault = body['model'] == 'needs-default';
        final rejected = needsDefault && body.containsKey('temperature');
        if (needsDefault && !rejected) {
          compatibilityStarted.complete();
          await releaseCompatibility.future;
        }
        final data = rejected
            ? _fixedTemperatureError
            : _successBody(ApiProtocol.openAiChatCompletions);
        handler.resolve(Response(
            requestOptions: options,
            statusCode: rejected ? 400 : 200,
            data: ResponseBody.fromString(
                jsonEncode(data), rejected ? 400 : 200)));
      }));
    addTearDown(() {
      if (!releaseCompatibility.isCompleted) releaseCompatibility.complete();
      dio.close();
    });
    final gateway = AiRequestGateway(
        store: MemoryGovernanceStore(), client: ChatApiService(dio: dio));
    final first = _sendConcurrentSampling(gateway, 'needs-default');
    await compatibilityStarted.future.timeout(const Duration(seconds: 2));
    final second = await _sendConcurrentSampling(gateway, 'ordinary');
    releaseCompatibility.complete();
    expect((await first)['success'], isTrue);
    expect(second['success'], isTrue);
    expect(bodies, hasLength(3));
    expect(bodies[1].containsKey('temperature'), isFalse);
    expect(bodies.last['model'], 'ordinary');
    expect(bodies.last['temperature'], 0.85);
  });
}

Future<Map<String, dynamic>> _sendConcurrentSampling(
        AiRequestGateway gateway, String model) =>
    gateway.sendChatMessage(
        apiKey: 'test-key',
        provider: ApiProvider.custom,
        customBaseUrl: 'https://relay.example.test/v1',
        model: model,
        messages: const [],
        maxRetries: 0,
        purpose: AiRequestPurpose.agent,
        conversationId: model,
        characterId: 'worker',
        taskId: model);

void _registerNativeSamplingErrorTests() {
  final fixtures = [
    (
      ApiProtocol.anthropicMessages,
      {
        'error': {
          'type': 'invalid_request_error',
          'message': 'temperature: Only the default (1) value is supported.'
        }
      }
    ),
    (
      ApiProtocol.geminiGenerateContent,
      {
        'error': {
          'code': 400,
          'status': 'INVALID_ARGUMENT',
          'message': 'temperature: Only the default value is supported.'
        }
      }
    ),
    (
      ApiProtocol.openAiChatCompletions,
      {
        'error': {
          'code': 'unsupported_parameter',
          'message': "'temperature' is not supported with this model."
        }
      }
    ),
  ];
  for (final (protocol, error) in fixtures) {
    for (final streaming in [false, true]) {
      test(
          'native temperature rejection is compatible ${protocol.name} streaming=$streaming',
          () async {
        final requests = <RequestOptions>[];
        final bodies = <Map<String, dynamic>>[];
        final dio =
            _fixtureDio(requests, bodies, protocol: protocol, error: error);
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
            messages: const [],
            maxRetries: 0);
        expect(result['success'], isTrue, reason: '$result');
        expect(requests, hasLength(2));
      });
    }
  }
}

Future<Map<String, dynamic>> _callSamplingRetry(
    ChatApiService client, MemoryGovernanceStore store, String mode) async {
  if (mode.startsWith('gateway')) {
    final gateway = AiRequestGateway(
        store: store, client: client, retrySleep: (_) async {});
    if (mode == 'gatewayBounded') {
      return gateway.sendChatMessageWithResponseLimit(
          apiKey: 'test-key',
          provider: ApiProvider.custom,
          customBaseUrl: 'https://relay.example.test/v1',
          model: 'opaque-model',
          messages: const [],
          maxRetries: 1,
          purpose: AiRequestPurpose.agent,
          conversationId: 'room',
          characterId: 'worker',
          taskId: 'task',
          maxResponseBytes: ChatApiService.defaultMaxResponseBytes);
    }
    final operation = mode == 'gateway'
        ? gateway.sendChatMessage
        : gateway.sendChatMessageStreamed;
    return operation(
        apiKey: 'test-key',
        provider: ApiProvider.custom,
        customBaseUrl: 'https://relay.example.test/v1',
        model: 'opaque-model',
        messages: const [],
        maxRetries: 1,
        purpose: AiRequestPurpose.agent,
        conversationId: 'room',
        characterId: 'worker',
        taskId: 'task',
        requiresTools: mode == 'gatewayStructured');
  }
  if (mode == 'bounded') {
    return client.sendChatMessageWithResponseLimit(
        apiKey: 'test-key',
        provider: ApiProvider.custom,
        customBaseUrl: 'https://relay.example.test/v1',
        model: 'opaque-model',
        messages: const [],
        maxRetries: 1,
        maxResponseBytes: ChatApiService.defaultMaxResponseBytes);
  }
  final operation = mode == 'direct'
      ? client.sendChatMessage
      : mode == 'structured'
          ? client.sendStructuredChatMessageStreamed
          : client.sendChatMessageStreamed;
  return operation(
      apiKey: 'test-key',
      provider: ApiProvider.custom,
      customBaseUrl: 'https://relay.example.test/v1',
      model: 'opaque-model',
      messages: const [],
      maxRetries: 1);
}
