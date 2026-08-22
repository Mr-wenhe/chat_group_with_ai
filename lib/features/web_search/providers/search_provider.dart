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
        ),
        snippet = sanitizeSearchText(
          snippet,
          maxLength: searchSnippetMaxLength,
        ),
        url = validateSearchUrl(url),
        providerScore = providerScore?.isFinite == true ? providerScore : null,
        language = language?.trim().isEmpty == true ? null : language?.trim();
}

/// Provider output deliberately contains normalized fields only, never raw
/// response JSON.
class SearchProviderResponse {
  final List<SearchProviderItem> items;
  final String? providerRequestId;
  final String? correctedQuery;
  final bool moreResultsAvailable;
  final SearchFailure? failure;
  final int? statusCode;

  SearchProviderResponse({
    required Iterable<SearchProviderItem> items,
    this.providerRequestId,
    this.correctedQuery,
    this.moreResultsAvailable = false,
    this.failure,
    this.statusCode,
  }) : items = List.unmodifiable(items);

  bool get hasResults => items.isNotEmpty;
}

class SearchHealthResult {
  final bool isHealthy;
  final int latencyMs;
  final SearchFailure? failure;
  final String? providerRequestId;

  const SearchHealthResult({
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
