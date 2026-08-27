part of 'search_coordinator_stage05_test.dart';

void _registerSearchCoordinatorStage05TestPart2() {
  test('cancelled half-open attempt does not strand the client circuit',
      () async {
    final clock = _FakeClock();
    final provider = _ScriptedProvider(
      SearchProviderKind.brave,
      [
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _failure(SearchFailureType.providerUnavailable, statusCode: 503),
        _success(path: 'recovered-after-cancel'),
      ],
    );
    final chain = SearchProviderChain(
      routes: [SearchProviderRoute(provider: provider)],
      retryPolicy: SearchRetryPolicy(
        maxRetries: 0,
        clock: clock.call,
        sleep: (_) async {},
      ),
      clock: clock.call,
    );

    for (var index = 0; index < 3; index++) {
      await chain.execute(
        request: _request(
          sourceMessageId: 'circuit-$index',
          turnId: 'circuit-$index',
        ),
        cancelToken: null,
        onStatus: null,
      );
    }
    clock.advance(const Duration(seconds: 31));
    final cancelled = CancelToken()..cancel();
    final cancelledSnapshot = await chain.execute(
      request: _request(sourceMessageId: 'cancelled-probe'),
      cancelToken: cancelled,
      onStatus: null,
    );
    expect(cancelledSnapshot.failure?.type, SearchFailureType.cancelled);
    expect(provider.searchCount, 3);

    final recovered = await chain.execute(
      request: _request(sourceMessageId: 'after-cancel'),
      cancelToken: null,
      onStatus: null,
    );
    expect(provider.searchCount, 4);
    expect(recovered.results.single.url.path, '/recovered-after-cancel');
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

  test('passes cancellation to the normalized provider route', () async {
    final pendingResponse = Completer<SearchProviderResponse>();
    final provider = _ScriptedProvider(
      SearchProviderKind.brave,
      [pendingResponse.future],
    );
    final coordinator = SearchCoordinator(
      store: MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto),
      routes: [SearchProviderRoute(provider: provider)],
    );
    final cancelToken = CancelToken();
    final pending = coordinator.search(
      request: _request(),
      conversationId: 'conversation-1',
      cancelToken: cancelToken,
    );
    await Future<void>.delayed(Duration.zero);

    expect(provider.receivedCancelToken, isNotNull);
    expect(provider.receivedCancelToken, isNot(same(cancelToken)));
    cancelToken.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(provider.receivedCancelToken!.isCancelled, isTrue);
    pendingResponse.complete(_failure(SearchFailureType.cancelled));

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
