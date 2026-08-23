import 'dart:async';

import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/web_search/application/search_coordinator.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/services/web_search_service.dart' as legacy;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_governance_store.dart';

class _FakeClock {
  DateTime value = DateTime.utc(2026, 8, 23, 12);

  DateTime call() => value;

  void advance(Duration duration) => value = value.add(duration);
}

class _ScriptedProvider implements SearchProvider {
  _ScriptedProvider(this._kind, this._script);

  final SearchProviderKind _kind;
  final List<Object> _script;
  final List<SearchRequest> requests = [];
  int searchCount = 0;

  @override
  SearchProviderKind get kind => _kind;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    searchCount++;
    requests.add(request);
    if (cancelToken?.isCancelled == true) {
      return _failure(SearchFailureType.cancelled);
    }
    final next = _script.isEmpty ? _success() : _script.removeAt(0);
    if (next is Future<SearchProviderResponse>) return next;
    if (next is SearchProviderResponse) return next;
    throw next;
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    return const SearchHealthResult(isHealthy: true);
  }

  static SearchProviderResponse _success() => SearchProviderResponse(
        items: [
          SearchProviderItem(
            title: 'Result',
            snippet: 'A result',
            url: Uri.parse('https://example.com/result'),
          ),
        ],
      );

  static SearchProviderResponse _failure(
    SearchFailureType type, {
    int? statusCode,
  }) {
    return SearchProviderResponse(
      items: const [],
      statusCode: statusCode,
      failure: SearchFailure(
        type: type,
        safeMessage: 'safe failure',
        statusCode: statusCode,
        retryable: false,
      ),
    );
  }
}

class _CancellableLegacyService implements legacy.WebSearchServicePort {
  final Completer<legacy.WebSearchSnapshot> response = Completer();
  CancelToken? receivedCancelToken;

  @override
  bool shouldSearch(String? text) => true;

  @override
  Future<legacy.WebSearchSnapshot> search(
    String query, {
    CancelToken? cancelToken,
  }) {
    receivedCancelToken = cancelToken;
    return response.future;
  }
}

SearchProviderResponse _success({String path = 'result'}) =>
    SearchProviderResponse(
      items: [
        SearchProviderItem(
          title: 'Result',
          snippet: 'A result',
          url: Uri.parse('https://example.com/$path'),
        ),
      ],
    );

SearchProviderResponse _failure(
  SearchFailureType type, {
  int? statusCode,
}) =>
    SearchProviderResponse(
      items: const [],
      statusCode: statusCode,
      failure: SearchFailure(
        type: type,
        safeMessage: 'safe failure',
        statusCode: statusCode,
        retryable: false,
      ),
    );

SearchRequest _request({
  String sourceMessageId = 'message-1',
  String turnId = 'turn-1',
  SearchCategory category = SearchCategory.general,
  SearchFreshness freshness = SearchFreshness.any,
  String locale = 'zh-CN',
  String? country,
  int maxResults = 5,
  bool safeSearch = true,
  bool forceRefresh = false,
  bool isSensitive = false,
}) {
  return SearchRequest(
    requestId: '$turnId-$sourceMessageId',
    rootRequestId: turnId,
    sourceMessageId: sourceMessageId,
    turnId: turnId,
    query: 'same query',
    category: category,
    freshness: freshness,
    locale: locale,
    country: country,
    maxResults: maxResults,
    safeSearch: safeSearch,
    forceRefresh: forceRefresh,
    isSensitive: isSensitive,
  );
}

