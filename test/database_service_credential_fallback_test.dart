import 'dart:io';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory hiveDirectory;
  late DatabaseService database;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    database = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

  test('debug saves a config when Keychain cannot persist the credential',
      () async {
    final config = ApiConfig(
      id: 'debug-keychain-fallback',
      name: 'debug',
      provider: 'custom',
      apiKey: 'secret',
    );

    await database.saveApiConfig(config);

    final saved = database.apiConfigBox.get(config.id)!;
    expect(saved.hasCredential, isTrue);
    expect(
      saved.credentialId,
      CredentialRepository.developmentHiveCredentialId,
    );
    expect(saved.legacyApiKeyForMigration, 'secret');

    await database.saveApiConfig(ApiConfig(
      id: config.id,
      name: 'renamed',
      provider: config.provider,
      customBaseUrl: config.customBaseUrl,
      createdAt: config.createdAt,
    ));

    final updated = database.apiConfigBox.get(config.id)!;
    expect(updated.name, 'renamed');
    expect(updated.legacyApiKeyForMigration, 'secret');
  });

  test('debug fallback config deletes without Keychain access', () async {
    final config = ApiConfig(
      id: 'debug-fallback-delete',
      name: 'debug',
      provider: 'custom',
      apiKey: 'secret',
      hasCredential: true,
      credentialId: CredentialRepository.developmentHiveCredentialId,
    );
    await database.apiConfigBox.put(config.id, config);

    final result = await DataLifecycleService(db: database).deleteApiConfig(
      config.id,
    );

    expect(result.isComplete, isTrue);
    expect(database.apiConfigBox.containsKey(config.id), isFalse);
  });
}
