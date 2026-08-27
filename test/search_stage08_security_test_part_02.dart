part of 'search_stage08_security_test.dart';

void _registerSearchStage08SecurityTestPart2() {
  test('untrusted provider failures are reduced to canonical diagnostics', () {
    final failure = mapSearchFailure(
      const SearchFailure(
        type: SearchFailureType.invalidResponse,
        safeMessage: 'response body api_key=body-secret',
        retryable: true,
        providerRequestId: 'Authorization: Bearer body-secret',
      ),
    );

    expect(failure.safeMessage, '搜索服务返回了无法识别的结果格式');
    expect(failure.providerRequestId, isNull);
    expect(failure.retryable, isFalse);
  });

  test('clearing search cache does not retain an in-flight result', () async {
    final cache = SearchTurnCache();
    final gate = Completer<String>();
    final key = SearchTurnCacheKey(
      sourceMessageId: 'message-stage08',
      turnId: 'turn-stage08',
      normalizedQuery: 'Flutter security',
      freshness: SearchFreshness.any,
      provider: 'brave',
    );
    final pending = cache.getOrLoad<String>(
      key: key,
      ttl: const Duration(minutes: 5),
      loader: () => gate.future,
    );

    SearchTurnCache.clearAll();
    gate.complete('stale-result');

    expect(await pending, 'stale-result');
    expect(cache.completedCount, 0);
  });

  test('turn cache evicts the oldest completed entries at its bound', () async {
    final cache = SearchTurnCache(maxEntries: 2);
    Future<String> load(String value) async => value;

    SearchTurnCacheKey key(String value) => SearchTurnCacheKey(
          sourceMessageId: value,
          turnId: value,
          normalizedQuery: value,
          freshness: SearchFreshness.any,
          provider: 'brave',
        );

    await cache.getOrLoad(
      key: key('one'),
      ttl: const Duration(minutes: 5),
      loader: () => load('one'),
    );
    await cache.getOrLoad(
      key: key('two'),
      ttl: const Duration(minutes: 5),
      loader: () => load('two'),
    );
    await cache.getOrLoad(
      key: key('three'),
      ttl: const Duration(minutes: 5),
      loader: () => load('three'),
    );

    expect(cache.completedCount, 2);
    var reloads = 0;
    await cache.getOrLoad(
      key: key('one'),
      ttl: const Duration(minutes: 5),
      loader: () async {
        reloads++;
        return 'one-again';
      },
    );
    expect(reloads, 1);
  });
}
