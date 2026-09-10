export 'search_audit_entry.dart';

enum AiRequestPurpose {
  reply('普通回复'),
  autoChat('自动聊天'),
  proactive('主动消息'),
  summary('记忆摘要'),
  agent('工作任务'),
  searchPlanning('搜索查询规划'),
  retry('重试'),
  connectionTest('连接测试');

  final String label;
  const AiRequestPurpose(this.label);
}

enum WebSearchPolicy {
  off('关闭'),
  ask('询问'),
  auto('自动');

  final String label;
  const WebSearchPolicy(this.label);
}

class ModelPrice {
  final String currency;
  final int inputMicrosPerMillion;
  final int? cachedInputMicrosPerMillion;
  final int outputMicrosPerMillion;
  final String version;

  const ModelPrice({
    required this.currency,
    required this.inputMicrosPerMillion,
    this.cachedInputMicrosPerMillion,
    required this.outputMicrosPerMillion,
    required this.version,
  });

  int estimateMicros({
    required int inputTokens,
    required int cachedInputTokens,
    required int outputTokens,
  }) {
    final uncached = (inputTokens - cachedInputTokens).clamp(0, inputTokens);
    return _cost(uncached, inputMicrosPerMillion) +
        _cost(
          cachedInputTokens,
          cachedInputMicrosPerMillion ?? inputMicrosPerMillion,
        ) +
        _cost(outputTokens, outputMicrosPerMillion);
  }

  static int _cost(int tokens, int microsPerMillion) =>
      (tokens * microsPerMillion + 999999) ~/ 1000000;
}

class ModelCapability {
  final String provider;
  final String modelId;
  final bool isKnown;
  final bool supportsStreaming;
  final bool supportsVision;
  final bool supportsTools;

  /// True only when this exact model has a documented native web-search
  /// protocol that yields independently verifiable source URLs.
  final bool supportsNativeWebSearch;

  /// True only when the native protocol accepts the application's freshness
  /// parameter for this exact model.
  final bool supportsNativeWebSearchFreshness;
  final int contextWindow;
  final int maxOutput;
  final ModelPrice? price;
  final String source;
  final String version;
  final DateTime updatedAt;

  const ModelCapability({
    required this.provider,
    required this.modelId,
    required this.isKnown,
    required this.supportsStreaming,
    required this.supportsVision,
    required this.supportsTools,
    this.supportsNativeWebSearch = false,
    this.supportsNativeWebSearchFreshness = false,
    required this.contextWindow,
    required this.maxOutput,
    required this.price,
    required this.source,
    required this.version,
    required this.updatedAt,
  });
}

class CustomModelCapability {
  final bool supportsStreaming;
  final bool supportsVision;
  final bool supportsTools;

  /// Custom OpenAI-compatible endpoints are intentionally conservative: a
  /// user declaration cannot opt an unknown protocol into native search.
  final bool supportsNativeWebSearch;
  final int contextWindow;
  final int maxOutput;

  const CustomModelCapability({
    this.supportsStreaming = false,
    this.supportsVision = false,
    this.supportsTools = false,
    this.supportsNativeWebSearch = false,
    this.contextWindow = 8192,
    this.maxOutput = 2048,
  });

  CustomModelCapability copyWith({
    bool? supportsStreaming,
    bool? supportsVision,
    bool? supportsTools,
    bool? supportsNativeWebSearch,
    int? contextWindow,
    int? maxOutput,
  }) {
    return CustomModelCapability(
      supportsStreaming: supportsStreaming ?? this.supportsStreaming,
      supportsVision: supportsVision ?? this.supportsVision,
      supportsTools: supportsTools ?? this.supportsTools,
      supportsNativeWebSearch:
          supportsNativeWebSearch ?? this.supportsNativeWebSearch,
      contextWindow: contextWindow ?? this.contextWindow,
      maxOutput: maxOutput ?? this.maxOutput,
    );
  }

