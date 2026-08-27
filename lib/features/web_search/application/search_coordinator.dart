import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';

import '../models/search_failure_factory.dart';
import '../models/search_models.dart' as domain;
import '../providers/search_provider.dart';
import 'search_coordinator_support.dart';
import 'search_intent_detector.dart';
import 'search_provider_chain.dart';
import 'search_provider_route.dart';
import 'search_query_planner.dart';
import 'search_retry_policy.dart';
import 'search_run_state.dart';
import 'search_turn_cache.dart';
import '../security/search_query_sanitizer.dart';

export 'search_provider_route.dart';
export 'search_retry_policy.dart';
export 'search_run_state.dart';
export 'search_turn_cache.dart';
export 'search_context_formatter.dart';
export 'search_intent_detector.dart';
export 'search_prompts.dart';
export 'search_query_planner.dart';
export '../security/search_query_sanitizer.dart';

part 'search_coordinator_legacy.dart';

/// Search orchestration: local intent, policy gates, optional planning, turn
/// cache, retry budget, and Provider failover.
class SearchCoordinator {
  final GovernancePersistence store;
  final SearchTurnCache cache;
  final SearchRetryPolicy retryPolicy;
  final SearchIntentDetector intentDetector;
  final SearchQuerySanitizer sanitizer;
  final SearchQueryPlanner? queryPlanner;
  final DateTime Function() _clock;
  final Uuid _uuid;
  final List<SearchProviderRoute> _routes;
  final Duration endToEndBudget;

  late final SearchCoordinatorSupport _support = SearchCoordinatorSupport(
    store: store,
    clock: _clock,
    uuid: _uuid,
  );
  late final SearchProviderChain _providerChain = SearchProviderChain(
    routes: _routes,
    retryPolicy: retryPolicy,
    clock: _clock,
  );

  SearchCoordinator({
    required this.store,
    Iterable<SearchProviderRoute> routes = const [],
    Iterable<SearchProviderRoute>? providerRoutes,
    Iterable<SearchProvider>? providers,
    SearchProvider? primaryProvider,
    Iterable<SearchProvider>? fallbackProviders,
    Iterable<SearchProvider>? backupProviders,
    SearchTurnCache? cache,
    SearchRetryPolicy? retryPolicy,
    SearchIntentDetector? intentDetector,
    SearchQuerySanitizer? sanitizer,
    this.queryPlanner,
    SearchRetrySleep sleep = searchRetrySleep,
    DateTime Function()? clock,
    Duration totalBudget = searchRetryBudget,
    this.endToEndBudget = searchEndToEndBudget,
    Uuid? uuid,
  })  : _clock = clock ?? DateTime.now,
        _uuid = uuid ?? const Uuid(),
        cache = cache ?? SearchTurnCache(clock: clock ?? DateTime.now),
        retryPolicy = retryPolicy ??
            SearchRetryPolicy(
              sleep: sleep,
              clock: clock ?? DateTime.now,
              totalBudget: totalBudget,
            ),
        intentDetector = intentDetector ?? const SearchIntentDetector(),
        sanitizer = sanitizer ?? const SearchQuerySanitizer(),
        _routes = _normalizeRoutes([
          ...routes,
          ...?providerRoutes,
          ...?providers?.map(
            (provider) => SearchProviderRoute(provider: provider),
          ),
          if (primaryProvider != null)
            SearchProviderRoute(provider: primaryProvider, isPrimary: true),
          ...?fallbackProviders?.map(
            (provider) => SearchProviderRoute(
              provider: provider,
              isFallback: true,
            ),
          ),
          ...?backupProviders?.map(
            (provider) => SearchProviderRoute(
              provider: provider,
              isFallback: true,
            ),
          ),
        ]);

  List<SearchProviderRoute> get providerRoutes => List.unmodifiable(_routes);

  WebSearchPolicy effectivePolicy(String conversationId) =>
      store.conversationSearchPolicy(conversationId) ??
      store.globalSearchPolicy;

