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
import 'package:chat_group/features/backup/backup_restore_service.dart';
import 'package:chat_group/features/backup/staged_backup_data.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:chat_group/features/ai_character/character_gender_migration_state.dart';
import 'package:chat_group/features/memory/memory_migrator.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

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
      character.gender = CharacterGender.male;
      await db.aiCharacterBox.put(id, character);
    }
    await db.appSettingsBox.put(CharacterGenderMigrator.migrationKey, true);
    await db.appSettingsBox.delete(CharacterGenderMigrator.stateKey);
    return candidateIdsAtCall.length;
  }
}

void main() {
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

  test('v2 backup excludes secrets and content-addresses attachments',
      () async {
    const secret = 'sk-stage04-must-never-leak';
    final attachment = File('${mediaDirectory.path}/note.txt');
    await attachment.writeAsString('same attachment');
    await _seedCoreData(db, attachment, apiKey: secret);
    final backup = File('${testRoot.path}/full.cgbak');

    final result = await BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    ).createBackup(destination: backup);

    expect(result.manifest.formatVersion, 1);
    expect(result.manifest.schemaVersion, 2);
    expect(result.manifest.counts['messages'], 2);
    expect(result.manifest.counts['attachments'], 1);
    expect(result.manifest.missingAttachments, isEmpty);
    expect(await backup.exists(), isTrue);
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
    expect(
      archive.files
          .any((file) => _containsBytes(file.content, utf8.encode(secret))),
      isFalse,
    );
    expect(
      archive.files.any(
          (file) => _containsBytes(file.content, utf8.encode('secure:api-1'))),
      isFalse,
    );

    final prepared = await BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    ).inspect(backup);
    addTearDown(prepared.dispose);
    expect(prepared.preview.credentialsToRebind, 1);
    expect(prepared.preview.attachmentCount, 1);
    expect(prepared.preview.checksumsValid, isTrue);
  });

  test('inspection is read-only and empty database restores references',
      () async {
    final attachment = File('${mediaDirectory.path}/photo.bin');
    await attachment.writeAsBytes([1, 2, 3, 4]);
    await _seedCoreData(db, attachment, apiKey: 'sk-not-exported');
    final sourceCharacter = db.aiCharacterBox.get('char-1')!;
    sourceCharacter.gender = CharacterGender.male;
    await sourceCharacter.save();
    final backup = File('${testRoot.path}/roundtrip.cgbak');
    final sourceService = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await sourceService.createBackup(destination: backup);

    await closeLifecycleHive(hiveDirectory);
    hiveDirectory = await openLifecycleHive();
    mediaDirectory = Directory('${hiveDirectory.path}/media');
    await mediaDirectory.create();
    db = DatabaseService();
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);
    expect(db.aiCharacterBox, isEmpty);
    expect(db.messageBox, isEmpty);

    final report = await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.emptyOnly,
    );

    expect(report.errors, isEmpty);
    expect(report.inserted['characters'], 1);
    expect(db.apiConfigBox.get('api-1')!.hasCredential, isFalse);
    expect(
      db.apiConfigBox.get('api-1')!.legacyApiKeyForMigration,
      isEmpty,
    );
    expect(
      db.apiConfigBox.get('api-1')!.customBaseUrl,
      'https://example.com/v1?region=cn',
    );
    expect(db.aiCharacterBox.get('char-1')!.apiKey, isEmpty);
    expect(db.aiCharacterBox.get('char-1')!.gender, CharacterGender.male);
    expect(db.chatGroupBox.get('group-1')!.aiCharacterIds, ['char-1']);
    expect(db.messageBox.get('msg-2')!.replyToMessageId, 'msg-1');
    expect(
      db.conversationSummaries()['group-1']?.lastMessageId,
      'msg-2',
    );
    expect(db.characterMemoryBox.get('memory-1')!.characterId, 'char-1');
    expect(
      db.relationshipStateBox.get('rel:char-1:ai:char-1')!.targetId,
      'char-1',
    );
    final restoredMedia = db.messageBox.get('msg-1')!.media!.single;
    expect(await File(restoredMedia.localPath).readAsBytes(), [1, 2, 3, 4]);
  });

  test('backup round-trip preserves both gender values', () async {
    final attachment = File('${mediaDirectory.path}/gender.txt');
    await attachment.writeAsString('gender');
    await _seedCoreData(db, attachment);
    final first = db.aiCharacterBox.get('char-1')!
      ..gender = CharacterGender.male;
    await first.save();
    final second = testCharacter('char-2', apiConfigId: 'api-1')
      ..gender = CharacterGender.female;
    await db.aiCharacterBox.put(second.id, second);

    final backup = File('${testRoot.path}/gender-roundtrip.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await service.createBackup(destination: backup);
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
    final records = _recordsFromArchive(archive, 'data/characters.json');
    expect(
      {
        for (final record in records)
          BackupEntityCodec.key(record):
              BackupEntityCodec.value(record)['gender'],
      },
      {'char-1': 'male', 'char-2': 'female'},
    );

    await reopenEmptyDatabase();
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);
    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.emptyOnly,
    );
    expect(db.aiCharacterBox.get('char-1')!.gender, CharacterGender.male);
    expect(db.aiCharacterBox.get('char-2')!.gender, CharacterGender.female);
  });

  test('repeated import supports skip and copy-with-new-ids', () async {
    final attachment = File('${mediaDirectory.path}/repeat.txt');
    await attachment.writeAsString('repeat');
    await _seedCoreData(db, attachment);
    final backup = File('${testRoot.path}/repeat.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await service.createBackup(destination: backup);

    final skipped = await service.inspect(backup);
    final skipReport = await service.restore(
      skipped,
      strategy: RestoreConflictStrategy.skipExisting,
    );
    await skipped.dispose();
    expect(skipReport.skipped['characters'], 1);
    expect(db.aiCharacterBox.length, 1);
    expect(db.messageBox.length, 2);

    final copied = await service.inspect(backup);
    final copyReport = await service.restore(
      copied,
      strategy: RestoreConflictStrategy.copyWithNewIds,
    );
    await copied.dispose();
    expect(copyReport.remapped['characters'], 1);
    expect(copyReport.remapped['messages'], 2);
    expect(db.aiCharacterBox.length, 2);
    expect(db.chatGroupBox.length, 2);
    expect(db.messageBox.length, 4);
    final copiedGroup = db.chatGroupBox.values.singleWhere(
      (group) => group.id != 'group-1',
    );
    final copiedCharacterId = copiedGroup.aiCharacterIds.single;
    expect(copiedCharacterId, isNot('char-1'));
    final copiedMessages = db.messageBox.values
        .where((message) => message.groupId == copiedGroup.id)
        .toList();
    expect(copiedMessages, hasLength(2));
    final copiedReply = copiedMessages.singleWhere((m) => m.content == 'reply');
    expect(copiedMessages.map((m) => m.id),
        contains(copiedReply.replyToMessageId));
    expect(
      db.groupMemoryBox.keys,
      contains('${copiedGroup.id}_2026-29'),
    );
  });

  test('rejects malicious paths and checksum corruption before writes',
      () async {
    final malicious = File('${testRoot.path}/malicious.cgbak');
    final archive = Archive()
      ..addFile(ArchiveFile.string('../outside.txt', 'escape'));
    await malicious.writeAsBytes(ZipEncoder().encodeBytes(archive));
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    await expectLater(
        service.inspect(malicious), throwsA(isA<BackupException>()));
    expect(await File('${testRoot.parent.path}/outside.txt').exists(), isFalse);
    expect(db.aiCharacterBox, isEmpty);

    final attachment = File('${mediaDirectory.path}/valid.txt');
    await attachment.writeAsString('valid');
    await _seedCoreData(db, attachment);
    final valid = File('${testRoot.path}/valid.cgbak');
    await service.createBackup(destination: valid);
    final decoded = ZipDecoder().decodeBytes(await valid.readAsBytes());
    final groups = decoded.findFile('data/groups.json')!;
    groups.content[0] ^= 0xff;
    final corrupt = File('${testRoot.path}/corrupt.cgbak');
    await corrupt.writeAsBytes(ZipEncoder().encodeBytes(decoded));

    await expectLater(
        service.inspect(corrupt), throwsA(isA<BackupException>()));
  });

  test('commit failure removes partial inserts and keeps existing data',
      () async {
    final attachment = File('${mediaDirectory.path}/rollback.txt');
    await attachment.writeAsString('rollback');
    await _seedCoreData(db, attachment);
    final backup = File('${testRoot.path}/rollback.cgbak');
    await BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    ).createBackup(destination: backup);

    await closeLifecycleHive(hiveDirectory);
    hiveDirectory = await openLifecycleHive();
    mediaDirectory = Directory('${hiveDirectory.path}/media');
    await mediaDirectory.create();
    db = DatabaseService();
    await db.aiCharacterBox.put('existing', testCharacter('existing'));
    await db.persistMessage(Message(
      id: 'existing-message',
      groupId: 'existing-conversation',
      senderId: 'user',
      senderType: 'user',
      content: 'keep indexed',
    ));
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
      onCommitWrite: (count) {
        if (count == 3) throw StateError('simulated commit failure');
      },
    );
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);

    await expectLater(
      service.restore(
        prepared,
        strategy: RestoreConflictStrategy.copyWithNewIds,
      ),
      throwsA(isA<BackupException>()),
    );

    expect(db.aiCharacterBox.keys, ['existing']);
    expect(db.apiConfigBox, isEmpty);
    expect(db.chatGroupBox, isEmpty);
    expect(db.messageBox.keys, ['existing-message']);
    expect(
      db.conversationSummaries()['existing-conversation']?.lastMessageId,
      'existing-message',
    );
    expect(await mediaDirectory.list().toList(), isEmpty);
  });

  test('configuration-only backup excludes messages and attachments', () async {
    final attachment = File('${mediaDirectory.path}/config-only.txt');
    await attachment.writeAsString('not included');
    await _seedCoreData(db, attachment);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    final estimate =
        await service.estimate(const BackupSelection.configurationOnly());
    final result = await service.createBackup(
      destination: File('${testRoot.path}/config-only.cgbak'),
      selection: const BackupSelection.configurationOnly(),
    );

    expect(estimate.counts['characters'], 1);
    expect(estimate.counts['messages'], 0);
    expect(estimate.attachmentCount, 0);
    expect(result.manifest.counts['messages'], 0);
    expect(result.manifest.counts['attachments'], 0);

    final prepared = await service.inspect(result.file);
    addTearDown(prepared.dispose);
    expect(
      prepared.manifest.files,
      isNot(contains('data/relationships.json')),
    );
  });

  test('conversation backup keeps only that conversation settings', () async {
    final attachment = File('${mediaDirectory.path}/conversation.txt');
    await attachment.writeAsString('conversation');
    await _seedCoreData(db, attachment);
    await db.appSettingsBox.putAll({
      'work_mode_enabled:group-1': true,
      'work_mode_enabled:other': true,
      'group_chat_read_at': {
        'group-1': '2026-07-16T00:00:00.000Z',
        'other': '2026-07-15T00:00:00.000Z',
      },
    });
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final backup = File('${testRoot.path}/conversation.cgbak');

    await service.createBackup(
      destination: backup,
      selection: const BackupSelection.conversation('group-1'),
    );
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);
    final settings = Map<String, dynamic>.from(jsonDecode(await File(
      '${prepared.stagingDirectory.path}/data/settings.json',
    ).readAsString()) as Map);

    expect(settings['work_mode_enabled:group-1'], isTrue);
    expect(settings, isNot(contains('work_mode_enabled:other')));
    expect(settings['group_chat_read_at'], {
      'group-1': '2026-07-16T00:00:00.000Z',
    });
  });

  test('v2 full backup includes global memory files and only global relations',
      () async {
    await _seedGlobalMemoryData(db, mediaDirectory);
    final backup = File('${testRoot.path}/global.cgbak');
    final result = await BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    ).createBackup(destination: backup);

    expect(result.manifest.schemaVersion, 2);
    expect(result.manifest.backupKind, BackupKind.full);
    expect(result.manifest.includesGlobalData, isTrue);
    expect(
      result.manifest.files.keys,
      containsAll([
        'data/user_profile.json',
        'data/permanent_memories.json',
        'data/relationship_events.json',
        'data/relationships.json',
      ]),
    );
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
    final relationships =
        _recordsFromArchive(archive, 'data/relationships.json');
    expect(
      relationships.map((record) => record['value']['groupId']),
      everyElement('global'),
    );
    expect(
      _recordsFromArchive(archive, 'data/permanent_memories.json'),
      hasLength(2),
    );
    expect(
      _recordsFromArchive(archive, 'data/relationship_events.json'),
      hasLength(2),
    );
  });

  test('v2 conversation backup isolates global evidence and marks legacy data',
      () async {
    await _seedGlobalMemoryData(db, mediaDirectory);
    final backup = File('${testRoot.path}/conversation-v2.cgbak');
    final result = await BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    ).createBackup(
      destination: backup,
      selection: const BackupSelection.conversation('group-1'),
    );
    final prepared = await BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    ).inspect(backup);
    addTearDown(prepared.dispose);
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());

    expect(result.manifest.backupKind, BackupKind.conversation);
    expect(result.manifest.conversationId, 'group-1');
    expect(result.manifest.includesGlobalData, isFalse);
    expect(result.manifest.compatibilityData,
        contains('data/character_memories.json'));
    expect(archive.findFile('data/user_profile.json'), isNull);
    expect(archive.findFile('data/relationships.json'), isNull);
    expect(_recordsFromArchive(archive, 'data/character_memories.json'),
        hasLength(1));

    final memories =
        _recordsFromArchive(archive, 'data/permanent_memories.json');
    expect(memories, hasLength(1));
    final memory = memories.single['value'] as Map;
    expect(memory['originConversationId'], 'group-1');
    expect(memory['sourceMessageIds'], ['msg-1']);
    expect(memory['supersedesIds'], isEmpty);
    expect(memory['participantIds'], ['user', 'char-1']);

    final events =
        _recordsFromArchive(archive, 'data/relationship_events.json');
    expect(events, hasLength(1));
    expect(events.single['value']['originConversationId'], 'group-1');
    expect(events.single['value']['sourceMessageIds'], ['msg-1']);
    expect(prepared.manifest.files.containsKey('data/relationships.json'),
        isFalse);
  });

  test('v1 and v2 manifests are both recognized without converting v1', () {
    final v1 = BackupManifest.fromJson({
      'format': BackupManifest.formatName,
      'formatVersion': 1,
      'schemaVersion': 1,
      'appVersion': '1.0.0',
      'createdAt': '2026-08-01T00:00:00.000Z',
      'scope': 'all',
      'counts': <String, int>{},
      'files': <String, dynamic>{},
      'missingAttachments': <String>[],
    });
    final v2 = BackupManifest.fromJson({
      'format': BackupManifest.formatName,
      'formatVersion': 1,
      'schemaVersion': 2,
      'backupKind': 'conversation',
      'includesGlobalData': false,
      'appVersion': '2.0.0',
      'createdAt': '2026-08-01T00:00:00.000Z',
      'scope': 'conversation',
      'conversationId': 'dm:char-1',
      'counts': <String, int>{},
      'files': <String, dynamic>{},
      'missingAttachments': <String>[],
    });

    expect(v1.schemaVersion, 1);
    expect(v1.isSupportedSchema, isTrue);
    expect(v1.toJson()['schemaVersion'], 1);
    expect(v2.schemaVersion, 2);
    expect(v2.backupKind, BackupKind.conversation);
    expect(v2.conversationId, 'dm:char-1');
  });

  test('real v1 fixture passes inspector and staged data loading', () async {
    final fixture = await _writeV1Fixture(testRoot);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);
    final data = await StagedBackupData.load(
      prepared.stagingDirectory,
      prepared.manifest,
    );

    expect(prepared.manifest.schemaVersion, 1);
    expect(prepared.manifest.isSupportedSchema, isTrue);
    expect(data.characters, hasLength(1));
    expect(data.groups, hasLength(1));
    expect(data.messages, hasLength(1));
    expect(data.relationships, hasLength(1));
    expect(data.userProfiles, isEmpty);
    expect(data.permanentMemories, isEmpty);
    expect(data.relationshipEvents, isEmpty);
  });

  test('rejects configuration backup carrying v2 global files', () async {
    final fixture = await _writeInvalidConfigurationGlobalFixture(testRoot);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    await expectLater(
      service.inspect(fixture),
      throwsA(isA<BackupException>()),
    );
  });

  test('failed staging generation leaves no successful package', () async {
    final emptyAttachment = File('${mediaDirectory.path}/empty.txt');
    await emptyAttachment.writeAsString('');
    await _seedCoreData(db, emptyAttachment);
    await db.appSettingsBox.put('token_usage', {
      'invalid': DateTime.utc(2026, 8, 1),
    });
    final destination = File('${testRoot.path}/failed.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    await expectLater(
      service.createBackup(destination: destination),
      throwsA(isA<BackupException>()),
    );
    expect(await destination.exists(), isFalse);
    expect(
      await testRoot
          .list()
          .where((entity) => entity.path.contains('backup_export_'))
          .isEmpty,
      isTrue,
    );
  });

  test('repeated v2 export keeps data file bytes stable', () async {
    await _seedGlobalMemoryData(db, mediaDirectory);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final first = File('${testRoot.path}/stable-1.cgbak');
    final second = File('${testRoot.path}/stable-2.cgbak');
    await service.createBackup(destination: first);
    await service.createBackup(destination: second);
    final firstArchive = ZipDecoder().decodeBytes(await first.readAsBytes());
    final secondArchive = ZipDecoder().decodeBytes(await second.readAsBytes());
    for (final path in [
      'data/messages.jsonl',
      'data/permanent_memories.json',
      'data/relationship_events.json',
      'data/relationships.json',
    ]) {
      expect(
        firstArchive.findFile(path)!.content,
        orderedEquals(secondArchive.findFile(path)!.content),
      );
    }
  });

  test('direct conversation copy remaps dm id, sender and read state',
      () async {
    final attachment = File('${mediaDirectory.path}/direct.txt');
    await attachment.writeAsString('direct');
    await _seedCoreData(db, attachment);
    await db.messageBox.put(
      'dm-msg-1',
      Message(
        id: 'dm-msg-1',
        groupId: 'dm:char-1',
        senderId: 'char-1',
        senderType: 'ai',
        content: 'private',
      ),
    );
    await db.appSettingsBox.put('direct_chat_read_at', {
      'dm:char-1': '2026-07-16T00:00:00.000Z',
    });
    final backup = File('${testRoot.path}/direct.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await service.createBackup(
      destination: backup,
      selection: const BackupSelection.conversation('dm:char-1'),
    );
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);

    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.copyWithNewIds,
    );

    final copiedCharacter =
        db.aiCharacterBox.values.singleWhere((item) => item.id != 'char-1');
    final copiedMessage = db.messageBox.values.singleWhere(
        (item) => item.content == 'private' && item.id != 'dm-msg-1');
    expect(copiedMessage.groupId, 'dm:${copiedCharacter.id}');
    expect(copiedMessage.senderId, copiedCharacter.id);
    expect(
      Map<String, dynamic>.from(db.appSettingsBox.get('direct_chat_read_at')),
      contains('dm:${copiedCharacter.id}'),
    );
  });

  test('copy restore preserves and remaps memory pin controls', () async {
    final attachment = File('${mediaDirectory.path}/memory-pins.txt');
    await attachment.writeAsString('memory pins');
    await _seedCoreData(db, attachment);
    await db.appSettingsBox.put('memory_pinned_keys_v1', [
      'group:group-1:group-1_2026-29',
      'character:memory-1:facts:dXNlcg==',
      'legacy:char-1',
      'relationship:relationship-1',
    ]);
    final backup = File('${testRoot.path}/memory-pins.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await service.createBackup(
      destination: backup,
      selection: const BackupSelection.all(),
    );
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);

    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.copyWithNewIds,
    );

    final copiedGroup =
        db.chatGroupBox.values.singleWhere((item) => item.id != 'group-1');
    final copiedCharacter =
        db.aiCharacterBox.values.singleWhere((item) => item.id != 'char-1');
    final copiedMemory = db.characterMemoryBox.values
        .singleWhere((item) => item.id != 'memory-1');
    final copiedRelationship = db.relationshipStateBox.values
        .singleWhere((item) => item.id != 'relationship-1');
    final copiedGroupMemory = db.groupMemoryBox.values
        .singleWhere((item) => item.groupId == copiedGroup.id);
    final pins = (db.appSettingsBox.get('memory_pinned_keys_v1') as List)
        .whereType<String>()
        .toSet();

    expect(
      pins,
      contains('group:${copiedGroup.id}:${copiedGroupMemory.key}'),
    );
    expect(
      pins,
      contains('character:${copiedMemory.id}:facts:dXNlcg=='),
    );
    expect(pins, contains('legacy:${copiedCharacter.id}'));
    expect(pins, contains('relationship:${copiedRelationship.id}'));
  });

  test('missing attachment is reported once and omitted from the package',
      () async {
    final attachment = File('${mediaDirectory.path}/missing.txt');
    await attachment.writeAsString('will disappear');
    await _seedCoreData(db, attachment);
    await attachment.delete();
    final backup = File('${testRoot.path}/missing.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    final result = await service.createBackup(destination: backup);
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);

    expect(result.manifest.missingAttachments, ['note.txt']);
    expect(prepared.preview.attachmentCount, 0);
  });

  test('symlinked attachment outside media directory is omitted', () async {
    final outside = File('${testRoot.path}/outside.txt');
    await outside.writeAsString('must not enter backup');
    final link = Link('${mediaDirectory.path}/escape.txt');
    await link.create(outside.path);
    await _seedCoreData(db, File(link.path));
    final backup = File('${testRoot.path}/symlink.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    final estimate = await service.estimate(const BackupSelection.all());
    final result = await service.createBackup(destination: backup);
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);

    expect(estimate.missingAttachments, 1);
    expect(result.manifest.missingAttachments, ['note.txt']);
    expect(prepared.preview.attachmentCount, 0);
  });

  test('unknown schema and staging tampering are rejected before commit',
      () async {
    final unknown = File('${testRoot.path}/unknown.cgbak');
    final archive = Archive()
      ..addFile(ArchiveFile.string(
        'manifest.json',
        jsonEncode({
          'format': BackupManifest.formatName,
          'formatVersion': 1,
          'schemaVersion': 99,
          'appVersion': 'future',
          'createdAt': DateTime.now().toIso8601String(),
          'scope': 'all',
          'counts': <String, int>{},
          'files': <String, dynamic>{},
          'missingAttachments': <String>[],
        }),
      ));
    await unknown.writeAsBytes(ZipEncoder().encodeBytes(archive));
    final sourceService = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await expectLater(
      sourceService.inspect(unknown),
      throwsA(isA<BackupException>()),
    );

    final attachment = File('${mediaDirectory.path}/tamper.txt');
    await attachment.writeAsString('original');
    await _seedCoreData(db, attachment);
    final valid = File('${testRoot.path}/tamper.cgbak');
    await sourceService.createBackup(destination: valid);
    await closeLifecycleHive(hiveDirectory);
    hiveDirectory = await openLifecycleHive();
    mediaDirectory = Directory('${hiveDirectory.path}/media');
    await mediaDirectory.create();
    db = DatabaseService();
    final restoreService = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await restoreService.inspect(valid);
    addTearDown(prepared.dispose);
    await File('${prepared.stagingDirectory.path}/data/groups.json')
        .writeAsString('[]');

    await expectLater(
      restoreService.restore(
        prepared,
        strategy: RestoreConflictStrategy.emptyOnly,
      ),
      throwsA(isA<BackupException>()),
    );
    expect(db.chatGroupBox, isEmpty);
    expect(db.messageBox, isEmpty);
  });

  test('v2 full restore round-trips global profile, memory, events and state',
      () async {
    await _seedGlobalMemoryData(db, mediaDirectory);
    final backup = File('${testRoot.path}/stage15-full.cgbak');
    final sourceService = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await sourceService.createBackup(destination: backup);

    await reopenEmptyDatabase();
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);
    final report = await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.emptyOnly,
    );

    expect(report.inserted['userProfiles'], 1);
    expect(report.inserted['permanentMemories'], 2);
    expect(report.inserted['relationshipEvents'], 2);
    expect(db.userProfileBox.get('me')!.displayName, '用户');
    expect(db.aiCharacterBox.get('char-1')!.memorySummary, '跨会话旧摘要机密');
    final memory = db.permanentMemoryBox.get('memory-current')!;
    expect(memory.sourceMessageIds, ['msg-1']);
    expect(memory.supersedesIds, ['memory-other']);
    final event = db.relationshipEventBox.get('event-current')!;
    expect(event.sourceCharacterId, 'char-1');
    expect(event.sourceMessageIds, ['msg-1']);
    final relationship = db.relationshipStateBox.get('rel:char-1:user:user')!;
    expect(relationship.stage, RelationshipStage.acquaintance);
    expect(relationship.revision, 1);
    expect(relationship.lastEventId, 'event-current');
    expect(relationship.updatedAt, isNotNull);
  });

  test('copyWithNewIds remaps every global reference and preserves user',
      () async {
    await _seedGlobalMemoryData(db, mediaDirectory);
    final backup = File('${testRoot.path}/stage15-copy.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await service.createBackup(destination: backup);
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);

    final report = await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.copyWithNewIds,
    );
    expect(report.remapped['characters'], 2);
    expect(report.remapped['groups'], 2);
    expect(report.remapped['messages'], 3);
    expect(report.remapped['permanentMemories'], 2);
    expect(report.remapped['relationshipEvents'], 2);

    final copiedCharacter = db.aiCharacterBox.values
        .singleWhere((item) => item.name == '小夏' && item.id != 'char-1');
    final copiedGroup = db.chatGroupBox.values.singleWhere(
      (item) => item.aiCharacterIds.contains(copiedCharacter.id),
    );
    final copiedMessage = db.messageBox.values.singleWhere(
      (item) => item.groupId == copiedGroup.id && item.content == 'hello',
    );
    final copiedMemory = db.permanentMemoryBox.values.singleWhere(
      (item) => item.content == '当前会话事实' && item.id != 'memory-current',
    );
    final copiedOtherMemory = db.permanentMemoryBox.values.singleWhere(
      (item) => item.content == '其他会话事实' && item.id != 'memory-other',
    );
    final copiedEvent = db.relationshipEventBox.values.singleWhere(
      (item) => item.reason == '当前事件' && item.id != 'event-current',
    );
    final copiedRelationship = db.relationshipStateBox.values.singleWhere(
      (item) =>
          item.sourceCharacterId == copiedCharacter.id &&
          item.targetType == RelationshipTargetType.user,
    );

    expect(copiedMessage.id, isNot('msg-1'));
    expect(copiedMessage.visibleToCharacterIds, [copiedCharacter.id]);
    expect(copiedMemory.observerCharacterId, copiedCharacter.id);
    expect(copiedMemory.subjectIds, contains('user'));
    expect(copiedMemory.participantIds, contains(copiedCharacter.id));
    expect(copiedMemory.sourceMessageIds, [copiedMessage.id]);
    expect(copiedMemory.supersedesIds, [copiedOtherMemory.id]);
    expect(copiedEvent.id, isNot('event-current'));
    expect(copiedEvent.sourceCharacterId, copiedCharacter.id);
    expect(copiedEvent.targetId, 'user');
    expect(copiedEvent.sourceMessageIds, [copiedMessage.id]);
    expect(
      copiedRelationship.id,
      RelationshipState.stableGlobalId(
        copiedCharacter.id,
        RelationshipTargetType.user,
        'user',
      ),
    );
    expect(db.relationshipStateBox.get(copiedRelationship.id),
        same(copiedRelationship));
    expect(copiedRelationship.lastEventId, copiedEvent.id);
    expect(db.userProfileBox.keys, ['me']);
  });

  test(
      'conversation restore replays only its events and keeps other direction state',
      () async {
    await _seedGlobalMemoryData(db, mediaDirectory);
    await db.relationshipEventBox.put(
      'event-current-later',
      RelationshipEvent(
        id: 'event-current-later',
        sourceCharacterId: 'char-1',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        reason: '当前事件后续',
        affinityBefore: 5,
        affinityAfter: 9,
        trustBefore: 4,
        trustAfter: 7,
        frictionBefore: 0,
        frictionAfter: 0,
        familiarityBefore: 5,
        familiarityAfter: 8,
        moodBefore: RelationshipMood.warm,
        moodAfter: RelationshipMood.protective,
        stageBefore: RelationshipStage.acquaintance,
        stageAfter: RelationshipStage.friend,
        originConversationId: 'group-1',
        originNameSnapshot: '测试群',
        sourceMessageIds: const ['msg-2'],
        revision: 2,
        occurredAt: DateTime.utc(2026, 8, 1, 13),
        createdBy: RelationshipEventCreator.automatic,
        createdAt: DateTime.utc(2026, 8, 1, 13),
      ),
    );
    final backup = File('${testRoot.path}/stage15-conversation.cgbak');
    final sourceService = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await sourceService.createBackup(
      destination: backup,
      selection: const BackupSelection.conversation('group-1'),
    );

    await reopenEmptyDatabase();
    final unrelatedAt = DateTime.utc(2026, 7, 1);
    await db.relationshipStateBox.put(
      'rel:other:user:user',
      RelationshipState.global(
        id: 'rel:other:user:user',
        sourceCharacterId: 'other',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        affinity: 77,
        lastInteractionAt: unrelatedAt,
      ),
    );
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);
    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.skipExisting,
    );

    expect(db.userProfileBox, isEmpty);
    expect(db.aiCharacterBox.get('char-1')!.memorySummary, isEmpty);
    expect(db.relationshipStateBox.get('rel:other:user:user')!.affinity, 77);
    final replayed = db.relationshipStateBox.get('rel:char-1:user:user');
    expect(replayed, isNotNull);
    expect(replayed!.affinity, 9);
    expect(replayed.trust, 7);
    expect(replayed.lastEventId, 'event-current-later');
    expect(db.relationshipStateBox.get('relationship-1'), isNull);
    expect(db.chatGroupBox.keys, contains('group-1'));
    expect(db.relationshipEventBox.keys, contains('event-current'));
    expect(db.relationshipEventBox.keys, contains('event-current-later'));
  });

  test('repeated v2 global import is idempotent for memories and events',
      () async {
    await _seedGlobalMemoryData(db, mediaDirectory);
    final backup = File('${testRoot.path}/stage15-repeat.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await service.createBackup(destination: backup);
    await reopenEmptyDatabase();
    final restoreService = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final first = await restoreService.inspect(backup);
    addTearDown(first.dispose);
    await restoreService.restore(
      first,
      strategy: RestoreConflictStrategy.emptyOnly,
    );
    final memories = db.permanentMemoryBox.length;
    final events = db.relationshipEventBox.length;

    final second = await restoreService.inspect(backup);
    addTearDown(second.dispose);
    final report = await restoreService.restore(
      second,
      strategy: RestoreConflictStrategy.copyWithNewIds,
    );

    expect(report.skipped['duplicateImport'], 1);
    expect(db.permanentMemoryBox.length, memories);
    expect(db.relationshipEventBox.length, events);
  });

  test('full restore preserves evidence IDs for deleted messages', () async {
    await _seedGlobalMemoryData(db, mediaDirectory);
    final backup = File('${testRoot.path}/stage15-deleted-source.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await service.createBackup(destination: backup);
    final withMemory = await _rewriteBackupJson(
      backup,
      File('${testRoot.path}/stage15-deleted-source-memory.cgbak'),
      'data/permanent_memories.json',
      (value) {
        for (final record in value as List) {
          if ((record as Map)['value']['id'] == 'memory-current') {
            record['value']['sourceMessageIds'] = ['deleted-message'];
          }
        }
      },
    );
    final rewritten = await _rewriteBackupJson(
      withMemory,
      File('${testRoot.path}/stage15-deleted-source-event.cgbak'),
      'data/relationship_events.json',
      (value) {
        for (final record in value as List) {
          if ((record as Map)['value']['id'] == 'event-current') {
            record['value']['sourceMessageIds'] = ['deleted-message'];
          }
        }
      },
    );

    await reopenEmptyDatabase();
    final restoreService = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await restoreService.inspect(rewritten);
    addTearDown(prepared.dispose);
    await restoreService.restore(
      prepared,
      strategy: RestoreConflictStrategy.emptyOnly,
    );

    expect(db.messageBox.containsKey('deleted-message'), isFalse);
    expect(db.permanentMemoryBox.get('memory-current')!.sourceMessageIds,
        ['deleted-message']);
    expect(db.relationshipEventBox.get('event-current')!.sourceMessageIds,
        ['deleted-message']);
  });

  test('v1 restore keeps legacy boxes then runs idempotent migration',
      () async {
    final fixture = await _writeV1Fixture(testRoot);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);
    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.emptyOnly,
    );

    expect(db.characterMemoryBox.get('legacy-memory')!.facts, ['旧版事实']);
    expect(
      db.permanentMemoryBox.values,
      contains(
          predicate<PermanentMemory>((memory) => memory.content == '旧版事实')),
    );
    expect(db.userProfileBox.get('me'), isNotNull);
    expect(db.relationshipStateBox.get('rel:char-1:user:user'), isNotNull);
    expect(
      db.relationshipEventBox.values,
      contains(predicate<RelationshipEvent>((event) =>
          event.createdBy == RelationshipEventCreator.legacyMigration)),
    );
    expect(db.appSettingsBox.get('memory_migration_marker_v1'), isA<Map>());

    final second = await MemoryMigrator(db).migrate();
    expect(second.alreadyMigrated, isTrue);
    expect(db.permanentMemoryBox.values, hasLength(2));
  });

  test('legacy character restore migrates only the missing gender', () async {
    final legacy = await _writeV1Fixture(testRoot);
    final fixture = await _rewriteBackupJson(
      legacy,
      File('${testRoot.path}/legacy-missing-gender.cgbak'),
      'data/characters.json',
      (value) {
        final character = ((value as List).single as Map)['value'] as Map;
        character['role'] = '父亲';
        character['systemPrompt'] = '我是男性';
      },
    );
    final locked = testCharacter('locked')..gender = CharacterGender.male;
    await db.aiCharacterBox.put(locked.id, locked);
    await db.appSettingsBox.put(CharacterGenderMigrator.migrationKey, true);

    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);
    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.skipExisting,
    );

    expect(db.aiCharacterBox.get('char-1')!.gender, CharacterGender.male);
    expect(db.aiCharacterBox.get('locked')!.gender, CharacterGender.male);
    expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), true);
    expect(db.appSettingsBox.get(CharacterGenderMigrator.stateKey), isNull);
  });

  test('legacy restore completes gender migration before returning', () async {
    final legacy = await _writeV1Fixture(testRoot);
    final fixture = await _rewriteBackupJson(
      legacy,
      File('${testRoot.path}/legacy-restore-migrates.cgbak'),
      'data/characters.json',
      (value) {
        final character = ((value as List).single as Map)['value'] as Map;
        character['role'] = '父亲';
        character['systemPrompt'] = '我是男性';
      },
    );
    final migrator = _FakeGenderMigrator(db, complete: true);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
      genderMigrator: migrator,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);

    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.emptyOnly,
    );

    expect(migrator.called, isTrue);
    expect(db.aiCharacterBox.get('char-1')!.gender, CharacterGender.male);
    expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), true);
    expect(db.appSettingsBox.get(CharacterGenderMigrator.stateKey), isNull);
  });

  test('invalid gender state keeps other database candidates on legacy restore',
      () async {
    final existing = testCharacter('old-candidate')
      ..role = '父亲'
      ..systemPrompt = '我是男性';
    await db.aiCharacterBox.put(existing.id, existing);
    await db.appSettingsBox.put(CharacterGenderMigrator.stateKey, {
      'candidateIds': ['old-candidate'],
      'completedIds': ['missing-candidate'],
      'decisions': <String, dynamic>{},
    });
    await db.appSettingsBox.put(CharacterGenderMigrator.migrationKey, false);

    final legacy = await _writeV1Fixture(testRoot);
    final fixture = await _rewriteBackupJson(
      legacy,
      File('${testRoot.path}/legacy-invalid-gender-state.cgbak'),
      'data/characters.json',
      (value) {
        final character = ((value as List).single as Map)['value'] as Map;
        character['role'] = '父亲';
        character['systemPrompt'] = '我是男性';
      },
    );
    final migrator = _FakeGenderMigrator(db, complete: false);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
      genderMigrator: migrator,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);

    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.skipExisting,
    );

    expect(migrator.called, isTrue);
    expect(migrator.candidateIdsAtCall,
        containsAll(<String>{'old-candidate', 'char-1'}));
    expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), false);
  });

  test(
      'completed gender migration limits invalid state rebuild to restored IDs',
      () async {
    final existing = testCharacter('old-candidate')
      ..role = '父亲'
      ..systemPrompt = '我是男性';
    await db.aiCharacterBox.put(existing.id, existing);
    await db.appSettingsBox.put(CharacterGenderMigrator.stateKey, {
      'candidateIds': ['old-candidate'],
      'completedIds': ['missing-candidate'],
      'decisions': <String, dynamic>{},
    });
    await db.appSettingsBox.put(CharacterGenderMigrator.migrationKey, true);

    final legacy = await _writeV1Fixture(testRoot);
    final fixture = await _rewriteBackupJson(
      legacy,
      File('${testRoot.path}/legacy-completed-invalid-gender-state.cgbak'),
      'data/characters.json',
      (value) {
        final character = ((value as List).single as Map)['value'] as Map;
        character['role'] = '父亲';
        character['systemPrompt'] = '我是男性';
      },
    );
    final migrator = _FakeGenderMigrator(db, complete: false);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
      genderMigrator: migrator,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);

    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.skipExisting,
    );

    expect(migrator.called, isTrue);
    expect(migrator.candidateIdsAtCall, contains('char-1'));
    expect(migrator.candidateIdsAtCall, isNot(contains('old-candidate')));
    expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), false);
  });

  test('completed gender migration discards a valid residual state', () async {
    final existing = testCharacter('old-candidate')
      ..role = '父亲'
      ..systemPrompt = '我是男性';
    await db.aiCharacterBox.put(existing.id, existing);
    await db.appSettingsBox.put(
      CharacterGenderMigrator.stateKey,
      CharacterGenderMigrationState(
        candidateIds: {'old-candidate'},
        decisions: {'old-candidate': CharacterGender.female},
      ).toMap(),
    );
    await db.appSettingsBox.put(CharacterGenderMigrator.migrationKey, true);

    final legacy = await _writeV1Fixture(testRoot);
    final fixture = await _rewriteBackupJson(
      legacy,
      File('${testRoot.path}/legacy-completed-valid-gender-state.cgbak'),
      'data/characters.json',
      (value) {
        final character = ((value as List).single as Map)['value'] as Map;
        character['role'] = '父亲';
        character['systemPrompt'] = '我是男性';
      },
    );
    final migrator = _FakeGenderMigrator(db, complete: false);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
      genderMigrator: migrator,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);

    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.skipExisting,
    );

    expect(migrator.called, isTrue);
    expect(migrator.candidateIdsAtCall, {'char-1'});
    expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), false);
  });

  test('incomplete gender migration rebuilds candidates when state is missing',
      () async {
    final existing = testCharacter('old-candidate')
      ..role = '父亲'
      ..systemPrompt = '我是男性';
    await db.aiCharacterBox.put(existing.id, existing);
    await db.appSettingsBox.put(CharacterGenderMigrator.migrationKey, false);

    final legacy = await _writeV1Fixture(testRoot);
    final fixture = await _rewriteBackupJson(
      legacy,
      File('${testRoot.path}/legacy-missing-gender-state.cgbak'),
      'data/characters.json',
      (value) {
        final character = ((value as List).single as Map)['value'] as Map;
        character['role'] = '父亲';
        character['systemPrompt'] = '我是男性';
      },
    );
    final migrator = _FakeGenderMigrator(db, complete: false);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
      genderMigrator: migrator,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);

    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.skipExisting,
    );

    expect(migrator.called, isTrue);
    expect(migrator.candidateIdsAtCall,
        containsAll(<String>{'old-candidate', 'char-1'}));
    expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), false);
  });

  test('legacy restore clears completed gender progress for the restored ID',
      () async {
    final legacy = await _writeV1Fixture(testRoot);
    final fixture = await _rewriteBackupJson(
      legacy,
      File('${testRoot.path}/legacy-completed-gender.cgbak'),
      'data/characters.json',
      (value) {
        final character = ((value as List).single as Map)['value'] as Map;
        character['role'] = '父亲';
        character['systemPrompt'] = '我是男性';
      },
    );
    await db.appSettingsBox.put(
      CharacterGenderMigrator.stateKey,
      CharacterGenderMigrationState(
        candidateIds: {'char-1'},
        completedIds: {'char-1'},
      ).toMap(),
    );
    await db.appSettingsBox.put(CharacterGenderMigrator.migrationKey, true);

    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);
    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.skipExisting,
    );

    expect(db.aiCharacterBox.get('char-1')!.gender, CharacterGender.male);
    expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), true);
    expect(db.appSettingsBox.get(CharacterGenderMigrator.stateKey), isNull);
  });

  test('legacy restore clears a stale gender decision for the restored ID',
      () async {
    final legacy = await _writeV1Fixture(testRoot);
    final fixture = await _rewriteBackupJson(
      legacy,
      File('${testRoot.path}/legacy-decided-gender.cgbak'),
      'data/characters.json',
      (value) {
        final character = ((value as List).single as Map)['value'] as Map;
        character['role'] = '父亲';
        character['systemPrompt'] = '我是男性';
      },
    );
    await db.appSettingsBox.put(
      CharacterGenderMigrator.stateKey,
      CharacterGenderMigrationState(
        candidateIds: {'char-1'},
        decisions: {'char-1': CharacterGender.female},
      ).toMap(),
    );
    await db.appSettingsBox.put(CharacterGenderMigrator.migrationKey, true);

    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);
    await service.restore(
      prepared,
      strategy: RestoreConflictStrategy.skipExisting,
    );

    expect(db.aiCharacterBox.get('char-1')!.gender, CharacterGender.male);
    expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), true);
    expect(db.appSettingsBox.get(CharacterGenderMigrator.stateKey), isNull);
  });

  test('missing global references are rejected before any restore write',
      () async {
    await _seedGlobalMemoryData(db, mediaDirectory);
    final backup = File('${testRoot.path}/stage15-invalid-source.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await service.createBackup(destination: backup);
    final conversationBackup = File(
      '${testRoot.path}/stage15-invalid-source-conversation.cgbak',
    );
    await service.createBackup(
      destination: conversationBackup,
      selection: const BackupSelection.conversation('group-1'),
    );
    final invalid = await _rewriteBackupJson(
      conversationBackup,
      File('${testRoot.path}/stage15-invalid.cgbak'),
      'data/permanent_memories.json',
      (value) {
        final records = value as List;
        (records.first as Map)['value']
            ['sourceMessageIds'] = ['missing-message'];
      },
    );

    await expectLater(
      service.inspect(invalid),
      throwsA(isA<BackupException>()),
    );
    final invalidSupersedes = await _rewriteBackupJson(
      backup,
      File('${testRoot.path}/stage15-invalid-supersedes.cgbak'),
      'data/permanent_memories.json',
      (value) {
        for (final record in value as List) {
          if ((record as Map)['value']['id'] == 'memory-current') {
            record['value']['supersedesIds'] = ['missing-memory'];
          }
        }
      },
    );
    await expectLater(
      service.inspect(invalidSupersedes),
      throwsA(isA<BackupException>()),
    );
    final invalidLastEvent = await _rewriteBackupJson(
      backup,
      File('${testRoot.path}/stage15-invalid-last-event.cgbak'),
      'data/relationships.json',
      (value) {
        for (final record in value as List) {
          if ((record as Map)['value']['id'] == 'rel:char-1:user:user') {
            record['value']['lastEventId'] = 'missing-event';
          }
        }
      },
    );
    await expectLater(
      service.inspect(invalidLastEvent),
      throwsA(isA<BackupException>()),
    );
    expect(db.permanentMemoryBox, hasLength(2));
    expect(db.relationshipEventBox, hasLength(2));
  });

  test(
      'global restore write failure rolls back profile, memory, events and relations',
      () async {
    await _seedGlobalMemoryData(db, mediaDirectory);
    final backup = File('${testRoot.path}/stage15-rollback.cgbak');
    final sourceService = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await sourceService.createBackup(destination: backup);
    await reopenEmptyDatabase();
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
      onCommitWrite: (count) {
        if (count == 12) throw StateError('stage15 global write failure');
      },
    );
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);

    await expectLater(
      service.restore(
        prepared,
        strategy: RestoreConflictStrategy.emptyOnly,
      ),
      throwsA(isA<BackupException>()),
    );
    expect(db.userProfileBox, isEmpty);
    expect(db.permanentMemoryBox, isEmpty);
    expect(db.relationshipEventBox, isEmpty);
    expect(db.relationshipStateBox, isEmpty);
    expect(db.aiCharacterBox, isEmpty);
    expect(await mediaDirectory.list().toList(), isEmpty);
  });
}

