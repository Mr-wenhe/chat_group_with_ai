part of 'search_models.dart';

class WebSearchResult {
  final String sourceId;
  final String title;
  final String snippet;
  final Uri url;
  final String displayHost;
  final DateTime? publishedAt;
  final double? providerScore;
  final String provider;
  final String? language;

  /// True only for the visible-browser fallback, which supports public HTTP
  /// pages in addition to HTTPS. Persist this bit so a restored snapshot can
  /// be validated with the same policy as the live result.
  final bool allowInsecureHttp;

  WebSearchResult({
    required String sourceId,
    required String title,
    required String snippet,
    required Uri url,
    String? displayHost,
    this.publishedAt,
    double? providerScore,
    required String provider,
    String? language,
    bool allowInsecureHttp = false,
  })  : sourceId = _requiredText(sourceId, 'sourceId'),
        title = sanitizeSearchText(
          title,
          maxLength: searchTitleMaxLength,
          fallback: '搜索结果',
          redactSecrets: true,
          redactOpaqueTokens: true,
        ),
        snippet = sanitizeSearchText(
          snippet,
          maxLength: searchSnippetMaxLength,
          redactSecrets: true,
          redactOpaqueTokens: true,
        ),
        // Only the explicit visible-browser provider may carry a public HTTP
        // result.  Keep the policy tied to the normalized provider identity
        // so a custom/provider route cannot opt into insecure evidence merely
        // by setting a boolean flag.
        allowInsecureHttp =
            allowInsecureHttp && provider.trim() == 'visibleBrowser',
        url = validateSearchUrl(
          url,
          allowInsecureHttp:
              allowInsecureHttp && provider.trim() == 'visibleBrowser',
        ),
        displayHost = _deriveDisplayHost(url, displayHost),
        providerScore = _finiteScore(providerScore),
        provider = sanitizeSearchText(
          provider,
          maxLength: searchProviderNameMaxLength,
          fallback: 'unknown',
        ),
        language = normalizeSearchLanguage(language);

  Map<String, dynamic> toMap() => {
        'sourceId': sourceId,
        'title': title,
        'snippet': snippet,
        'url': url.toString(),
        'publishedAt': publishedAt?.toUtc().toIso8601String(),
        'providerScore': providerScore,
        'provider': provider,
        'language': language,
        if (allowInsecureHttp) 'allowInsecureHttp': true,
      };
}

class WebSearchSnapshot {
  final String requestId;
  final String rootRequestId;
  final String originalTextHash;
  final List<String> executedQueries;
  final DateTime searchedAt;
  final String provider;
  final List<WebSearchResult> results;
  final SearchFailure? failure;
  final int? statusCode;
  final bool fromCache;
  final bool degraded;
  final int latencyMs;
  final int retryCount;

  WebSearchSnapshot({
    String requestId = '',
    String rootRequestId = '',
    String originalTextHash = '',
    Iterable<String> executedQueries = const [],
    required this.searchedAt,
    required String provider,
    required Iterable<WebSearchResult> results,
    this.failure,
    this.statusCode,
    this.fromCache = false,
    this.degraded = false,
    int latencyMs = 0,
    int retryCount = 0,
  })  : requestId = normalizeSearchCorrelationId(requestId),
        rootRequestId = normalizeSearchCorrelationId(rootRequestId),
        originalTextHash = _normalizeSnapshotHash(originalTextHash),
        executedQueries = List.unmodifiable(
          executedQueries
              .take(searchMaxExecutedQueries)
              .map(
                (query) => sanitizeSearchText(
                  query,
                  maxLength: searchQueryMaxLength,
                  redactSecrets: true,
                  redactOpaqueTokens: true,
                ),
              )
              .where((query) => query.isNotEmpty),
        ),
        provider = sanitizeSearchText(
          provider,
          maxLength: searchProviderNameMaxLength,
          fallback: 'unknown',
        ),
        results = List.unmodifiable(results.take(searchMaxResultsLimit)),
        latencyMs = latencyMs < 0 ? 0 : latencyMs,
        retryCount = retryCount < 0 ? 0 : retryCount;

  WebSearchSnapshot copyWith({
    String? requestId,
    String? rootRequestId,
    String? originalTextHash,
    Iterable<String>? executedQueries,
    DateTime? searchedAt,
    String? provider,
    Iterable<WebSearchResult>? results,
    SearchFailure? failure,
    bool clearFailure = false,
    int? statusCode,
    bool? fromCache,
    bool? degraded,
    int? latencyMs,
    int? retryCount,
  }) {
    return WebSearchSnapshot(
      requestId: requestId ?? this.requestId,
      rootRequestId: rootRequestId ?? this.rootRequestId,
      originalTextHash: originalTextHash ?? this.originalTextHash,
      executedQueries: executedQueries ?? this.executedQueries,
      searchedAt: searchedAt ?? this.searchedAt,
      provider: provider ?? this.provider,
      results: results ?? this.results,
      failure: clearFailure ? null : failure ?? this.failure,
      statusCode: statusCode ?? this.statusCode,
      fromCache: fromCache ?? this.fromCache,
      degraded: degraded ?? this.degraded,
      latencyMs: latencyMs ?? this.latencyMs,
      retryCount: retryCount ?? this.retryCount,
    );
  }

