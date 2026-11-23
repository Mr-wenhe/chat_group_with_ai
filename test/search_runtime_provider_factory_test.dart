import 'dart:io';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/web_search/application/search_runtime_provider_factory.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/native_web_search_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

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

  test('native-only mode constructs no independent search providers', () {
    final routes = SearchRuntimeProviderFactory(
      store: SearchProviderConfigStore(box: box, isRelease: true),
    ).buildRoutes(
      nativeSearch: NativeWebSearchBinding(
        provider: ApiProvider.zhipu,
        model: 'glm-4-flash',
        resolveCredential: () async => 'role-key',
      ),
    );

    expect(routes, hasLength(1));
    expect(routes.single.isNative, isTrue);
    expect(routes.single.kind, SearchProviderKind.nativeModel);
    expect(routes.single.id, 'native:zhipu:glm-4-flash');
  });

  test('retired providers never create implicit fallback routes', () {
    final factory = SearchRuntimeProviderFactory(
        store: SearchProviderConfigStore(box: box, isRelease: true));
    expect(factory.buildRoutes(), isEmpty);
    expect(
        factory.buildRoutes(
            nativeSearch: NativeWebSearchBinding(
                provider: ApiProvider.qwen,
                model: 'qwen-plus',
                resolveCredential: () async => 'key')),
        isEmpty);
    for (final kind in SearchProviderKind.values) {
      expect(
          SearchRuntimeProviderFactory.isProviderAllowedForPlatform(kind,
              isWeb: false, isRelease: true),
          kind == SearchProviderKind.nativeModel);
    }
  });
}