Future<File> _writeV1Fixture(Directory root) async {
  const character = {
    'id': 'char-1',
    'name': '旧角色',
    'avatar': '旧',
    'age': 20,
    'role': '测试',
    'personalityTags': <String>[],
    'systemPrompt': 'legacy',
    'memorySummary': '【事实】旧版摘要事实',
    'apiProvider': '',
    'modelName': '',
    'customBaseUrl': '',
    'hourlyReplyLimit': 60,
    'hourlyReplyCount': 0,
    'lastReplyTimestamp': null,
    'isActive': true,
    'createdAt': '2026-08-01T00:00:00.000Z',
    'apiConfigId': '',
    'agenticEnabled': true,
    'skillIds': <String>[],
    'toolPermissions': <String>[],
  };
  const group = {
    'id': 'group-1',
    'name': '旧群',
    'theme': '旧版',
    'description': '',
    'aiCharacterIds': ['char-1'],
    'createdAt': '2026-08-01T00:00:00.000Z',
  };
  const message = {
    'key': 'message-1',
    'value': {
      'id': 'message-1',
      'groupId': 'group-1',
      'senderId': 'user',
      'senderType': 'user',
      'content': '旧版消息',
      'timestamp': '2026-08-01T00:00:00.000Z',
      'replyToMessageId': null,
      'isMention': false,
      'mentionedAiIds': <String>[],
      'media': <dynamic>[],
    },
  };
  const relationship = {
    'key': 'relationship-1',
    'value': {
      'id': 'relationship-1',
      'groupId': 'group-1',
      'sourceCharacterId': 'char-1',
      'targetId': 'user',
      'targetType': 'user',
      'affinity': 1,
      'trust': 1,
      'friction': 0,
      'familiarity': 1,
      'recentMood': 'neutral',
      'notes': '',
      'lastInteractionAt': '2026-08-01T00:00:00.000Z',
      'createdAt': '2026-08-01T00:00:00.000Z',
    },
  };
  const characterMemory = {
    'key': 'legacy-memory',
    'value': {
      'id': 'legacy-memory',
      'groupId': 'group-1',
      'characterId': 'char-1',
      'facts': ['旧版事实'],
      'relationshipNotes': <String>[],
      'personaGrowth': <String>[],
      'lastUpdatedAt': '2026-08-01T00:00:00.000Z',
      'createdAt': '2026-08-01T00:00:00.000Z',
    },
  };
  final contents = <String, String>{
    'data/api_configs.json': '[]',
    'data/characters.json': jsonEncode([
      {'key': 'char-1', 'value': character}
    ]),
    'data/groups.json': jsonEncode([
      {'key': 'group-1', 'value': group}
    ]),
    'data/messages.jsonl': '${jsonEncode(message)}\n',
    'data/group_memories.json': '[]',
    'data/character_memories.json': jsonEncode([characterMemory]),
    'data/relationships.json': jsonEncode([relationship]),
    'data/skills.json': '[]',
    'data/agent_tasks.json': '[]',
    'data/work_mode.json': '[]',
    'data/settings.json': '{}',
  };
  final archive = Archive();
  final files = <String, dynamic>{};
  for (final entry in contents.entries) {
    final bytes = utf8.encode(entry.value);
    files[entry.key] = {
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  archive.addFile(ArchiveFile.string(
    'manifest.json',
    jsonEncode({
      'format': BackupManifest.formatName,
      'formatVersion': 1,
      'schemaVersion': 1,
      'appVersion': '1.0.0',
      'createdAt': '2026-08-01T00:00:00.000Z',
      'scope': 'all',
      'counts': {
        'apiConfigs': 0,
        'characters': 1,
        'groups': 1,
        'messages': 1,
        'characterMemories': 1,
        'groupMemories': 0,
        'relationships': 1,
        'skills': 0,
        'agentTasks': 0,
        'workMode': 0,
        'settings': 0,
        'attachments': 0,
      },
      'files': files,
      'missingAttachments': <String>[],
      'credentialsIncluded': false,
    }),
  ));
  final fixture = File('${root.path}/legacy-v1.cgbak');
  await fixture.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return fixture;
}

Future<File> _rewriteBackupJson(
  File source,
  File destination,
  String path,
  void Function(dynamic value) mutate,
) async {
  final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
  final manifestFile = archive.findFile('manifest.json')!;
  final manifest = Map<String, dynamic>.from(
    jsonDecode(utf8.decode(manifestFile.content)) as Map,
  );
  final dataFile = archive.findFile(path)!;
  final decoded = jsonDecode(utf8.decode(dataFile.content));
  mutate(decoded);
  final content = jsonEncode(decoded);
  final bytes = utf8.encode(content);
  final files = Map<String, dynamic>.from(manifest['files'] as Map);
  files[path] = {
    'bytes': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
  manifest['files'] = files;

  final rewritten = Archive();
  for (final file in archive.files) {
    if (file.name == path) {
      rewritten.addFile(ArchiveFile.string(path, content));
    } else if (file.name == 'manifest.json') {
      rewritten
          .addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
    } else {
      rewritten.addFile(ArchiveFile(file.name, file.size, file.content));
    }
  }
  await destination.writeAsBytes(ZipEncoder().encodeBytes(rewritten));
  return destination;
}

Future<File> _writeInvalidConfigurationGlobalFixture(Directory root) async {
  const globalPaths = [
    'data/user_profile.json',
    'data/permanent_memories.json',
    'data/relationship_events.json',
    'data/relationships.json',
  ];
  final archive = Archive();
  final files = <String, dynamic>{};
  for (final path in globalPaths) {
    const content = '[]';
    final bytes = utf8.encode(content);
    files[path] = {
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
    archive.addFile(ArchiveFile.string(path, content));
  }
  archive.addFile(ArchiveFile.string(
    'manifest.json',
    jsonEncode({
      'format': BackupManifest.formatName,
      'formatVersion': 1,
      'schemaVersion': 2,
      'backupKind': 'full',
      'includesGlobalData': false,
      'appVersion': '2.0.0',
      'createdAt': '2026-08-01T00:00:00.000Z',
      'scope': 'configurationOnly',
      'counts': <String, int>{},
      'files': files,
      'missingAttachments': <String>[],
    }),
  ));
  final fixture = File('${root.path}/invalid-configuration-global.cgbak');
  await fixture.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return fixture;
}

List<Map<String, dynamic>> _recordsFromArchive(
  Archive archive,
  String path,
) {
  final file = archive.findFile(path);
  if (file == null) return const [];
  final decoded = jsonDecode(utf8.decode(file.content));
  return (decoded as List)
      .map((item) => Map<String, dynamic>.from(item as Map))
      .toList(growable: false);
}

Future<void> _seedGlobalMemoryData(
  DatabaseService db,
  Directory mediaDirectory,
) async {
  final attachment = File('${mediaDirectory.path}/global.txt');
  await attachment.writeAsString('global');
  await _seedCoreData(db, attachment);
  final seededCharacter = db.aiCharacterBox.get('char-1')!
    ..memorySummary = '跨会话旧摘要机密';
  await db.aiCharacterBox.put(seededCharacter.id, seededCharacter);
  await db.aiCharacterBox.put('char-2', testCharacter('char-2'));
  await db.chatGroupBox.put(
    'group-2',
    ChatGroup(
      id: 'group-2',
      name: '其他群',
      theme: '隔离',
      aiCharacterIds: const ['char-2'],
    ),
  );
  await db.messageBox.put(
    'other-msg',
    Message(
      id: 'other-msg',
      groupId: 'group-2',
      senderId: 'char-2',
      senderType: 'ai',
      content: 'other conversation',
    ),
  );
  final occurredAt = DateTime.utc(2026, 8, 1, 12);
  await db.userProfileBox.put(
    'me',
    UserProfile(
      displayName: '用户',
      preferredAddress: '朋友',
      avatar: '我',
      bio: '备份测试',
      updatedAt: occurredAt,
      createdAt: occurredAt,
    ),
  );
  await db.permanentMemoryBox.put(
    'memory-current',
    PermanentMemory(
      id: 'memory-current',
      observerCharacterId: 'char-1',
      kind: MemoryKind.fact,
      content: '当前会话事实',
      subjectIds: const ['user', 'char-2'],
      participantIds: const ['user', 'char-1', 'char-2'],
      supersedesIds: const ['memory-other'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originConversationId: 'group-1',
      originNameSnapshot: '测试群',
      sourceMessageIds: const ['msg-1'],
      occurredAt: occurredAt,
      createdAt: occurredAt,
      updatedAt: occurredAt,
    ),
  );
  await db.permanentMemoryBox.put(
    'memory-other',
    PermanentMemory(
      id: 'memory-other',
      observerCharacterId: 'char-2',
      kind: MemoryKind.preference,
      content: '其他会话事实',
      subjectIds: const ['user'],
      participantIds: const ['user', 'char-2'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originConversationId: 'group-2',
      originNameSnapshot: '其他群',
      sourceMessageIds: const ['other-msg'],
      occurredAt: occurredAt,
      createdAt: occurredAt,
      updatedAt: occurredAt,
    ),
  );
  await db.relationshipEventBox.put(
    'event-current',
    RelationshipEvent(
      id: 'event-current',
      sourceCharacterId: 'char-1',
      targetType: RelationshipTargetType.user,
      targetId: 'user',
      reason: '当前事件',
      affinityBefore: 0,
      affinityAfter: 5,
      trustBefore: 0,
      trustAfter: 4,
      frictionBefore: 0,
      frictionAfter: 0,
      familiarityBefore: 0,
      familiarityAfter: 5,
      moodBefore: RelationshipMood.neutral,
      moodAfter: RelationshipMood.warm,
      stageBefore: RelationshipStage.stranger,
      stageAfter: RelationshipStage.acquaintance,
      originConversationId: 'group-1',
      originNameSnapshot: '测试群',
      sourceMessageIds: const ['msg-1'],
      revision: 1,
      occurredAt: occurredAt,
      createdBy: RelationshipEventCreator.automatic,
      createdAt: occurredAt,
    ),
  );
  await db.relationshipEventBox.put(
    'event-other',
    RelationshipEvent(
      id: 'event-other',
      sourceCharacterId: 'char-2',
      targetType: RelationshipTargetType.user,
      targetId: 'user',
      reason: '其他事件',
      affinityBefore: 0,
      affinityAfter: 3,
      trustBefore: 0,
      trustAfter: 2,
      frictionBefore: 0,
      frictionAfter: 0,
      familiarityBefore: 0,
      familiarityAfter: 3,
      moodBefore: RelationshipMood.neutral,
      moodAfter: RelationshipMood.warm,
      stageBefore: RelationshipStage.stranger,
      stageAfter: RelationshipStage.acquaintance,
      originConversationId: 'group-2',
      originNameSnapshot: '其他群',
      sourceMessageIds: const ['other-msg'],
      revision: 1,
      occurredAt: occurredAt,
      createdBy: RelationshipEventCreator.automatic,
      createdAt: occurredAt,
    ),
  );
  await db.relationshipStateBox.put(
    'rel:char-1:user:user',
    RelationshipState.global(
      id: 'rel:char-1:user:user',
      sourceCharacterId: 'char-1',
      targetType: RelationshipTargetType.user,
      targetId: 'user',
      affinity: 5,
      trust: 4,
      familiarity: 5,
      recentMood: RelationshipMood.warm,
      stage: RelationshipStage.acquaintance,
      revision: 1,
      lastEventId: 'event-current',
      lastInteractionAt: occurredAt,
      updatedAt: occurredAt,
      createdAt: occurredAt,
    ),
  );
}

bool _containsBytes(List<int> source, List<int> pattern) {
  if (pattern.isEmpty) return true;
  for (var i = 0; i <= source.length - pattern.length; i++) {
    var matches = true;
    for (var j = 0; j < pattern.length; j++) {
      if (source[i + j] != pattern[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Future<void> _seedCoreData(
  DatabaseService db,
  File attachment, {
  String apiKey = '',
}) async {
  await db.apiConfigBox.put(
    'api-1',
    ApiConfig(
      id: 'api-1',
      name: 'DeepSeek',
      provider: 'deepseek',
      apiKey: apiKey,
      customBaseUrl: 'https://example.com/v1?api_key=$apiKey&region=cn#private',
      credentialId: 'secure:api-1',
      hasCredential: true,
    ),
  );
  await db.aiCharacterBox.put(
    'char-1',
    AICharacter(
      id: 'char-1',
      name: '小夏',
      avatar: '夏',
      age: 22,
      role: '朋友',
      personalityTags: const ['真诚'],
      systemPrompt: '自然聊天',
      apiKey: apiKey,
      apiProvider: 'deepseek',
      apiConfigId: 'api-1',
    ),
  );
  await db.chatGroupBox.put(
    'group-1',
    ChatGroup(
      id: 'group-1',
      name: '测试群',
      theme: '恢复',
      aiCharacterIds: const ['char-1'],
    ),
  );
  final media = MediaAttachment(
    id: 'attachment-1',
    type: 'file',
    localPath: attachment.path,
    fileName: 'note.txt',
    fileSize: await attachment.length(),
    mimeType: 'text/plain',
  );
  await db.messageBox.putAll({
    'msg-1': Message(
      id: 'msg-1',
      groupId: 'group-1',
      senderId: 'user',
      senderType: 'user',
      content: 'hello',
      media: [media],
      visibleToCharacterIds: const ['char-1'],
    ),
    'msg-2': Message(
      id: 'msg-2',
      groupId: 'group-1',
      senderId: 'char-1',
      senderType: 'ai',
      content: 'reply',
      replyToMessageId: 'msg-1',
      media: [media],
      visibleToCharacterIds: const ['char-1'],
    ),
  });
  await db.groupMemoryBox.put(
    'group-1_2026-29',
    GroupMemory(groupId: 'group-1', topicSummary: '测试恢复'),
  );
  await db.characterMemoryBox.put(
    'memory-1',
    CharacterMemory(
      id: 'memory-1',
      groupId: 'group-1',
      characterId: 'char-1',
      facts: const ['用户关心备份'],
    ),
  );
  await db.relationshipStateBox.put(
    'relationship-1',
    RelationshipState(
      id: 'relationship-1',
      groupId: 'global',
      sourceCharacterId: 'char-1',
      targetId: 'char-1',
      targetType: RelationshipTargetType.ai,
    ),
  );
  await db.appSettingsBox.putAll({
    'theme_mode': 'dark',
    'pinned_group_ids': ['group-1'],
    'direct_chat_read_at': <String, String>{},
    'message_ids_by_group': {
      'group-1': ['msg-1', 'msg-2'],
    },
    'credential_cache': 'must-not-export',
  });
}
