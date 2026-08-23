import 'package:dio/dio.dart';

import '../models/search_failure.dart';
import '../models/search_models.dart' as domain;
import '../providers/search_provider.dart';
import '../models/search_failure_factory.dart';
import 'search_failure_mapper.dart';
import 'search_provider_route.dart';
import 'search_retry_policy.dart';
import 'search_run_state.dart';
import 'search_snapshot_builder.dart';

/// Executes the ordered normalized Provider chain without knowing any
/// Provider-specific response JSON.
class SearchProviderChain {
  final List<SearchProviderRoute> _routes;
  final SearchRetryPolicy retryPolicy;
  final DateTime Function() _clock;

  SearchProviderChain({
    required Iterable<SearchProviderRoute> routes,
    required this.retryPolicy,
    DateTime Function()? clock,
  })  : _routes = List.unmodifiable(routes),
        _clock = clock ?? DateTime.now;

  String primaryProviderKey(domain.SearchRequest request) {
    final routes = _routesFor(request);
    return routes.isEmpty ? 'none' : routes.first.cacheKey;
  }

  Future<domain.WebSearchSnapshot> execute({
    required domain.SearchRequest request,
    required CancelToken? cancelToken,
    required SearchStatusListener? onStatus,
  }) async {
    final routes = _routesFor(request);
    final startedAt = _clock();
    final deadline = startedAt.add(retryPolicy.totalBudget);
    var retryCount = 0;
    domain.WebSearchSnapshot? lastSnapshot;

    if (routes.isEmpty) {
      return _failureSnapshot(
        request: request,
        provider: 'none',
        failure:
            buildSearchFailure(type: SearchFailureType.invalidConfiguration),
      );
    }

    for (var index = 0; index < routes.length; index++) {
      final route = routes[index];
      if (_isCancelled(cancelToken)) {
        return _cancelledSnapshot(request: request, provider: route.kind.name);
      }
      if (!_hasBudget(deadline)) break;

      _emit(
        onStatus,
        SearchRunStatus.searching,
        request: request,
        provider: route.kind.name,
        retryNumber: retryCount,
      );
      final attempt = await retryPolicy.execute<SearchProviderResponse>(
        operation: (_) => route.provider.search(
          request,
          credential: route.credential,
          cancelToken: cancelToken,
        ),
        shouldRetryResult: (response) => SearchRetryPolicy.isRetryableFailure(
          failure: response.failure,
          statusCode: response.statusCode,
        ),
        shouldRetryError: (error) =>
            !request.isSensitive && SearchRetryPolicy.isRetryableError(error),
        allowRetry: !request.isSensitive,
        maxRetriesOverride: (retryPolicy.maxRetries - retryCount)
            .clamp(0, retryPolicy.maxRetries)
            .toInt(),
        deadline: deadline,
        isCancelled: () => _isCancelled(cancelToken),
        onRetry: (retryNumber, delay) {
          _emit(
            onStatus,
            SearchRunStatus.retrying,
            request: request,
            provider: route.kind.name,
            retryNumber: retryNumber,
            retryDelay: delay,
          );
        },
      );
      retryCount += attempt.retryCount;

      if (attempt.error != null) {
        final failure = mapSearchFailure(attempt.error!);
        lastSnapshot = _failureSnapshot(
          request: request,
          provider: route.kind.name,
          failure: failure,
          retryCount: retryCount,
          degraded: index > 0,
          latencyMs: _elapsedMilliseconds(startedAt),
        );
        if (request.isSensitive ||
            failure.type == SearchFailureType.unsafeQuery ||
            failure.type == SearchFailureType.cancelled ||
            attempt.budgetExhausted ||
            attempt.error is SearchCancelledException) {
          return lastSnapshot;
        }
        continue;
      }

      final response = _normalizeResponse(attempt.requireValue);
      final snapshot = const SearchSnapshotBuilder().build(
        request: request,
        provider: route.kind.name,
        response: response,
        searchedAt: startedAt.toUtc(),
        retryCount: retryCount,
        degraded: index > 0,
        latencyMs: _elapsedMilliseconds(startedAt),
      );
      lastSnapshot = snapshot;

      if (response.items.isNotEmpty && response.failure == null) {
        return snapshot;
      }
      if (response.failure?.type == SearchFailureType.cancelled) {
        return snapshot;
      }
      // A sensitive request is allowed to make at most one external request.
      // A provider-side unsafe classification is also terminal; sending the
      // same text to another Provider would defeat the safety decision.
      if (request.isSensitive ||
          response.failure?.type == SearchFailureType.unsafeQuery) {
        return snapshot;
      }
      // An empty result is a business state, but another configured Provider
      // can still have useful coverage. If every route is empty, the last
      // snapshot remains noResults rather than becoming failed.
    }

    return lastSnapshot ??
        _failureSnapshot(
          request: request,
          provider: routes.last.kind.name,
          failure:
              buildSearchFailure(type: SearchFailureType.providerUnavailable),
          retryCount: retryCount,
          degraded: routes.length > 1,
          latencyMs: _elapsedMilliseconds(startedAt),
        );
  }

