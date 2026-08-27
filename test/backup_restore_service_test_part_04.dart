part of 'backup_restore_service_test.dart';

void _registerBackupRestoreServiceTestPart4() {
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
    final locked = testCharacter('locked', gender: CharacterGender.male);
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
    final existing = testCharacter('old-candidate', hasKnownGender: false)
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
    final existing = testCharacter('old-candidate', hasKnownGender: false)
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
    final existing = testCharacter('old-candidate', hasKnownGender: false)
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
    final existing = testCharacter('old-candidate', hasKnownGender: false)
      ..role = '父亲'
      ..systemPrompt = '我是男性';
    await db.aiCharacterBox.put(existing.id, existing);
    final locked = testCharacter(
      'locked',
      gender: CharacterGender.male,
      hasKnownGender: true,
    );
    await db.aiCharacterBox.put(locked.id, locked);
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
    expect(migrator.candidateIdsAtCall, isNot(contains('locked')));
    expect(db.aiCharacterBox.get('locked')!.gender, CharacterGender.male);
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
}
