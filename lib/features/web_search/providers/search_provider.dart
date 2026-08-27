import 'package:dio/dio.dart';

import '../models/search_failure.dart';
import '../models/search_models.dart';

/// Provider-normalized item before source IDs and final result ordering exist.
class SearchProviderItem {
  final String title;
  final String snippet;
  final Uri url;
  final DateTime? publishedAt;
  final double? providerScore;
  final String? language;

  SearchProviderItem({
    required String title,
    required String snippet,
    required Uri url,
    this.publishedAt,
    double? providerScore,
    String? language,
  })  : title = sanitizeSearchText(
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
        url = validateSearchUrl(url),
        providerScore = providerScore?.isFinite == true ? providerScore : null,
        language = normalizeSearchLanguage(language);
}

/// Provider output deliberately contains normalized fields only, never raw
/// response JSON.
class SearchProviderResponse {
  final List<SearchProviderItem> items;
  final String? providerRequestId;

  /// Provider selected by a gateway or native adapter. This is deliberately
  /// metadata only; source evidence is always represented by [items].
  final String? sourceProvider;
  final String? correctedQuery;
  final bool moreResultsAvailable;
  final bool fromCache;
  final bool degraded;

  /// Stops the provider chain from sending a configuration or cancellation
  /// failure to another provider where it would be silently hidden.
  final bool terminal;
  final SearchFailure? failure;
  final int? statusCode;

  SearchProviderResponse({
    required Iterable<SearchProviderItem> items,
    this.providerRequestId,
    this.sourceProvider,
    this.correctedQuery,
    this.moreResultsAvailable = false,
    this.fromCache = false,
    this.degraded = false,
    this.terminal = false,
    this.failure,
    this.statusCode,
  }) : items = List.unmodifiable(items);

  bool get hasResults => items.isNotEmpty;
}

/// Browser builds do not dispatch search requests. Dio's Web adapter can
/// materialize a complete XHR response before application-level byte limits
/// run, so every concrete provider has the same terminal failure boundary in
/// addition to the runtime route/configuration gates.
SearchProviderResponse webSearchUnsupportedResponse() {
  return SearchProviderResponse(
    items: const [],
    terminal: true,
    failure: const SearchFailure(
      type: SearchFailureType.invalidConfiguration,
      safeMessage: 'Web 端不支持联网搜索',
      retryable: false,
    ),
  );
}

class SearchHealthResult {
  /// Correlates a health probe with transport diagnostics without exposing
  /// the probe query or response body.
  final String requestId;
  final bool isHealthy;
  final int latencyMs;
  final SearchFailure? failure;
  final String? providerRequestId;

  const SearchHealthResult({
    this.requestId = '',
    required this.isHealthy,
    this.latencyMs = 0,
    this.failure,
    this.providerRequestId,
  });
}

abstract interface class SearchProvider {
  SearchProviderKind get kind;

  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  });

  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  });
}
