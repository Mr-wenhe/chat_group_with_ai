part of 'search_provider_config_credential_flow_test.dart';

void _registerSearchProviderConfigCredentialFlowTestPart2() {
  test('attention updates cannot overwrite a concurrent configuration save',
      () async {
    final store = _MemoryCredentialStore();
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: true,
    );
    final observer = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: true,
    );
    const original = SearchProviderConfig(
      id: 'search-concurrent',
      name: 'Original',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
    );
    await box.put(SearchProviderConfigStore.configsKey, [original.toMap()]);

    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    store.afterWrite = () async {
      writeStarted.complete();
      await releaseWrite.future;
    };
    final saveFuture = settings.save(
      original.copyWith(name: 'Renamed'),
      enteredCredential: 'new-key',
    );
    await writeStarted.future;

    final attentionFuture = observer.setRequiresAttention(
      original.id,
      true,
    );
    await Future<void>.delayed(Duration.zero);
    releaseWrite.complete();
    await Future.wait<void>([saveFuture, attentionFuture]);

    final saved = settings.findById(original.id)!;
    expect(saved.name, 'Renamed');
    expect(saved.requiresAttention, isTrue);
  });

  test('delete waits for a concurrent save instead of resurrecting metadata',
      () async {
    final store = _MemoryCredentialStore();
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: true,
    );
    final deleter = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: true,
    );
    const original = SearchProviderConfig(
      id: 'search-concurrent-delete',
      name: 'Original',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
    );
    await box.put(SearchProviderConfigStore.configsKey, [original.toMap()]);

    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    store.afterWrite = () async {
      writeStarted.complete();
      await releaseWrite.future;
    };
    final saveFuture = settings.save(
      original.copyWith(name: 'Resurrected'),
      enteredCredential: 'new-key',
    );
    await writeStarted.future;
    final deleteFuture = deleter.delete(original.id);
    await Future<void>.delayed(Duration.zero);
    releaseWrite.complete();

    await Future.wait<Object?>([saveFuture, deleteFuture]);

    expect(settings.findById(original.id), isNull);
    expect(store.values, isEmpty);
  });

  test('release write failure never stores a development fallback', () async {
    final store = _MemoryCredentialStore()..writeError = StateError('denied');
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: true,
      allowDevelopmentFallback: true,
    );

    final result = await settings.save(
      const SearchProviderConfig(
        id: 'search-1',
        name: 'Brave',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://api.search.example/v1',
      ),
      enteredCredential: 'must-not-enter-hive',
    );

    expect(result.isSuccess, isFalse);
    expect(result.credentialFailure, CredentialFailure.systemError);
    expect(box.get(SearchProviderConfigStore.configsKey), isNull);
  });

  test('debug fallback has its own marker and is resolved only outside release',
      () async {
    final store = _MemoryCredentialStore()..writeError = StateError('denied');
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: false,
      allowDevelopmentFallback: true,
    );
    final result = await settings.save(
      const SearchProviderConfig(
        id: 'search-1',
        name: 'Brave',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://api.search.example/v1',
      ),
      enteredCredential: 'debug-only-key',
    );

    expect(result.isSuccess, isTrue);
    final saved = settings.findById('search-1')!;
    expect(saved.credentialId,
        SearchCredentialRepository.developmentHiveCredentialId);
    expect(saved.credentialId,
        isNot(CredentialRepository.developmentHiveCredentialId));
    expect(saved.developmentLegacyApiKey, 'debug-only-key');

    final releaseResolver = SearchCredentialResolver(
      credentials: repository,
      isRelease: true,
    );
    expect(await releaseResolver.resolve(saved), isNull);
    expect(store.readCount, 0);

    final debugResolver = SearchCredentialResolver(
      credentials: repository,
      isRelease: false,
    );
    expect(await debugResolver.resolve(saved), 'debug-only-key');
  });

  test(
      'debug does not fall back to Hive after a completed write fails verification',
      () async {
    final store = _MemoryCredentialStore()
      ..nextReadValueOverride = 'different-value';
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: false,
      allowDevelopmentFallback: true,
    );

    final result = await settings.save(
      const SearchProviderConfig(
        id: 'search-1',
        name: 'Brave',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://api.search.example/v1',
      ),
      enteredCredential: 'must-not-enter-hive',
    );

    expect(result.isSuccess, isFalse);
    expect(box.get(SearchProviderConfigStore.configsKey), isNull);
    expect(store.values, isEmpty);
  });

  test('debug fallback also handles unavailable secure storage', () async {
    final store = _MemoryCredentialStore();
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: false,
    );
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: false,
      allowDevelopmentFallback: true,
    );

    final result = await settings.save(
      const SearchProviderConfig(
        id: 'search-unavailable',
        name: 'Brave',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://api.search.example/v1',
      ),
      enteredCredential: 'debug-only-key',
    );

    expect(result.isSuccess, isTrue);
    expect(settings.findById('search-unavailable')!.credentialId,
        SearchCredentialRepository.developmentHiveCredentialId);
  });

  test('local development gateway uses the same endpoint policy for testing',
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
        isRelease: false,
        allowDevelopmentFallback: true,
      ),
      credentialResolver: SearchCredentialResolver(credentials: repository),
      providerFactory: (_) => provider,
    );

    final result = await service.testConnection(
      config: const SearchProviderConfig(
        id: 'local-gateway',
        name: 'Local gateway',
        provider: SearchProviderKind.gateway,
        baseUrl: 'http://127.0.0.1:8080/v1',
      ),
      enteredCredential: 'local-key',
    );

    expect(result.isHealthy, isTrue);
    expect(provider.receivedCredential, 'local-key');
  });

  test('local development exception does not permit a public provider route',
      () async {
    final repository = SearchCredentialRepository(
      store: _MemoryCredentialStore(),
      secureStorageAvailable: true,
    );
    final provider = _FakeSearchProvider(SearchProviderKind.brave);
    final service = SearchProviderConfigService(
      store: SearchProviderConfigStore(
        box: box,
        credentials: repository,
        isRelease: false,
        allowDevelopmentFallback: true,
      ),
      credentialResolver: SearchCredentialResolver(credentials: repository),
      providerFactory: (_) => provider,
    );

    final result = await service.testConnection(
      config: const SearchProviderConfig(
        id: 'local-brave',
        name: 'Local Brave',
        provider: SearchProviderKind.brave,
        baseUrl: 'http://127.0.0.1:8080/v1',
      ),
      enteredCredential: 'local-key',
    );

    expect(result.isHealthy, isFalse);
    expect(provider.receivedCredential, isNull);
  });
}
