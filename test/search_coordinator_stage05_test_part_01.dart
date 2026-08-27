part of 'search_coordinator_stage05_test.dart';

void _registerSearchCoordinatorStage05TestPart1() {
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

  test('hard retry budget cancels the in-flight provider attempt', () async {
    final provider = _CancellationAwareProvider();
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: provider)],
      totalBudget: const Duration(milliseconds: 40),
      sleep: (_) async {},
    );

    final snapshot = await coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
    );

    expect(provider.searchCount, 1);
    expect(provider.cancellationObserved, isTrue);
    expect(snapshot?.failure?.type, SearchFailureType.receiveTimeout);
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

  test('ask status discloses every provider that routing may contact',
      () async {
    final firstPersisted = _ScriptedProvider(
      SearchProviderKind.tavily,
      [_success()],
    );
    final actualPrimary = _ScriptedProvider(
      SearchProviderKind.brave,
      [_success()],
    );
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.ask),
      routes: [
        SearchProviderRoute(provider: firstPersisted),
        SearchProviderRoute(provider: actualPrimary, isPrimary: true),
      ],
    );
    SearchRunState? consentState;

    await coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
      requestConsent: (_) async => true,
      onStatus: (state) {
        if (state.status == SearchRunStatus.awaitingConsent) {
          consentState = state;
        }
      },
    );

    expect(
      consentState?.provider,
      '${SearchProviderKind.brave.name}；备用：${SearchProviderKind.tavily.name}',
    );
    expect(firstPersisted.searchCount, 0);
    expect(actualPrimary.searchCount, 1);
  });

  test('three retryable failures open the provider circuit for thirty seconds',
      () async {
    final clock = _FakeClock();
    SearchProviderResponse retryableFailure() => SearchProviderResponse(
          items: const [],
          statusCode: 503,
          failure: const SearchFailure(
            type: SearchFailureType.providerUnavailable,
            safeMessage: 'temporarily unavailable',
            statusCode: 503,
            retryable: true,
          ),
        );
    final primary = _ScriptedProvider(
      SearchProviderKind.brave,
      [
        retryableFailure(),
        retryableFailure(),
        retryableFailure(),
        _success(path: 'recovered'),
      ],
    );
    final backup = _ScriptedProvider(SearchProviderKind.tavily, []);
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [
        SearchProviderRoute(provider: primary, isPrimary: true),
        SearchProviderRoute(provider: backup, isFallback: true),
      ],
      retryPolicy: SearchRetryPolicy(
        maxRetries: 0,
        clock: clock.call,
        sleep: (_) async {},
      ),
      clock: clock.call,
    );

    for (var index = 0; index < 3; index++) {
      await coordinator.search(
        request: _request(
          sourceMessageId: 'failure-$index',
          turnId: 'failure-$index',
          forceRefresh: true,
        ),
        conversationId: 'conversation-1',
      );
    }
    await coordinator.search(
      request: _request(
        sourceMessageId: 'open-circuit',
        turnId: 'open-circuit',
        forceRefresh: true,
      ),
      conversationId: 'conversation-1',
    );

    expect(primary.searchCount, 3);
    expect(backup.searchCount, 4);

    clock.advance(const Duration(seconds: 31));
    final recovered = await coordinator.search(
      request: _request(
        sourceMessageId: 'half-open',
        turnId: 'half-open',
        forceRefresh: true,
      ),
      conversationId: 'conversation-1',
    );
    expect(primary.searchCount, 4);
    expect(recovered?.results.single.url.path, '/recovered');
  });
}
