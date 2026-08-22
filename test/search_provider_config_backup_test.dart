import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/backup/backup_restore_service.dart';
import 'package:chat_group/features/backup/backup_models.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory hiveDirectory;
  late Directory root;
  late Directory mediaDirectory;
  late DatabaseService db;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    root = await Directory.systemTemp.createTemp('search_provider_backup_');
    mediaDirectory = Directory('${hiveDirectory.path}/media')
      ..createSync(recursive: true);
    db = DatabaseService();
  });

  tearDown(() async {
    await closeLifecycleHive(hiveDirectory);
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('backup stores search metadata only and restore unbinds credentials',
      () async {
    const secret = 'debug-search-secret';
    await db.appSettingsBox.put(
      SearchProviderConfigStore.configsKey,
      [
        {
          'id': 'search-1',
          'name': 'Brave',
          'provider': 'brave',
          'baseUrl': 'https://api.example.com/v1?api_key=url-secret#fragment',
          'enabled': true,
          'isDefault': true,
          'credentialId': 'development-hive-web-search',
          'hasCredential': true,
          'legacyApiKey': secret,
        },
      ],
    );
    await db.appSettingsBox.put(
      SearchProviderConfigStore.defaultProviderKey,
      'search-1',
    );

    final backup = File('${root.path}/search.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: root,
    );
    await service.createBackup(
      destination: backup,
      selection: const BackupSelection.configurationOnly(),
    );

    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
    final settingsFile = archive.findFile('data/settings.json')!;
    final settings = jsonDecode(utf8.decode(settingsFile.content)) as Map;
    final configs = settings[SearchProviderConfigStore.configsKey] as List;
    final restoredMetadata = configs.single as Map;
    expect(restoredMetadata['credentialId'], isNull);
    expect(restoredMetadata['legacyApiKey'], isNull);
    expect(restoredMetadata['baseUrl'], 'https://api.example.com/v1');
    expect(restoredMetadata['credentialRequired'], isTrue);
    expect(utf8.decode(settingsFile.content), isNot(contains(secret)));

    await closeLifecycleHive(hiveDirectory);
    hiveDirectory = await openLifecycleHive();
    mediaDirectory = Directory('${hiveDirectory.path}/media')
      ..createSync(recursive: true);
    db = DatabaseService();
    final restoreService = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: root,
    );
    final prepared = await restoreService.inspect(backup);
    addTearDown(prepared.dispose);
    await restoreService.restore(
      prepared,
      strategy: RestoreConflictStrategy.emptyOnly,
    );

    final restored = db.appSettingsBox.get(SearchProviderConfigStore.configsKey)
        as List<dynamic>;
    final restoredConfig = Map<String, dynamic>.from(restored.single as Map);
    expect(restoredConfig['credentialId'], '');
    expect(restoredConfig['hasCredential'], isFalse);
    expect(restoredConfig, isNot(contains('legacyApiKey')));
  });

  test('copy restore remaps search config IDs instead of duplicating them',
      () async {
    await db.appSettingsBox.put(
      SearchProviderConfigStore.configsKey,
      [
        {
          'id': 'search-1',
          'name': 'Source',
          'provider': 'brave',
          'baseUrl': 'https://api.example.com/v1',
          'enabled': true,
          'isDefault': true,
          'credentialId': '',
          'hasCredential': false,
        },
      ],
    );
    await db.appSettingsBox.put(
      SearchProviderConfigStore.defaultProviderKey,
      'search-1',
    );

    final backup = File('${root.path}/copy-search.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: root,
    );
    await service.createBackup(
      destination: backup,
      selection: const BackupSelection.configurationOnly(),
    );

    await db.appSettingsBox.put(
      SearchProviderConfigStore.configsKey,
      [
        {
          'id': 'search-1',
          'name': 'Existing',
          'provider': 'brave',
          'baseUrl': 'https://api.example.com/v1',
          'enabled': true,
          'isDefault': true,
          'credentialId': 'credential.web-search.search-1',
          'hasCredential': true,
        },
      ],
    );

    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);
    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.copyWithNewIds,
    );

    final restored = (db.appSettingsBox
            .get(SearchProviderConfigStore.configsKey) as List<dynamic>)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final ids = restored.map((item) => item['id']).toSet();
    expect(restored, hasLength(2));
    expect(ids, hasLength(2));
    final imported = restored.singleWhere((item) => item['name'] == 'Source');
    expect(imported['credentialId'], '');
    expect(imported['hasCredential'], isFalse);
  });
}
