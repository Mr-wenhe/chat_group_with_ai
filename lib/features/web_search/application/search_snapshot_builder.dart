import 'package:crypto/crypto.dart';
import 'dart:convert';

import '../models/search_models.dart';
import '../providers/search_provider.dart';
import '../providers/search_provider_http_support.dart';

/// Converts provider items into the stable, citation-facing search snapshot.
///
/// Deduplication happens before source IDs are assigned so a source ID never
/// points at a result that was removed later in the pipeline.
class SearchSnapshotBuilder {
  static const int maxSourcesPerHost = 2;

  const SearchSnapshotBuilder();

  WebSearchSnapshot build({
    required SearchRequest request,
    required String provider,
    required SearchProviderResponse response,
    required DateTime searchedAt,
    required int latencyMs,
    int retryCount = 0,
    bool fromCache = false,
    bool degraded = false,
  }) {
    final results = <WebSearchResult>[];
    final seenUrls = <String>{};
    final hostCounts = <String, int>{};

    for (final item in response.items) {
      if (!item.hasSourceUrl && provider.trim() != 'zhipu-native') continue;
      if (item.allowInsecureHttp) {
        // No active route supports HTTP evidence. Drop provider-supplied
        // legacy metadata rather than aborting the whole search turn.
        continue;
      }
      final canonicalUrl = !item.hasSourceUrl
          ? 'content:${_hash('${item.title}\n${item.snippet}')}'
          : _canonicalUrl(item.url);
      if (!seenUrls.add(canonicalUrl)) continue;
      final host = item.hasSourceUrl ? item.url.host.toLowerCase() : null;
      final hostCount = host == null ? 0 : hostCounts[host] ?? 0;
      if (host != null && hostCount >= maxSourcesPerHost) continue;
      if (results.length >= request.maxResults) break;
      if (host != null) hostCounts[host] = hostCount + 1;
      results.add(
        WebSearchResult(
          sourceId: 'S${results.length + 1}',
          title: item.title,
          snippet: item.snippet,
          url: item.hasSourceUrl ? item.url : null,
          displayHost: item.hasSourceUrl ? item.url.host : '智谱搜索',
          publishedAt: item.publishedAt,
          providerScore: item.providerScore,
          provider: provider,
          language: item.language,
          allowInsecureHttp: false,
        ),
      );
    }

    final failure = response.failure;
    final safeFailure = failure == null
        ? null
        : buildSearchFailure(
            type: failure.type,
            statusCode: failure.statusCode ?? response.statusCode,
            providerRequestId: safeProviderRequestId(failure.providerRequestId),
          );
    return WebSearchSnapshot(
      requestId: request.requestId,
      rootRequestId: request.rootRequestId,
      originalTextHash: request.originalTextHash ?? _hash(request.query),
      executedQueries: [request.query],
      searchedAt: searchedAt,
      provider: provider,
      results: results,
      failure: safeFailure,
      statusCode: response.statusCode,
      fromCache: fromCache,
      degraded: degraded,
      latencyMs: latencyMs,
      retryCount: retryCount,
    );
  }
}

String _canonicalUrl(Uri url) {
  final normalizedPath = url.path == '/' ? '' : url.path;
  return url
      .replace(
        scheme: url.scheme.toLowerCase(),
        host: url.host.toLowerCase(),
        path: normalizedPath,
        fragment: '',
      )
      .toString();
}

String _hash(String value) =>
    sha256.convert(utf8.encode(value.trim())).toString();