void main() {
  test('off and ask denial never call a provider', () async {
    final provider = _ScriptedProvider(SearchProviderKind.brave, []);
    final offStore = MemoryGovernanceStore();
    final offCoordinator = SearchCoordinator(
      store: offStore,
      routes: [SearchProviderRoute(provider: provider)],
    );

    final off = await offCoordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
    );

    expect(off, isNull);
    expect(provider.searchCount, 0);
    expect(offStore.searchAudits.single.status, 'disabled');

    final askStore = MemoryGovernanceStore(
      globalSearchPolicy: WebSearchPolicy.ask,
    );
    final askCoordinator = SearchCoordinator(
      store: askStore,
      routes: [SearchProviderRoute(provider: provider)],
    );
    final denied = await askCoordinator.search(
      request: _request(sourceMessageId: 'message-2'),
      conversationId: 'conversation-1',
      requestConsent: (_) async => false,
    );

    expect(denied, isNull);
    expect(provider.searchCount, 0);
    expect(askStore.searchAudits.single.status, 'denied');
  });

  test('same turn and query share one in-flight future and snapshot', () async {
    final gate = Completer<SearchProviderResponse>();
    final provider = _ScriptedProvider(
      SearchProviderKind.brave,
      [gate.future],
    );
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: provider)],
    );
    final request = _request();

    final first = coordinator.search(
      request: request,
      conversationId: 'conversation-1',
    );
    final second = coordinator.search(
      request: request,
      conversationId: 'conversation-1',
    );
    await Future<void>.delayed(Duration.zero);

    expect(provider.searchCount, 1);
    gate.complete(_success());
    final snapshots = await Future.wait([first, second]);

    expect(identical(snapshots[0], snapshots[1]), isTrue);
    expect(snapshots[0]?.searchedAt, isNotNull);
  });

  test('cache key isolates source message and honors TTL and force refresh',
      () async {
    final clock = _FakeClock();
    final provider = _ScriptedProvider(
      SearchProviderKind.brave,
      [_success(path: 'one'), _success(path: 'two'), _success(path: 'three')],
    );
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: provider)],
      clock: clock.call,
      sleep: (_) async {},
    );

    final first = await coordinator.search(
      request: _request(
        category: SearchCategory.finance,
        freshness: SearchFreshness.day,
      ),
      conversationId: 'conversation-1',
    );
    final cached = await coordinator.search(
      request: _request(
        category: SearchCategory.finance,
        freshness: SearchFreshness.day,
      ),
      conversationId: 'conversation-1',
    );

    expect(provider.searchCount, 1);
    expect(first?.fromCache, isFalse);
    expect(cached?.fromCache, isTrue);
    expect(cached?.searchedAt, first?.searchedAt);

    final otherSource = await coordinator.search(
      request: _request(
        sourceMessageId: 'message-2',
        category: SearchCategory.finance,
        freshness: SearchFreshness.day,
      ),
      conversationId: 'conversation-1',
    );
    expect(otherSource?.fromCache, isFalse);
    expect(provider.searchCount, 2);

    clock.advance(const Duration(minutes: 2));
    final expired = await coordinator.search(
      request: _request(
        sourceMessageId: 'message-2',
        category: SearchCategory.finance,
        freshness: SearchFreshness.day,
      ),
      conversationId: 'conversation-1',
    );
    expect(expired?.fromCache, isFalse);
    expect(provider.searchCount, 3);

    final force = await coordinator.search(
      request: _request(
        sourceMessageId: 'message-2',
        category: SearchCategory.finance,
        freshness: SearchFreshness.day,
        forceRefresh: true,
      ),
      conversationId: 'conversation-1',
    );
    expect(force?.fromCache, isFalse);
    expect(provider.searchCount, 4);
  });

  test('cache key isolates locale, country, result count, and safe search',
      () async {
    final provider = _ScriptedProvider(SearchProviderKind.brave, []);
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: provider)],
    );

    await coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
    );
    final differentRequest = await coordinator.search(
      request: _request(
        locale: 'en-US',
        country: 'US',
        maxResults: 10,
        safeSearch: false,
      ),
      conversationId: 'conversation-1',
    );

    expect(differentRequest?.fromCache, isFalse);
    expect(provider.searchCount, 2);
  });

  test('retries only transient failures, records retry count, and emits state',
      () async {
    final delays = <Duration>[];
    final provider = _ScriptedProvider(
      SearchProviderKind.brave,
      [
        _failure(SearchFailureType.rateLimited, statusCode: 429),
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _success(),
      ],
    );
    final states = <SearchRunStatus>[];
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: provider)],
      sleep: (delay) async => delays.add(delay),
    );

    final snapshot = await coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
      onStatus: (state) => states.add(state.status),
    );

    expect(snapshot?.hasResults, isTrue);
    expect(snapshot?.retryCount, 2);
    expect(provider.searchCount, 3);
    expect(delays, const [searchRetryDelay1, searchRetryDelay2]);
    expect(
        states,
        containsAllInOrder([
          SearchRunStatus.planning,
          SearchRunStatus.searching,
          SearchRunStatus.retrying,
          SearchRunStatus.retrying,
          SearchRunStatus.evaluating,
          SearchRunStatus.completed,
        ]));
  });

  test('retry backoff cannot cross the configured total budget', () async {
    final clock = _FakeClock();
    final provider = _ScriptedProvider(
      SearchProviderKind.brave,
      [
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _success(),
      ],
    );
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: provider)],
      clock: clock.call,
      totalBudget: const Duration(seconds: 1),
      sleep: (delay) async => clock.advance(delay),
    );

    final snapshot = await coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
    );

    expect(provider.searchCount, 2);
    expect(snapshot?.retryCount, 1);
    expect(snapshot?.hasFailure, isTrue);
    expect(clock.value, DateTime.utc(2026, 8, 23, 12, 0, 0, 500));
  });

  test('does not retry unauthorized, invalid configuration, or sensitive query',
      () async {
    final unauthorized = _ScriptedProvider(
      SearchProviderKind.brave,
      [_failure(SearchFailureType.unauthorized, statusCode: 401)],
    );
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: unauthorized)],
      sleep: (_) async => fail('non-retryable failure must not sleep'),
    );

    final unauthorizedSnapshot = await coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
    );
    expect(unauthorized.searchCount, 1);
    expect(unauthorizedSnapshot?.failure?.type, SearchFailureType.unauthorized);

    final sensitive = _ScriptedProvider(
      SearchProviderKind.brave,
      [
        _failure(SearchFailureType.rateLimited, statusCode: 429),
        _success(),
      ],
    );
    final sensitiveCoordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: sensitive)],
    );
    final sensitiveSnapshot = await sensitiveCoordinator.search(
      request: _request(isSensitive: true),
      conversationId: 'conversation-1',
    );
    expect(sensitive.searchCount, 0);
    expect(sensitiveSnapshot?.failure?.type, SearchFailureType.unsafeQuery);
  });

  test('does not fail over a sensitive query after consent', () async {
    final primary = _ScriptedProvider(
      SearchProviderKind.brave,
      [_failure(SearchFailureType.rateLimited, statusCode: 429)],
    );
    final backup = _ScriptedProvider(
      SearchProviderKind.tavily,
      [_success()],
    );
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.ask),
      routes: [
        SearchProviderRoute(provider: primary, isPrimary: true),
        SearchProviderRoute(provider: backup),
      ],
    );

    final snapshot = await coordinator.search(
      request: _request(isSensitive: true),
      conversationId: 'conversation-1',
      requestConsent: (_) async => true,
    );

    expect(snapshot?.failure?.type, SearchFailureType.rateLimited);
    expect(primary.searchCount, 1);
    expect(backup.searchCount, 0);
  });

  test('uses configured backup after primary failure and marks degraded',
      () async {
    final primary = _ScriptedProvider(
      SearchProviderKind.tavily,
      [_failure(SearchFailureType.unauthorized, statusCode: 401)],
    );
    final backup = _ScriptedProvider(SearchProviderKind.brave, [_success()]);
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [
        SearchProviderRoute(provider: primary, isPrimary: true),
        SearchProviderRoute(provider: backup),
      ],
    );

    final snapshot = await coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
    );

    expect(primary.searchCount, 1);
    expect(backup.searchCount, 1);
    expect(snapshot?.provider, 'brave');
    expect(snapshot?.degraded, isTrue);
    expect(snapshot?.hasResults, isTrue);
  });

  test('only allows DuckDuckGo fallback for stable general knowledge',
      () async {
    final primary = _ScriptedProvider(
      SearchProviderKind.tavily,
      [
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
      ],
    );
    final duck = _ScriptedProvider(
      SearchProviderKind.duckDuckGoInstantAnswer,
      [_success()],
    );
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [
        SearchProviderRoute(provider: primary),
        SearchProviderRoute(provider: duck),
      ],
      sleep: (_) async {},
    );

    final general = await coordinator.search(
      request: _request(category: SearchCategory.general),
      conversationId: 'conversation-1',
    );
    expect(general?.provider, 'duckDuckGoInstantAnswer');
    expect(general?.degraded, isTrue);
    expect(duck.searchCount, 1);

    final newsDuck = _ScriptedProvider(
      SearchProviderKind.duckDuckGoInstantAnswer,
      [_success()],
    );
    final newsPrimary = _ScriptedProvider(
      SearchProviderKind.tavily,
      [
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
      ],
    );
    final newsCoordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [
        SearchProviderRoute(provider: newsPrimary),
        SearchProviderRoute(provider: newsDuck),
      ],
      sleep: (_) async {},
    );
    final news = await newsCoordinator.search(
      request: _request(category: SearchCategory.news),
      conversationId: 'conversation-1',
    );
    expect(newsDuck.searchCount, 0);
    expect(news?.hasFailure, isTrue);

    final freshDuck = _ScriptedProvider(
      SearchProviderKind.duckDuckGoInstantAnswer,
      [_success()],
    );
    final freshPrimary = _ScriptedProvider(
      SearchProviderKind.tavily,
      [
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
      ],
    );
    final freshCoordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [
        SearchProviderRoute(provider: freshPrimary),
        SearchProviderRoute(provider: freshDuck),
      ],
      sleep: (_) async {},
    );
    final fresh = await freshCoordinator.search(
      request: _request(
        category: SearchCategory.general,
        freshness: SearchFreshness.day,
      ),
      conversationId: 'conversation-1',
    );
    expect(freshDuck.searchCount, 0);
    expect(fresh?.hasFailure, isTrue);
  });

  test('keeps noResults distinct from failed and does not cache failures',
      () async {
    final provider = _ScriptedProvider(
      SearchProviderKind.brave,
      [
        _failure(SearchFailureType.noResults),
        _failure(SearchFailureType.unauthorized, statusCode: 401),
      ],
    );
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: provider)],
    );
    final states = <SearchRunStatus>[];

    final noResults = await coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
      onStatus: (state) => states.add(state.status),
    );
    final failed = await coordinator.search(
      request: _request(forceRefresh: true),
      conversationId: 'conversation-1',
    );

    expect(noResults?.hasFailure, isFalse);
    expect(noResults?.failure?.type, SearchFailureType.noResults);
    expect(states.last, SearchRunStatus.noResults);
    expect(failed?.hasFailure, isTrue);
    expect(failed?.failure?.type, SearchFailureType.unauthorized);
    expect(provider.searchCount, 2);
  });

  test('cancellation produces cancelled state without retry', () async {
    final provider = _ScriptedProvider(
      SearchProviderKind.brave,
      [_failure(SearchFailureType.cancelled)],
    );
    final states = <SearchRunStatus>[];
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: provider)],
      sleep: (_) async => fail('cancelled search must not sleep'),
    );

    final snapshot = await coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
      onStatus: (state) => states.add(state.status),
    );

    expect(snapshot?.failure?.type, SearchFailureType.cancelled);
    expect(states.last, SearchRunStatus.cancelled);
    expect(provider.searchCount, 1);
  });

  test('passes cancellation to the legacy compatibility service', () async {
    final service = _CancellableLegacyService();
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      service: service,
    );
    final cancelToken = CancelToken();
    final pending = coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
      cancelToken: cancelToken,
    );
    await Future<void>.delayed(Duration.zero);

    expect(service.receivedCancelToken, same(cancelToken));
    cancelToken.cancel();
    service.response.complete(
      legacy.WebSearchSnapshot(
        query: 'same query',
        searchedAt: DateTime.utc(2026, 8, 23),
        results: const [],
      ),
    );

    final snapshot = await pending;
    expect(snapshot?.failure?.type, SearchFailureType.cancelled);
  });

  test('audit blocks scanner-detected secrets before the provider', () async {
    const secret = 'sk-live-stage05-secret';
    final provider = _ScriptedProvider(
      SearchProviderKind.brave,
      [_failure(SearchFailureType.unauthorized, statusCode: 401)],
    );
    final store = MemoryGovernanceStore(
      globalSearchPolicy: WebSearchPolicy.auto,
    );
    final coordinator = SearchCoordinator(
      store: store,
      routes: [
        SearchProviderRoute(provider: provider, credential: secret),
      ],
    );

    await coordinator.search(
      request: SearchRequest(
        requestId: 'request-1',
        rootRequestId: 'turn-1',
        sourceMessageId: 'message-1',
        turnId: 'turn-1',
        query: 'find $secret',
      ),
      conversationId: 'conversation-1',
    );

    final audit = store.searchAudits.single;
    expect(provider.searchCount, 0);
    expect(audit.provider, 'none');
    expect(audit.failureType, SearchFailureType.unsafeQuery.name);
    expect(audit.fromCache, isFalse);
    expect(audit.queryPreview, isNot(contains(secret)));
    expect(audit.toMap().toString(), isNot(contains(secret)));
  });

  test('SearchTurnCache removes a failed future so the next call can retry',
      () async {
    final cache = SearchTurnCache();
    final key = SearchTurnCacheKey(
      sourceMessageId: 'message-1',
      turnId: 'turn-1',
      normalizedQuery: 'query',
      freshness: SearchFreshness.any,
      provider: 'brave',
    );
    var calls = 0;

    Future<SearchSnapshot> load() async {
      calls++;
      if (calls == 1) throw StateError('transient test failure');
      return _domainSnapshot();
    }

    await expectLater(
      cache.getOrLoad<SearchSnapshot>(
        key: key,
        ttl: const Duration(minutes: 1),
        loader: load,
      ),
      throwsStateError,
    );
    final recovered = await cache.getOrLoad<SearchSnapshot>(
      key: key,
      ttl: const Duration(minutes: 1),
      loader: load,
    );

    expect(calls, 2);
    expect(recovered.results, hasLength(1));
  });
}

typedef SearchSnapshot = WebSearchSnapshot;

WebSearchSnapshot _domainSnapshot() => WebSearchSnapshot(
      requestId: 'request-1',
      rootRequestId: 'turn-1',
      originalTextHash: 'a' * 64,
      executedQueries: const ['query'],
      searchedAt: DateTime.utc(2026, 8, 23),
      provider: 'brave',
      results: [
        WebSearchResult(
          sourceId: 'S1',
          title: 'Result',
          snippet: 'Snippet',
          url: Uri.parse('https://example.com'),
          provider: 'brave',
        ),
      ],
    );
