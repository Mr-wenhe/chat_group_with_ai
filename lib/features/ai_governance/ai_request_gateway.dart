import 'dart:async';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/retry_handler.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_guard.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

class AiRequestGateway {
  static const blockedPrefix = '治理拦截：';

  final GovernancePersistence store;
  final ChatApiService client;
  final AiRequestGuard guard;
  final DateTime Function() clock;
  final RetrySleep retrySleep;
  final void Function(String warning)? onWarning;

  AiRequestGateway({
    required this.store,
    ChatApiService? client,
    DateTime Function()? clock,
    RetrySleep? retrySleep,
    this.onWarning,
  })  : client = client ?? ChatApiService(),
        guard = store.guard,
        clock = clock ?? DateTime.now,
        retrySleep = retrySleep ?? Future<void>.delayed;

  static bool isBlockedMessage(String? message) =>
      message?.startsWith(blockedPrefix) ?? false;

  ModelCapability capability(ApiProvider provider, String model) {
    return guard.capability(provider, model);
  }

  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    required AiRequestPurpose purpose,
    required String conversationId,
    required String characterId,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = RetryHandler.defaultMaxRetries,
    CancelToken? cancelToken,
    bool requiresTools = false,
    bool userInitiated = false,
  }) async {
    await store.ensureLedgerBox();
    return _sendWithRetries(
      provider: provider,
      model: model,
      messages: messages,
      purpose: purpose,
      conversationId: conversationId,
      characterId: characterId,
      maxTokens: maxTokens,
      maxRetries: maxRetries,
      streaming: false,
      requiresTools: requiresTools,
      userInitiated: userInitiated,
      operation: (attempt) => client.sendChatMessage(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: customBaseUrl,
        model: model,
        messages: messages,
        temperature: attempt.temperatureFor(temperature),
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        maxRetries: 0,
        cancelToken: cancelToken,
      ),
    );
  }

  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    required AiRequestPurpose purpose,
    required String conversationId,
    required String characterId,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    int maxRetries = RetryHandler.defaultMaxRetries,
    CancelToken? cancelToken,
    bool requiresTools = false,
    bool userInitiated = false,
  }) async {
    await store.ensureLedgerBox();
    return _sendWithRetries(
      provider: provider,
      model: model,
      messages: messages,
      purpose: purpose,
      conversationId: conversationId,
      characterId: characterId,
      maxTokens: maxTokens,
      maxRetries: maxRetries,
      streaming: true,
      requiresTools: requiresTools,
      userInitiated: userInitiated,
      operation: (attempt) => client.sendChatMessageStreamed(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: customBaseUrl,
        model: model,
        messages: messages,
        temperature: attempt.temperatureFor(temperature),
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        maxRetries: 0,
        cancelToken: cancelToken,
      ),
    );
  }

  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    required AiRequestPurpose purpose,
    required String conversationId,
    required String characterId,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
    bool requiresTools = false,
    bool userInitiated = false,
  }) async* {
    await store.ensureLedgerBox();
    final rootRequestId = const Uuid().v4();
    final prepared = guard.check(
      provider: provider,
      model: model,
      messages: messages,
      purpose: purpose,
      conversationId: conversationId,
      maxTokens: maxTokens,
      streaming: true,
      requiresTools: requiresTools,
      userInitiated: userInitiated,
    );
    if (!prepared.allowed) {
      // 预留预算必须在每个出口释放，否则并发预留计数会泄漏（后续请求被误判超额）。
      guard.release(conversationId, prepared.reservedMicros);
      await _recordBlocked(
        rootRequestId: rootRequestId,
        provider: provider,
        model: model,
        purpose: purpose,
        reason: prepared.reason!,
      );
      yield ChatStreamEvent.error('$blockedPrefix${prepared.reason}');
      return;
    }
    if (prepared.warning?.contains('软阈值') ?? false) {
      onWarning?.call(prepared.warning!);
    }

    final stopwatch = Stopwatch()..start();
    int? inputTokens;
    int? cachedTokens;
    int? outputTokens;
    var outputCharacters = 0;
    String status = 'cancelled';
    String? failureType;
    bool attemptRecorded = false;
    try {
      await for (final event in client.streamChatMessage(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: customBaseUrl,
        model: model,
        messages: messages,
        temperature: temperature,
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        cancelToken: cancelToken,
      )) {
        if (event.type == ChatStreamEventType.token) {
          outputCharacters += event.delta?.length ?? 0;
        } else if (event.type == ChatStreamEventType.done) {
          inputTokens = event.promptTokens;
          cachedTokens = event.cachedTokens;
          outputTokens = event.completionTokens;
          status = 'success';
        } else if (event.type == ChatStreamEventType.error) {
          status = 'failed';
          failureType = _failureType(event.message);
        }
        if (event.type == ChatStreamEventType.done) {
          attemptRecorded = true;
          await _recordAttempt(
            requestId: rootRequestId,
            rootRequestId: rootRequestId,
            provider: provider,
            model: model,
            characterId: characterId,
            conversationId: conversationId,
            purpose: purpose,
            originPurpose: purpose,
            capability: prepared.capability!,
            estimatedInputTokens: prepared.inputTokens,
            estimatedOutputTokens: (outputCharacters / 4).ceil(),
            inputTokens: inputTokens,
            cachedTokens: cachedTokens,
            outputTokens: outputTokens,
            exactUsage: inputTokens != null && outputTokens != null,
            latencyMs: stopwatch.elapsedMilliseconds,
            retryCount: 0,
            status: status,
            failureType: failureType,
          );
        }
        yield event;
      }
    } finally {
      guard.release(conversationId, prepared.reservedMicros);
      if (!attemptRecorded && status != 'success') {
        await _recordAttempt(
          requestId: rootRequestId,
          rootRequestId: rootRequestId,
          provider: provider,
          model: model,
          characterId: characterId,
          conversationId: conversationId,
          purpose: purpose,
          originPurpose: purpose,
          capability: prepared.capability!,
          estimatedInputTokens: prepared.inputTokens,
          estimatedOutputTokens: (outputCharacters / 4).ceil(),
          inputTokens: inputTokens,
          cachedTokens: cachedTokens,
          outputTokens: outputTokens,
          exactUsage: inputTokens != null && outputTokens != null,
          latencyMs: stopwatch.elapsedMilliseconds,
          retryCount: 0,
          status: status,
          failureType: failureType,
        );
      }
    }
  }

  Future<Map<String, dynamic>> _sendWithRetries({
    required ApiProvider provider,
    required String model,
    required List<Map<String, dynamic>> messages,
    required AiRequestPurpose purpose,
    required String conversationId,
    required String characterId,
    required int maxTokens,
    required int maxRetries,
    required bool streaming,
    required bool requiresTools,
    required bool userInitiated,
    required RetryOperation<Map<String, dynamic>> operation,
  }) async {
    final rootRequestId = const Uuid().v4();
    var attempts = 0;
    final result = await RetryHandler.executeWithRetry<Map<String, dynamic>>(
      maxRetries: maxRetries,
      sleep: retrySleep,
      shouldRetryResult: RetryHandler.isTransientResult,
      operation: (attempt) async {
        attempts = attempt.retryNumber + 1;
        final prepared = guard.check(
          provider: provider,
          model: model,
          messages: messages,
          purpose: purpose,
          conversationId: conversationId,
          maxTokens: maxTokens,
          streaming: streaming,
          requiresTools: requiresTools,
          userInitiated: userInitiated,
        );
        try {
          final requestId = attempt.retryNumber == 0
              ? rootRequestId
              : '$rootRequestId:${attempt.retryNumber}';
          if (!prepared.allowed) {
            await _recordBlocked(
              requestId: requestId,
              rootRequestId: rootRequestId,
              provider: provider,
              model: model,
              purpose:
                  attempt.retryNumber == 0 ? purpose : AiRequestPurpose.retry,
              reason: prepared.reason!,
              retryCount: attempt.retryNumber,
            );
            return {
              'success': false,
              'message': '$blockedPrefix${prepared.reason}',
              'governanceBlocked': true,
              'requestId': rootRequestId,
            };
          }
          if (attempt.retryNumber == 0 &&
              (prepared.warning?.contains('软阈值') ?? false)) {
            onWarning?.call(prepared.warning!);
          }

          final stopwatch = Stopwatch()..start();
          final response = await operation(attempt);
          final success = response['success'] == true;
          final inputTokens = response['promptTokens'] as int?;
          final outputTokens = response['completionTokens'] as int?;
          final cachedTokens = response['cachedTokens'] as int?;
          final responseText = response['message']?.toString() ?? '';
          await _recordAttempt(
            requestId: requestId,
            rootRequestId: rootRequestId,
            provider: provider,
            model: response['model']?.toString() ?? model,
            characterId: characterId,
            conversationId: conversationId,
            purpose:
                attempt.retryNumber == 0 ? purpose : AiRequestPurpose.retry,
            originPurpose: purpose,
            capability: prepared.capability!,
            estimatedInputTokens: prepared.inputTokens,
            estimatedOutputTokens:
                success ? (responseText.length / 4).ceil() : 0,
            inputTokens: inputTokens,
            cachedTokens: cachedTokens,
            outputTokens: outputTokens,
            exactUsage: inputTokens != null && outputTokens != null,
            latencyMs: stopwatch.elapsedMilliseconds,
            retryCount: attempt.retryNumber,
            status: success ? 'success' : 'failed',
            failureType: success ? null : _failureType(responseText, response),
          );
          return {
            ...response,
            'requestId': rootRequestId,
            if (prepared.warning != null) 'budgetWarning': prepared.warning,
          };
        } finally {
          // 无论成功/失败/被拦截，都释放 check 时预留的预算，避免并发预留计数泄漏。
          guard.release(conversationId, prepared.reservedMicros);
        }
      },
    );
    if (result['success'] != true && attempts > 1) {
      return {
        ...result,
        'retryExhausted': true,
        'retryCount': attempts - 1,
      };
    }
    return {...result, 'retryCount': attempts - 1};
  }

  Future<void> _recordAttempt({
    required String requestId,
    required String rootRequestId,
    required ApiProvider provider,
    required String model,
    required String characterId,
    required String conversationId,
    required AiRequestPurpose purpose,
    required AiRequestPurpose originPurpose,
    required ModelCapability capability,
    required int estimatedInputTokens,
    required int estimatedOutputTokens,
    required int? inputTokens,
    required int? cachedTokens,
    required int? outputTokens,
    required bool exactUsage,
    required int latencyMs,
    required int retryCount,
    required String status,
    required String? failureType,
  }) async {
    final effectiveInput = inputTokens ?? estimatedInputTokens;
    final effectiveCached = cachedTokens ?? 0;
    final effectiveOutput = outputTokens ?? estimatedOutputTokens;
    int? cost;
    final price = capability.price;
    if (price != null) {
      cost = price.estimateMicros(
        inputTokens: effectiveInput,
        cachedInputTokens: effectiveCached,
        outputTokens: effectiveOutput,
      );
    }
    if (status == 'success') {
      await store.addLedgerEntry(UsageLedgerEntry(
        requestId: requestId,
        rootRequestId: rootRequestId,
        timestamp: clock(),
        provider: provider.name,
        model: model,
        characterId: characterId,
        conversationId: conversationId,
        purpose: purpose,
        originPurpose: originPurpose,
        inputTokens: effectiveInput,
        cachedInputTokens: effectiveCached,
        outputTokens: effectiveOutput,
        estimatedCostMicros: cost,
        currency: price?.currency,
        priceVersion: price?.version,
        exactUsage: exactUsage,
      ));
    }
    await store.addDiagnostic(AiRequestDiagnostic(
      requestId: requestId,
      rootRequestId: rootRequestId,
      timestamp: clock(),
      purpose: purpose,
      provider: provider.name,
      model: model,
      latencyMs: latencyMs,
      retryCount: retryCount,
      inputTokens: status == 'success' ? effectiveInput : inputTokens,
      cachedInputTokens: status == 'success' ? effectiveCached : cachedTokens,
      outputTokens: status == 'success' ? effectiveOutput : outputTokens,
      estimatedCostMicros: status == 'success' ? cost : null,
      currency: status == 'success' ? price?.currency : null,
      status: status,
      failureType: failureType,
    ));
  }

  Future<void> _recordBlocked({
    String? requestId,
    required String rootRequestId,
    required ApiProvider provider,
    required String model,
    required AiRequestPurpose purpose,
    required String reason,
    int retryCount = 0,
  }) {
    return store.addDiagnostic(AiRequestDiagnostic(
      requestId: requestId ?? rootRequestId,
      rootRequestId: rootRequestId,
      timestamp: clock(),
      purpose: purpose,
      provider: provider.name,
      model: model,
      latencyMs: 0,
      retryCount: retryCount,
      inputTokens: null,
      cachedInputTokens: null,
      outputTokens: null,
      estimatedCostMicros: null,
      currency: null,
      status: 'blocked',
      failureType: _blockedFailureType(reason),
    ));
  }

  static String _failureType(
    String? message, [
    Map<String, dynamic>? result,
  ]) {
    if (result?['statusCode'] case final int code) return 'http_$code';
    final value = message?.toLowerCase() ?? '';
    if (value.contains('取消')) return 'cancelled';
    if (value.contains('超时') || value.contains('timeout')) return 'timeout';
    if (value.contains('网络') || value.contains('connection')) {
      return 'connection';
    }
    return 'provider_error';
  }

  static String _blockedFailureType(String reason) {
    if (reason.contains('预算')) return 'budget';
    if (reason.contains('图片') || reason.contains('能力')) return 'capability';
    if (reason.contains('上下文') || reason.contains('输出上限')) {
      return 'context_limit';
    }
    return 'policy';
  }
}
