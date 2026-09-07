import 'dart:io';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/features/web_search/application/search_runtime_provider_factory.dart';
import 'package:chat_group/features/web_search/data/search_credential_repository.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/models/search_provider_config.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/native_web_search_adapter.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/features/web_search/presentation/web_search_settings_section.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

class _EmptyCredentialStore implements CredentialStore {
  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {}
}

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _UnauthorizedSearchProvider implements SearchProvider {
  int searchCount = 0;
  String? healthCredential;

  @override
  SearchProviderKind get kind => SearchProviderKind.brave;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    searchCount++;
    return SearchProviderResponse(
      items: [],
      terminal: true,
      failure: const SearchFailure(
        type: SearchFailureType.unauthorized,
        safeMessage: 'unauthorized',
        retryable: false,
      ),
    );
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    healthCredential = credential;
    return const SearchHealthResult(isHealthy: false);
  }
}

void main() {
  test('Web builds do not expose a search Provider route', () {
    for (final isRelease in [false, true]) {
      for (final provider in SearchProviderKind.values) {
        expect(
          SearchRuntimeProviderFactory.isProviderAllowedForPlatform(
            provider,
            isWeb: true,
            isRelease: isRelease,
          ),
          isFalse,
        );
      }
    }
  });

  late Directory hiveDirectory;
  late Box<dynamic> box;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    box = Hive.box<dynamic>('app_settings');
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

  test('adds the built-in DuckDuckGo fallback after configured routes',
      () async {
    const config = SearchProviderConfig(
      id: 'brave-primary',
      name: 'Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      enabled: true,
      isDefault: true,
      credentialId: 'credential.web-search.brave-primary',
      hasCredential: true,
      credentialRequired: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes();

    expect(
      routes.map((route) => route.kind),
      [
        SearchProviderKind.brave,
        SearchProviderKind.duckDuckGoInstantAnswer,
        SearchProviderKind.keylessHtml,
      ],
    );
    expect(routes.last.isFallback, isTrue);
    expect(routes.last.id, 'builtin-keyless-html');
  });

  test('uses the built-in DuckDuckGo route when no Provider is configured', () {
    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes();

    expect(routes, hasLength(2));
    expect(routes.first.kind, SearchProviderKind.duckDuckGoInstantAnswer);
    expect(routes.first.isFallback, isTrue);
    expect(routes.last.kind, SearchProviderKind.keylessHtml);
    expect(routes.last.isFallback, isTrue);
  });

  test('adds visible browser only as the final fallback when supplied', () {
    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes(
      visibleBrowserSearch: (request, {cancelToken}) async =>
          SearchProviderResponse(
              items: const [], sourceProvider: 'visibleBrowser'),
    );

    expect(routes, hasLength(3));
    expect(routes[0].kind, SearchProviderKind.duckDuckGoInstantAnswer);
    expect(routes[1].kind, SearchProviderKind.keylessHtml);
    expect(routes.last.isVisibleBrowser, isTrue);
    expect(routes.last.id, 'builtin-visible-browser');
  });

  test('excludes a Provider whose credential requires attention', () async {
    const config = SearchProviderConfig(
      id: 'expired-brave',
      name: 'Expired Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.brave.com/res/v1',
      enabled: true,
      isDefault: true,
      requiresAttention: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes();

    expect(routes, hasLength(2));
    expect(routes.first.kind, SearchProviderKind.duckDuckGoInstantAnswer);
    expect(routes.last.kind, SearchProviderKind.keylessHtml);
  });

  test('a route marked requiresAttention stops dispatching on the same page',
      () async {
    const config = SearchProviderConfig(
      id: 'brave-expired',
      name: 'Expired Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.brave.com/res/v1',
      enabled: true,
      credentialId: 'credential.web-search.brave-expired',
      hasCredential: true,
      credentialRequired: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    final credentialStore = _MemoryCredentialStore()
      ..values['credential.web-search.brave-expired'] = 'valid-key';
    final settings = SearchProviderConfigStore(
      box: box,
      isRelease: true,
      credentials: SearchCredentialRepository(
        store: credentialStore,
        secureStorageAvailable: true,
      ),
    );
    final delegate = _UnauthorizedSearchProvider();
    final provider = CredentialResolvingSearchProvider(
      config: config,
      resolver: SearchCredentialResolver(
        credentials: settings.credentials,
        isRelease: true,
      ),
      delegate: delegate,
      store: settings,
    );
    final request = SearchRequest(query: 'Flutter release');

    final first = await provider.search(request, credential: null);
    final second = await provider.search(request, credential: null);

    expect(first.failure?.type, SearchFailureType.unauthorized);
    expect(second.failure?.type, SearchFailureType.invalidConfiguration);
    expect(delegate.searchCount, 1);
    expect(settings.findById(config.id)?.requiresAttention, isTrue);
  });

  testWidgets('settings warns when a Provider credential requires attention',
      (tester) async {
    const config = SearchProviderConfig(
      id: 'expired-brave',
      name: 'Expired Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.brave.com/res/v1',
      enabled: true,
      requiresAttention: true,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SearchProviderConfigTile(config: config)),
      ),
    );

    expect(find.textContaining('需要重新验证凭据'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  test('does not duplicate an explicitly configured DuckDuckGo route',
      () async {
    const config = SearchProviderConfig(
      id: 'duck',
      name: 'DuckDuckGo',
      provider: SearchProviderKind.duckDuckGoInstantAnswer,
      baseUrl: 'https://api.duckduckgo.com/',
      enabled: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes();

    expect(routes, hasLength(2));
    expect(routes.first.kind, SearchProviderKind.duckDuckGoInstantAnswer);
    expect(routes.last.kind, SearchProviderKind.keylessHtml);
  });

  test('does not duplicate an explicitly configured keyless HTML route',
      () async {
    const config = SearchProviderConfig(
      id: 'duck-html',
      name: 'DuckDuckGo HTML',
      provider: SearchProviderKind.keylessHtml,
      baseUrl: '',
      enabled: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes();

    expect(
      routes.map((route) => route.kind),
      [
        SearchProviderKind.keylessHtml,
        SearchProviderKind.duckDuckGoInstantAnswer,
      ],
    );
    expect(
        routes.where((route) => route.kind == SearchProviderKind.keylessHtml),
        hasLength(1));
  });

  test('uses the built-in DuckDuckGo route when legacy metadata has no URL',
      () async {
    const config = SearchProviderConfig(
      id: 'duck-legacy',
      name: 'DuckDuckGo',
      provider: SearchProviderKind.duckDuckGoInstantAnswer,
      baseUrl: '',
      enabled: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes();

    expect(routes, hasLength(2));
    expect(routes.first.kind, SearchProviderKind.duckDuckGoInstantAnswer);
    expect(routes.last.kind, SearchProviderKind.keylessHtml);
  });

  test('builds the configured Gateway route instead of a disabled placeholder',
      () async {
    const config = SearchProviderConfig(
      id: 'gateway-primary',
      name: 'Company Gateway',
      provider: SearchProviderKind.gateway,
      baseUrl: 'https://search.example.com',
      enabled: true,
      isDefault: true,
      credentialId: 'credential.web-search.gateway-primary',
      hasCredential: true,
      credentialRequired: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes();

    expect(routes.first.kind, SearchProviderKind.gateway);
    expect(routes.first.isFallback, isFalse);
  });

  test('does not route a restored keyless provider', () async {
    const config = SearchProviderConfig(
      id: 'restored-gateway',
      name: 'Restored Gateway',
      provider: SearchProviderKind.gateway,
      baseUrl: 'https://search.example.com',
      enabled: true,
      credentialRequired: true,
      hasCredential: false,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes();

    expect(routes, hasLength(2));
    expect(routes.first.kind, SearchProviderKind.duckDuckGoInstantAnswer);
    expect(routes.last.kind, SearchProviderKind.keylessHtml);
  });

  test('does not route a keyless Gateway in release metadata', () async {
    const config = SearchProviderConfig(
      id: 'hand-edited-gateway',
      name: 'Hand edited Gateway',
      provider: SearchProviderKind.gateway,
      baseUrl: 'https://search.example.com',
      enabled: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes();

    expect(routes, hasLength(2));
    expect(routes.first.kind, SearchProviderKind.duckDuckGoInstantAnswer);
    expect(routes.last.kind, SearchProviderKind.keylessHtml);
  });

  test('marks a bound provider for attention when secure storage loses its key',
      () async {
    const config = SearchProviderConfig(
      id: 'missing-brave-key',
      name: 'Missing Brave key',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.brave.com/res/v1',
      enabled: true,
      credentialId: 'credential.web-search.missing-brave-key',
      hasCredential: true,
      credentialRequired: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    final credentials = SearchCredentialRepository(
      store: _EmptyCredentialStore(),
      secureStorageAvailable: true,
    );
    final store = SearchProviderConfigStore(
      box: box,
      credentials: credentials,
      isRelease: true,
    );
    final routes = SearchRuntimeProviderFactory(
      store: store,
      credentialResolver: SearchCredentialResolver(
        credentials: credentials,
        isRelease: true,
      ),
    ).buildRoutes();

    final response = await routes.first.provider.search(
      SearchRequest(query: 'Flutter release'),
      credential: null,
    );

    expect(response.failure?.type, SearchFailureType.invalidConfiguration);
    expect(store.findById(config.id)?.requiresAttention, isTrue);
  });

  test('bound provider health checks do not persist attention metadata',
      () async {
    const config = SearchProviderConfig(
      id: 'missing-brave-health-key',
      name: 'Missing Brave health key',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      enabled: true,
      credentialId: 'credential.web-search.missing-brave-health-key',
      hasCredential: true,
      credentialRequired: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    final credentials = SearchCredentialRepository(
      store: _EmptyCredentialStore(),
      secureStorageAvailable: true,
    );
    final store = SearchProviderConfigStore(
      box: box,
      credentials: credentials,
      isRelease: true,
    );
    final provider = CredentialResolvingSearchProvider(
      config: config,
      resolver: SearchCredentialResolver(
        credentials: credentials,
        isRelease: true,
      ),
      delegate: _UnauthorizedSearchProvider(),
      store: store,
    );

    final result = await provider.testConnection(
      credential: null,
      probeQuery: 'Flutter official documentation',
    );

    expect(result.isHealthy, isFalse);
    expect(store.findById(config.id)?.requiresAttention, isFalse);
  });

  test('bound provider health checks use the entered credential directly',
      () async {
    const config = SearchProviderConfig(
      id: 'fresh-brave-health-key',
      name: 'Fresh Brave health key',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      enabled: true,
      credentialId: 'credential.web-search.fresh-brave-health-key',
      hasCredential: true,
      credentialRequired: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);
    final credentials = SearchCredentialRepository(
      store: _EmptyCredentialStore(),
      secureStorageAvailable: true,
    );
    final store = SearchProviderConfigStore(
      box: box,
      credentials: credentials,
      isRelease: true,
    );
    final delegate = _UnauthorizedSearchProvider();
    final provider = CredentialResolvingSearchProvider(
      config: config,
      resolver: SearchCredentialResolver(
        credentials: credentials,
        isRelease: true,
      ),
      delegate: delegate,
      store: store,
    );

    await provider.testConnection(
      credential: 'fresh-health-key',
      probeQuery: 'Flutter official documentation',
    );

    expect(delegate.healthCredential, 'fresh-health-key');
  });

  test(
      'adds an explicitly bound native Qwen route before its independent fallback',
      () async {
    const config = SearchProviderConfig(
      id: 'gateway-primary',
      name: 'Company Gateway',
      provider: SearchProviderKind.gateway,
      baseUrl: 'https://search.example.com',
      enabled: true,
      isDefault: true,
      credentialId: 'credential.web-search.gateway-primary',
      hasCredential: true,
      credentialRequired: true,
    );
    await box.put(SearchProviderConfigStore.configsKey, [config.toMap()]);

    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes(
      nativeSearch: NativeWebSearchBinding(
        provider: ApiProvider.qwen,
        model: 'qwen-plus',
        resolveCredential: () async => 'dashscope-key',
      ),
    );

    expect(routes.first.provider, isA<NativeWebSearchProvider>());
    expect(routes[1].kind, SearchProviderKind.gateway);
  });

  test('native Qwen remains usable without a separately configured Provider',
      () {
    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes(
      nativeSearch: NativeWebSearchBinding(
        provider: ApiProvider.qwen,
        model: 'qwen-plus',
        resolveCredential: () async => 'dashscope-key',
      ),
    );

    expect(routes.first.provider, isA<NativeWebSearchProvider>());
    expect(routes.first.isPrimary, isTrue);
    expect(routes[1].kind, SearchProviderKind.duckDuckGoInstantAnswer);
    expect(routes.last.kind, SearchProviderKind.keylessHtml);
    expect(routes.last.isFallback, isTrue);
  });
}
