import 'search_failure.dart';
import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';
import '../security/search_endpoint_validator.dart';
import '../security/search_secret_scanner.dart';

part 'search_snapshot_models.dart';

// Brave rejects queries longer than 400 characters. Keeping the shared
// request model within that provider limit prevents later coordinators from
// sending an otherwise valid SearchRequest that the HTTP adapter cannot use.
const int searchQueryMaxLength = 400;
const int searchTitleMaxLength = 300;
const int searchSnippetMaxLength = 800;
const int searchUrlMaxLength = 2048;
const int searchProviderNameMaxLength = 120;
const int searchLanguageMaxLength = 64;
const int searchDefaultMaxResults = 5;
const int searchMaxResultsLimit = 20;
const int searchMaxExecutedQueries = 5;
const int searchLocaleMaxLength = 16;
const int searchCountryMaxLength = 2;

final RegExp _searchLocalePattern =
    RegExp(r'^[A-Za-z]{2,3}(?:-[A-Za-z]{2,4})?$');
final RegExp _searchCountryPattern = RegExp(r'^[A-Za-z]{2}$');

enum SearchProviderKind {
  gateway,
  tavily,
  brave,
  duckDuckGoInstantAnswer,
  keylessHtml,
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
    String requestId = '',
    String rootRequestId = '',
    String? sourceMessageId,
    String turnId = '',
    required String query,
    String? originalTextHash,
    this.category = SearchCategory.general,
    this.freshness = SearchFreshness.any,
    String locale = 'zh-CN',
    String? country,
    int maxResults = searchDefaultMaxResults,
    this.safeSearch = true,
    this.forceRefresh = false,
    bool isSensitive = false,
  })  : requestId = normalizeSearchCorrelationId(requestId),
        rootRequestId = normalizeSearchCorrelationId(rootRequestId),
        sourceMessageId = normalizeSearchCorrelationId(sourceMessageId),
        turnId = normalizeSearchCorrelationId(turnId),
        isSensitive = isSensitive ||
            const SearchSecretScanner()
                .containsSensitiveData(query, includeOpaqueTokens: true),
        query = _sanitizeRequestQuery(query),
        originalTextHash = _normalizeHash(originalTextHash),
        locale = normalizeSearchLocale(locale),
        country = normalizeSearchCountry(country),
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

Uri validateSearchUrl(Uri url, {bool allowInsecureHttp = false}) {
  final scheme = url.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') ||
      (!allowInsecureHttp && scheme != 'https') ||
      url.host.trim().isEmpty ||
      url.userInfo.isNotEmpty ||
      SearchEndpointValidator.isPrivateOrLocalHost(url.host) ||
      _containsSensitiveUrlData(url)) {
    throw ArgumentError.value(
        url, 'url', 'Only absolute HTTPS URLs are supported');
  }
  // Fragments are not sent to the server and are not useful as evidence. Do
  // not carry an untrusted fragment into the prompt or external opener.
  final normalized = url.replace(
    scheme: scheme,
    fragment: null,
  );
  if (normalized.toString().length > searchUrlMaxLength) {
    throw ArgumentError.value(
      url,
      'url',
      'Search URLs must not exceed $searchUrlMaxLength characters',
    );
  }
  return normalized;
}

Uri? tryValidateSearchUrl(Uri? url, {bool allowInsecureHttp = false}) {
  if (url == null) return null;
  try {
    return validateSearchUrl(url, allowInsecureHttp: allowInsecureHttp);
  } on ArgumentError {
    return null;
  }
}

bool _containsSensitiveUrlData(Uri url) {
  const scanner = SearchSecretScanner();
  if (scanner.containsSensitiveData(url.host, includeOpaqueTokens: true) ||
      scanner.containsSensitiveData(url.path, includeOpaqueTokens: true) ||
      scanner.containsSensitiveData(url.fragment, includeOpaqueTokens: true)) {
    return true;
  }
  for (final parameter in url.queryParameters.entries) {
    if (scanner.isSensitiveParameter(parameter.key) ||
        scanner.containsSensitiveData(
          parameter.value,
          includeOpaqueTokens: true,
        )) {
      return true;
    }
  }
  return false;
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
  bool redactSecrets = false,
  bool redactOpaqueTokens = false,
}) {
  final normalized = value
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final secretSafe = redactSecrets
      ? const SearchSecretScanner().redact(
          normalized,
          includeOpaqueTokens: redactOpaqueTokens,
        )
      : normalized;
  if (secretSafe.isEmpty) return fallback ?? '';
  if (secretSafe.length <= maxLength) return secretSafe;
  return secretSafe.substring(0, maxLength).trimRight();
}

String _sanitizeRequestQuery(String value) {
  final redacted = sanitizeSearchText(
    value,
    maxLength: searchQueryMaxLength,
    redactSecrets: true,
    redactOpaqueTokens: true,
  );
  return redacted
      .replaceAll(SearchSecretScanner.redaction, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String? _normalizeHash(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (!RegExp(r'^[a-f0-9]{64}$', caseSensitive: false).hasMatch(normalized)) {
    throw ArgumentError.value(value, 'originalTextHash', 'Must be SHA-256');
  }
  return normalized.toLowerCase();
}

/// Snapshots can be restored from older or user-edited message maps. Invalid
/// hashes are discarded instead of rejecting an otherwise usable snapshot.
String _normalizeSnapshotHash(String value) {
  try {
    return _normalizeHash(value) ?? '';
  } on ArgumentError {
    return '';
  }
}

/// Provider language metadata is untrusted display/snapshot data. Keep it
/// bounded just like titles and snippets before it reaches persistence or a
/// prompt, while preserving the provider's original language syntax.
String? normalizeSearchLanguage(String? value) {
  if (value == null) return null;
  final normalized = sanitizeSearchText(
    value,
    maxLength: searchLanguageMaxLength,
    redactSecrets: true,
    redactOpaqueTokens: true,
  );
  return normalized.isEmpty ? null : normalized;
}

/// Applies the same bounded BCP-47 subset to every request boundary. Provider
/// adapters must never receive arbitrary locale text from direct callers.
String normalizeSearchLocale(String? value) {
  final normalized = value?.trim() ?? '';
  if (normalized.length > searchLocaleMaxLength ||
      !_searchLocalePattern.hasMatch(normalized)) {
    return 'zh-CN';
  }
  final parts = normalized.split('-');
  return parts.length == 1
      ? parts.single.toLowerCase()
      : '${parts.first.toLowerCase()}-${parts.last.toUpperCase()}';
}

/// Normalizes an optional ISO-3166 alpha-2 country code, dropping malformed
/// values instead of allowing a provider-specific interpretation.
String? normalizeSearchCountry(String? value) {
  final normalized = value?.trim() ?? '';
  if (normalized.length != searchCountryMaxLength ||
      !_searchCountryPattern.hasMatch(normalized)) {
    return null;
  }
  return normalized.toUpperCase();
}

/// Correlation identifiers are operational metadata, but callers may derive
/// them from user-controlled IDs. Keep them bounded and opaque-looking so a
/// malformed value cannot become a log, status, or audit exfiltration path.
String normalizeSearchCorrelationId(String? value) {
  final normalized = value?.trim() ?? '';
  if (normalized.isEmpty || normalized.length > 128) return '';
  if (const SearchSecretScanner().containsSensitiveData(normalized)) return '';
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$').hasMatch(normalized)
      ? normalized
      : '';
}

double? _finiteScore(double? value) => value?.isFinite == true ? value : null;

String _deriveDisplayHost(Uri url, String? _) => url.host;
