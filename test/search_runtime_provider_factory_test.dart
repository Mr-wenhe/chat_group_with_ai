import 'dart:io';

import 'package:chat_group/features/web_search/application/search_runtime_provider_factory.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/models/search_provider_config.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory hiveDirectory;
  late Box<dynamic> box;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    box = Hive.box<dynamic>('app_settings');
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

  test('adds the built-in DuckDuckGo fallback after configured routes', () async {
    const config = SearchProviderConfig(
      id: 'brave-primary',
      name: 'Brave',
      provider: SearchProviderKind.brave,
      baseUrl: 'https://api.search.example/v1',
      enabled: true,
      isDefault: true,
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
      ],
    );
    expect(routes.last.isFallback, isTrue);
    expect(routes.last.id, 'builtin-duckduckgo-fallback');
  });

  test('keeps the legacy route empty when no Provider is configured', () {
    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes();

    expect(routes, isEmpty);
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

    expect(routes, hasLength(1));
    expect(routes.single.kind, SearchProviderKind.duckDuckGoInstantAnswer);
  });
}