  List<SearchProviderRoute> _routesFor(domain.SearchRequest request) {
    final indexed = _routes
        .where((route) => route.enabled)
        .where(
          (route) =>
              route.kind != domain.SearchProviderKind.duckDuckGoInstantAnswer ||
              _isStableKnowledge(request),
        )
        .toList(growable: false)
        .asMap()
        .entries
        .toList();
    indexed.sort((left, right) {
      final a = left.value;
      final b = right.value;
      final aDuck = a.kind == domain.SearchProviderKind.duckDuckGoInstantAnswer;
      final bDuck = b.kind == domain.SearchProviderKind.duckDuckGoInstantAnswer;
      if (aDuck != bDuck) return aDuck ? 1 : -1;
      if (a.isPrimary != b.isPrimary) return a.isPrimary ? -1 : 1;
      if (a.isFallback != b.isFallback) return a.isFallback ? 1 : -1;
      final priority = a.priority.compareTo(b.priority);
      return priority == 0 ? left.key.compareTo(right.key) : priority;
    });
    return indexed.map((entry) => entry.value).toList(growable: false);
  }

  static bool _isStableKnowledge(domain.SearchRequest request) =>
      request.category == domain.SearchCategory.general &&
      request.freshness == domain.SearchFreshness.any;

  SearchProviderResponse _normalizeResponse(SearchProviderResponse response) {
    if (response.items.isNotEmpty || response.failure != null) return response;
    return SearchProviderResponse(
      items: const [],
      providerRequestId: response.providerRequestId,
      correctedQuery: response.correctedQuery,
      moreResultsAvailable: response.moreResultsAvailable,
      statusCode: response.statusCode,
      failure: buildSearchFailure(
        type: SearchFailureType.noResults,
        statusCode: response.statusCode,
        providerRequestId: response.providerRequestId,
      ),
    );
  }

  domain.WebSearchSnapshot _failureSnapshot({
    required domain.SearchRequest request,
    required String provider,
    required SearchFailure failure,
    int retryCount = 0,
    bool degraded = false,
    int latencyMs = 0,
  }) {
    return domain.WebSearchSnapshot(
      requestId: request.requestId,
      rootRequestId: request.rootRequestId,
      originalTextHash: request.originalTextHash ?? '',
      executedQueries: [request.query],
      searchedAt: _clock().toUtc(),
      provider: provider,
      results: const [],
      failure: failure,
      statusCode: failure.statusCode,
      retryCount: retryCount,
      degraded: degraded,
      latencyMs: latencyMs,
    );
  }

  domain.WebSearchSnapshot _cancelledSnapshot({
    required domain.SearchRequest request,
    required String provider,
  }) =>
      _failureSnapshot(
        request: request,
        provider: provider,
        failure: buildSearchFailure(type: SearchFailureType.cancelled),
      );

  void _emit(
    SearchStatusListener? listener,
    SearchRunStatus status, {
    required domain.SearchRequest request,
    required String provider,
    int retryNumber = 0,
    Duration? retryDelay,
  }) {
    listener?.call(
      SearchRunState(
        status,
        query: request.query,
        provider: provider,
        retryNumber: retryNumber,
        retryDelay: retryDelay,
      ),
    );
  }

  bool _isCancelled(CancelToken? token) => token?.isCancelled == true;

  bool _hasBudget(DateTime deadline) {
    final now = _clock();
    return now.isBefore(deadline);
  }

  int _elapsedMilliseconds(DateTime startedAt) {
    final elapsed = _clock().difference(startedAt).inMilliseconds;
    return elapsed < 0 ? 0 : elapsed;
  }
}
