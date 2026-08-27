part of 'ai_request_gateway.dart';

extension _AiRequestGatewayRetrySupport on AiRequestGateway {
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
              'message': '${AiRequestGateway.blockedPrefix}${prepared.reason}',
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
            failureType: success
                ? null
                : AiRequestGateway._failureType(responseText, response),
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
      failureType: AiRequestGateway._blockedFailureType(reason),
    ));
  }
}
