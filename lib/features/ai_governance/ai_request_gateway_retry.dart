part of 'ai_request_gateway.dart';

extension _AiRequestGatewayRetrySupport on AiRequestGateway {
  Future<Map<String, dynamic>> _sendWithRetries({
    required ApiProvider provider,
    required String model,
    required List<Map<String, dynamic>> messages,
    required AiRequestPurpose purpose,
    required String conversationId,
    required String characterId,
    required String? taskId,
    required int? runBoundary,
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
              taskId: taskId,
              runBoundary: runBoundary,
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
          final responses = _transportUsageAttempts(response);
          for (var transport = 0; transport < responses.length; transport++) {
            final response = responses[transport];
            final success = response['success'] == true;
            final inputTokens = response['promptTokens'] as int?;
            final outputTokens = response['completionTokens'] as int?;
            final cachedTokens = response['cachedTokens'] as int?;
            final responseText = response['message']?.toString() ?? '';
            await _recordAttempt(
              requestId: transport == 0
                  ? requestId
                  : '$requestId:transport:$transport',
              rootRequestId: rootRequestId,
              provider: provider,
              model: response['model']?.toString() ?? model,
              characterId: characterId,
              conversationId: conversationId,
              purpose:
                  attempt.retryNumber == 0 ? purpose : AiRequestPurpose.retry,
              taskId: taskId,
              runBoundary: runBoundary,
              originPurpose: purpose,
              capability: prepared.capability!,
              estimatedInputTokens: prepared.inputTokens,
              estimatedOutputTokens:
                  success ? (responseText.length / 4).ceil() : 0,
              inputTokens: inputTokens,
              cachedTokens: cachedTokens,
              outputTokens: outputTokens,
              reportedUsage: ReportedTokenUsage.fromMap(response),
              exactUsage: inputTokens != null && outputTokens != null,
              latencyMs: stopwatch.elapsedMilliseconds,
              retryCount: attempt.retryNumber,
              status: success ? 'success' : 'failed',
              failureType: success
                  ? null
                  : AiRequestGateway._failureType(responseText, response),
              failureDetail:
                  success ? null : response['failureDetail']?.toString(),
            );
          }
          final publicResponse = Map<String, dynamic>.from(response)
            ..remove('usageAttempts');
          return {
            ...publicResponse,
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
    required String? taskId,
    required int? runBoundary,
    required AiRequestPurpose originPurpose,
    required ModelCapability capability,
    required int estimatedInputTokens,
    required int estimatedOutputTokens,
    required int? inputTokens,
    required int? cachedTokens,
    required int? outputTokens,
    required bool exactUsage,
    required ReportedTokenUsage reportedUsage,
    required int latencyMs,
    required int retryCount,
    required String status,
    required String? failureType,
    required String? failureDetail,
  }) async {
    final hasValidReportedUsage = reportedUsage.complete && reportedUsage.valid;
    // 失败请求可能只上报了部分 usage：例如 Anthropic 协议下 cached/written 缺失时
    // `inputTokens` 为 null，但 `uncachedInputTokens`（不含缓存的已知输入）仍在。
    // 此时不能用 0 覆盖已知消耗——否则预算只记了输出那点零头，下一请求不会被
    // 硬预算阻断。保留已知输入的下界，宁可略低估也不能丢光。
    final effectiveInput = reportedUsage.valid && inputTokens != null
        ? inputTokens
        : status == 'success'
            ? estimatedInputTokens
            : reportedUsage.valid
                ? (reportedUsage.uncachedInputTokens ?? 0)
                : 0;
    final effectiveCached = reportedUsage.valid ? cachedTokens ?? 0 : 0;
    final effectiveOutput = reportedUsage.valid && outputTokens != null
        ? outputTokens
        : status == 'success'
            ? estimatedOutputTokens
            : 0;
    int? cost;
    final price = capability.price;
    if (price != null &&
        (reportedUsage.cacheWriteTokens ?? 0) == 0 &&
        (status == 'success' || hasValidReportedUsage)) {
      cost = price.estimateMicros(
        inputTokens: effectiveInput,
        cachedInputTokens: effectiveCached,
        outputTokens: effectiveOutput,
      );
    }
    // Persist unknown failures too: bounded diagnostic retention must not make
    // an incomplete task total silently look complete later.
    await store.addLedgerEntry(UsageLedgerEntry(
      requestId: requestId,
      rootRequestId: rootRequestId,
      timestamp: clock(),
      provider: provider.name,
      model: model,
      characterId: characterId,
      conversationId: conversationId,
      taskId: taskId,
      runBoundary: runBoundary,
      purpose: purpose,
      originPurpose: originPurpose,
      inputTokens: effectiveInput,
      cachedInputTokens: effectiveCached,
      outputTokens: effectiveOutput,
      estimatedCostMicros: cost,
      budgetCostMicros: cost ??
          price?.estimateMicros(
            inputTokens: effectiveInput +
                (reportedUsage.valid ? reportedUsage.cacheWriteTokens ?? 0 : 0),
            cachedInputTokens: 0,
            outputTokens: effectiveOutput,
          ),
      currency: price?.currency,
      priceVersion: price?.version,
      exactUsage: exactUsage && hasValidReportedUsage,
      reportedUsage: reportedUsage,
      status: status,
    ));
    await store.addDiagnostic(AiRequestDiagnostic(
      requestId: requestId,
      rootRequestId: rootRequestId,
      timestamp: clock(),
      purpose: purpose,
      provider: provider.name,
      model: model,
      taskId: taskId,
      runBoundary: runBoundary,
      latencyMs: latencyMs,
      retryCount: retryCount,
      inputTokens: status == 'success'
          ? effectiveInput
          : hasValidReportedUsage
              ? inputTokens
              : null,
      cachedInputTokens: status == 'success'
          ? effectiveCached
          : hasValidReportedUsage
              ? cachedTokens
              : null,
      outputTokens: status == 'success'
          ? effectiveOutput
          : hasValidReportedUsage
              ? outputTokens
              : null,
      estimatedCostMicros:
          status == 'success' || hasValidReportedUsage ? cost : null,
      currency:
          status == 'success' || hasValidReportedUsage ? price?.currency : null,
      exactUsage: status == 'success'
          ? exactUsage && hasValidReportedUsage
          : hasValidReportedUsage,
      reportedUsage: reportedUsage,
      status: status,
      failureType: failureType,
      failureDetail: failureDetail,
    ));
  }

  Future<void> _recordBlocked({
    String? requestId,
    required String rootRequestId,
    required ApiProvider provider,
    required String model,
    required AiRequestPurpose purpose,
    required String? taskId,
    required int? runBoundary,
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
      taskId: taskId,
      runBoundary: runBoundary,
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

/// Nested compatibility fallbacks are distinct billable attempts, not repeated usage frames.
List<Map<String, dynamic>> _transportUsageAttempts(
    Map<String, dynamic> result) {
  final attempts = result['usageAttempts'];
  if (attempts is! List) return [result];
  return [
    for (final attempt in attempts.whereType<Map>())
      ..._transportUsageAttempts(Map<String, dynamic>.from(attempt))
  ];
}
