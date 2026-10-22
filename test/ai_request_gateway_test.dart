import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_governance_store.dart';

class FakeCompletionClient extends ChatApiService {
  int sendCount = 0;
  int boundedCount = 0;
  int streamedCount = 0;
  int structuredStreamedCount = 0;
  int? lastSendMaxTokens;
  int? lastBoundedMaxTokens;
  int? lastStructuredStreamedMaxTokens;
  bool structuredStreamedFailure = false;
  bool terminalFrameRequested = false;
  String? streamedReasoningEffort;
  String? fallbackReasoningEffort;
  Duration? structuredStreamedReceiveTimeout;
  final boundedReceiveTimeouts = <Duration>[];

  /// Result returned by the structured streamed call when set; lets a test
  /// simulate a provider rejection that carries an HTTP status.
  Map<String, dynamic>? structuredStreamedResult;

  /// Result returned by the bounded compatibility call when set, so a test can
  /// exercise the fallback path's own failure payload.
  Map<String, dynamic>? boundedResult;
  final temperatures = <double>[];
  Future<Map<String, dynamic>> Function(int count)? responder;

  @override
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = 5,
    CancelToken? cancelToken,
    bool allowReasoningContentFallback = false,
    String? promptCacheKey,
  }) async {
    sendCount++;
    lastSendMaxTokens = maxTokens;
    temperatures.add(temperature);
    return responder?.call(sendCount) ??
        {
          'success': true,
          'message': 'ok',
          'promptTokens': 100,
          'cachedTokens': 20,
          'completionTokens': 10,
        };
  }

  @override
  Future<Map<String, dynamic>> sendChatMessageWithResponseLimit({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = 5,
    CancelToken? cancelToken,
    String? reasoningEffort,
    bool structuredJson = false,
    bool allowReasoningContentFallback = false,
    required int maxResponseBytes,
    String? promptCacheKey,
  }) async {
    fallbackReasoningEffort = reasoningEffort;
    boundedCount++;
    lastBoundedMaxTokens = maxTokens;
    boundedReceiveTimeouts.add(receiveTimeout ?? Duration.zero);
    return boundedResult ?? {'success': true, 'message': '{}'};
  }

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    int maxRetries = 5,
    CancelToken? cancelToken,
    bool finishOnTerminalFrame = false,
    String? reasoningEffort,
    void Function()? onResponseActivity,
    void Function(ChatStreamEvent event)? onEvent,
    String? promptCacheKey,
  }) async {
    streamedCount++;
    return {'success': true, 'message': '{}'};
  }

  @override
  Future<Map<String, dynamic>> sendStructuredChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    int maxRetries = 5,
    CancelToken? cancelToken,
    bool finishOnTerminalFrame = false,
    String? reasoningEffort,
    void Function()? onResponseActivity,
    void Function(ChatStreamEvent event)? onEvent,
    String? promptCacheKey,
  }) async {
    terminalFrameRequested = finishOnTerminalFrame;
    streamedReasoningEffort = reasoningEffort;
    onResponseActivity?.call();
    structuredStreamedCount++;
    lastStructuredStreamedMaxTokens = maxTokens;
    structuredStreamedReceiveTimeout = receiveTimeout;
    if (structuredStreamedResult != null) return structuredStreamedResult!;
    if (structuredStreamedFailure) {
      return {'success': false, 'message': '连接超时'};
    }
    return {'success': true, 'message': '{}'};
  }
}

class FakeStreamingErrorClient extends ChatApiService {
  final String errorMessage;

  FakeStreamingErrorClient(this.errorMessage);

  @override
  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
    bool finishOnTerminalFrame = false,
    String? reasoningEffort,
    void Function()? onResponseActivity,
    String? promptCacheKey,
  }) async* {
    yield ChatStreamEvent.error(errorMessage);
  }
}

