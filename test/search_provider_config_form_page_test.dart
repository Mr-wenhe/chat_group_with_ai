import 'dart:io';

import 'package:chat_group/features/settings/search_provider_config_form_page.dart';
import 'package:chat_group/features/web_search/data/search_credential_repository.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

class _MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  int readCount = 0;
  int writeCount = 0;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async {
    readCount++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writeCount++;
    values[key] = value;
  }
}

class _HealthyProvider implements SearchProvider {
  String? credential;

  @override
  SearchProviderKind get kind => SearchProviderKind.brave;

  @override
  Future<SearchProviderResponse> search(
    request, {
    required String? credential,
    cancelToken,
  }) async =>
      SearchProviderResponse(items: const []);

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    this.credential = credential;
    return const SearchHealthResult(isHealthy: true);
  }
}

void main() {
  late Directory hiveDirectory;
  late Box<dynamic> box;
  late _MemoryCredentialStore secureStore;
  late SearchProviderConfigStore settings;
  late _HealthyProvider provider;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    box = Hive.box<dynamic>('app_settings');
    secureStore = _MemoryCredentialStore();
    final credentials = SearchCredentialRepository(
      store: secureStore,
      secureStorageAvailable: true,
    );
    settings = SearchProviderConfigStore(
      box: box,
      credentials: credentials,
      isRelease: true,
    );
    provider = _HealthyProvider();
  });

  tearDown(() async {
    if (Hive.isBoxOpen('app_settings')) {
      await box.flush();
    }
    await closeLifecycleHive(hiveDirectory);
  });

  testWidgets('new key connection test does not persist before save',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SearchProviderConfigFormPage(
          store: settings,
          providerFactory: (_) => provider,
        ),
      ),
    );

    await tester.enterText(
        find.byKey(const ValueKey('search-config-name')), 'Brave');
    await tester.enterText(
      find.byKey(const ValueKey('search-config-base-url')),
      'https://api.example.com/v1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('search-config-credential')),
      'fresh-key',
    );
    await tester.tap(find.text('测试连接'));
    await tester.pump();

    expect(provider.credential, 'fresh-key');
    expect(secureStore.writeCount, 0);
    expect(secureStore.readCount, 0);
    expect(box.get(SearchProviderConfigStore.configsKey), isNull);

    await tester.tap(find.text('保存配置').last);
    await tester.pump();
    await tester.pump();
    expect(box.get(SearchProviderConfigStore.configsKey), isA<List>());
    expect(secureStore.writeCount, greaterThan(0));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.runAsync(() => box.flush());
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
