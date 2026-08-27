part of 'search_stage06_test.dart';

void _registerSearchStage06TestPart1() {
  group('SearchIntentDetector', () {
    const detector = SearchIntentDetector();

    test('detects Chinese and English search intent', () {
      expect(detector.detect('帮我联网查 Flutter 最新稳定版').shouldSearch, isTrue);
      expect(
          detector
              .detect('search the web for the current Flutter release')
              .shouldSearch,
          isTrue);
      expect(
        detector.detect('帮我写一段温柔的开场白').shouldSearch,
        isFalse,
      );
      expect(detector.detect('Explain what a mutex is').shouldSearch, isFalse);
    });

    test('generated origins never grant search permission', () {
      for (final origin in [
        SearchMessageOrigin.ai,
        SearchMessageOrigin.proactive,
        SearchMessageOrigin.autoChat,
        SearchMessageOrigin.regeneration,
      ]) {
        final decision = detector.detect(
          'search the web for the latest news',
          origin: origin,
        );
        expect(decision.shouldSearch, isFalse, reason: origin.name);
      }
    });
  });

  group('SearchQuerySanitizer', () {
    const sanitizer = SearchQuerySanitizer();

    test('redacts keys, bearer, JWT, PEM, long tokens and local paths', () {
      const jwt =
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature123456';
      const pem = '''-----BEGIN PRIVATE KEY-----
secret-material
-----END PRIVATE KEY-----''';
      const query =
          'search api_key=sk-live-test-secret Bearer abcdefghijklmnop '
          '$jwt $pem 0123456789abcdef0123456789abcdef '
          '/Users/alice/Documents/attachment.txt';

      final result = sanitizer.sanitize(query);

      expect(result.containsSensitiveData, isTrue);
      expect(result.text, isNot(contains('sk-live-test-secret')));
      expect(result.text, isNot(contains('Bearer')));
      expect(result.text, isNot(contains('eyJ')));
      expect(result.text, isNot(contains('BEGIN PRIVATE KEY')));
      expect(result.text, isNot(contains('/Users/alice')));
      expect(
          result.findings.map((finding) => finding.type),
          containsAll([
            SearchSecretType.apiKey,
            SearchSecretType.bearerToken,
            SearchSecretType.jwt,
            SearchSecretType.pemPrivateKey,
            SearchSecretType.longHexToken,
            SearchSecretType.localPath,
          ]));
    });

    test('keeps ordinary product versions and enforces query length', () {
      final result = const SearchQuerySanitizer(maxQueryLength: 40).sanitize(
        'Flutter 3.24.0 stable release notes and migration guide',
      );

      expect(result.containsSensitiveData, isFalse);
      expect(result.wasTruncated, isTrue);
      expect(result.text.length, lessThanOrEqualTo(40));
      expect(result.text, contains('3.24.0'));
    });

    test('redacts a Bearer token nested inside an Authorization assignment',
        () {
      final result = sanitizer.sanitize(
        'search Authorization: Bearer nested-secret-token-123456789',
      );

      expect(result.containsSensitiveData, isTrue);
      expect(result.text, isNot(contains('nested-secret-token-123456789')));
    });

    test('removes script and style fragments before any network boundary', () {
      final result = sanitizer.sanitize(
        '<script>api_key=sk-live-secret</script><style>.x{}</style> Flutter',
      );

      expect(result.wasMarkupStripped, isTrue);
      expect(result.text, 'Flutter');
      expect(result.text, isNot(contains('sk-live-secret')));
    });
  });

  group('SearchQueryPlanner', () {
    test('parses strict JSON and records the independent Gateway purpose',
        () async {
      final store = MemoryGovernanceStore();
      final client = _PlannerClient([_validPlanJson()]);
      final planner = _planner(store, client);
      final decision = const SearchIntentDetector().detect(
        '帮我查 Flutter 最新稳定版',
      );

      final plan = await planner.plan(
        userMessage: '帮我查 Flutter 最新稳定版',
        decision: decision,
        minimalContext:
            '只保留 Flutter 这个实体 ${List.filled(2000, 'x').join()} 尾部完整历史',
      );

      expect(plan.usedPlanner, isTrue);
      expect(plan.primaryQuery, 'Flutter latest stable release');
      expect(plan.fallbackQuery, contains('docs.flutter.dev'));
      expect(
          store.ledgerEntries.single.purpose, AiRequestPurpose.searchPlanning);
      expect(store.diagnostics.single.purpose, AiRequestPurpose.searchPlanning);
      expect(client.calls.single, hasLength(2));
      expect(client.calls.single['content'], contains('只保留 Flutter'));
      expect(client.calls.single['content'], isNot(contains('完整历史')));
      expect(client.calls.single['content'].toString().length, lessThan(2500));
    });

    test('repairs invalid JSON once', () async {
      final store = MemoryGovernanceStore();
      final client = _PlannerClient(['not json', _validPlanJson()]);
      final planner = _planner(store, client);
      final decision =
          const SearchIntentDetector().detect('search latest Flutter');

      final plan = await planner.plan(
        userMessage: 'search latest Flutter',
        decision: decision,
      );

      expect(plan.usedPlanner, isTrue);
      expect(plan.repairedJson, isTrue);
      expect(client.sendCount, 2);
      expect(client.calls[1].values.join(' '), contains('只修复格式'));
    });

    test('stops after one failed repair and uses local query', () async {
      final store = MemoryGovernanceStore();
      final client = _PlannerClient(['not json', '{"wrong":true}']);
      final planner = _planner(store, client);
      final decision =
          const SearchIntentDetector().detect('search latest Flutter');

      final plan = await planner.plan(
        userMessage: 'search latest Flutter',
        decision: decision,
      );

      expect(client.sendCount, 2);
      expect(plan.usedPlanner, isFalse);
      expect(plan.primaryQuery, 'search latest Flutter');
    });

    test('propagates cancellation to the optional planner request', () async {
      final store = MemoryGovernanceStore();
      final client = _PlannerClient([_validPlanJson()]);
      final planner = _planner(store, client);
      final decision =
          const SearchIntentDetector().detect('search latest Flutter');
      final cancelToken = CancelToken();

      await planner.plan(
        userMessage: 'search latest Flutter',
        decision: decision,
        cancelToken: cancelToken,
      );

      expect(client.receivedCancelToken, isNot(same(cancelToken)));
      cancelToken.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(client.receivedCancelToken?.isCancelled, isTrue);
    });

    test('bounds an uncooperative planner request without cancelling search',
        () async {
      final store = MemoryGovernanceStore();
      final client = _PlannerClient(const [], hang: true);
      final planner = _planner(
        store,
        client,
        requestTimeout: const Duration(milliseconds: 20),
      );
      final decision =
          const SearchIntentDetector().detect('search latest Flutter');
      final parentCancelToken = CancelToken();

      final plan = await planner.plan(
        userMessage: 'search latest Flutter',
        decision: decision,
        cancelToken: parentCancelToken,
      );

      expect(plan.usedPlanner, isFalse);
      expect(plan.primaryQuery, 'search latest Flutter');
      expect(client.receivedReceiveTimeout, const Duration(milliseconds: 20));
      expect(client.receivedCancelToken, isNot(same(parentCancelToken)));
      expect(client.receivedCancelToken?.isCancelled, isTrue);
      expect(parentCancelToken.isCancelled, isFalse);
    });

    test('rejects an oversized planner response before JSON repair', () async {
      final store = MemoryGovernanceStore();
      final client = _PlannerClient([
        'x' * (SearchQueryPlanner.maxPlannerResponseBytes + 1),
        _validPlanJson(),
      ]);
      final planner = _planner(store, client);
      final decision =
          const SearchIntentDetector().detect('search latest Flutter');

      final plan = await planner.plan(
        userMessage: 'search latest Flutter',
        decision: decision,
      );

      expect(client.sendCount, 1);
      expect(
        client.receivedMaxResponseBytes,
        SearchQueryPlanner.maxPlannerResponseBytes,
      );
      expect(plan.usedPlanner, isFalse);
    });

    test('shares one end-to-end deadline between Planner and Provider',
        () async {
      final store = MemoryGovernanceStore(
        globalSearchPolicy: WebSearchPolicy.auto,
      );
      final client = _PlannerClient([_validPlanJson()]);
      final provider = _SequenceProvider(
        [_successResponse()],
        delay: const Duration(milliseconds: 200),
      );
      final coordinator = SearchCoordinator(
        store: store,
        routes: [SearchProviderRoute(provider: provider)],
        queryPlanner: _planner(store, client),
        endToEndBudget: const Duration(milliseconds: 40),
      );
      final stopwatch = Stopwatch()..start();

      final result = await coordinator.searchIfAllowed(
        text: 'search latest Flutter',
        conversationId: 'deadline-test',
        requestConsent: (_) async => true,
      );
      stopwatch.stop();

      expect(result?.hasFailure, isTrue);
      expect(client.sendCount, 1);
      expect(provider.searchCount, 1);
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
    });

    test('direct search uses the coordinator budget when no deadline is given',
        () async {
      final store = MemoryGovernanceStore(
        globalSearchPolicy: WebSearchPolicy.auto,
      );
      final provider = _SequenceProvider(
        [_successResponse()],
        delay: const Duration(milliseconds: 200),
      );
      final coordinator = SearchCoordinator(
        store: store,
        routes: [SearchProviderRoute(provider: provider)],
        endToEndBudget: const Duration(milliseconds: 40),
      );

      final result = await coordinator.search(
        request: SearchRequest(query: 'search latest Flutter'),
        conversationId: 'direct-budget-test',
      );

      expect(result?.hasFailure, isTrue);
      expect(provider.searchCount, 1);
    });

    test('consent wait does not consume the end-to-end search budget',
        () async {
      final clock = _FakeClock();
      final store = MemoryGovernanceStore(
        globalSearchPolicy: WebSearchPolicy.ask,
      );
      final provider = _SequenceProvider([_successResponse()]);
      final coordinator = SearchCoordinator(
        store: store,
        routes: [SearchProviderRoute(provider: provider)],
        clock: clock.call,
        endToEndBudget: const Duration(milliseconds: 20),
      );

      final result = await coordinator.searchIfAllowed(
        text: 'search Flutter latest',
        conversationId: 'consent-budget-test',
        requestConsent: (_) async {
          clock.advance(const Duration(milliseconds: 50));
          return true;
        },
      );

      expect(result?.hasResults, isTrue);
      expect(provider.searchCount, 1);
    });

    test('fallback consent wait also remains outside the search budget',
        () async {
      final clock = _FakeClock();
      final store = MemoryGovernanceStore(
        globalSearchPolicy: WebSearchPolicy.ask,
      );
      final provider = _SequenceProvider([
        _noResultsResponse(),
        _successResponse(),
      ]);
      final coordinator = SearchCoordinator(
        store: store,
        routes: [SearchProviderRoute(provider: provider)],
        clock: clock.call,
        endToEndBudget: const Duration(milliseconds: 20),
      );

      final result = await coordinator.searchIfAllowed(
        text: 'search Flutter latest',
        conversationId: 'fallback-consent-budget-test',
        requestConsent: (_) async {
          clock.advance(const Duration(milliseconds: 50));
          return true;
        },
      );

      expect(result?.hasResults, isTrue);
      expect(provider.searchCount, 2);
    });
  });
}
