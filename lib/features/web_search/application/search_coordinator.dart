import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/services/web_search_service.dart' as legacy;

import '../models/search_failure_factory.dart';
import '../models/search_models.dart' as domain;
import '../providers/search_provider.dart';
import 'search_coordinator_support.dart';
import 'search_legacy_executor.dart';
import 'search_provider_chain.dart';
import 'search_provider_route.dart';
import 'search_retry_policy.dart';
import 'search_run_state.dart';
import 'search_turn_cache.dart';

export 'search_provider_route.dart';
export 'search_retry_policy.dart';
export 'search_run_state.dart';
export 'search_turn_cache.dart';

/// Pure search orchestration: policy gates, turn cache, retry budget, and
/// Provider failover. Query intent/planning remains outside this class.
class SearchCoordinator {
  final GovernancePersistence store;
  final legacy.WebSearchServicePort? service;
  final SearchTurnCache cache;
  final SearchRetryPolicy retryPolicy;
  final DateTime Function() _clock;
  final Uuid _uuid;
  final List<SearchProviderRoute> _routes;

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
  late final SearchLegacyExecutor? _legacyExecutor = service == null
      ? null
      : SearchLegacyExecutor(
          service: service!,
          cache: cache,
          retryPolicy: retryPolicy,
          clock: _clock,
        );

  SearchCoordinator({
    required this.store,
    this.service,
    Iterable<SearchProviderRoute> routes = const [],
    Iterable<SearchProviderRoute>? providerRoutes,
    Iterable<SearchProvider>? providers,
    SearchProvider? primaryProvider,
    Iterable<SearchProvider>? fallbackProviders,
    Iterable<SearchProvider>? backupProviders,
    SearchTurnCache? cache,
    SearchRetryPolicy? retryPolicy,
    SearchRetrySleep sleep = searchRetrySleep,
    DateTime Function()? clock,
    Duration totalBudget = searchRetryBudget,
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
  }) async {
    final prepared = _support.prepareRequest(request, conversationId);
    final effective = _constrainedPolicy(
      configured: effectivePolicy(conversationId),
      requested: policy,
    );
    if (!await _passPolicyGate(
      request: prepared,
      policy: effective,
      requestConsent: requestConsent,
      conversationId: conversationId,
      onStatus: onStatus,
    )) {
      return null;
    }

    if (prepared.isSensitive && effective == WebSearchPolicy.auto) {
      final snapshot = _support.failureSnapshot(
        request: prepared,
        provider: 'none',
        failure: buildSearchFailure(type: SearchFailureType.unsafeQuery),
      );
      _emit(
        onStatus,
        SearchRunStatus.failed,
        request: prepared,
        domainSnapshot: snapshot,
      );
      await _support.auditDomain(
        conversationId: conversationId,
        request: prepared,
        snapshot: snapshot,
        status: SearchRunStatus.failed,
      );
      return snapshot;
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
        domainSnapshot: snapshot,
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
          )
        : service == null
            ? _support.failureSnapshot(
                request: prepared,
                provider: 'none',
                failure: buildSearchFailure(
                  type: SearchFailureType.invalidConfiguration,
                ),
              )
            : _support.domainFromLegacy(
                prepared,
                await _legacyExecutor!.search(
                  request: prepared,
                  cancelToken: cancelToken,
                  onStatus: onStatus,
                ),
              );

    _emit(
      onStatus,
      SearchRunStatus.evaluating,
      request: prepared,
      domainSnapshot: snapshot,
    );
    final status = _support.domainStatus(snapshot);
    _emit(
      onStatus,
      status,
      request: prepared,
      domainSnapshot: snapshot,
    );
    await _support.auditDomain(
      conversationId: conversationId,
      request: prepared,
      snapshot: snapshot,
      status: status,
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
  }) =>
      search(
        request: request,
        conversationId: conversationId,
        requestConsent: requestConsent,
        onStatus: onStatus,
        policy: policy,
        cancelToken: cancelToken,
      );

  /// Backward-compatible facade used by the current chat room.
  Future<legacy.WebSearchSnapshot?> searchIfAllowed({
    required String? text,
    required String conversationId,
    required SearchConsent requestConsent,
    SearchStatusListener? onStatus,
    String? sourceMessageId,
    String? turnId,
    domain.SearchCategory category = domain.SearchCategory.general,
    domain.SearchFreshness freshness = domain.SearchFreshness.any,
    String locale = 'zh-CN',
    String? country,
    int maxResults = domain.searchDefaultMaxResults,
    bool safeSearch = true,
    bool forceRefresh = false,
    bool isSensitive = false,
    CancelToken? cancelToken,
  }) async {
    final query = text?.trim() ?? '';
    if (query.isEmpty) return null;
    if (service != null && !service!.shouldSearch(query)) return null;
    if (service == null && _routes.isEmpty) return null;

    final prepared = _support.prepareRequest(
      domain.SearchRequest(
        requestId: _uuid.v4(),
        rootRequestId: turnId ?? conversationId,
        sourceMessageId:
            sourceMessageId ?? SearchCoordinatorSupport.hash(query),
        turnId: turnId ?? conversationId,
        query: query,
        category: category,
        freshness: freshness,
        locale: locale,
        country: country,
        maxResults: maxResults,
        safeSearch: safeSearch,
        forceRefresh: forceRefresh,
        isSensitive: isSensitive,
      ),
      conversationId,
    );

    if (_routes.isEmpty && service != null) {
      return _searchLegacyIfAllowed(
        request: prepared,
        conversationId: conversationId,
        requestConsent: requestConsent,
        onStatus: onStatus,
        cancelToken: cancelToken,
      );
    }

    final snapshot = await search(
      request: prepared,
      conversationId: conversationId,
      requestConsent: requestConsent,
      onStatus: onStatus,
      cancelToken: cancelToken,
    );
    return snapshot == null
        ? null
        : _support.toLegacySnapshot(prepared.query, snapshot).copyWith(
              sourceMessageId: prepared.sourceMessageId,
              turnId: prepared.turnId,
            );
  }

