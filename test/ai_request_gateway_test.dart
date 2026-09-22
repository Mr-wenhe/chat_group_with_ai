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
  bool structuredStreamedFailure = false;
  Duration? structuredStreamedReceiveTimeout;
  final boundedReceiveTimeouts = <Duration>[];

  /// Result returned by the structured streamed call when set; lets a test
  /// simulate a provider rejection that carries an HTTP status.
  Map<String, dynamic>? structuredStreamedResult;
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
  }) async {
    sendCount++;
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
    bool structuredJson = false,
    required int maxResponseBytes,
  }) async {
    boundedCount++;
    boundedReceiveTimeouts.add(receiveTimeout ?? Duration.zero);
    return {'success': true, 'message': '{}'};
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
    void Function(ChatStreamEvent event)? onEvent,
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
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    structuredStreamedCount++;
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
  }) async* {
    yield ChatStreamEvent.error(errorMessage);
  }
}

void main() {
  const messages = [
    {'role': 'user', 'content': 'hello'},
  ];

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
      maxRetries: 0,
      userInitiated: true,
    );

    expect(result['success'], isTrue);
    final entry = store.ledgerEntries.single;
    expect(entry.inputTokens, 100);
    expect(entry.cachedInputTokens, 20);
    expect(entry.outputTokens, 10);
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
}
