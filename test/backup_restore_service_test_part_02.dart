part of 'backup_restore_service_test.dart';

void _registerBackupRestoreServiceTestPart2() {
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

  test('rejects a manifest that exceeds the pre-decode byte limit', () async {
    final fixture = await _writeV1Fixture(testRoot);
    final oversized = File('${testRoot.path}/oversized-manifest.cgbak');
    await _rewriteManifestArchive(
      fixture,
      oversized,
      (manifest) {
        manifest['padding'] = 'x' * (BackupInspector.maxManifestBytes + 1);
      },
    );

    await expectLater(
      BackupRestoreService(
        db: db,
        mediaDirectory: mediaDirectory,
        tempRoot: testRoot,
      ).inspect(oversized),
      throwsA(isA<BackupException>()),
    );
  });

  test('rejects actual archive output beyond the entry limit', () async {
    const entryByteLimit = 1024;
    const expandedByteLimit = 2048;
    final payload = List<int>.filled(entryByteLimit + 1, 0x41);
    final manifest = {
      'format': BackupManifest.formatName,
      'formatVersion': 1,
      'schemaVersion': 1,
      'appVersion': '1.0.0',
      'createdAt': '2026-08-01T00:00:00.000Z',
      'scope': BackupScope.configurationOnly.name,
      'counts': <String, int>{},
      'files': {
        'data/settings.json': {
          'bytes': payload.length,
          'sha256': sha256.convert(payload).toString(),
        },
      },
      'missingAttachments': <String>[],
      'credentialsIncluded': false,
    };
    final archive = Archive()
      // Deliberately understate the uncompressed size in the ZIP header. The
      // decoder must enforce the limit on bytes actually emitted by inflate.
      ..addFile(ArchiveFile('data/settings.json', 1, payload))
      ..addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
    final fixture = File('${testRoot.path}/understated-entry-size.cgbak');
    await fixture.writeAsBytes(ZipEncoder().encodeBytes(archive));

    await expectLater(
      BackupInspector(
        db: db,
        tempRoot: testRoot,
        entryByteLimit: entryByteLimit,
        expandedByteLimit: expandedByteLimit,
      ).inspect(fixture),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('单文件限制'),
        ),
      ),
    );
  });

  test('rejects actual archive output beyond the expanded limit', () async {
    const entryByteLimit = 1024;
    const expandedByteLimit = 1900;
    final firstPayload = List<int>.filled(900, 0x41);
    final secondPayload = List<int>.filled(900, 0x42);
    final manifest = {
      'format': BackupManifest.formatName,
      'formatVersion': 1,
      'schemaVersion': 1,
      'appVersion': '1.0.0',
      'createdAt': '2026-08-01T00:00:00.000Z',
      'scope': BackupScope.configurationOnly.name,
      'counts': <String, int>{},
      'files': {
        'data/settings.json': {
          'bytes': firstPayload.length,
          'sha256': sha256.convert(firstPayload).toString(),
        },
        'data/api_configs.json': {
          'bytes': secondPayload.length,
          'sha256': sha256.convert(secondPayload).toString(),
        },
      },
      'missingAttachments': <String>[],
      'credentialsIncluded': false,
    };
    final archive = Archive()
      // Both entries stay below the per-entry cap. Their deliberately tiny
      // ZIP size declarations must not bypass the aggregate actual-byte cap.
      ..addFile(ArchiveFile('data/settings.json', 1, firstPayload))
      ..addFile(ArchiveFile('data/api_configs.json', 1, secondPayload))
      ..addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
    final fixture = File('${testRoot.path}/understated-expanded-size.cgbak');
    await fixture.writeAsBytes(ZipEncoder().encodeBytes(archive));

    await expectLater(
      BackupInspector(
        db: db,
        tempRoot: testRoot,
        entryByteLimit: entryByteLimit,
        expandedByteLimit: expandedByteLimit,
      ).inspect(fixture),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('实际解压体积超过限制'),
        ),
      ),
    );
  });

  test('rejects a deeply nested manifest before jsonDecode materializes it',
      () async {
    final fixture = await _writeV1Fixture(testRoot);
    final nested = File('${testRoot.path}/nested-manifest.cgbak');
    await _rewriteManifestArchive(
      fixture,
      nested,
      (manifest) {
        dynamic value = 'leaf';
        for (var index = 0; index < 40; index++) {
          value = [value];
        }
        manifest['nested'] = value;
      },
    );

    await expectLater(
      BackupRestoreService(
        db: db,
        mediaDirectory: mediaDirectory,
        tempRoot: testRoot,
      ).inspect(nested),
      throwsA(isA<BackupException>()),
    );
  });

  test('real v1 fixture caches validated staged data', () async {
    final fixture = await _writeV1Fixture(testRoot);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);
    expect(prepared.validatedData, isA<StagedBackupData>());
    final data = prepared.validatedData! as StagedBackupData;

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

  test('staged JSONL records reject an oversized line before decoding',
      () async {
    final fixture = await _writeV1Fixture(testRoot);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);

    final oversizedMessage = {
      'key': 'message-1',
      'value': {
        'id': 'message-1',
        'groupId': 'group-1',
        'senderId': 'user',
        'senderType': 'user',
        'content': 'x' * (StagedBackupData.maxJsonLineBytes + 1),
        'timestamp': '2026-08-01T00:00:00.000Z',
        'replyToMessageId': null,
        'isMention': false,
        'mentionedAiIds': <String>[],
        'media': <dynamic>[],
      },
    };
    await File('${prepared.stagingDirectory.path}/data/messages.jsonl')
        .writeAsString(jsonEncode(oversizedMessage));

    await expectLater(
      StagedBackupData.load(prepared.stagingDirectory, prepared.manifest),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('备份记录行过长'),
        ),
      ),
    );
  });

  test('staged data rejects an oversized aggregate before materialization',
      () async {
    final fixture = await _writeV1Fixture(testRoot);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);

    await expectLater(
      StagedBackupData.load(
        prepared.stagingDirectory,
        prepared.manifest,
        maxAggregateBytes: 1,
      ),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('备份数据总大小超过限制'),
        ),
      ),
    );
  });

  test('staged JSON rejects excessive nesting before materialization',
      () async {
    final fixture = await _writeV1Fixture(testRoot);
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    final prepared = await service.inspect(fixture);
    addTearDown(prepared.dispose);

    final nested = <String, dynamic>{};
    var cursor = nested;
    for (var depth = 0; depth <= StagedBackupData.maxJsonDepth; depth++) {
      final child = <String, dynamic>{};
      cursor['child'] = child;
      cursor = child;
    }
    await File('${prepared.stagingDirectory.path}/data/characters.json')
        .writeAsString(jsonEncode([
      {
        'key': 'char-1',
        'value': {
          'id': 'char-1',
          'apiConfigId': '',
          'nested': nested,
        },
      },
    ]));

    await expectLater(
      StagedBackupData.load(prepared.stagingDirectory, prepared.manifest),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('备份 JSON 结构过深'),
        ),
      ),
    );
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
}