  factory CustomModelCapability.fromMap(Map<dynamic, dynamic> map) {
    return CustomModelCapability(
      supportsStreaming: map['supportsStreaming'] == true,
      supportsVision: map['supportsVision'] == true,
      supportsTools: map['supportsTools'] == true,
      // Do not deserialize a native-search opt-in. Native search is protocol
      // specific and must be registered by the application, not inferred from
      // arbitrary custom endpoint metadata.
      supportsNativeWebSearch: false,
      contextWindow: (map['contextWindow'] as num?)?.toInt() ?? 8192,
      maxOutput: (map['maxOutput'] as num?)?.toInt() ?? 2048,
    );
  }

  Map<String, dynamic> toMap() => {
        'supportsStreaming': supportsStreaming,
        'supportsVision': supportsVision,
        'supportsTools': supportsTools,
        'supportsNativeWebSearch': false,
        'contextWindow': contextWindow,
        'maxOutput': maxOutput,
      };
}

class BudgetSettings {
  final int? dailyHardLimitMicros;
  final int? monthlyHardLimitMicros;
  final int? conversationHardLimitMicros;
  final int? autoChatDailyHardLimitMicros;
  final int softThresholdPercent;
  final bool allowUserOverride;
  final bool autoChatEnabled;
  final bool proactiveEnabled;
  final bool summaryEnabled;

  const BudgetSettings({
    this.dailyHardLimitMicros,
    this.monthlyHardLimitMicros,
    this.conversationHardLimitMicros,
    this.autoChatDailyHardLimitMicros,
    this.softThresholdPercent = 80,
    this.allowUserOverride = false,
    this.autoChatEnabled = true,
    this.proactiveEnabled = true,
    this.summaryEnabled = true,
  });

  factory BudgetSettings.fromMap(Map<dynamic, dynamic> map) {
    int? positive(String key) {
      final value = (map[key] as num?)?.toInt();
      return value != null && value > 0 ? value : null;
    }

    return BudgetSettings(
      dailyHardLimitMicros: positive('dailyHardLimitMicros'),
      monthlyHardLimitMicros: positive('monthlyHardLimitMicros'),
      conversationHardLimitMicros: positive('conversationHardLimitMicros'),
      autoChatDailyHardLimitMicros: positive('autoChatDailyHardLimitMicros'),
      softThresholdPercent:
          ((map['softThresholdPercent'] as num?)?.toInt() ?? 80).clamp(1, 99),
      allowUserOverride: map['allowUserOverride'] == true,
      autoChatEnabled: map['autoChatEnabled'] != false,
      proactiveEnabled: map['proactiveEnabled'] != false,
      summaryEnabled: map['summaryEnabled'] != false,
    );
  }

  Map<String, dynamic> toMap() => {
        'dailyHardLimitMicros': dailyHardLimitMicros,
        'monthlyHardLimitMicros': monthlyHardLimitMicros,
        'conversationHardLimitMicros': conversationHardLimitMicros,
        'autoChatDailyHardLimitMicros': autoChatDailyHardLimitMicros,
        'softThresholdPercent': softThresholdPercent,
        'allowUserOverride': allowUserOverride,
        'autoChatEnabled': autoChatEnabled,
        'proactiveEnabled': proactiveEnabled,
        'summaryEnabled': summaryEnabled,
      };

  BudgetSettings copyWith({
    int? dailyHardLimitMicros,
    int? monthlyHardLimitMicros,
    int? conversationHardLimitMicros,
    int? autoChatDailyHardLimitMicros,
    int? softThresholdPercent,
    bool? allowUserOverride,
    bool? autoChatEnabled,
    bool? proactiveEnabled,
    bool? summaryEnabled,
    bool clearDaily = false,
    bool clearMonthly = false,
    bool clearConversation = false,
    bool clearAutoChat = false,
  }) {
    return BudgetSettings(
      dailyHardLimitMicros:
          clearDaily ? null : dailyHardLimitMicros ?? this.dailyHardLimitMicros,
      monthlyHardLimitMicros: clearMonthly
          ? null
          : monthlyHardLimitMicros ?? this.monthlyHardLimitMicros,
      conversationHardLimitMicros: clearConversation
          ? null
          : conversationHardLimitMicros ?? this.conversationHardLimitMicros,
      autoChatDailyHardLimitMicros: clearAutoChat
          ? null
          : autoChatDailyHardLimitMicros ?? this.autoChatDailyHardLimitMicros,
      softThresholdPercent: softThresholdPercent ?? this.softThresholdPercent,
      allowUserOverride: allowUserOverride ?? this.allowUserOverride,
      autoChatEnabled: autoChatEnabled ?? this.autoChatEnabled,
      proactiveEnabled: proactiveEnabled ?? this.proactiveEnabled,
      summaryEnabled: summaryEnabled ?? this.summaryEnabled,
    );
  }
}