  bool get hasResults => results.isNotEmpty;

  /// noResults is a terminal business state, not a transport failure.
  bool get hasFailure => failure != null && !failure!.isNoResults;

  bool get hasNoResults => results.isEmpty;

  int get sourceCount => results.length;

  Map<String, dynamic> toMap() => {
        'requestId': requestId,
        'rootRequestId': rootRequestId,
        'originalTextHash': originalTextHash,
        'executedQueries': executedQueries,
        'searchedAt': searchedAt.toUtc().toIso8601String(),
        'provider': provider,
        'results': results.map((result) => result.toMap()).toList(),
        if (failure != null)
          'failure': {
            'type': failure!.type.name,
            'safeMessage': failure!.safeMessage,
            'statusCode': failure!.statusCode,
            'retryable': failure!.retryable,
            'providerRequestId': failure!.providerRequestId,
          },
        'statusCode': statusCode,
        'fromCache': fromCache,
        'degraded': degraded,
        'latencyMs': latencyMs,
        'retryCount': retryCount,
      };

  static WebSearchSnapshot? fromMap(Map<dynamic, dynamic> map) {
    try {
      final searchedAt = DateTime.tryParse(map['searchedAt']?.toString() ?? '');
      if (searchedAt == null) return null;
      final results = <WebSearchResult>[];
      final rawResults =
          map['results'] is List ? map['results'] as List : const [];
      var scannedResults = 0;
      for (final raw in rawResults) {
        if (scannedResults++ >= searchMaxResultsLimit) break;
        if (raw is! Map) continue;
        final url = Uri.tryParse(raw['url']?.toString() ?? '');
        if (url == null) continue;
        try {
          final provider = raw['provider']?.toString() ?? '';
          // Do not let arbitrary persisted providers opt into HTTP. The flag
          // is accepted only for the internal visible-browser provider.
          final allowInsecureHttp =
              provider == 'visibleBrowser' && raw['allowInsecureHttp'] == true;
          results.add(
            WebSearchResult(
              sourceId: raw['sourceId']?.toString() ?? '',
              title: raw['title']?.toString() ?? '',
              snippet: raw['snippet']?.toString() ?? '',
              url: url,
              publishedAt: DateTime.tryParse(
                raw['publishedAt']?.toString() ?? '',
              ),
              providerScore: raw['providerScore'] is num
                  ? (raw['providerScore'] as num).toDouble()
                  : null,
              provider: provider,
              language: raw['language']?.toString(),
              allowInsecureHttp: allowInsecureHttp,
            ),
          );
        } on ArgumentError {
          continue;
        }
      }
      final failureMap = map['failure'];
      SearchFailure? failure;
      if (failureMap is Map) {
        final typeName = failureMap['type']?.toString();
        SearchFailureType? type;
        for (final candidate in SearchFailureType.values) {
          if (candidate.name == typeName) {
            type = candidate;
            break;
          }
        }
        if (type != null) {
          failure = SearchFailure(
            type: type,
            // Rebuild presentation and retry policy from the enum. Persisted
            // maps are untrusted and must not smuggle provider text or a
            // caller-controlled retry flag into a portable message backup.
            safeMessage: safeMessageForSearchFailure(type),
            statusCode: (failureMap['statusCode'] as num?)?.toInt(),
            retryable: searchFailureIsRetryable(type),
            providerRequestId: _normalizedRestoredRequestId(
              failureMap['providerRequestId']?.toString(),
            ),
          );
        }
      }
      return WebSearchSnapshot(
        requestId: map['requestId']?.toString() ?? '',
        rootRequestId: map['rootRequestId']?.toString() ?? '',
        originalTextHash: map['originalTextHash']?.toString() ?? '',
        executedQueries: (map['executedQueries'] as List? ?? const [])
            .take(searchMaxExecutedQueries)
            .map((query) => query.toString()),
        searchedAt: searchedAt,
        provider: map['provider']?.toString() ?? '',
        results: results,
        failure: failure,
        statusCode: (map['statusCode'] as num?)?.toInt(),
        fromCache: map['fromCache'] == true,
        degraded: map['degraded'] == true,
        latencyMs: (map['latencyMs'] as num?)?.toInt() ?? 0,
        retryCount: (map['retryCount'] as num?)?.toInt() ?? 0,
      );
    } on Object {
      return null;
    }
  }

  static String? _normalizedRestoredRequestId(String? value) {
    final normalized = normalizeSearchCorrelationId(value);
    return normalized.isEmpty ? null : normalized;
  }
}
