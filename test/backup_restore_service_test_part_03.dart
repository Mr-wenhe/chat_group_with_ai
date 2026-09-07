part of 'backup_restore_service_test.dart';

void _registerBackupRestoreServiceTestPart3() {
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

  test(
      'malformed inline attachment is reported as missing without filesystem access',
      () async {
    final attachment = File('${mediaDirectory.path}/valid.txt');
    await attachment.writeAsString('valid');
    await _seedCoreData(db, attachment);
    await db.messageBox.put(
      'invalid-inline-message',
      Message(
        id: 'invalid-inline-message',
        groupId: 'group-1',
        senderId: 'user',
        senderType: 'user',
        content: 'invalid inline',
        media: [
          MediaAttachment(
            id: 'invalid-inline-attachment',
            type: 'file',
            localPath: 'data:text/plain;base64,%%%not-base64%%%',
            fileName: 'invalid.txt',
          ),
        ],
      ),
    );
    final backup = File('${testRoot.path}/invalid-inline.cgbak');
    final service = BackupRestoreService(
      db: db,
      mediaDirectory: mediaDirectory,
      tempRoot: testRoot,
    );

    final estimate = await service.estimate(const BackupSelection.all());
    final result = await service.createBackup(destination: backup);

    expect(estimate.missingAttachments, 1);
    expect(result.manifest.missingAttachments, contains('invalid.txt'));
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
}
