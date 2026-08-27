part of 'data_lifecycle_service_test.dart';

void _registerDataLifecycleServiceTestPart2() {
  test('loader detects restricted messages outside the initial page', () async {
    const firstMemberId = 'page-member-a';
    const secondMemberId = 'page-member-b';
    const groupId = 'paginated-visibility-group';
    await db.aiCharacterBox.putAll({
      firstMemberId: testCharacter(firstMemberId),
      secondMemberId: testCharacter(secondMemberId),
    });
    await db.chatGroupBox.put(
      groupId,
      ChatGroup(
        id: groupId,
        name: '分页可见性群',
        theme: '',
        aiCharacterIds: const [firstMemberId, secondMemberId],
      ),
    );

    final baseTime = DateTime(2026, 1, 1);
    await db.messageBox.putAll({
      for (var index = 0; index < 81; index++)
        'page-message-$index': Message(
          id: 'page-message-$index',
          groupId: groupId,
          senderId: 'user',
          senderType: 'user',
          content: '消息$index',
          timestamp: baseTime.add(Duration(minutes: index)),
          visibleToCharacterIds: index == 0
              ? const [firstMemberId]
              : const [firstMemberId, secondMemberId],
        ),
    });

    final loaded = await ChatRoomLoader(
      db: db,
      resolveApiConfig: (_) => null,
    ).load(groupId);

    expect(loaded.messages, hasLength(80));
    expect(loaded.messages.any((message) => message.id == 'page-message-0'),
        isFalse);
    expect(loaded.hasRestrictedHistory, isTrue);
  });

  test(
      'loader treats legacy messages without visibility snapshots as restricted',
      () async {
    const characterId = 'legacy-visibility-character';
    const groupId = 'legacy-visibility-group';
    await db.aiCharacterBox.put(characterId, testCharacter(characterId));
    await db.chatGroupBox.put(
      groupId,
      ChatGroup(
        id: groupId,
        name: '旧消息群',
        theme: '',
        aiCharacterIds: const [characterId],
      ),
    );
    await db.messageBox.put(
      'legacy-visibility-message',
      Message(
        id: 'legacy-visibility-message',
        groupId: groupId,
        senderId: 'user',
        senderType: 'user',
        content: '旧消息',
      ),
    );

    final loaded = await ChatRoomLoader(
      db: db,
      resolveApiConfig: (_) => null,
    ).load(groupId);

    expect(loaded.hasRestrictedHistory, isTrue);
  });

  test(
      'deleting a message invalidates group memory unless explicitly transient',
      () async {
    const groupId = 'message-memory-invalidation-group';
    await db.chatGroupBox.put(
      groupId,
      ChatGroup(
        id: groupId,
        name: '摘要失效群',
        theme: '',
        aiCharacterIds: const ['c1'],
      ),
    );
    await db.messageBox.put(
      'message-to-delete',
      Message(
        id: 'message-to-delete',
        groupId: groupId,
        senderId: 'user',
        senderType: 'user',
        content: '受限内容',
        visibleToCharacterIds: const ['someone-else'],
      ),
    );
    await db.groupMemoryBox.put(
      'memory-to-invalidate',
      GroupMemory(groupId: groupId, topicSummary: '旧摘要'),
    );

    expect(
      (await service.deleteMessage('message-to-delete', groupId: groupId))
          .isComplete,
      isTrue,
    );
    expect(db.groupMemoryBox.get('memory-to-invalidate'), isNull);

    await db.messageBox.put(
      'transient-message',
      Message(
        id: 'transient-message',
        groupId: groupId,
        senderId: 'c1',
        senderType: 'ai',
        content: '临时进度',
      ),
    );
    await db.groupMemoryBox.put(
      'transient-memory',
      GroupMemory(groupId: groupId, topicSummary: '保留摘要'),
    );

    expect(
      (await service.deleteMessage(
        'transient-message',
        groupId: groupId,
        invalidateGroupMemory: false,
      ))
          .isComplete,
      isTrue,
    );
    expect(db.groupMemoryBox.get('transient-memory'), isNotNull);
  });

  test('legacy deleted snapshot without gender does not surface fake female',
      () async {
    await db.appSettingsBox.put(
      DataLifecycleSettings.deletedCharacterSnapshotsKey,
      {
        'legacy-deleted': {
          'name': '旧删除角色',
          'avatar': '旧',
          'age': 20,
          'role': '旧角色',
        },
      },
    );

    final snapshot = service.deletedCharacter('legacy-deleted');
    expect(snapshot, isNotNull);
    expect(snapshot!.hasKnownGender, isFalse);
    expect(snapshot.displayGenderLabel, '未知');
    expect(snapshot.promptIdentity, isNot(contains('性别女')));
    expect(service.deletedCharacters().single.name, '旧删除角色');
  });

  test('unknown deleted snapshot does not persist compatibility female',
      () async {
    final unknown = testCharacter('pending-deleted', hasKnownGender: false);
    await DataLifecycleSettings(db).saveDeletedCharacter(unknown);

    final raw = db.appSettingsBox.get(
      DataLifecycleSettings.deletedCharacterSnapshotsKey,
    ) as Map;
    final snapshot = raw['pending-deleted'] as Map;
    expect(snapshot.containsKey('gender'), isFalse);
    expect(
        service.deletedCharacter('pending-deleted')!.hasKnownGender, isFalse);
  });

  test('character full policy deletes private history and orphan attachment',
      () async {
    const characterId = 'c1';
    final conversationId = DirectChatSession.conversationIdFor(characterId);
    final attachment = File('${mediaDirectory.path}/dm.txt');
    await attachment.writeAsString('private');
    await db.aiCharacterBox.put(characterId, testCharacter(characterId));
    await db.messageBox.put(
      'dm',
      Message(
        id: 'dm',
        groupId: conversationId,
        senderId: characterId,
        senderType: 'ai',
        content: 'private',
        media: [MediaAttachment(type: 'file', localPath: attachment.path)],
      ),
    );

    final result = await service.deleteCharacter(
      characterId,
      policy: CharacterDeletionPolicy.deleteRelatedData,
    );

    expect(result.isComplete, isTrue);
    expect(db.messageBox.isEmpty, isTrue);
    expect(await attachment.exists(), isFalse);
    expect(service.deletedCharacter(characterId), isNull);
  });

  test('group deletion keeps permanent data and global state by default',
      () async {
    await db.chatGroupBox.putAll({
      'g1':
          ChatGroup(id: 'g1', name: '一群', theme: '', aiCharacterIds: const []),
      'g2':
          ChatGroup(id: 'g2', name: '二群', theme: '', aiCharacterIds: const []),
    });
    await db.messageBox.putAll({
      'm1': Message(
        id: 'm1',
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '群一证据',
      ),
      'm2': Message(
        id: 'm2',
        groupId: 'g2',
        senderId: 'user',
        senderType: 'user',
        content: '群二保留',
      ),
    });
    await db.permanentMemoryBox.putAll({
      'pm-g1': testPermanentMemory(
        id: 'pm-g1',
        originConversationId: 'g1',
        originNameSnapshot: '一群',
        sourceMessageIds: ['m1'],
      ),
      'pm-g2': testPermanentMemory(
        id: 'pm-g2',
        originConversationId: 'g2',
        originNameSnapshot: '二群',
      ),
      'pm-unknown': testPermanentMemory(
        id: 'pm-unknown',
        originConversationId: null,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
      ),
    });
    await db.relationshipEventBox.putAll({
      'event-g1': testRelationshipEvent(
        id: 'event-g1',
        originConversationId: 'g1',
        originNameSnapshot: '一群',
        sourceMessageIds: ['m1'],
        revision: 1,
        affinityAfter: 10,
      ),
      'event-g2': testRelationshipEvent(
        id: 'event-g2',
        originConversationId: 'g2',
        originNameSnapshot: '二群',
        revision: 2,
        affinityAfter: 20,
      ),
    });
    final globalId = RelationshipState.stableGlobalId(
      'source',
      RelationshipTargetType.user,
      'user',
    );
    await db.relationshipStateBox.putAll({
      'legacy-g1': RelationshipState(
        id: 'legacy-g1',
        groupId: 'g1',
        sourceCharacterId: 'source',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
      ),
      globalId: RelationshipState.global(
        id: globalId,
        sourceCharacterId: 'source',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        affinity: 20,
        revision: 2,
        lastEventId: 'event-g2',
      ),
    });
    await db.appSettingsBox.put(DataLifecycleSettings.memoryPinnedKey, [
      'relationship:$globalId',
    ]);

    final plan = await service.previewGroup('g1');
    expect(plan.count('messages'), 1);
    expect(plan.count('permanentMemories'), 0);
    expect(plan.optionalCount('permanentMemories'), 1);
    expect(plan.optionalCount('relationshipEvents'), 1);
    expect(plan.retainedCount('globalRelationshipStates'), 1);
    expect(plan.count('memoryPins'), 0);

    expect((await service.deleteGroup('g1')).isComplete, isTrue);
    expect(db.chatGroupBox.containsKey('g1'), isFalse);
    expect(db.messageBox.containsKey('m1'), isFalse);
    expect(db.messageBox.containsKey('m2'), isTrue);
    expect(db.relationshipStateBox.containsKey('legacy-g1'), isFalse);
    expect(db.relationshipStateBox.containsKey(globalId), isTrue);
    expect(db.appSettingsBox.get(DataLifecycleSettings.memoryPinnedKey), [
      'relationship:$globalId',
    ]);
    expect(db.permanentMemoryBox.length, 3);
    expect(db.relationshipEventBox.length, 2);
    expect(db.permanentMemoryBox.get('pm-g1')!.originNameSnapshot, '一群');
    expect(db.permanentMemoryBox.get('pm-g1')!.sourceMessageIds, ['m1']);
    expect(db.relationshipEventBox.get('event-g1')!.originNameSnapshot, '一群');
    expect(db.relationshipEventBox.get('event-g1')!.sourceMessageIds, ['m1']);
  });
}