  Future<domain.WebSearchSnapshot> _searchProvidersCached({
    required domain.SearchRequest request,
    required CancelToken? cancelToken,
    required SearchStatusListener? onStatus,
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
  }) async {
    if (policy == WebSearchPolicy.off) {
      _emit(onStatus, SearchRunStatus.disabled, request: request);
      await _support.auditSimple(
        conversationId: conversationId,
        query: request.query,
        status: SearchRunStatus.disabled,
      );
      return false;
    }
    if (policy != WebSearchPolicy.ask) return true;

    _emit(onStatus, SearchRunStatus.awaitingConsent, request: request);
    final allowed = await requestConsent?.call(request.query) ?? false;
    if (allowed) return true;

    _emit(onStatus, SearchRunStatus.denied, request: request);
    await _support.auditSimple(
      conversationId: conversationId,
      query: request.query,
      status: SearchRunStatus.denied,
    );
    return false;
  }

  Future<legacy.WebSearchSnapshot?> _searchLegacyIfAllowed({
    required domain.SearchRequest request,
    required String conversationId,
    required SearchConsent requestConsent,
    required SearchStatusListener? onStatus,
    required CancelToken? cancelToken,
  }) async {
    final policy = effectivePolicy(conversationId);
    if (!await _passPolicyGate(
      request: request,
      policy: policy,
      requestConsent: requestConsent,
      conversationId: conversationId,
      onStatus: onStatus,
    )) {
      return null;
    }
    if (request.isSensitive && policy == WebSearchPolicy.auto) {
      final snapshot = _support.toLegacySnapshot(
        request.query,
        _support.failureSnapshot(
          request: request,
          provider: 'none',
          failure: buildSearchFailure(type: SearchFailureType.unsafeQuery),
        ),
      );
      _emit(onStatus, SearchRunStatus.failed,
          request: request, snapshot: snapshot);
      await _support.auditLegacy(
        conversationId: conversationId,
        request: request,
        snapshot: snapshot,
        status: SearchRunStatus.failed,
      );
      return snapshot;
    }
    if (_isCancelled(cancelToken)) {
      final snapshot = _support.toLegacySnapshot(
        request.query,
        _support.cancelledSnapshot(
          request: request,
          provider: legacy.WebSearchService.providerName,
        ),
      );
      _emit(
        onStatus,
        SearchRunStatus.cancelled,
        request: request,
        snapshot: snapshot,
      );
      await _support.auditLegacy(
        conversationId: conversationId,
        request: request,
        snapshot: snapshot,
        status: SearchRunStatus.cancelled,
      );
      return snapshot;
    }

    _emit(onStatus, SearchRunStatus.planning, request: request);
    final snapshot = await _legacyExecutor!.search(
      request: request,
      cancelToken: cancelToken,
      onStatus: onStatus,
    );
    _emit(
      onStatus,
      SearchRunStatus.evaluating,
      request: request,
      snapshot: snapshot,
    );
    final status = _support.legacyStatus(snapshot);
    _emit(onStatus, status, request: request, snapshot: snapshot);
    await _support.auditLegacy(
      conversationId: conversationId,
      request: request,
      snapshot: snapshot,
      status: status,
    );
    return snapshot;
  }

  void _emit(
    SearchStatusListener? listener,
    SearchRunStatus status, {
    required domain.SearchRequest request,
    String provider = '',
    int retryNumber = 0,
    Duration? retryDelay,
    legacy.WebSearchSnapshot? snapshot,
    domain.WebSearchSnapshot? domainSnapshot,
  }) {
    listener?.call(
      SearchRunState(
        status,
        query: request.query,
        provider: provider.isEmpty
            ? domainSnapshot?.provider ?? snapshot?.provider ?? ''
            : provider,
        retryNumber: retryNumber,
        retryDelay: retryDelay,
        snapshot: snapshot ??
            (domainSnapshot == null
                ? null
                : _support.toLegacySnapshot(request.query, domainSnapshot)),
        domainSnapshot: domainSnapshot,
      ),
    );
  }

  static List<SearchProviderRoute> _normalizeRoutes(
    List<SearchProviderRoute> routes,
  ) =>
      List.unmodifiable(routes);

  bool _isCancelled(CancelToken? token) => token?.isCancelled == true;

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
