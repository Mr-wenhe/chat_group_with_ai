part of 'backup_restore_service_test.dart';

/// Writes a minimal stored (uncompressed) ZIP whose central-directory entry
/// name is [entryName], bypassing the `archive` package encoder. The encoder
/// normalises `../` path segments on some platforms (notably the GitHub
/// Actions Linux runner), which would strip the traversal payload before
/// [ZipPreflight] can see it. Building the raw ZIP bytes directly guarantees
/// the entry name reaches the validator verbatim on every platform.
Future<void> _writeRawZip(
  File target, {
  required String entryName,
  required String content,
}) async {
  final nameBytes = utf8.encode(entryName);
  final contentBytes = utf8.encode(content);
  final crc = getCrc32(contentBytes);
  final size = contentBytes.length;

  final local = <int>[
    ..._u32le(0x04034b50), // local file header signature
    ..._u16le(20), ..._u16le(0), ..._u16le(0), // version, flags, stored
    ..._u16le(0), ..._u16le(0x0021), // mod time, mod date
    ..._u32le(crc), ..._u32le(size), ..._u32le(size), // crc, sizes
    ..._u16le(nameBytes.length), ..._u16le(0), // name len, extra len
    ...nameBytes, ...contentBytes,
  ];
  final cd = <int>[
    ..._u32le(0x02014b50), // central directory header signature
    ..._u16le(20), ..._u16le(20), ..._u16le(0), ..._u16le(0), // versions, flags, stored
    ..._u16le(0), ..._u16le(0x0021), // mod time, mod date
    ..._u32le(crc), ..._u32le(size), ..._u32le(size), // crc, sizes
    ..._u16le(nameBytes.length), ..._u16le(0), ..._u16le(0), // name, extra, comment
    ..._u16le(0), ..._u16le(0), ..._u32le(0), ..._u32le(0), // disk, attrs, local offset
    ...nameBytes,
  ];
  final eocd = <int>[
    ..._u32le(0x06054b50), // EOCD signature
    ..._u16le(0), ..._u16le(0), // disk numbers
    ..._u16le(1), ..._u16le(1), // cd record counts
    ..._u32le(cd.length), ..._u32le(local.length), // cd size, cd offset
    ..._u16le(0), // comment length
  ];
  await target.writeAsBytes(Uint8List.fromList([...local, ...cd, ...eocd]));
}

List<int> _u16le(int value) => [value & 0xff, (value >> 8) & 0xff];

List<int> _u32le(int value) => [
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];

void _registerBackupRestoreServiceTestPart1() {
  test('validates record arrays incrementally across input chunks', () async {
    final payload = List.filled(100000, 'x').join();
    final record = jsonEncode({
      'key': 'large-record',
      'value': {'id': 'large-record', 'content': payload},
    });
    final file = File('${testRoot.path}/large-records.json');
    await file.writeAsString('[$record,$record]');

    await StagedBackupData.validateRecordFile(file, 'data/large-records.json');
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

  test('export rejects an oversized JSONL message before creating a package',
      () async {
    final attachment = File('${mediaDirectory.path}/oversized-message.txt');
    await attachment.writeAsString('attachment');
    await _seedCoreData(db, attachment);
    await db.messageBox.put(
      'oversized-message',
      Message(
        id: 'oversized-message',
        groupId: 'group-1',
        senderId: 'user',
        senderType: 'user',
        content: 'x' * (StagedBackupData.maxJsonLineBytes + 1),
      ),
    );

    final destination = File('${testRoot.path}/oversized-message.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    await expectLater(
      service.createBackup(destination: destination),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('备份记录行过长'),
        ),
      ),
    );
    expect(await destination.exists(), isFalse);
  });

  test('inspection is read-only and empty database restores references',
      () async {
    final attachment = File('${mediaDirectory.path}/photo.bin');
    await attachment.writeAsBytes([1, 2, 3, 4]);
    await _seedCoreData(db, attachment, apiKey: 'sk-not-exported');
    final sourceCharacter =
        db.aiCharacterBox.get('char-1')!.withGender(CharacterGender.male);
    await db.aiCharacterBox.put(sourceCharacter.id, sourceCharacter);
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

  test('inspection rejects a filesystem symlink used as the backup source',
      () async {
    final backup = File('${testRoot.path}/regular.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );
    await service.createBackup(destination: backup);
    final link = Link('${testRoot.path}/source-link.cgbak');
    await link.create(backup.path);

    await expectLater(
      service.inspect(File(link.path)),
      throwsA(isA<BackupException>()),
    );
  }, skip: Platform.isWindows ? 'symlink privileges vary on Windows' : null);

  test('backup round-trip preserves both gender values', () async {
    final attachment = File('${mediaDirectory.path}/gender.txt');
    await attachment.writeAsString('gender');
    await _seedCoreData(db, attachment);
    final first =
        db.aiCharacterBox.get('char-1')!.withGender(CharacterGender.male);
    await db.aiCharacterBox.put(first.id, first);
    final second = testCharacter(
      'char-2',
      apiConfigId: 'api-1',
      gender: CharacterGender.female,
    );
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

  test('legacy backup without gender stays unknown until migration', () {
    final json = BackupEntityCodec.character(testCharacter('legacy'))
      ..remove('gender');

    final decoded = BackupEntityCodec.decodeCharacter(json);

    expect(decoded.gender, CharacterGender.female);
    expect(decoded.hasKnownGender, isFalse);
    expect(decoded.displayGenderLabel, '未知');
  });

  test('unknown gender is omitted from new backups', () {
    final encoded = BackupEntityCodec.character(
      testCharacter('pending', hasKnownGender: false),
    );

    expect(encoded.containsKey('gender'), isFalse);
    expect(
      BackupEntityCodec.decodeCharacter(encoded).hasKnownGender,
      isFalse,
    );
  });

  test('invalid gender in a backup is queued for migration', () async {
    final legacy = await _writeV1Fixture(testRoot);
    final fixture = await _rewriteBackupJson(
      legacy,
      File('${testRoot.path}/invalid-gender.cgbak'),
      'data/characters.json',
      (value) {
        final character = ((value as List).single as Map)['value'] as Map;
        character['gender'] = 'not-a-gender';
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
      strategy: RestoreConflictStrategy.emptyOnly,
    );

    expect(migrator.called, isTrue);
    expect(migrator.candidateIdsAtCall, contains('char-1'));
    expect(db.aiCharacterBox.get('char-1')!.hasKnownGender, isFalse);
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
    // Build a raw ZIP with a traversal entry name (`../outside.txt`) so the
    // payload reaches ZipPreflight regardless of how the `archive` encoder
    // normalises path segments on the current platform.
    final malicious = File('${testRoot.path}/malicious.cgbak');
    await _writeRawZip(
      malicious,
      entryName: '../outside.txt',
      content: 'escape',
    );
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

  test('partial attachment copy is rolled back before final rename', () async {
    final attachment = File('${mediaDirectory.path}/copy-failure.txt');
    await attachment.writeAsString('copy failure');
    await _seedCoreData(db, attachment);
    final backup = File('${testRoot.path}/copy-failure.cgbak');
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
    var copyCalls = 0;
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
      attachmentCopy: (source, target) async {
        copyCalls++;
        await target.writeAsString('partial');
        throw StateError('simulated attachment copy failure');
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

    expect(copyCalls, 1);
    expect(await mediaDirectory.list().toList(), isEmpty);
    expect(db.messageBox, isEmpty);
    expect(db.chatGroupBox, isEmpty);
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
}
