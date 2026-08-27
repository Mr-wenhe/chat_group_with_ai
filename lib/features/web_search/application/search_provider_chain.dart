import 'dart:async';

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
import '../security/search_query_sanitizer.dart';

/// Executes the ordered normalized Provider chain without knowing any
/// Provider-specific response JSON.
class SearchProviderChain {
  static const int _circuitFailureThreshold = 3;
  static const Duration _circuitOpenDuration = Duration(seconds: 30);

  final List<SearchProviderRoute> _routes;
  final SearchRetryPolicy retryPolicy;
  final DateTime Function() _clock;
  final Map<String, _ProviderCircuitState> _circuits = {};

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

  String primaryProviderName(domain.SearchRequest request) {
    final routes = _routesFor(request);
    return routes.isEmpty ? 'none' : routes.first.providerName;
  }

  /// Human-readable disclosure for every Provider that may receive this
  /// query. Consent cannot be limited to the primary route because a later
  /// retry may legitimately cross a Provider boundary.
  String providerDisclosure(domain.SearchRequest request) {
    final names = _routesFor(request)
        .map((route) => route.providerName)
        .toSet()
        .toList(growable: false);
    if (names.isEmpty) return 'none';
    if (names.length == 1) return names.single;
    return '${names.first}；备用：${names.skip(1).join('、')}';
  }

  Future<domain.WebSearchSnapshot> execute({
    required domain.SearchRequest request,
    required CancelToken? cancelToken,
    required SearchStatusListener? onStatus,
    DateTime? deadline,
  }) async {
    final sanitized = const SearchQuerySanitizer().sanitize(request.query);
    request = request.copyWith(
      query: sanitized.text,
      isSensitive: request.isSensitive || sanitized.containsSensitiveData,
    );
    if (sanitized.blocked ||
        (request.isSensitive && request.query.trim().isEmpty)) {
      return _failureSnapshot(
        request: request,
        provider: 'none',
        failure: buildSearchFailure(type: SearchFailureType.unsafeQuery),
      );
    }
    final routes = _routesFor(request);
    final startedAt = _clock();
    final policyDeadline = startedAt.add(retryPolicy.totalBudget);
    final effectiveDeadline =
        deadline == null || policyDeadline.isBefore(deadline)
            ? policyDeadline
            : deadline;
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
      if (!_hasBudget(effectiveDeadline)) break;
      // Do not reserve a half-open probe until the request is known to be
      // dispatchable. Cancellation or an exhausted budget must not strand a
      // circuit in half-open state.
      if (!_canAttempt(route)) continue;

      _emit(
        onStatus,
        SearchRunStatus.searching,
        request: request,
        provider: route.kind.name,
        retryNumber: retryCount,
      );
      CancelToken? attemptCancelToken;
      final attempt = await retryPolicy.execute<SearchProviderResponse>(
        operation: (_) {
          attemptCancelToken = _childCancelToken(cancelToken);
          return route.provider.search(
            request,
            credential: route.credential,
            cancelToken: attemptCancelToken,
          );
        },
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
        deadline: effectiveDeadline,
        isCancelled: () => _isCancelled(cancelToken),
        onTimeout: () => attemptCancelToken?.cancel(),
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
        if (failure.retryable) {
          _recordRetryableFailure(route);
        } else {
          _recordProviderResponse(route);
        }
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
      if (response.failure?.retryable == true) {
        _recordRetryableFailure(route);
      } else {
        _recordProviderResponse(route);
      }
      final snapshot = const SearchSnapshotBuilder().build(
        request: request,
        provider: response.sourceProvider ?? route.kind.name,
        response: response,
        searchedAt: startedAt.toUtc(),
        retryCount: retryCount,
        fromCache: response.fromCache,
        degraded: index > 0 || response.degraded,
        latencyMs: _elapsedMilliseconds(startedAt),
      );
      lastSnapshot = snapshot;

      if (response.items.isNotEmpty && response.failure == null) {
        return snapshot;
      }
      if (response.failure?.type == SearchFailureType.cancelled) {
        return snapshot;
      }
      if (response.terminal) return snapshot;
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
              route.isNative ||
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
    if (response.failure != null) {
      return SearchProviderResponse(
        items: response.items,
        providerRequestId: response.providerRequestId,
        sourceProvider: response.sourceProvider,
        correctedQuery: response.correctedQuery,
        moreResultsAvailable: response.moreResultsAvailable,
        fromCache: response.fromCache,
        degraded: response.degraded,
        terminal: response.terminal,
        statusCode: response.statusCode,
        failure: sanitizeSearchFailure(response.failure!),
      );
    }
    if (response.items.isNotEmpty) return response;
    return SearchProviderResponse(
      items: const [],
      providerRequestId: response.providerRequestId,
      sourceProvider: response.sourceProvider,
      correctedQuery: response.correctedQuery,
      moreResultsAvailable: response.moreResultsAvailable,
      fromCache: response.fromCache,
      degraded: response.degraded,
      terminal: response.terminal,
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
    final safeFailure = sanitizeSearchFailure(failure);
    return domain.WebSearchSnapshot(
      requestId: request.requestId,
      rootRequestId: request.rootRequestId,
      originalTextHash: request.originalTextHash ?? '',
      executedQueries: [request.query],
      searchedAt: _clock().toUtc(),
      provider: provider,
      results: const [],
      failure: safeFailure,
      statusCode: safeFailure.statusCode,
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
        requestId: request.requestId,
        rootRequestId: request.rootRequestId,
        query: request.query,
        provider: provider,
        retryNumber: retryNumber,
        retryDelay: retryDelay,
      ),
    );
  }

  bool _isCancelled(CancelToken? token) => token?.isCancelled == true;

  /// Gives each retry its own cancellation scope. A hard retry timeout must
  /// stop the current Dio request without cancelling a caller-owned token that
  /// may be shared with the surrounding conversation run.
  CancelToken _childCancelToken(CancelToken? parent) {
    final child = CancelToken();
    if (parent == null) return child;
    if (parent.isCancelled) {
      child.cancel();
      return child;
    }
    unawaited(
      parent.whenCancel.then<void>((_) {
        if (!child.isCancelled) child.cancel();
      }),
    );
    return child;
  }

  bool _canAttempt(SearchProviderRoute route) {
    final state = _circuits[route.cacheKey];
    final openUntil = state?.openUntil;
    if (state == null || openUntil == null) return true;
    if (_clock().isBefore(openUntil)) return false;
    if (state.halfOpenInFlight) return false;
    state.halfOpenInFlight = true;
    return true;
  }

  void _recordRetryableFailure(SearchProviderRoute route) {
    final state = _circuits.putIfAbsent(
      route.cacheKey,
      _ProviderCircuitState.new,
    );
    state.consecutiveFailures++;
    if (state.halfOpenInFlight ||
        state.consecutiveFailures >= _circuitFailureThreshold) {
      state.openUntil = _clock().add(_circuitOpenDuration);
      state.halfOpenInFlight = false;
    }
  }

  void _recordProviderResponse(SearchProviderRoute route) {
    _circuits.remove(route.cacheKey);
  }

  bool _hasBudget(DateTime deadline) {
    final now = _clock();
    return now.isBefore(deadline);
  }

  int _elapsedMilliseconds(DateTime startedAt) {
    final elapsed = _clock().difference(startedAt).inMilliseconds;
    return elapsed < 0 ? 0 : elapsed;
  }
}

class _ProviderCircuitState {
  int consecutiveFailures = 0;
  DateTime? openUntil;
  bool halfOpenInFlight = false;
}
