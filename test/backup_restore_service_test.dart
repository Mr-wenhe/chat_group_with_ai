import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/backup/backup_models.dart';
import 'package:chat_group/features/backup/backup_entity_codec.dart';
import 'package:chat_group/features/backup/backup_inspector.dart';
import 'package:chat_group/features/backup/backup_restore_service.dart';
import 'package:chat_group/features/backup/staged_backup_data.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:chat_group/features/ai_character/character_gender_migration_state.dart';
import 'package:chat_group/features/memory/memory_migrator.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

part 'backup_restore_service_test_helpers_01.dart';
part 'backup_restore_service_test_helpers_02.dart';
part 'backup_restore_service_test_part_01.dart';
part 'backup_restore_service_test_part_02.dart';
part 'backup_restore_service_test_part_03.dart';
part 'backup_restore_service_test_part_04.dart';
part 'backup_restore_service_test_part_05.dart';

class _FakeGenderMigrator extends CharacterGenderMigrator {
  final bool complete;
  bool called = false;
  Set<String> candidateIdsAtCall = {};

  _FakeGenderMigrator(
    super.db, {
    required this.complete,
  });

  @override
  Future<int> migrate() async {
    called = true;
    final raw = db.appSettingsBox.get(CharacterGenderMigrator.stateKey);
    final state =
        raw is Map ? CharacterGenderMigrationState.tryFromMap(raw) : null;
    candidateIdsAtCall = {...?state?.candidateIds};
    if (!complete) return 0;

    for (final id in candidateIdsAtCall) {
      final character = db.aiCharacterBox.get(id);
      if (character == null) continue;
      await db.aiCharacterBox
          .put(id, character.withGender(CharacterGender.male));
    }
    await db.appSettingsBox.put(CharacterGenderMigrator.migrationKey, true);
    await db.appSettingsBox.delete(CharacterGenderMigrator.stateKey);
    return candidateIdsAtCall.length;
  }
}

late Directory testRoot;
late Directory hiveDirectory;
late Directory mediaDirectory;
late DatabaseService db;

Future<void> reopenEmptyDatabase() async {
  await closeLifecycleHive(hiveDirectory);
  hiveDirectory = await openLifecycleHive();
  mediaDirectory = Directory('${hiveDirectory.path}/media');
  await mediaDirectory.create();
  db = DatabaseService();
}

void main() {
  setUp(() async {
    testRoot = await Directory.systemTemp.createTemp('backup_restore_test_');
    hiveDirectory = await openLifecycleHive();
    mediaDirectory = Directory('${hiveDirectory.path}/media');
    await mediaDirectory.create();
    db = DatabaseService();
  });

  tearDown(() async {
    await closeLifecycleHive(hiveDirectory);
    if (await testRoot.exists()) await testRoot.delete(recursive: true);
  });

  _registerBackupRestoreServiceTestPart1();
  _registerBackupRestoreServiceTestPart2();
  _registerBackupRestoreServiceTestPart3();
  _registerBackupRestoreServiceTestPart4();
  _registerBackupRestoreServiceTestPart5();
}
