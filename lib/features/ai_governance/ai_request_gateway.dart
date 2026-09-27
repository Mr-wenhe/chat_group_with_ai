import 'dart:async';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/retry_handler.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_guard.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

part 'ai_request_gateway_retry.dart';

class AiRequestGateway {
  static const blockedPrefix = '治理拦截：';

  /// Idle-gap bound for the streamed work-mode attempt. dio resets its receive
  /// timeout on every chunk, so this abandons a stream that stopped emitting
  /// without capping the whole turn: work-mode turns legitimately run for
  /// minutes and the caller owns the overall deadline.
  static const Duration _structuredStreamIdleTimeout = Duration(seconds: 30);

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
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
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
        apiProtocol: apiProtocol,
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

  /// Sends a non-streaming request through a transport-level response limit.
  ///
  /// Small-schema callers such as the optional search planner must reject an
  /// oversized upstream body before the JSON decoder materializes it.
  Future<Map<String, dynamic>> sendChatMessageWithResponseLimit({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
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
    bool structuredJson = false,
    bool requiresTools = false,
    bool userInitiated = false,
    required int maxResponseBytes,
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
      operation: (attempt) => client.sendChatMessageWithResponseLimit(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: apiProtocol,
        customBaseUrl: customBaseUrl,
        model: model,
        messages: messages,
        temperature: attempt.temperatureFor(temperature),
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        maxRetries: 0,
        cancelToken: cancelToken,
        maxResponseBytes: maxResponseBytes,
        structuredJson: structuredJson,
      ),
    );
  }

  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
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
    void Function(ChatStreamEvent event)? onEvent,
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
      operation: (attempt) {
        final requestTemperature = attempt.temperatureFor(temperature);
        if (requiresTools && purpose == AiRequestPurpose.agent) {
          return _structuredWorkCompletionWithJsonFallback(
            apiKey: apiKey,
            provider: provider,
            apiProtocol: apiProtocol,
            customBaseUrl: customBaseUrl,
            model: model,
            messages: messages,
            temperature: requestTemperature,
            maxTokens: maxTokens,
            receiveTimeout: receiveTimeout,
            cancelToken: cancelToken,
            onEvent: onEvent,
          );
        }
        return client.sendChatMessageStreamed(
          apiKey: apiKey,
          provider: provider,
          apiProtocol: apiProtocol,
          customBaseUrl: customBaseUrl,
          model: model,
          messages: messages,
          temperature: requestTemperature,
          maxTokens: maxTokens,
          receiveTimeout: receiveTimeout,
          maxRetries: 0,
          cancelToken: cancelToken,
          onEvent: onEvent,
        );
      },
    );
  }

  Future<Map<String, dynamic>> _structuredWorkCompletionWithJsonFallback({
    required String apiKey,
    required ApiProvider provider,
    required ApiProtocol apiProtocol,
    required String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    required double temperature,
    required int maxTokens,
    required Duration receiveTimeout,
    required CancelToken? cancelToken,
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    // No step here carries a total-duration bound: the caller owns the overall
    // work-mode deadline and the cancellation token. The streaming attempt
    // only bounds its idle gap, so a stream that stops emitting hands over to
    // the compatibility path instead of holding the task lease until that
    // deadline.
    final streamed = await client.sendStructuredChatMessageStreamed(
      apiKey: apiKey,
      provider: provider,
      apiProtocol: apiProtocol,
      customBaseUrl: customBaseUrl,
      model: model,
      messages: messages,
      temperature: temperature,
      maxTokens: maxTokens,
      receiveTimeout: _structuredStreamIdleTimeout,
      maxRetries: 0,
      cancelToken: cancelToken,
      onEvent: onEvent,
    );
    if (!_needsCompletionFallback(streamed)) return streamed;
    final structured = await client.sendChatMessageWithResponseLimit(
      apiKey: apiKey,
      provider: provider,
      apiProtocol: apiProtocol,
      customBaseUrl: customBaseUrl,
      model: model,
      messages: messages,
      temperature: temperature,
      maxTokens: maxTokens,
      receiveTimeout: receiveTimeout,
      maxRetries: 0,
      cancelToken: cancelToken,
      structuredJson: true,
      maxResponseBytes: ChatApiService.defaultMaxResponseBytes,
    );
    if (structured['statusCode'] != 400) return structured;
    return client.sendChatMessageWithResponseLimit(
      apiKey: apiKey,
      provider: provider,
      apiProtocol: apiProtocol,
      customBaseUrl: customBaseUrl,
      model: model,
      messages: messages,
      temperature: temperature,
      maxTokens: maxTokens,
      receiveTimeout: receiveTimeout,
      maxRetries: 0,
      cancelToken: cancelToken,
      structuredJson: false,
      maxResponseBytes: ChatApiService.defaultMaxResponseBytes,
    );
  }

  /// Whether a failed streamed attempt is worth one non-streaming retry.
  ///
  /// The compatibility call is a different transport, so it earns an attempt on
  /// transport failures, on server-side/rate-limit statuses, and on an empty
  /// successful body: some gateways close an SSE stream without emitting the
  /// JSON payload. A rejected request (401/404 and other client errors) and a
  /// deterministic local failure such as an invalid or oversized body fail
  /// identically there, so they must not cost the task another provider call.
  bool _needsCompletionFallback(Map<String, dynamic> result) {
    // A user stop is terminal: never re-send it on another path.
    if (result['message'] == ChatApiService.cancelledResultMessage) {
      return false;
    }
    if (result['success'] != true) {
      // The client marks a bounded protocol failure (an empty completion, for
      // example) as retryable, the same signal `WorkFailure` reads, so re-ask
      // on the compatibility transport instead of treating it as internal.
      if (result['retryable'] == true) return true;
      final statusCode = result['statusCode'];
      if (statusCode is int) return _isRetryableCompletionStatus(statusCode);
      // No status: retry only on a positive transport-failure signal.
      return RetryHandler.isTransientResult(result);
    }
    final message = result['message'];
    return message is! String || message.trim().isEmpty;
  }

  /// The streamed attempt and the compatibility call are different transports,
  /// so a server-side or rate-limit status earns one attempt there even though
  /// the shared retry policy only retries a narrower set of statuses.
  static bool _isRetryableCompletionStatus(int statusCode) =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;

  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
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
        apiProtocol: apiProtocol,
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

  static String _failureType(
    String? message, [
    Map<String, dynamic>? result,
  ]) {
    if (result?['statusCode'] case final int code) return 'http_$code';
    final value = message?.toLowerCase() ?? '';
    final status = RegExp(r'\bhttp\s+(\d{3})\b', caseSensitive: false)
        .firstMatch(value)
        ?.group(1);
    if (status != null) return 'http_$status';
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