  /// Executes an already prepared request. Stage 06 may supply a planned
  /// query later; this method never invokes an LLM planner itself.
  Future<domain.WebSearchSnapshot?> search({
    required domain.SearchRequest request,
    required String conversationId,
    SearchConsent? requestConsent,
    SearchStatusListener? onStatus,
    WebSearchPolicy? policy,
    CancelToken? cancelToken,
    bool consentAlreadyGranted = false,
    DateTime? deadline,
  }) async {
    final sanitized = sanitizer.sanitize(request.query);
    final prepared = _support.prepareRequest(
      request.copyWith(
        query: sanitized.text,
        // The coordinator is the final privacy boundary. Callers may provide
        // an explicit flag, but the local scanner must be authoritative too.
        isSensitive: request.isSensitive || sanitized.containsSensitiveData,
      ),
      conversationId,
    );
    final effective = _constrainedPolicy(
      configured: effectivePolicy(conversationId),
      requested: policy,
    );
    // Direct callers of search()/searchTurn() must receive the same bounded
    // end-to-end contract as the message facade. When no explicit deadline is
    // supplied, start the coordinator budget here; the Provider chain will
    // still take the tighter retry-policy budget if it is configured.
    var providerDeadline = deadline ?? _clock().add(endToEndBudget);
    if (effective == WebSearchPolicy.off) {
      // Keep the disabled audit semantics even when the query is entirely
      // sensitive and therefore has no safe preview to show.
      if (!await _passPolicyGate(
        request: prepared,
        policy: effective,
        requestConsent: requestConsent,
        conversationId: conversationId,
        onStatus: onStatus,
        consentAlreadyGranted: consentAlreadyGranted,
      )) {
        return null;
      }
    } else if (sanitized.blocked ||
        (prepared.isSensitive && prepared.query.trim().isEmpty)) {
      // An all-secret query must never reach an ask dialog with an empty
      // preview or a Provider with an empty query. The explicit-sensitive
      // branch also protects callers that already redacted their query
      // before entering this coordinator.
      return _unsafeSnapshot(
        request: prepared,
        conversationId: conversationId,
        onStatus: onStatus,
      );
    } else {
      final consentStartedAt = _clock();
      final allowed = await _passPolicyGate(
        request: prepared,
        policy: effective,
        requestConsent: requestConsent,
        conversationId: conversationId,
        onStatus: onStatus,
        consentAlreadyGranted: consentAlreadyGranted,
      );
      if (!allowed) return null;
      if (effective == WebSearchPolicy.ask && !consentAlreadyGranted) {
        // Explicit consent is a user interaction, not network work. Extend
        // the shared deadline by the time spent waiting for that decision so a
        // slow dialog cannot make the Provider appear to time out immediately.
        providerDeadline = providerDeadline.add(
          _positiveElapsed(consentStartedAt),
        );
      }
    }

    if (prepared.isSensitive && effective == WebSearchPolicy.auto) {
      return _unsafeSnapshot(
        request: prepared,
        conversationId: conversationId,
        onStatus: onStatus,
      );
    }

    if (_isCancelled(cancelToken)) {
      final snapshot = _support.cancelledSnapshot(
        request: prepared,
        provider: _routes.isEmpty ? 'none' : _routes.first.kind.name,
      );
      _emit(
        onStatus,
        SearchRunStatus.cancelled,
        request: prepared,
        snapshot: snapshot,
      );
      await _support.auditDomain(
        conversationId: conversationId,
        request: prepared,
        snapshot: snapshot,
        status: SearchRunStatus.cancelled,
      );
      return snapshot;
    }

    _emit(onStatus, SearchRunStatus.planning, request: prepared);
    final snapshot = _routes.isNotEmpty
        ? await _searchProvidersCached(
            request: prepared,
            cancelToken: cancelToken,
            onStatus: onStatus,
            deadline: providerDeadline,
          )
        : _support.failureSnapshot(
            request: prepared,
            provider: 'none',
            failure: buildSearchFailure(
              type: SearchFailureType.invalidConfiguration,
            ),
          );

    _emit(
      onStatus,
      SearchRunStatus.evaluating,
      request: prepared,
      snapshot: snapshot,
    );
    final status = _support.domainStatus(snapshot);
    _emit(
      onStatus,
      status,
      request: prepared,
      snapshot: snapshot,
    );
    await _support.auditDomain(
      conversationId: conversationId,
      request: prepared,
      snapshot: snapshot,
      status: status,
    );
    return snapshot;
  }

