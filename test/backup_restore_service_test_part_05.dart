part of 'backup_restore_service_test.dart';

void _registerBackupRestoreServiceTestPart5() {
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
