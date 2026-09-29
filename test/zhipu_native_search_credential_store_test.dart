import 'dart:io';

import 'package:chat_group/features/web_search/data/search_credential_repository.dart';
import 'package:chat_group/features/web_search/data/zhipu_native_search_credential_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late Box<dynamic> box;
  late MemoryCredentialStore secureStore;

  setUp(() async {
    directory = await openLifecycleHive();
    box = Hive.box<dynamic>('app_settings');
    secureStore = MemoryCredentialStore();
  });

  tearDown(() => closeLifecycleHive(directory));

  test('stores only a marker after secure save and resolves the key', () async {
    final store = ZhipuNativeSearchCredentialStore(
      box: box,
      credentials: SearchCredentialRepository(
        store: secureStore,
        secureStorageAvailable: true,
      ),
      isRelease: true,
      allowDevelopmentFallback: false,
    );

    final saved = await store.save('zhipu-secret');
    expect(saved.isSuccess, isTrue);
    expect(store.hasConfiguredCredential, isTrue);
    expect(await store.resolve(), 'zhipu-secret');
    final metadata = Map<dynamic, dynamic>.from(
      box.get(ZhipuNativeSearchCredentialStore.settingsKey) as Map,
    );
    expect(metadata['credentialId'], store.secureCredentialId);
    expect(metadata.containsKey('legacyApiKey'), isFalse);

    final cleared = await store.clear();
    expect(cleared.isSuccess, isTrue);
    expect(store.hasConfiguredCredential, isFalse);
    expect(await store.resolve(), isNull);
    expect(secureStore.values, isEmpty);
  });

  test('development fallback is explicit and unavailable in release', () async {
    final debugStore = ZhipuNativeSearchCredentialStore(
      box: box,
      credentials: SearchCredentialRepository(secureStorageAvailable: false),
      isRelease: false,
      allowDevelopmentFallback: true,
    );
    final saved = await debugStore.save('debug-secret');
    expect(saved.isSuccess, isTrue);
    expect(saved.usedDevelopmentFallback, isTrue);
    expect(await debugStore.resolve(), 'debug-secret');

    final releaseStore = ZhipuNativeSearchCredentialStore(
      box: box,
      credentials: SearchCredentialRepository(secureStorageAvailable: false),
      isRelease: true,
      allowDevelopmentFallback: false,
    );
    expect(releaseStore.hasConfiguredCredential, isFalse);
    expect(await releaseStore.resolve(), isNull);
  });

  test('rejects control characters before touching secure storage', () async {
    final store = ZhipuNativeSearchCredentialStore(
      box: box,
      credentials: SearchCredentialRepository(
        store: secureStore,
        secureStorageAvailable: true,
      ),
      isRelease: true,
    );
    final result = await store.save('bad\nkey');
    expect(result.isSuccess, isFalse);
    expect(secureStore.values, isEmpty);
    expect(box.get(ZhipuNativeSearchCredentialStore.settingsKey), isNull);
  });
}
