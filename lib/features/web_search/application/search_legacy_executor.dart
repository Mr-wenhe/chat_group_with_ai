import 'package:dio/dio.dart';

import 'package:chat_group/services/web_search_service.dart' as legacy;

import '../models/search_failure.dart';
import '../models/search_failure_factory.dart';
import '../models/search_models.dart' as domain;
import 'search_failure_mapper.dart';
import 'search_retry_policy.dart';
import 'search_run_state.dart';
import 'search_turn_cache.dart';

/// Runs the pre-Stage-02 facade behind the same turn cache and retry policy.
/// It exists only for migration compatibility; new Providers use
/// [SearchProviderChain].
class SearchLegacyExecutor {
  final legacy.WebSearchServicePort service;
  final SearchTurnCache cache;
  final SearchRetryPolicy retryPolicy;
  final DateTime Function() _clock;

  SearchLegacyExecutor({
    required this.service,
    required this.cache,
    required this.retryPolicy,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  Future<legacy.WebSearchSnapshot> search({
    required domain.SearchRequest request,
    required CancelToken? cancelToken,
    required SearchStatusListener? onStatus,
  }) {
    if (request.category != domain.SearchCategory.general) {
      return Future<legacy.WebSearchSnapshot>.value(
        _unsupportedCategorySnapshot(request),
      );
    }
    final key = SearchTurnCacheKey.fromRequest(
      request: request,
      provider: legacy.WebSearchService.providerName,
    );
    return cache.getOrLoad<legacy.WebSearchSnapshot>(
      key: key,
      ttl: _ttlFor(request.category),
      forceRefresh: request.forceRefresh,
      loader: () => _searchWithRetry(
        request: request,
        cancelToken: cancelToken,
        onStatus: onStatus,
      ),
      shouldCache: (value) => !value.hasFailure,
      markFromCache: (value) => value.copyWith(fromCache: true),
    );
  }

  legacy.WebSearchSnapshot _unsupportedCategorySnapshot(
    domain.SearchRequest request,
  ) {
    final failure = buildSearchFailure(
      type: SearchFailureType.invalidConfiguration,
    );
    return legacy.WebSearchSnapshot(
      requestId: request.requestId,
      rootRequestId: request.rootRequestId,
      sourceMessageId: request.sourceMessageId,
      turnId: request.turnId,
      originalTextHash: request.originalTextHash ?? '',
      executedQueries: [request.query],
      query: request.query,
      searchedAt: _clock().toUtc(),
      provider: legacy.WebSearchService.providerName,
      results: const [],
      error: failure.safeMessage,
      failureType: failure.type,
      safeMessage: failure.safeMessage,
      statusCode: failure.statusCode,
    );
  }

  Future<legacy.WebSearchSnapshot> _searchWithRetry({
    required domain.SearchRequest request,
    required CancelToken? cancelToken,
    required SearchStatusListener? onStatus,
  }) async {
    final startedAt = _clock();
    final deadline = startedAt.add(retryPolicy.totalBudget);
    final attempt = await retryPolicy.execute<legacy.WebSearchSnapshot>(
      operation: (_) => service.search(
        request.query,
        cancelToken: cancelToken,
      ),
      shouldRetryResult: (snapshot) => SearchRetryPolicy.isRetryableFailure(
        failure: snapshot.failureType == null
            ? null
            : SearchFailure(
                type: snapshot.failureType!,
                safeMessage: snapshot.safeMessage ?? '',
                statusCode: snapshot.statusCode,
                retryable: false,
              ),
        statusCode: snapshot.statusCode,
      ),
      shouldRetryError: SearchRetryPolicy.isRetryableError,
      allowRetry: !request.isSensitive,
      deadline: deadline,
      isCancelled: () => cancelToken?.isCancelled == true,
      onRetry: (retryNumber, delay) {
        onStatus?.call(
          SearchRunState(
            SearchRunStatus.retrying,
            query: request.query,
            provider: legacy.WebSearchService.providerName,
            retryNumber: retryNumber,
            retryDelay: delay,
          ),
        );
      },
    );
    if (attempt.value != null) {
      final snapshot = attempt.requireValue;
      return snapshot.copyWith(
        // The legacy facade may already report its own retry count. Do not
        // double-count it when the compatibility port is wrapped here.
        retryCount:
            snapshot.retryCount == 0 ? attempt.retryCount : snapshot.retryCount,
        latencyMs: snapshot.latencyMs > 0
            ? snapshot.latencyMs
            : _elapsedMilliseconds(startedAt),
      );
    }

    final failure = mapSearchFailure(attempt.error!);
    return legacy.WebSearchSnapshot(
      requestId: request.requestId,
      rootRequestId: request.rootRequestId,
      sourceMessageId: request.sourceMessageId,
      turnId: request.turnId,
      originalTextHash: request.originalTextHash ?? '',
      executedQueries: [request.query],
      query: request.query,
      searchedAt: startedAt.toUtc(),
      provider: legacy.WebSearchService.providerName,
      results: const [],
      error: failure.safeMessage,
      failureType: failure.type,
      safeMessage: failure.safeMessage,
      statusCode: failure.statusCode,
      retryCount: attempt.retryCount,
      latencyMs: _elapsedMilliseconds(startedAt),
    );
  }

  int _elapsedMilliseconds(DateTime startedAt) {
    final elapsed = _clock().difference(startedAt).inMilliseconds;
    return elapsed < 0 ? 0 : elapsed;
  }

  static Duration _ttlFor(domain.SearchCategory category) => switch (category) {
        domain.SearchCategory.news ||
        domain.SearchCategory.weather =>
          const Duration(minutes: 2),
        domain.SearchCategory.finance => const Duration(minutes: 1),
        domain.SearchCategory.software ||
        domain.SearchCategory.policy =>
          const Duration(minutes: 30),
        domain.SearchCategory.academic => const Duration(hours: 24),
        domain.SearchCategory.general ||
        domain.SearchCategory.local =>
          const Duration(hours: 6),
      };
}
