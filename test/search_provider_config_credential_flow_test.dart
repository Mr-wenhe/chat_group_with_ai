import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/features/web_search/application/search_provider_config_service.dart';
import 'package:chat_group/features/web_search/data/search_credential_repository.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/models/search_provider_config.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

part 'search_provider_config_credential_flow_test_part_01.dart';
part 'search_provider_config_credential_flow_test_part_02.dart';

class _MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  int readCount = 0;
  int writeCount = 0;
  int deleteCount = 0;
  Object? writeError;
  Object? readError;
  Object? deleteError;
  Future<void> Function()? afterWrite;
  String? nextReadValueOverride;

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
    final override = nextReadValueOverride;
    nextReadValueOverride = null;
    if (override != null) return override;
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
  SearchHealthResult healthResult =
      const SearchHealthResult(isHealthy: true, latencyMs: 4);

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
    return healthResult;
  }
}

late Directory hiveDirectory;
late Box<dynamic> box;

void main() {
  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    box = Hive.box<dynamic>('app_settings');
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

  _registerSearchProviderConfigCredentialFlowTestPart1();
  _registerSearchProviderConfigCredentialFlowTestPart2();
}
