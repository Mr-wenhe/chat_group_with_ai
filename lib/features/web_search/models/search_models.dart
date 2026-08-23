import 'search_failure.dart';

// Brave rejects queries longer than 400 characters. Keeping the shared
// request model within that provider limit prevents later coordinators from
// sending an otherwise valid SearchRequest that the HTTP adapter cannot use.
const int searchQueryMaxLength = 400;
const int searchTitleMaxLength = 300;
const int searchSnippetMaxLength = 800;
const int searchProviderNameMaxLength = 120;
const int searchDefaultMaxResults = 5;
const int searchMaxResultsLimit = 20;

enum SearchProviderKind {
  gateway,
  tavily,
  brave,
  duckDuckGoInstantAnswer,
}

enum SearchCategory {
  general,
  news,
  weather,
  finance,
  software,
  policy,
  academic,
  local,
}

enum SearchFreshness {
  any,
  day,
  week,
  month,
  year,
}

class SearchRequest {
  final String requestId;
  final String rootRequestId;
  final String sourceMessageId;
  final String turnId;
  final String query;
  final String? originalTextHash;
  final SearchCategory category;
  final SearchFreshness freshness;
  final String locale;
  final String? country;
  final int maxResults;
  final bool safeSearch;
  final bool forceRefresh;
  final bool isSensitive;

  SearchRequest({
    this.requestId = '',
    this.rootRequestId = '',
    String? sourceMessageId,
    this.turnId = '',
    required String query,
    String? originalTextHash,
    this.category = SearchCategory.general,
    this.freshness = SearchFreshness.any,
    String locale = 'zh-CN',
    String? country,
    int maxResults = searchDefaultMaxResults,
    this.safeSearch = true,
    this.forceRefresh = false,
    this.isSensitive = false,
  })  : query = sanitizeSearchText(query, maxLength: searchQueryMaxLength),
        sourceMessageId = sourceMessageId?.trim() ?? '',
        originalTextHash = _normalizeHash(originalTextHash),
        locale = locale.trim().isEmpty ? 'zh-CN' : locale.trim(),
        country = _normalizeOptionalText(country),
        maxResults = _validateMaxResults(maxResults);

  SearchRequest copyWith({
    String? requestId,
    String? rootRequestId,
    String? sourceMessageId,
    String? turnId,
    String? query,
    String? originalTextHash,
    SearchCategory? category,
    SearchFreshness? freshness,
    String? locale,
    String? country,
    int? maxResults,
    bool? safeSearch,
    bool? forceRefresh,
    bool? isSensitive,
  }) {
    return SearchRequest(
      requestId: requestId ?? this.requestId,
      rootRequestId: rootRequestId ?? this.rootRequestId,
      sourceMessageId: sourceMessageId ?? this.sourceMessageId,
      turnId: turnId ?? this.turnId,
      query: query ?? this.query,
      originalTextHash: originalTextHash ?? this.originalTextHash,
      category: category ?? this.category,
      freshness: freshness ?? this.freshness,
      locale: locale ?? this.locale,
      country: country ?? this.country,
      maxResults: maxResults ?? this.maxResults,
      safeSearch: safeSearch ?? this.safeSearch,
      forceRefresh: forceRefresh ?? this.forceRefresh,
      isSensitive: isSensitive ?? this.isSensitive,
    );
  }
}

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
  })  : sourceId = _requiredText(sourceId, 'sourceId'),
        title = sanitizeSearchText(
          title,
          maxLength: searchTitleMaxLength,
          fallback: '搜索结果',
        ),
        snippet = sanitizeSearchText(
          snippet,
          maxLength: searchSnippetMaxLength,
        ),
        url = validateSearchUrl(url),
        displayHost = _deriveDisplayHost(url, displayHost),
        providerScore = _finiteScore(providerScore),
        provider = sanitizeSearchText(
          provider,
          maxLength: searchProviderNameMaxLength,
          fallback: 'unknown',
        ),
        language = _normalizeOptionalText(language);
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
    this.requestId = '',
    this.rootRequestId = '',
    this.originalTextHash = '',
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
  })  : executedQueries = List.unmodifiable(
          executedQueries
              .map((query) => query.trim())
              .where((query) => query.isNotEmpty),
        ),
        provider = sanitizeSearchText(
          provider,
          maxLength: searchProviderNameMaxLength,
          fallback: 'unknown',
        ),
        results = List.unmodifiable(results),
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
}

Uri validateSearchUrl(Uri url) {
  final scheme = url.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') || url.host.trim().isEmpty) {
    throw ArgumentError.value(
        url, 'url', 'Only absolute http/https URLs are supported');
  }
  return url;
}

int _validateMaxResults(int value) {
  if (value <= 0 || value > searchMaxResultsLimit) {
    throw ArgumentError.value(
      value,
      'maxResults',
      'Must be between 1 and $searchMaxResultsLimit',
    );
  }
  return value;
}

String _requiredText(String value, String fieldName) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, fieldName, 'Must not be empty');
  }
  return normalized;
}

String sanitizeSearchText(
  String value, {
  required int maxLength,
  String? fallback,
}) {
  final normalized = value
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return fallback ?? '';
  if (normalized.length <= maxLength) return normalized;
  return normalized.substring(0, maxLength).trimRight();
}

String? _normalizeHash(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (!RegExp(r'^[a-f0-9]{64}$', caseSensitive: false).hasMatch(normalized)) {
    throw ArgumentError.value(value, 'originalTextHash', 'Must be SHA-256');
  }
  return normalized.toLowerCase();
}

String? _normalizeOptionalText(String? value) {
  if (value == null) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

double? _finiteScore(double? value) => value?.isFinite == true ? value : null;

String _deriveDisplayHost(Uri url, String? _) => url.host;
