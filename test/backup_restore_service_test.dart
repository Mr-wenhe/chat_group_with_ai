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
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/backup/backup_models.dart';
import 'package:chat_group/features/backup/backup_restore_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory testRoot;
  late Directory hiveDirectory;
  late Directory mediaDirectory;
  late DatabaseService db;

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

  test('v1 backup excludes secrets and content-addresses attachments',
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
    expect(result.manifest.schemaVersion, 1);
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
    expect(db.apiConfigBox.get('api-1')!.legacyApiKey, isEmpty);
    expect(
      db.apiConfigBox.get('api-1')!.customBaseUrl,
      'https://example.com/v1?region=cn',
    );
    expect(db.aiCharacterBox.get('char-1')!.apiKey, isEmpty);
    expect(db.chatGroupBox.get('group-1')!.aiCharacterIds, ['char-1']);
    expect(db.messageBox.get('msg-2')!.replyToMessageId, 'msg-1');
    expect(
      db.conversationSummaries()['group-1']?.lastMessageId,
      'msg-2',
    );
    expect(db.characterMemoryBox.get('memory-1')!.characterId, 'char-1');
    expect(
      db.relationshipStateBox.get('relationship-1')!.targetId,
      'char-1',
    );
    final restoredMedia = db.messageBox.get('msg-1')!.media!.single;
    expect(await File(restoredMedia.localPath).readAsBytes(), [1, 2, 3, 4]);
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
    ),
    'msg-2': Message(
      id: 'msg-2',
      groupId: 'group-1',
      senderId: 'char-1',
      senderType: 'ai',
      content: 'reply',
      replyToMessageId: 'msg-1',
      media: [media],
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
      groupId: 'group-1',
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