void main() {
  const messages = [
    {'role': 'user', 'content': 'hello'},
  ];

  for (final status in ['success', 'failed']) {
    for (final scope in ['daily', 'monthly', 'conversation', 'autoChat']) {
      test('缓存写入 $status 仍占用 $scope 预算，费用未知不等于零', () async {
        final store = MemoryGovernanceStore(
            budgetSettings: BudgetSettings(
          dailyHardLimitMicros: scope == 'daily' ? 100000 : null,
          monthlyHardLimitMicros: scope == 'monthly' ? 100000 : null,
          conversationHardLimitMicros: scope == 'conversation' ? 100000 : null,
          autoChatDailyHardLimitMicros: scope == 'autoChat' ? 100000 : null,
        ));
        final client = FakeCompletionClient()
          ..responder = (_) async => {
                'success': status == 'success',
                'message': 'not retryable',
                'promptTokens': 1000000,
                'completionTokens': 20,
                'cachedTokens': 0,
                'cacheWriteTokens': 900000,
              };
        final gateway = AiRequestGateway(store: store, client: client);
        final purpose = scope == 'autoChat'
            ? AiRequestPurpose.autoChat
            : AiRequestPurpose.agent;
        Future<Map<String, dynamic>> send() => gateway.sendChatMessage(
              apiKey: 'test',
              provider: ApiProvider.deepseek,
              model: 'deepseek-chat',
              messages: messages,
              purpose: purpose,
              conversationId: 'room',
              characterId: 'actor',
              taskId: 'task',
              maxRetries: 0,
            );
        await send();
        final entry = store.ledgerEntries.single;
        expect(entry.estimatedCostMicros, isNull);
        expect(entry.budgetCostMicros, greaterThan(100000));
        expect(UsageLedgerEntry.fromMap(entry.toMap()).budgetCostMicros,
            entry.budgetCostMicros);
        final result = await send();
        expect(result['governanceBlocked'], isTrue);
        expect(client.sendCount, 1);
        expect(gateway.guard.reservedMicrosTotal, 0);
      });
    }
  }

  test('旧缓存写入账本缺少预算字段时仍回算预算，不改写实报', () async {
    final store = MemoryGovernanceStore(
        budgetSettings: const BudgetSettings(dailyHardLimitMicros: 100000));
    final client = FakeCompletionClient()
      ..responder = (_) async => {
            'success': true,
            'message': 'OK',
            'promptTokens': 1000000,
            'completionTokens': 20,
            'cachedTokens': 0,
            'cacheWriteTokens': 900000,
          };
    final gateway = AiRequestGateway(store: store, client: client);
    Future<Map<String, dynamic>> send() => gateway.sendChatMessage(
          apiKey: 'test',
          provider: ApiProvider.deepseek,
          model: 'deepseek-chat',
          messages: messages,
          purpose: AiRequestPurpose.agent,
          conversationId: 'room',
          characterId: 'actor',
          taskId: 'task',
          maxRetries: 0,
        );
    await send();
    final legacyMap = store.ledgerEntries.single.toMap()
      ..remove('budgetCostMicros');
    store.ledgerEntries[0] = UsageLedgerEntry.fromMap(legacyMap);
    expect(store.ledgerEntries.single.budgetCostMicros, isNull);
    expect((await send())['governanceBlocked'], isTrue);
    expect(client.sendCount, 1);
    expect(store.ledgerEntries.single.reportedUsage!.inputTokens, 1000000);
  });

  test('能力和硬预算均在网络调用前阻断', () async {
    final store = MemoryGovernanceStore(
      budgetSettings: const BudgetSettings(dailyHardLimitMicros: 1),
    );
    final client = FakeCompletionClient();
    final gateway = AiRequestGateway(store: store, client: client);

    final budgetResult = await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.autoChat,
      conversationId: 'group-1',
      characterId: 'char-1',
      maxRetries: 0,
    );
    expect(budgetResult['governanceBlocked'], isTrue);
    expect(client.sendCount, 0);

    final visionResult = await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.qwen,
      model: 'qwen-plus',
      messages: const [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,abc'},
            },
          ],
        },
      ],
      purpose: AiRequestPurpose.reply,
      conversationId: 'group-1',
      characterId: 'char-1',
      maxRetries: 0,
    );
    expect(visionResult['governanceBlocked'], isTrue);
    expect(client.sendCount, 0);
  });

  test('无请求侧输出上限时仍按半窗口预留治理预算', () async {
    final store = MemoryGovernanceStore();
    await store.saveCustomCapability(
      'custom',
      'uncapped-output',
      const CustomModelCapability(contextWindow: 128, maxOutput: 128),
    );

    final result = store.guard.check(
      provider: ApiProvider.custom,
      model: 'uncapped-output',
      messages: [
        {'role': 'user', 'content': List.filled(300, 'x').join()},
      ],
      purpose: AiRequestPurpose.agent,
      conversationId: 'work-task',
      maxTokens: 0,
      streaming: false,
      requiresTools: false,
      userInitiated: true,
    );

    expect(result.allowed, isFalse);
    expect(result.reason, contains('估算上下文'));
  });

  test('零 maxTokens 不发送协议输出上限且仍经治理预检', () async {
    final client = FakeCompletionClient();
    final gateway = AiRequestGateway(
      store: MemoryGovernanceStore(),
      client: client,
    );

    final result = await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.sensenova,
      model: 'sensenova-6.8-flash-lite',
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: 'work-task',
      characterId: 'worker',
      maxTokens: 0,
      maxRetries: 0,
    );

    expect(result['success'], isTrue);
    expect(client.lastSendMaxTokens, 0);
  });

  test('省略协议输出上限仍按模型最大可用输出预留费用预算', () async {
    final client = FakeCompletionClient();
    final gateway = AiRequestGateway(
      store: MemoryGovernanceStore(
        budgetSettings: const BudgetSettings(dailyHardLimitMicros: 1),
      ),
      client: client,
    );

    final result = await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: 'work-task',
      characterId: 'worker',
      maxTokens: 0,
      maxRetries: 0,
    );

    expect(result['governanceBlocked'], isTrue);
    expect(client.sendCount, 0);
  });

  test('已知视觉模型带图不被治理拦截', () async {
    final store = MemoryGovernanceStore();
    final client = FakeCompletionClient();
    final gateway = AiRequestGateway(store: store, client: client);

    final result = await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.qwen,
      model: 'qwen-vl-plus',
      messages: const [
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,abc'},
            },
          ],
        },
      ],
      purpose: AiRequestPurpose.reply,
      conversationId: 'group-1',
      characterId: 'char-1',
      maxRetries: 0,
    );
    expect(result['governanceBlocked'], isNot(isTrue));
    expect(result['success'], isTrue);
    expect(client.sendCount, 1);
  });

  test('后台用途开关阻断自动聊天、主动消息和摘要', () async {
    final store = MemoryGovernanceStore(
      budgetSettings: const BudgetSettings(
        autoChatEnabled: false,
        proactiveEnabled: false,
        summaryEnabled: false,
      ),
    );
    final client = FakeCompletionClient();
    final gateway = AiRequestGateway(store: store, client: client);

    for (final purpose in const [
      AiRequestPurpose.autoChat,
      AiRequestPurpose.proactive,
      AiRequestPurpose.summary,
    ]) {
      final result = await gateway.sendChatMessage(
        apiKey: 'secret',
        provider: ApiProvider.deepseek,
        model: 'deepseek-chat',
        messages: messages,
        purpose: purpose,
        conversationId: 'group-1',
        characterId: 'char-1',
        maxRetries: 0,
      );
      expect(result['governanceBlocked'], isTrue, reason: purpose.name);
    }
    expect(client.sendCount, 0);
  });

  test('账本保存 Token、用途、价格版本和整数费用', () async {
    final store = MemoryGovernanceStore();
    final client = FakeCompletionClient();
    final gateway = AiRequestGateway(store: store, client: client);

    final result = await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.reply,
      conversationId: 'group-1',
      characterId: 'char-1',
      taskId: 'task-usage-1',
      runBoundary: 17,
      maxRetries: 0,
      userInitiated: true,
    );

    expect(result['success'], isTrue);
    final entry = store.ledgerEntries.single;
    expect(entry.inputTokens, 100);
    expect(entry.cachedInputTokens, 20);
    expect(entry.outputTokens, 10);
    expect(entry.taskId, 'task-usage-1');
    expect(entry.runBoundary, 17);
    expect(entry.purpose, AiRequestPurpose.reply);
    expect(entry.priceVersion, 'deepseek-usd-2026-06');
    expect(entry.estimatedCostMicros, isPositive);
    expect(entry.exactUsage, isTrue);
    expect(
      aggregateUsage(store.ledgerEntries, (item) => item.characterId)
          .values
          .single
          .requestCount,
      1,
    );
    expect(
      aggregateUsage(store.ledgerEntries, (item) => item.conversationId)
          .values
          .single
          .inputTokens,
      100,
    );
    expect(
      aggregateUsage(store.ledgerEntries, (item) => item.model)
          .values
          .single
          .outputTokens,
      10,
    );
    expect(
      aggregateUsage(
              store.ledgerEntries, (item) => item.timestamp.day.toString())
          .values
          .single
          .costMicrosByCurrency['USD'],
      entry.estimatedCostMicros,
    );
    final restored = UsageLedgerEntry.fromMap(entry.toMap());
    expect(restored.taskId, 'task-usage-1');
    expect(restored.runBoundary, 17);
    final restoredDiagnostic = AiRequestDiagnostic.fromMap(
      store.diagnostics.single.toMap(),
    );
    expect(restoredDiagnostic.taskId, 'task-usage-1');
    expect(restoredDiagnostic.runBoundary, 17);
  });

  test('精确记录失败请求用量且把真实重试作为独立消费归入任务', () async {
    final store = MemoryGovernanceStore();
    final client = FakeCompletionClient();
    client.responder = (count) async => count == 1
        ? {
            'success': false,
            'statusCode': 503,
            'message': 'busy',
            'promptTokens': 11,
            'completionTokens': 2,
            'cachedTokens': 3,
          }
        : {
            'success': true,
            'message': 'ok',
            'promptTokens': 20,
            'completionTokens': 5,
            'cachedTokens': 4,
          };
    final gateway = AiRequestGateway(
      store: store,
      client: client,
      retrySleep: (_) async {},
    );

    await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: 'group-1',
      characterId: 'worker',
      taskId: 'task-retry-1',
      runBoundary: 23,
      maxRetries: 1,
    );

    expect(store.ledgerEntries, hasLength(2));
    expect(store.ledgerEntries.map((entry) => entry.status),
        ['failed', 'success']);
    expect(
      store.ledgerEntries.map((entry) => entry.requestId).toSet(),
      hasLength(2),
    );
    expect(store.ledgerEntries.map((entry) => entry.rootRequestId).toSet(),
        hasLength(1));
    expect(store.ledgerEntries.map((entry) => entry.inputTokens), [11, 20]);
    expect(store.ledgerEntries.map((entry) => entry.outputTokens), [2, 5]);
    expect(store.ledgerEntries.map((entry) => entry.cachedInputTokens), [3, 4]);
    expect(store.ledgerEntries.every((entry) => entry.taskId == 'task-retry-1'),
        isTrue);
    expect(
        store.ledgerEntries.every((entry) => entry.runBoundary == 23), isTrue);
    expect(store.diagnostics.map((item) => item.retryCount), [0, 1]);
    expect(store.diagnostics.every((item) => item.taskId == 'task-retry-1'),
        isTrue);
  });

  test('旧账本缺少任务归属时保持可读且未知归属不猜测', () {
    final restored = UsageLedgerEntry.fromMap({
      'requestId': 'legacy-request',
      'rootRequestId': 'legacy-root',
      'purpose': 'reply',
      'inputTokens': 1,
      'outputTokens': 2,
      'exactUsage': true,
    });
    expect(restored.taskId, isNull);
    expect(restored.runBoundary, isNull);
    expect(restored.status, 'success');
    final malformed = UsageLedgerEntry.fromMap({
      'taskId': 17,
      'runBoundary': 1.5,
    });
    expect(malformed.taskId, isNull);
    expect(malformed.runBoundary, isNull);
  });

  test('缺少上游用量时明确标估算，诊断保留估算标记', () async {
    final store = MemoryGovernanceStore();
    final client = FakeCompletionClient()
      ..responder = (_) async => {'success': true, 'message': 'a short answer'};
    final gateway = AiRequestGateway(store: store, client: client);

    await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: 'group-1',
      characterId: 'worker',
      taskId: 'task-estimated',
      runBoundary: 4,
      maxRetries: 0,
    );

    expect(store.ledgerEntries.single.exactUsage, isFalse);
    expect(store.ledgerEntries.single.inputTokens, greaterThan(0));
    expect(store.ledgerEntries.single.outputTokens, 4);
    expect(store.diagnostics.single.exactUsage, isFalse);
    expect(store.diagnostics.single.toSafeText(), contains('exactUsage=false'));
  });

  test('模型能力声明不改写结构有效的上游实报用量', () async {
    final store = MemoryGovernanceStore();
    await store.saveCustomCapability(
      ApiProvider.custom.name,
      'step-5-preview',
      const CustomModelCapability(contextWindow: 1000000, maxOutput: 8192),
    );
    final client = FakeCompletionClient()
      ..responder = (_) async => {
            'success': true,
            'message': 'ok',
            'promptTokens': 100000000,
            'cachedTokens': 2,
            'completionTokens': 3,
          };
    final gateway = AiRequestGateway(store: store, client: client);

    await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.custom,
      model: 'step-5-preview',
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: 'group-1',
      characterId: 'worker',
      taskId: 'task-outlier',
      maxRetries: 0,
    );

    final entry = store.ledgerEntries.single;
    expect(entry.inputTokens, 100000000);
    expect(entry.cachedInputTokens, 2);
    expect(entry.outputTokens, 3);
    expect(entry.exactUsage, isTrue);
    expect(entry.reportedUsage!.inputTokens, 100000000);
    expect(store.diagnostics.single.exactUsage, isTrue);
    expect(store.diagnostics.single.inputTokens, entry.inputTokens);
  });

  test('价格未知只记 Token，诊断不含 Key、Authorization 或正文', () async {
    final store = MemoryGovernanceStore();
    final client = FakeCompletionClient();
    final gateway = AiRequestGateway(store: store, client: client);
    const secret = 'sk-never-export';
    const body = 'private-message-body';

    await gateway.sendChatMessage(
      apiKey: secret,
      provider: ApiProvider.custom,
      model: 'private-model',
      messages: const [
        {'role': 'user', 'content': body},
      ],
      purpose: AiRequestPurpose.reply,
      conversationId: 'dm:1',
      characterId: 'char-1',
      maxRetries: 0,
    );

    expect(store.ledgerEntries.single.estimatedCostMicros, isNull);
    final diagnostic = store.diagnostics.single.toSafeText();
    expect(diagnostic, isNot(contains(secret)));
    expect(diagnostic, isNot(contains(body)));
    expect(diagnostic.toLowerCase(), isNot(contains('authorization')));
  });

  test('工作模式使用结构化流式请求', () async {
    final client = FakeCompletionClient();
    final gateway = AiRequestGateway(
      store: MemoryGovernanceStore(),
      client: client,
    );

    for (final entry in const [
      (provider: ApiProvider.sensenova, model: 'sensenova-6.8-flash-lite'),
      (provider: ApiProvider.deepseek, model: 'deepseek-chat'),
    ]) {
      await gateway.sendChatMessageStreamed(
        apiKey: 'secret',
        provider: entry.provider,
        model: entry.model,
        messages: messages,
        purpose: AiRequestPurpose.agent,
        conversationId: 'work-task',
        characterId: 'worker',
        maxRetries: 0,
        requiresTools: true,
      );
    }

    expect(client.sendCount, 0);
    expect(client.streamedCount, 0);
    expect(client.structuredStreamedCount, 2);
  });

  test(
      'group execution keeps terminal, activity and reasoning options through fallback',
      () async {
    final client = FakeCompletionClient()..structuredStreamedFailure = true;
    final gateway =
        AiRequestGateway(store: MemoryGovernanceStore(), client: client);
    var activity = 0;
    await gateway.sendChatMessageStreamed(
        apiKey: 'test-key',
        provider: ApiProvider.custom,
        model: 'step-5-preview',
        messages: messages,
        purpose: AiRequestPurpose.agent,
        conversationId: 'group',
        characterId: 'worker',
        requiresTools: true,
        maxRetries: 0,
        receiveTimeout: const Duration(seconds: 300),
        finishOnTerminalFrame: true,
        reasoningEffort: 'low',
        onResponseActivity: () {
          activity++;
        });
    expect(client.terminalFrameRequested, isTrue);
    expect(
        client.structuredStreamedReceiveTimeout, const Duration(seconds: 300));
    expect(client.streamedReasoningEffort, 'low');
    expect(client.fallbackReasoningEffort, 'low');
    expect(activity, 1);
  });

  test('SenseNova stalled work response retries structured non-stream JSON',
      () async {
    final client = FakeCompletionClient();
    client.structuredStreamedFailure = true;
    final gateway = AiRequestGateway(
      store: MemoryGovernanceStore(),
      client: client,
    );

    final result = await gateway.sendChatMessageStreamed(
      apiKey: 'secret',
      provider: ApiProvider.sensenova,
      model: 'sensenova-6.8-flash-lite',
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: 'work-task',
      characterId: 'worker',
      maxRetries: 0,
      requiresTools: true,
    );

    expect(result['success'], isTrue);
    expect(client.sendCount, 0);
    expect(client.boundedCount, 1);
  });

  test('工作模式流式尝试只约束空闲间隙，兼容路径继承调用方预算', () async {
    const callerBudget = Duration(seconds: 300);
    final client = FakeCompletionClient();
    client.structuredStreamedFailure = true;
    final gateway = AiRequestGateway(
      store: MemoryGovernanceStore(),
      client: client,
    );

    await gateway.sendChatMessageStreamed(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: 'work-task',
      characterId: 'worker',
      maxRetries: 0,
      requiresTools: true,
      receiveTimeout: callerBudget,
    );

    // The streamed attempt may only bound its idle gap; a work-mode turn
    // legitimately runs longer than that.
    expect(
      client.structuredStreamedReceiveTimeout,
      lessThan(callerBudget),
    );
    // The compatibility path keeps the caller's full budget instead of
    // inheriting the short idle bound.
    expect(client.boundedReceiveTimeouts, [callerBudget]);
  });

  test('工作模式对确定性失败不再发起额外请求', () async {
    // A client error, a malformed body and an oversized body all fail the same
    // way on the compatibility path, and a user stop must never be re-sent.
    for (final failure in <Map<String, dynamic>>[
      {'success': false, 'statusCode': 401, 'message': '鉴权失败'},
      {'success': false, 'message': '响应格式无效'},
      {'success': false, 'message': '模型响应超过安全大小限制'},
      {'success': false, 'message': '请求已取消'},
    ]) {
      final client = FakeCompletionClient();
      client.structuredStreamedResult = failure;
      final gateway = AiRequestGateway(
        store: MemoryGovernanceStore(),
        client: client,
      );

      final result = await gateway.sendChatMessageStreamed(
        apiKey: 'secret',
        provider: ApiProvider.deepseek,
        model: 'deepseek-chat',
        messages: messages,
        purpose: AiRequestPurpose.agent,
        conversationId: 'work-task',
        characterId: 'worker',
        maxRetries: 0,
        requiresTools: true,
      );

      expect(result['message'], failure['message']);
      expect(client.boundedCount, 0, reason: '$failure 不应触发兼容路径');
      expect(client.streamedCount, 0, reason: '$failure 不应触发兼容路径');
    }
  });

  test('Retry-After 提示穿过网关的直返与兼容两条路径', () async {
    final directClient = FakeCompletionClient()
      ..structuredStreamedResult = {
        'success': false,
        'statusCode': 402,
        'retryAfterMs': 5000,
        'message': '需要付费',
      };
    final directGateway = AiRequestGateway(
      store: MemoryGovernanceStore(),
      client: directClient,
    );

    final direct = await directGateway.sendChatMessageStreamed(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: 'work-task',
      characterId: 'worker',
      maxRetries: 0,
      requiresTools: true,
    );

    // 非重试状态直接返回流式结果：提示不能被字段收窄丢掉。
    expect(directClient.boundedCount, 0);
    expect(direct['retryAfterMs'], 5000);

    final fallbackClient = FakeCompletionClient()
      ..structuredStreamedResult = {
        'success': false,
        'statusCode': 429,
        'retryAfterMs': 7000,
        'message': 'HTTP 429 请求失败',
      }
      ..boundedResult = {
        'success': false,
        'statusCode': 429,
        'retryAfterMs': 3000,
        'message': 'HTTP 429 请求失败',
      };
    final fallbackGateway = AiRequestGateway(
      store: MemoryGovernanceStore(),
      client: fallbackClient,
    );

    final fallback = await fallbackGateway.sendChatMessageStreamed(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: 'work-task',
      characterId: 'worker',
      maxRetries: 0,
      requiresTools: true,
    );

    // 429 会落到兼容路径，最终生效的是那次调用的提示，同样不能被丢掉。
    expect(fallbackClient.boundedCount, 1);
    expect(fallback['retryAfterMs'], 3000);
  });

  test('工作模式对客户端标记为可重试的空回复仍走兼容路径', () async {
    final client = FakeCompletionClient();
    client.structuredStreamedResult = {
      'success': false,
      'message': '模型返回了空内容',
      'failureCode': 'emptyResponse',
      'retryable': true,
    };
    final gateway = AiRequestGateway(
      store: MemoryGovernanceStore(),
      client: client,
    );

    final result = await gateway.sendChatMessageStreamed(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.agent,
      conversationId: 'work-task',
      characterId: 'worker',
      maxRetries: 0,
      requiresTools: true,
    );

    // The bounded protocol failure carries the same retryable signal that
    // WorkFailure reads, so the compatibility call must still run.
    expect(client.boundedCount, 1);
    expect(result['success'], isTrue);
  });

  test('空回复记为可重试的协议失败而不是笼统的供应商错误', () async {
    final store = MemoryGovernanceStore();
    final client = FakeCompletionClient();
    client.responder = (_) async => {
          'success': false,
          'message': '模型返回了空内容',
          'failureCode': 'emptyResponse',
          'retryable': true,
        };
    final gateway = AiRequestGateway(store: store, client: client);

    await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.reply,
      conversationId: 'group-1',
      characterId: 'char-1',
      maxRetries: 0,
    );

    expect(store.diagnostics.last.status, 'failed');
    expect(store.diagnostics.last.failureType, 'empty_completion');
  });

  test('网关重试按 RetryAttempt 回退温度', () async {
    final store = MemoryGovernanceStore();
    final client = FakeCompletionClient();
    client.responder = (count) async => count <= 5
        ? {'success': false, 'statusCode': 503, 'message': 'busy'}
        : {
            'success': true,
            'message': 'ok',
            'promptTokens': 1,
            'completionTokens': 1,
          };
    final gateway = AiRequestGateway(
      store: store,
      client: client,
      retrySleep: (_) async {},
    );

    final result = await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.reply,
      conversationId: 'group-1',
      characterId: 'char-1',
      temperature: 0.9,
      maxRetries: 5,
    );

    expect(result['success'], isTrue);
    expect(client.temperatures, [0.9, 0.9, 0.9, 0.9, 0.6, 0.4]);
  });

  test('重试前再次预算预检', () async {
    final store = MemoryGovernanceStore();
    final client = FakeCompletionClient();
    client.responder = (count) async {
      if (count == 1) {
        store.budgetSettings = const BudgetSettings(dailyHardLimitMicros: 1);
        return {'success': false, 'statusCode': 503, 'message': 'busy'};
      }
      return {'success': true, 'message': 'should not run'};
    };
    final gateway = AiRequestGateway(
      store: store,
      client: client,
      retrySleep: (_) async {},
    );

    final result = await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.reply,
      conversationId: 'group-1',
      characterId: 'char-1',
      maxRetries: 1,
    );

    expect(result['governanceBlocked'], isTrue);
    expect(client.sendCount, 1);
    expect(store.diagnostics.last.failureType, 'budget');
  });

  test('流式请求被治理拦截后释放预算预留（不泄漏）', () async {
    final store = MemoryGovernanceStore(
      budgetSettings: const BudgetSettings(dailyHardLimitMicros: 1),
    );
    final client = FakeCompletionClient();
    final gateway = AiRequestGateway(store: store, client: client);

    // deepseek-chat 有明确美元价格，check 会预留预估成本；但日预算硬上限=1 会被拦截。
    final events = gateway.streamChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      purpose: AiRequestPurpose.reply,
      conversationId: 'group-1',
      characterId: 'char-1',
    );
    final received = await events.toList();

    expect(
      received.any((event) => event.type == ChatStreamEventType.error),
      isTrue,
      reason: '被预算硬上限拦截应输出 error 事件',
    );
    expect(client.sendCount, 0);

    // 回归：拦截分支必须释放 check 时预留的预算，否则 _reservedMicros 永久泄漏，
    // 后续同类请求会被错误拦截。
    expect(gateway.guard.reservedMicrosTotal, 0,
        reason: '被拦截的流式请求应释放预留，避免预算计数泄漏');
  });

  test('流式 HTTP 错误遥测保留状态码', () async {
    final store = MemoryGovernanceStore();
    final gateway = AiRequestGateway(
      store: store,
      client: FakeStreamingErrorClient('HTTP 503 请求失败'),
    );

    await gateway
        .streamChatMessage(
          apiKey: 'secret',
          provider: ApiProvider.deepseek,
          model: 'deepseek-chat',
          messages: messages,
          purpose: AiRequestPurpose.reply,
          conversationId: 'group-1',
          characterId: 'char-1',
        )
        .toList();

    expect(store.diagnostics.last.failureType, 'http_503');
  });

  test('未登记模型可以流式：不会被治理层以「未声明支持流式输出」拦下', () async {
    final store = MemoryGovernanceStore();
    final gateway = AiRequestGateway(
      store: store,
      client: FakeStreamingErrorClient('HTTP 503 请求失败'),
    );

    final events = await gateway
        .streamChatMessage(
          apiKey: 'k',
          provider: ApiProvider.custom,
          model: 'deepseek/deepseek-flash',
          messages: messages,
          purpose: AiRequestPurpose.reply,
          conversationId: 'group-1',
          characterId: 'char-1',
        )
        .toList();

    expect(
      events.where((event) => (event.message ?? '').contains('未声明支持流式')),
      isEmpty,
    );
    // 请求真的发出去了：诊断记的是上游状态，而不是治理拦截（拦截会记 capability）。
    expect(store.diagnostics.last.failureType, 'http_503');
  });

  test('非流式失败的异常原因写进诊断', () async {
    final store = MemoryGovernanceStore();
    final gateway = AiRequestGateway(
      store: store,
      client: ChatApiService(dio: _throwingDio(), retrySleep: (_) async {}),
    );

    await gateway.sendChatMessage(
      apiKey: 'secret',
      provider: ApiProvider.deepseek,
      model: 'deepseek-chat',
      messages: messages,
      purpose: AiRequestPurpose.connectionTest,
      conversationId: '',
      characterId: '',
      maxRetries: 0,
    );

    expect(store.diagnostics.last.status, 'failed');
    expect(store.diagnostics.last.failureType, 'provider_error');
    expect(
      store.diagnostics.last.failureDetail,
      contains('FormatException'),
    );
  });

  test('流式失败的异常原因写进诊断', () async {
    final store = MemoryGovernanceStore();
    final gateway = AiRequestGateway(
      store: store,
      client: ChatApiService(dio: _throwingDio(), retrySleep: (_) async {}),
    );

    await gateway
        .streamChatMessage(
          apiKey: 'secret',
          provider: ApiProvider.deepseek,
          model: 'deepseek-chat',
          messages: messages,
          purpose: AiRequestPurpose.reply,
          conversationId: 'group-1',
          characterId: 'char-1',
        )
        .toList();

    expect(store.diagnostics.last.status, 'failed');
    expect(
      store.diagnostics.last.failureDetail,
      contains('FormatException'),
    );
  });
}

/// 每次请求都以「无法归类的传输异常」失败的 Dio；用于验证失败原因是否被保留。
Dio _throwingDio() {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      handler.reject(DioException(
        requestOptions: options,
        type: DioExceptionType.unknown,
        error: const FormatException('provider body was HTML'),
      ));
    },
  ));
  return dio;
}
