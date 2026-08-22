import 'dart:io';

import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/features/web_search/application/search_provider_config_service.dart';
import 'package:chat_group/features/web_search/data/search_credential_repository.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/models/search_provider_config.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/features/web_search/security/search_endpoint_validator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

class _MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  int readCount = 0;
  int writeCount = 0;
  int deleteCount = 0;
  Object? writeError;
  Object? readError;
  Object? deleteError;
  Future<void> Function()? afterWrite;

  @override
  Future<void> delete(String key) async {
    deleteCount++;
    if (deleteError != null) throw deleteError!;
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    readCount++;
    if (readError != null) throw readError!;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCount++;
    if (writeError != null) throw writeError!;
    values[key] = value;
    final callback = afterWrite;
    afterWrite = null;
    if (callback != null) await callback();
  }
}

class _FakeSearchProvider implements SearchProvider {
  final SearchProviderKind providerKind;
  String? receivedCredential;

  _FakeSearchProvider(this.providerKind);

  @override
  SearchProviderKind get kind => providerKind;

  @override
  Future<SearchProviderResponse> search(
    request, {
    required String? credential,
    cancelToken,
  }) async {
    receivedCredential = credential;
    return SearchProviderResponse(items: const []);
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    receivedCredential = credential;
    return const SearchHealthResult(isHealthy: true, latencyMs: 4);
  }
}

void main() {
  late Directory hiveDirectory;
  late Box<dynamic> box;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    box = Hive.box<dynamic>('app_settings');
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

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

  test('gateway connection test can pass without a client credential',
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

    expect(result.isHealthy, isTrue);
    expect(provider.receivedCredential, isNull);
    expect(store.readCount, 0);
  });

  test('empty key on edit resolves the existing secure credential', () async {
    final store = _MemoryCredentialStore();
    final repository = SearchCredentialRepository(
      store: store,
      secureStorageAvailable: true,
    );
    store.values[repository.credentialIdFor('search-1')] = 'saved-key';
    final provider = _FakeSearchProvider(SearchProviderKind.brave);
    final service = SearchProviderConfigService(
      store: SearchProviderConfigStore(
        box: box,
        credentials: repository,
        isRelease: true,
      ),
      credentialResolver:
          SearchCredentialResolver(credentials: repository, isRelease: true),
      providerFactory: (_) => provider,
    );

    final result = await service.testConnection(
      config: SearchProviderConfig(
        id: 'search-1',
        name: 'Brave',
        provider: SearchProviderKind.brave,
        baseUrl: 'https://api.search.example/v1',
        credentialId: repository.credentialIdFor('search-1'),
        hasCredential: true,
      ),
      enteredCredential: '   ',
    );

    expect(result.isHealthy, isTrue);
    expect(provider.receivedCredential, 'saved-key');
    expect(store.writeCount, 0);
  });

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

  test('endpoint validation is strict in release and explicit for local dev',
      () {
    final cases = <String, bool>{
      'https://api.example.com/v1': true,
      'http://api.example.com/v1': false,
      'file:///tmp/search': false,
      'javascript:alert(1)': false,
      'https://user:pass@example.com': false,
      'https://example.com/search?api_key=secret': false,
      'https://127.0.0.1:8080/v1': false,
      'https://10.0.0.5/v1': false,
      'https://169.254.169.254/latest': false,
      'https://[::1]:8080/v1': false,
      'https://2130706433/v1': false,
      'https://0x7f000001/v1': false,
      'https://0177.0.0.1/v1': false,
    };
    for (final entry in cases.entries) {
      final result = SearchEndpointValidator.validate(
        entry.key,
        isRelease: true,
      );
      expect(result.isValid, entry.value, reason: entry.key);
    }

    expect(
      SearchEndpointValidator.validate(
        'http://127.0.0.1:8080/v1',
        isRelease: false,
        allowLocalDevelopmentGateway: true,
      ).isValid,
      isTrue,
    );

    expect(
      SearchEndpointValidator.sanitizeForBackup(
        'https://example.com/v1?api_key=secret#fragment',
      ),
      'https://example.com/v1',
    );
  });
}
