part of 'search_provider_config_security_test.dart';

void _registerSearchProviderConfigSecurityTestPart1() {
  test('search config round-trips as a map without an ApiConfig secret', () {
    const config = SearchProviderConfig(
      id: 'search-1',
      name: 'Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      enabled: true,
      isDefault: true,
      credentialId: 'credential.web-search.search-1',
      hasCredential: true,
    );

    final map = config.toMap();
    expect(map, isA<Map<String, dynamic>>());
    expect(map, isNot(contains('apiKey')));
    expect(map, isNot(contains('legacyApiKey')));
    expect(SearchProviderConfig.fromMap(map).credentialId,
        'credential.web-search.search-1');
  });

  test('search credentials use an isolated prefix and typed failures',
      () async {
    final store = _MemoryCredentialStore();
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );

    final saved = await repository.save('search-1', 'search-secret');
    expect(saved.isSuccess, isTrue);
    expect(store.values.keys, contains('credential.web-search.search-1'));
    expect(store.values.keys, isNot(contains('api_config_key_search-1')));

    store.readError = StateError('keychain unavailable');
    final read = await repository.read('search-1');
    expect(read.failure, CredentialFailure.systemError);
    expect(read.value, isNull);
  });

  test('failed credential verification removes the untracked candidate',
      () async {
    final store = _MemoryCredentialStore()
      ..nextReadValueOverride = 'different-value';
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );

    final result = await repository.save('search-1', 'new-secret');

    expect(result.isSuccess, isFalse);
    expect(result.canUseDevelopmentFallback, isFalse);
    expect(store.values, isEmpty);
    expect(store.deleteCount, 1);
  });

  test('credential read exception also removes the untracked candidate',
      () async {
    final store = _MemoryCredentialStore()..readError = StateError('denied');
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );

    final result = await repository.save('search-1', 'new-secret');

    expect(result.isSuccess, isFalse);
    expect(result.canUseDevelopmentFallback, isFalse);
    expect(store.values, isEmpty);
    expect(store.deleteCount, 1);
  });

  test('newly entered key is tested directly with zero credential writes',
      () async {
    final store = _MemoryCredentialStore();
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final provider = _FakeSearchProvider(SearchProviderKind.brave);
    final service = SearchProviderConfigService(
      store: SearchProviderConfigStore(
        box: box,
        credentials: repository,
        isRelease: false,
      ),
      credentialResolver: SearchCredentialResolver(credentials: repository),
      providerFactory: (_) => provider,
    );

    final result = await service.testConnection(
      config: const SearchProviderConfig(
        id: 'search-1',
        name: 'Brave',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://api.search.example/v1',
      ),
      enteredCredential: 'fresh-key',
    );

    expect(result.isHealthy, isTrue);
    expect(provider.receivedCredential, 'fresh-key');
    expect(store.writeCount, 0);
    expect(store.readCount, 0);
    expect(store.deleteCount, 0);
  });

  test('health details discard provider response text and unsafe IDs',
      () async {
    final store = _MemoryCredentialStore();
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final provider = _FakeSearchProvider(SearchProviderKind.brave)
      ..healthResult = const SearchHealthResult(
        isHealthy: false,
        requestId: 'request-health',
        providerRequestId: 'Authorization: Bearer body-secret',
        failure: SearchFailure(
          type: SearchFailureType.invalidResponse,
          safeMessage: 'response body api_key=body-secret',
          retryable: false,
        ),
      );
    final service = SearchProviderConfigService(
      store: SearchProviderConfigStore(
        box: box,
        credentials: repository,
        isRelease: false,
      ),
      credentialResolver: SearchCredentialResolver(credentials: repository),
      providerFactory: (_) => provider,
    );

    final result = await service.testConnection(
      config: const SearchProviderConfig(
        id: 'search-health',
        name: 'Brave',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://api.search.example/v1',
      ),
      enteredCredential: 'fresh-key',
    );

    expect(result.errorMessage, '搜索 Provider 连接测试失败');
    expect(result.health?.failure?.safeMessage, '搜索服务返回了无法识别的结果格式');
    expect(result.health?.providerRequestId, isNull);
    expect(result.health?.requestId, 'request-health');
    expect(result.health?.failure?.safeMessage, isNot(contains('body-secret')));
  });

  test('keyless DuckDuckGo connection test does not require a credential',
      () async {
    final store = _MemoryCredentialStore();
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final provider = _FakeSearchProvider(
      SearchProviderKind.duckDuckGoInstantAnswer,
    );
    final service = SearchProviderConfigService(
      store: SearchProviderConfigStore(
        box: box,
        credentials: repository,
        isRelease: true,
      ),
      credentialResolver: SearchCredentialResolver(credentials: repository),
      providerFactory: (_) => provider,
    );

    final result = await service.testConnection(
      config: const SearchProviderConfig(
        id: 'duckduckgo',
        name: 'DuckDuckGo',
        provider: SearchProviderKind.duckDuckGoInstantAnswer,
        baseUrl: 'https://api.duckduckgo.com/',
      ),
      enteredCredential: '',
    );

    expect(result.isHealthy, isTrue);
    expect(provider.receivedCredential, isNull);
    expect(store.readCount, 0);
  });

  test('DuckDuckGo connection test ignores legacy endpoint metadata', () async {
    final repository = SearchCredentialRepository(
      store: _MemoryCredentialStore(),
      secureStorageAvailable: true,
    );
    final provider = _FakeSearchProvider(
      SearchProviderKind.duckDuckGoInstantAnswer,
    );
    final service = SearchProviderConfigService(
      store: SearchProviderConfigStore(
        box: box,
        credentials: repository,
        isRelease: true,
      ),
      credentialResolver: SearchCredentialResolver(credentials: repository),
      providerFactory: (_) => provider,
    );

    final result = await service.testConnection(
      config: const SearchProviderConfig(
        id: 'duck-legacy',
        name: 'DuckDuckGo',
        provider: SearchProviderKind.duckDuckGoInstantAnswer,
        baseUrl: 'not a URL',
      ),
      enteredCredential: '',
    );

    expect(result.isHealthy, isTrue);
  });

  test('runtime settings discard invalid locale and country metadata', () {
    final settings = SearchRuntimeSettings.fromMap({
      'locale': 'not a locale value',
      'country': 'CHN',
    });

    expect(settings.locale, SearchRuntimeSettings.defaultLocale);
    expect(settings.country, isNull);
  });

  test('provider metadata drops oversized persisted fields', () {
    final config = SearchProviderConfig.fromMap({
      'id': List.filled(129, 'i').join(),
      'name': List.filled(81, 'n').join(),
      'baseUrl': 'https://example.com/${List.filled(2050, 'a').join()}',
      'credentialId': List.filled(257, 'c').join(),
      'provider': 'brave',
    });

    expect(config.id, isEmpty);
    expect(config.name, isEmpty);
    expect(config.baseUrl, isEmpty);
    expect(config.credentialId, isEmpty);

    final oversizedFallback = SearchProviderConfig.fromMap(
      {
        'id': 'legacy-fallback',
        'name': 'Legacy fallback',
        'provider': 'brave',
        'baseUrl': 'https://example.com',
        'credentialId': searchDevelopmentFallbackCredentialId,
        'hasCredential': true,
        'legacyApiKey': 'k' * (SearchProviderConfig.maxCredentialLength + 1),
      },
      allowDevelopmentFallback: true,
    );

    expect(oversizedFallback.invalidCredentialBinding, isTrue);
    expect(oversizedFallback.developmentLegacyApiKey, isNull);
  });

  test('public config store validates draft and entered credential bounds',
      () async {
    final repository = SearchCredentialRepository(
      store: _MemoryCredentialStore(),
      secureStorageAvailable: true,
    );
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: true,
    );

    final invalidDraft = await settings.save(
      const SearchProviderConfig(
        id: '',
        name: '',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://search.example.com',
      ),
    );
    final oversizedCredential = await settings.save(
      const SearchProviderConfig(
        id: 'bounded',
        name: 'Bounded',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://search.example.com',
      ),
      enteredCredential: List.filled(
        SearchProviderConfig.maxCredentialLength + 1,
        'x',
      ).join(),
    );

    expect(invalidDraft.isSuccess, isFalse);
    expect(oversizedCredential.isSuccess, isFalse);
    expect(box.get(SearchProviderConfigStore.configsKey), isNull);
  });

  test('credential repository rejects unbounded direct inputs', () async {
    final repository = SearchCredentialRepository(
      store: _MemoryCredentialStore(),
      secureStorageAvailable: true,
    );
    final oversizedId = 'i' * (SearchProviderConfig.maxIdLength + 1);
    final oversizedSecret =
        's' * (SearchProviderConfig.maxCredentialLength + 1);

    expect(repository.credentialIdFor(oversizedId), isEmpty);
    expect((await repository.save(oversizedId, 'secret')).isSuccess, isFalse);
    expect(
        (await repository.save('bounded', oversizedSecret)).isSuccess, isFalse);
    expect(
      (await repository.read(oversizedId)).failure,
      CredentialFailure.systemError,
    );
    expect(
      (await repository.delete(oversizedId)).failure,
      CredentialFailure.systemError,
    );
  });

  test('oversized persisted credential binding remains marked for repair',
      () async {
    final oversizedId = 'credential.web-search.${'x' * 300}';
    await box.put(SearchProviderConfigStore.configsKey, [
      {
        'id': 'oversized-binding',
        'name': 'Oversized binding',
        'provider': 'brave',
        'baseUrl': 'https://search.example.com',
        'credentialId': oversizedId,
        'hasCredential': true,
      },
    ]);
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: SearchCredentialRepository(
        store: _MemoryCredentialStore(),
        secureStorageAvailable: true,
      ),
      isRelease: true,
    );

    final config = settings.findById('oversized-binding')!;

    expect(config.credentialId, isEmpty);
    expect(config.invalidCredentialBinding, isTrue);
    expect(config.requiresAttention, isTrue);
    expect(settings.hasUnknownCredentialBinding(config.id), isTrue);
    expect((await settings.delete(config.id)).isSuccess, isFalse);
    expect(settings.findById(config.id), isNotNull);
  });

  test('release gateway connection test requires a client credential',
      () async {
    final store = _MemoryCredentialStore();
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final provider = _FakeSearchProvider(SearchProviderKind.gateway);
    final service = SearchProviderConfigService(
      store: SearchProviderConfigStore(
        box: box,
        credentials: repository,
        isRelease: true,
      ),
      credentialResolver: SearchCredentialResolver(credentials: repository),
      providerFactory: (_) => provider,
    );

    final result = await service.testConnection(
      config: const SearchProviderConfig(
        id: 'gateway',
        name: 'Gateway',
        provider: SearchProviderKind.gateway,
        baseUrl: 'https://gateway.example.com/v1',
      ),
      enteredCredential: '',
    );

    expect(result.isHealthy, isFalse);
    expect(result.credentialFailure, CredentialFailure.unavailable);
    expect(provider.receivedCredential, isNull);
    expect(store.readCount, 0);
  });

  test('existing Gateway token is resolved when its edit field is left blank',
      () async {
    final store = _MemoryCredentialStore();
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    expect(
        (await repository.save('gateway-existing', 'stored-token')).isSuccess,
        isTrue);
    final provider = _FakeSearchProvider(SearchProviderKind.gateway);
    final service = SearchProviderConfigService(
      store: SearchProviderConfigStore(
        box: box,
        credentials: repository,
        isRelease: true,
      ),
      credentialResolver: SearchCredentialResolver(
        credentials: repository,
        isRelease: true,
      ),
      providerFactory: (_) => provider,
    );

    final result = await service.testConnection(
      config: const SearchProviderConfig(
        id: 'gateway-existing',
        name: 'DuckDuckGo',
        provider: SearchProviderKind.duckDuckGoInstantAnswer,
        baseUrl: 'https://api.duckduckgo.com/',
        credentialId: 'credential.web-search.gateway-existing',
        hasCredential: true,
      ),
      enteredCredential: '',
    );

    expect(result.isHealthy, isTrue);
    expect(provider.receivedCredential, 'stored-token');
    expect(store.writeCount, 1);
    expect(store.readCount, 2);
  });
}