class UsageLedgerEntry {
  final String requestId;
  final String rootRequestId;
  final DateTime timestamp;
  final String provider;
  final String model;
  final String characterId;
  final String conversationId;
  final AiRequestPurpose purpose;
  final AiRequestPurpose originPurpose;
  final int inputTokens;
  final int cachedInputTokens;
  final int outputTokens;
  final int? estimatedCostMicros;
  final String? currency;
  final String? priceVersion;
  final bool exactUsage;

  const UsageLedgerEntry({
    required this.requestId,
    required this.rootRequestId,
    required this.timestamp,
    required this.provider,
    required this.model,
    required this.characterId,
    required this.conversationId,
    required this.purpose,
    required this.originPurpose,
    required this.inputTokens,
    required this.cachedInputTokens,
    required this.outputTokens,
    required this.estimatedCostMicros,
    required this.currency,
    required this.priceVersion,
    required this.exactUsage,
  });

  factory UsageLedgerEntry.fromMap(Map<dynamic, dynamic> map) {
    final purposeName = map['purpose']?.toString();
    return UsageLedgerEntry(
      requestId: map['requestId']?.toString() ?? '',
      rootRequestId: map['rootRequestId']?.toString() ?? '',
      timestamp: DateTime.tryParse(map['timestamp']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      provider: map['provider']?.toString() ?? '',
      model: map['model']?.toString() ?? '',
      characterId: map['characterId']?.toString() ?? '',
      conversationId: map['conversationId']?.toString() ?? '',
      purpose: AiRequestPurpose.values.firstWhere(
        (value) => value.name == purposeName,
        orElse: () => AiRequestPurpose.reply,
      ),
      originPurpose: AiRequestPurpose.values.firstWhere(
        (value) => value.name == map['originPurpose']?.toString(),
        orElse: () => AiRequestPurpose.values.firstWhere(
          (value) => value.name == purposeName,
          orElse: () => AiRequestPurpose.reply,
        ),
      ),
      inputTokens: (map['inputTokens'] as num?)?.toInt() ?? 0,
      cachedInputTokens: (map['cachedInputTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (map['outputTokens'] as num?)?.toInt() ?? 0,
      estimatedCostMicros: (map['estimatedCostMicros'] as num?)?.toInt(),
      currency: map['currency']?.toString(),
      priceVersion: map['priceVersion']?.toString(),
      exactUsage: map['exactUsage'] == true,
    );
  }

  Map<String, dynamic> toMap() => {
        'requestId': requestId,
        'rootRequestId': rootRequestId,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'provider': provider,
        'model': model,
        'characterId': characterId,
        'conversationId': conversationId,
        'purpose': purpose.name,
        'originPurpose': originPurpose.name,
        'inputTokens': inputTokens,
        'cachedInputTokens': cachedInputTokens,
        'outputTokens': outputTokens,
        'estimatedCostMicros': estimatedCostMicros,
        'currency': currency,
        'priceVersion': priceVersion,
        'exactUsage': exactUsage,
      };
}

class UsageTotals {
  int inputTokens = 0;
  int cachedInputTokens = 0;
  int outputTokens = 0;
  int requestCount = 0;
  final Map<String, int> costMicrosByCurrency = {};

  void add(UsageLedgerEntry entry) {
    inputTokens += entry.inputTokens;
    cachedInputTokens += entry.cachedInputTokens;
    outputTokens += entry.outputTokens;
    requestCount++;
    final cost = entry.estimatedCostMicros;
    final currency = entry.currency;
    if (cost != null && currency != null) {
      costMicrosByCurrency[currency] =
          (costMicrosByCurrency[currency] ?? 0) + cost;
    }
  }
}

Map<String, UsageTotals> aggregateUsage(
  Iterable<UsageLedgerEntry> entries,
  String Function(UsageLedgerEntry entry) keyOf,
) {
  final totals = <String, UsageTotals>{};
  for (final entry in entries) {
    totals.putIfAbsent(keyOf(entry), UsageTotals.new).add(entry);
  }
  return totals;
}

class AiRequestDiagnostic {
  final String requestId;
  final String rootRequestId;
  final DateTime timestamp;
  final AiRequestPurpose purpose;
  final String provider;
  final String model;
  final int latencyMs;
  final int retryCount;
  final int? inputTokens;
  final int? cachedInputTokens;
  final int? outputTokens;
  final int? estimatedCostMicros;
  final String? currency;
  final String status;
  final String? failureType;

  const AiRequestDiagnostic({
    required this.requestId,
    required this.rootRequestId,
    required this.timestamp,
    required this.purpose,
    required this.provider,
    required this.model,
    required this.latencyMs,
    required this.retryCount,
    required this.inputTokens,
    required this.cachedInputTokens,
    required this.outputTokens,
    required this.estimatedCostMicros,
    required this.currency,
    required this.status,
    required this.failureType,
  });

  factory AiRequestDiagnostic.fromMap(Map<dynamic, dynamic> map) {
    final purposeName = map['purpose']?.toString();
    return AiRequestDiagnostic(
      requestId: map['requestId']?.toString() ?? '',
      rootRequestId: map['rootRequestId']?.toString() ?? '',
      timestamp: DateTime.tryParse(map['timestamp']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      purpose: AiRequestPurpose.values.firstWhere(
        (value) => value.name == purposeName,
        orElse: () => AiRequestPurpose.reply,
      ),
      provider: map['provider']?.toString() ?? '',
      model: map['model']?.toString() ?? '',
      latencyMs: (map['latencyMs'] as num?)?.toInt() ?? 0,
      retryCount: (map['retryCount'] as num?)?.toInt() ?? 0,
      inputTokens: (map['inputTokens'] as num?)?.toInt(),
      cachedInputTokens: (map['cachedInputTokens'] as num?)?.toInt(),
      outputTokens: (map['outputTokens'] as num?)?.toInt(),
      estimatedCostMicros: (map['estimatedCostMicros'] as num?)?.toInt(),
      currency: map['currency']?.toString(),
      status: map['status']?.toString() ?? 'unknown',
      failureType: map['failureType']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'requestId': requestId,
        'rootRequestId': rootRequestId,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'purpose': purpose.name,
        'provider': provider,
        'model': model,
        'latencyMs': latencyMs,
        'retryCount': retryCount,
        'inputTokens': inputTokens,
        'cachedInputTokens': cachedInputTokens,
        'outputTokens': outputTokens,
        'estimatedCostMicros': estimatedCostMicros,
        'currency': currency,
        'status': status,
        'failureType': failureType,
      };

  String toSafeText() => [
        'requestId=$requestId',
        'rootRequestId=$rootRequestId',
        'time=${timestamp.toUtc().toIso8601String()}',
        'purpose=${purpose.name}',
        'provider=$provider',
        'model=$model',
        'latencyMs=$latencyMs',
        'retryCount=$retryCount',
        'tokens=${inputTokens ?? '-'}+${outputTokens ?? '-'}',
        'cachedTokens=${cachedInputTokens ?? '-'}',
        'costMicros=${estimatedCostMicros ?? '-'}',
        'currency=${currency ?? '-'}',
        'status=$status',
        'failureType=${failureType ?? '-'}',
      ].join('\n');
}