  Future<domain.WebSearchSnapshot> _unsafeSnapshot({
    required domain.SearchRequest request,
    required String conversationId,
    required SearchStatusListener? onStatus,
  }) async {
    final snapshot = _support.failureSnapshot(
      request: request,
      provider: 'none',
      failure: buildSearchFailure(type: SearchFailureType.unsafeQuery),
    );
    _emit(
      onStatus,
      SearchRunStatus.failed,
      request: request,
      snapshot: snapshot,
    );
    await _support.auditDomain(
      conversationId: conversationId,
      request: request,
      snapshot: snapshot,
      status: SearchRunStatus.failed,
    );
    return snapshot;
  }

  Future<domain.WebSearchSnapshot?> searchTurn({
    required domain.SearchRequest request,
    required String conversationId,
    SearchConsent? requestConsent,
    SearchStatusListener? onStatus,
    WebSearchPolicy? policy,
    CancelToken? cancelToken,
    bool consentAlreadyGranted = false,
    DateTime? deadline,
  }) =>
      search(
        request: request,
        conversationId: conversationId,
        requestConsent: requestConsent,
        onStatus: onStatus,
        policy: policy,
        cancelToken: cancelToken,
        consentAlreadyGranted: consentAlreadyGranted,
        deadline: deadline,
      );

  Future<domain.WebSearchSnapshot> _searchProvidersCached({
    required domain.SearchRequest request,
    required CancelToken? cancelToken,
    required SearchStatusListener? onStatus,
    DateTime? deadline,
  }) {
    final key = SearchTurnCacheKey.fromRequest(
      request: request,
      provider: _providerChain.primaryProviderKey(request),
    );
    return cache.getOrLoad<domain.WebSearchSnapshot>(
      key: key,
      ttl: SearchCoordinatorSupport.ttlFor(request.category),
      forceRefresh: request.forceRefresh,
      loader: () => _providerChain.execute(
        request: request,
        cancelToken: cancelToken,
        onStatus: onStatus,
        deadline: deadline,
      ),
      shouldCache: (snapshot) => !snapshot.hasFailure,
      markFromCache: (snapshot) => snapshot.copyWith(fromCache: true),
    );
  }

  Future<bool> _passPolicyGate({
    required domain.SearchRequest request,
    required WebSearchPolicy policy,
    required SearchConsent? requestConsent,
    required String conversationId,
    required SearchStatusListener? onStatus,
    bool consentAlreadyGranted = false,
    String? providerOverride,
  }) async {
    if (policy == WebSearchPolicy.off) {
      _emit(onStatus, SearchRunStatus.disabled, request: request);
      await _support.auditSimple(
        conversationId: conversationId,
        request: request,
        status: SearchRunStatus.disabled,
      );
      return false;
    }
    if (policy != WebSearchPolicy.ask || consentAlreadyGranted) return true;

    _emit(
      onStatus,
      SearchRunStatus.awaitingConsent,
      request: request,
      provider: providerOverride ?? _providerChain.providerDisclosure(request),
    );
    final allowed = await requestConsent?.call(request.query) ?? false;
    if (allowed) return true;

    _emit(onStatus, SearchRunStatus.denied, request: request);
    await _support.auditSimple(
      conversationId: conversationId,
      request: request,
      status: SearchRunStatus.denied,
    );
    return false;
  }

  void _emit(
    SearchStatusListener? listener,
    SearchRunStatus status, {
    required domain.SearchRequest request,
    String provider = '',
    int retryNumber = 0,
    Duration? retryDelay,
    domain.WebSearchSnapshot? snapshot,
  }) {
    listener?.call(
      SearchRunState(
        status,
        requestId: request.requestId,
        rootRequestId: request.rootRequestId,
        query: request.query,
        provider: provider.isEmpty ? snapshot?.provider ?? '' : provider,
        retryNumber: retryNumber,
        retryDelay: retryDelay,
        snapshot: snapshot,
      ),
    );
  }

  static List<SearchProviderRoute> _normalizeRoutes(
    List<SearchProviderRoute> routes,
  ) =>
      List.unmodifiable(routes);

  bool _isCancelled(CancelToken? token) => token?.isCancelled == true;

  Duration _positiveElapsed(DateTime startedAt) {
    final elapsed = _clock().difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// A caller may narrow governance for one request, but never widen it.
  static WebSearchPolicy _constrainedPolicy({
    required WebSearchPolicy configured,
    required WebSearchPolicy? requested,
  }) {
    if (requested == null || requested.index >= configured.index) {
      return configured;
    }
    return requested;
  }
}
