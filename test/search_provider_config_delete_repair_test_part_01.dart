part of 'search_provider_config_delete_repair_test.dart';

void _registerSearchProviderConfigDeleteRepairTestPart1() {
  test('metadata failure restores the previous secure credential', () async {
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
      credentialId: 'credential.web-search.search-1',
      hasCredential: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    store.values[repository.credentialIdFor(config.id)] = 'old-key';
    store.afterWrite = () async => box.close();

    final result = await settings.save(config, enteredCredential: 'new-key');

    expect(result.isSuccess, isFalse);
    expect(store.values[repository.credentialIdFor(config.id)], 'old-key');
  });

  test('failed credential rotation restores the previous secure credential',
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
      id: 'search-rotation',
      name: 'Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      credentialId: 'credential.web-search.search-rotation',
      hasCredential: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    store.values[repository.credentialIdFor(config.id)] = 'old-key';
    store.afterWrite = () async {
      store.nextReadValueOverride = 'verification-mismatch';
    };

    final result = await settings.save(config, enteredCredential: 'new-key');

    expect(result.isSuccess, isFalse);
    expect(store.values[repository.credentialIdFor(config.id)], 'old-key');
    expect(settings.findById(config.id)!.credentialId,
        repository.credentialIdFor(config.id));
  });

  test('switching to a keyless provider removes the previous secure credential',
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
    const previous = SearchProviderConfig(
      id: 'search-switch',
      name: 'Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      credentialId: 'credential.web-search.search-switch',
      hasCredential: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [previous.toMap()]);
    store.values[repository.credentialIdFor(previous.id)] = 'old-key';

    final result = await settings.save(
      const SearchProviderConfig(
        id: 'search-switch',
        name: 'DuckDuckGo',
        provider: SearchProviderKind.duckDuckGoInstantAnswer,
        baseUrl: 'https://api.duckduckgo.com/',
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(store.values, isEmpty);
    expect(settings.findById(previous.id)!.hasCredential, isFalse);
  });

  test('failed credential deletion does not switch to a keyless provider',
      () async {
    final store = _MemoryCredentialStore()..deleteError = StateError('denied');
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: true,
    );
    const previous = SearchProviderConfig(
      id: 'search-switch-failure',
      name: 'Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      credentialId: 'credential.web-search.search-switch-failure',
      hasCredential: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [previous.toMap()]);
    store.values[repository.credentialIdFor(previous.id)] = 'old-key';

    final result = await settings.save(
      const SearchProviderConfig(
        id: 'search-switch-failure',
        name: 'DuckDuckGo',
        provider: SearchProviderKind.duckDuckGoInstantAnswer,
        baseUrl: 'https://api.duckduckgo.com/',
      ),
    );

    expect(result.isSuccess, isFalse);
    expect(settings.findById(previous.id)!.provider, SearchProviderKind.brave);
    expect(store.values[repository.credentialIdFor(previous.id)], 'old-key');
  });

  test('credential deletion failure restores the metadata', () async {
    final store = _MemoryCredentialStore()..deleteError = StateError('denied');
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
      id: 'search-delete',
      name: 'Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      credentialId: 'credential.web-search.search-delete',
      hasCredential: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    store.values[repository.credentialIdFor(config.id)] = 'saved-key';

    final result = await settings.delete(config.id);

    expect(result.isSuccess, isFalse);
    expect(settings.findById(config.id), isNotNull);
    expect(store.values[repository.credentialIdFor(config.id)], 'saved-key');
  });

  test('failed rollback leaves a durable credential repair marker', () async {
    final store = _MemoryCredentialStore()..deleteError = StateError('denied');
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    const config = SearchProviderConfig(
      id: 'search-delete-repair',
      name: 'Repair deletion',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      credentialId: 'credential.web-search.search-delete-repair',
      hasCredential: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    store.values[repository.credentialIdFor(config.id)] = 'saved-key';
    final settings = SearchProviderConfigStore(
      box: box,
      credentials: repository,
      isRelease: true,
    );
    store.beforeDelete = () => box.close();

    final failed = await settings.delete(config.id);

    expect(failed.isSuccess, isFalse);
    await Hive.close();
    await reopenLifecycleHive(hiveDirectory);
    final reopened = SearchProviderConfigStore(
      box: Hive.box<dynamic>('app_settings'),
      credentials: repository,
      isRelease: true,
    );
    final repairState = Hive.box<dynamic>('app_settings').get(
      SearchProviderConfigStore.credentialRepairKey,
    );
    expect(repairState, isA<Map>());
    expect(
      (repairState as Map)[config.id]['credentialId'],
      repository.credentialIdFor(config.id),
    );

    store.deleteError = null;
    final repaired = await reopened.delete(config.id);

    expect(repaired.isSuccess, isTrue);
    expect(store.values, isEmpty);
    expect(
      Hive.box<dynamic>('app_settings').get(
        SearchProviderConfigStore.credentialRepairKey,
      ),
      isNull,
    );
  });

  test('unknown credential binding refuses deletion and preserves metadata',
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
      id: 'search-unknown-binding',
      name: 'Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      credentialId: 'credential.other-domain.value',
      hasCredential: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final result = await settings.delete(config.id);

    expect(result.isSuccess, isFalse);
    expect(settings.findById(config.id), isNotNull);
    expect(store.deleteCount, 0);
  });

  test('unknown credential binding refuses credential rotation', () async {
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
      id: 'search-unknown-rotation',
      name: 'Unknown rotation',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      credentialId: 'credential.web-search.unmanaged',
      hasCredential: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final result = await settings.save(config, enteredCredential: 'new-key');

    expect(result.isSuccess, isFalse);
    expect(result.errorMessage, contains('无法安全迁移'));
    expect(store.values, isEmpty);
    expect(
      settings.findById(config.id)?.credentialId,
      'credential.web-search.unmanaged',
    );
  });

  test('unknown search binding has an explicit repair path', () async {
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
      id: 'search-repair',
      name: 'Repair',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      credentialId: 'credential.web-search.legacy-repair',
      hasCredential: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    store.values[config.credentialId] = 'legacy-key';

    expect(settings.canRepairUnknownCredentialBinding(config.id), isTrue);
    final result = await settings.repairUnknownCredentialBinding(config.id);

    expect(result.isSuccess, isTrue);
    expect(store.values, isEmpty);
    final repaired = settings.findById(config.id)!;
    expect(repaired.credentialId, isEmpty);
    expect(repaired.hasCredential, isFalse);
    expect(repaired.credentialRequired, isTrue);
    expect(repaired.requiresAttention, isTrue);
  });

  test('orphaned credential repair markers are enumerable and retryable',
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
    final credentialId = repository.credentialIdFor('orphan-repair');
    store.values[credentialId] = 'orphan-key';
    await box.put(SearchProviderConfigStore.credentialRepairKey, {
      'orphan-repair': {
        'configId': 'orphan-repair',
        'credentialId': credentialId,
        'operation': 'delete',
      },
    });

    expect(settings.pendingCredentialRepairIds, ['orphan-repair']);
    final repaired = await settings.retryPendingCredentialRepairs();

    expect(repaired, ['orphan-repair']);
    expect(store.values, isEmpty);
    expect(
      box.get(SearchProviderConfigStore.credentialRepairKey),
      isNull,
    );
  });

  test('completed binding repair retry preserves the repaired configuration',
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
    const config = SearchProviderConfig(
      id: 'repair-completed',
      name: 'Repaired Provider',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      credentialRequired: true,
      requiresAttention: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    await box.put(SearchProviderConfigStore.credentialRepairKey, {
      config.id: {
        'configId': config.id,
        'credentialId': repository.credentialIdFor(config.id),
        'operation': 'repair_binding',
      },
    });

    final repaired = await settings.retryPendingCredentialRepairs();

    expect(repaired, [config.id]);
    expect(settings.findById(config.id), isNotNull);
    expect(box.get(SearchProviderConfigStore.credentialRepairKey), isNull);
  });

  test('cross-domain unknown binding cannot be repaired by search', () async {
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
      id: 'search-cross-domain',
      name: 'Cross domain',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      credentialId: 'credential.api-config.other',
      hasCredential: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    store.values[config.credentialId] = 'must-remain-owned-by-api';

    expect(settings.canRepairUnknownCredentialBinding(config.id), isFalse);
    final result = await settings.repairUnknownCredentialBinding(config.id);

    expect(result.isSuccess, isFalse);
    expect(store.values[config.credentialId], 'must-remain-owned-by-api');
  });
}
