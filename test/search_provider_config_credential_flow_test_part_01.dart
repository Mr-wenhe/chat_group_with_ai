part of 'search_provider_config_credential_flow_test.dart';

void _registerSearchProviderConfigCredentialFlowTestPart1() {
  test('config loading normalizes multiple default markers', () async {
    await box.put(
      SearchProviderConfigStore.configsKey,
      [
        const SearchProviderConfig(
          id: 'search-a',
          name: 'A',
          provider: SearchProviderKind.brave,
          baseUrl: 'https://a.example.com',
          isDefault: true,
        ).toMap(),
        const SearchProviderConfig(
          id: 'search-b',
          name: 'B',
          provider: SearchProviderKind.tavily,
          baseUrl: 'https://b.example.com',
          isDefault: true,
        ).toMap(),
      ],
    );
    await box.put(SearchProviderConfigStore.defaultProviderKey, 'search-b');

    final settings = SearchProviderConfigStore(box: box, isRelease: true);
    final configs = settings.configs;

    expect(configs.where((config) => config.isDefault), hasLength(1));
    expect(settings.findById('search-b')!.isDefault, isTrue);
  });

  test('release save rejects a new Gateway without a client token', () async {
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: SearchCredentialRepository(
        store: _MemoryCredentialStore(),
        secureStorageAvailable: true,
      ),
      isRelease: true,
    );

    final result = await settings.save(
      const SearchProviderConfig(
        id: 'gateway-without-token',
        name: 'Gateway',
        provider: SearchProviderKind.gateway,
        baseUrl: 'https://search.example.com',
      ),
    );

    expect(result.isSuccess, isFalse);
    expect(result.credentialFailure, CredentialFailure.unavailable);
    expect(settings.findById('gateway-without-token'), isNull);
  });

  test('Brave and Tavily saves reject missing credentials', () async {
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: SearchCredentialRepository(
        store: _MemoryCredentialStore(),
        secureStorageAvailable: true,
      ),
      isRelease: true,
    );

    for (final provider in [
      SearchProviderKind.brave,
      SearchProviderKind.tavily,
    ]) {
      final id = 'keyless-${provider.name}';
      final result = await settings.save(
        SearchProviderConfig(
          id: id,
          name: provider.name,
          provider: provider,
          baseUrl: 'https://search.example.com/v1',
        ),
      );

      expect(result.isSuccess, isFalse, reason: provider.name);
      expect(settings.findById(id), isNull);
    }
  });

  test('invalid persisted IDs block writes without normalization', () async {
    await box.put(SearchProviderConfigStore.configsKey, [
      const SearchProviderConfig(
        id: ' existing ',
        name: 'Malformed',
        provider: SearchProviderKind.duckDuckGoInstantAnswer,
        baseUrl: 'https://api.duckduckgo.com/',
      ).toMap(),
    ]);
    final settings = SearchProviderConfigStore(box: box, isRelease: true);

    final result = await settings.save(
      const SearchProviderConfig(
        id: 'new-provider',
        name: 'New',
        provider: SearchProviderKind.duckDuckGoInstantAnswer,
        baseUrl: 'https://api.duckduckgo.com/',
      ),
    );

    expect(result.isSuccess, isFalse);
    expect(
      (box.get(SearchProviderConfigStore.configsKey) as List).single['id'],
      ' existing ',
    );
  });

  test('failed candidate cleanup leaves a durable recovery marker', () async {
    final store = _MemoryCredentialStore()
      ..nextReadValueOverride = 'verification-mismatch'
      ..deleteError = StateError('keychain locked');
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: true,
    );

    final result = await settings.save(
      const SearchProviderConfig(
        id: 'recovery-marker',
        name: 'Recovery',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://search.example.com/v1',
      ),
      enteredCredential: 'new-key',
    );

    expect(result.isSuccess, isFalse);
    final marker = box.get(SearchProviderConfigStore.credentialRepairKey);
    expect(marker, isA<Map>());
    expect(
        (marker as Map)['recovery-marker']['operation'], 'credential_recovery');

    store.deleteError = null;
    expect(await settings.retryPendingCredentialRepairs(), ['recovery-marker']);
    expect(store.values, isEmpty);
    expect(box.get(SearchProviderConfigStore.credentialRepairKey), isNull);
  });

  test('marker write failure never clears an unresolved rotation candidate',
      () async {
    final store = _MemoryCredentialStore()
      ..nextReadValueOverride = 'verification-mismatch'
      ..deleteError = StateError('keychain locked');
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: true,
    );
    store.afterWrite = () async => box.close();

    final result = await settings.save(
      const SearchProviderConfig(
        id: 'marker-write-failure',
        name: 'Marker write failure',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://search.example.com/v1',
      ),
      enteredCredential: 'new-key',
    );

    expect(result.isSuccess, isFalse);
    await Hive.close();
    await reopenLifecycleHive(hiveDirectory);
    final reopened = SearchProviderConfigStore(
      box: Hive.box<dynamic>('app_settings'),
      credentials: repository,
      isRelease: true,
    );
    store.deleteError = null;

    final repaired = await reopened.retryPendingCredentialRepairs();

    expect(repaired, ['marker-write-failure']);
    expect(store.values, isEmpty);
    expect(
      Hive.box<dynamic>('app_settings')
          .get(SearchProviderConfigStore.credentialRepairKey),
      isNull,
    );
  });

  test('retry clears a stale rotation marker without deleting owned key',
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
    const config = SearchProviderConfig(
      id: 'rotation-marker-owned',
      name: 'Owned credential',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://search.example.com/v1',
      credentialId: 'credential.web-search.rotation-marker-owned',
      hasCredential: true,
    );
    store.values[config.credentialId] = 'still-usable';
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    await box.put(SearchProviderConfigStore.credentialRepairKey, {
      config.id: {
        'configId': config.id,
        'credentialId': config.credentialId,
        'operation': 'credential_rotation',
      },
    });

    expect(
      await settings.retryPendingCredentialRepairs(),
      [config.id],
    );
    expect(store.values[config.credentialId], 'still-usable');
    expect(box.get(SearchProviderConfigStore.credentialRepairKey), isNull);
  });

  test('formal save writes secure credential and delete removes it', () async {
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
    const config = SearchProviderConfig(
      id: 'search-1',
      name: 'Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
    );

    final saved = await settings.save(config, enteredCredential: 'saved-key');
    expect(saved.isSuccess, isTrue);
    expect(box.get(SearchProviderConfigStore.configsKey), isA<List>());
    expect(store.values[repository.credentialIdFor('search-1')], 'saved-key');

    final deleted = await settings.delete('search-1');
    expect(deleted.isSuccess, isTrue);
    expect(store.values, isEmpty);
    expect(settings.findById('search-1'), isNull);
  });
}
