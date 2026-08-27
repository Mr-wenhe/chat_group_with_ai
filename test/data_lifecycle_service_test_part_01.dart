part of 'data_lifecycle_service_test.dart';

void _registerDataLifecycleServiceTestPart1() {
  test('group preview and cascade cover every relation and are idempotent',
      () async {
    final removedFile = File('${mediaDirectory.path}/removed.jpg');
    final sharedFile = File('${mediaDirectory.path}/shared.jpg');
    await removedFile.writeAsString('removed');
    await sharedFile.writeAsString('shared');
    await db.aiCharacterBox.put('c1', testCharacter('c1'));
    await db.chatGroupBox.put(
      'g1',
      ChatGroup(id: 'g1', name: '一群', theme: '', aiCharacterIds: ['c1']),
    );
    await db.chatGroupBox.put(
      'g2',
      ChatGroup(id: 'g2', name: '二群', theme: '', aiCharacterIds: ['c1']),
    );
    final removedMessage = Message(
      id: 'm1',
      groupId: 'g1',
      senderId: 'c1',
      senderType: 'ai',
      content: 'remove',
      media: [
        MediaAttachment(type: 'image', localPath: removedFile.path),
        MediaAttachment(type: 'image', localPath: sharedFile.path),
      ],
    );
    final retainedMessage = Message(
      id: 'm2',
      groupId: 'g2',
      senderId: 'c1',
      senderType: 'ai',
      content: 'keep',
      replyToMessageId: 'm1',
      media: [MediaAttachment(type: 'image', localPath: sharedFile.path)],
    );
    await db.messageBox.putAll({'m1': removedMessage, 'm2': retainedMessage});
    await db.groupMemoryBox.put(
      'g1_week',
      GroupMemory(groupId: 'g1', topicSummary: 'memory'),
    );
    await db.characterMemoryBox.put(
      'cm1',
      CharacterMemory(id: 'cm1', groupId: 'g1', characterId: 'c1'),
    );
    await db.relationshipStateBox.put(
      'r1',
      RelationshipState(
        id: 'r1',
        groupId: 'g1',
        sourceCharacterId: 'c1',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
      ),
    );
    await db.agentTaskBox.put(
      't1',
      AgentTask(
        id: 't1',
        groupId: 'g1',
        characterId: 'c1',
        userRequest: 'task',
      ),
    );
    await db.workModeWorkspaceBox.put(
      'g1',
      WorkModeWorkspace(
          id: 'w1', conversationId: 'g1', conversationType: 'group'),
    );
    await db.appSettingsBox.put('message_ids_by_group', {
      'g1': ['m1'],
      'g2': ['m2'],
    });
    await db.appSettingsBox.put('group_chat_read_at', {'g1': '2026-07-01'});
    await db.appSettingsBox.put('group_chat_last_proactive_at', {'g1': 'x'});
    await db.appSettingsBox.put('pinned_group_ids', ['g1', 'g2']);
    await db.appSettingsBox.put('work_mode_enabled:g1', true);
    await db.appSettingsBox.put('context_compressed_through:g1:c1', 'm1');
    await db.appSettingsBox.put('memory_pinned_keys_v1', [
      'group:g1:g1_week',
      'character:cm1:facts:dGVzdA==',
      'relationship:r1',
    ]);

    final plan = await service.previewGroup('g1');
    expect(plan.count('messages'), 1);
    expect(plan.count('groupMemories'), 1);
    expect(plan.count('characterMemories'), 1);
    expect(plan.count('relationships'), 1);
    expect(plan.count('tasks'), 1);
    expect(plan.count('workspaces'), 1);
    expect(plan.count('attachments'), 1);

    expect((await service.deleteGroup('g1')).isComplete, isTrue);
    expect((await service.deleteGroup('g1')).isComplete, isTrue);
    expect(db.chatGroupBox.containsKey('g1'), isFalse);
    expect(db.messageBox.containsKey('m1'), isFalse);
    expect(db.messageBox.get('m2')!.replyToMessageId, isNull);
    expect(db.groupMemoryBox.isEmpty, isTrue);
    expect(db.characterMemoryBox.isEmpty, isTrue);
    expect(db.relationshipStateBox.isEmpty, isTrue);
    expect(db.agentTaskBox.isEmpty, isTrue);
    expect(db.workModeWorkspaceBox.isEmpty, isTrue);
    expect(await removedFile.exists(), isFalse);
    expect(await sharedFile.exists(), isTrue);
    expect(db.pinnedGroupIds(), {'g2'});
    expect(db.appSettingsBox.get('memory_pinned_keys_v1'), isEmpty);
    expect(service.hasPendingOperation, isFalse);
  });

  test('large group preview and deletion process ten thousand messages',
      () async {
    await db.chatGroupBox.put(
      'large',
      ChatGroup(
        id: 'large',
        name: '大群',
        theme: '',
        aiCharacterIds: const [],
      ),
    );
    final messages = <String, Message>{};
    for (var index = 0; index < 10000; index++) {
      final id = 'message-$index';
      messages[id] = Message(
        id: id,
        groupId: 'large',
        senderId: 'user',
        senderType: 'user',
        content: '$index',
      );
    }
    await db.messageBox.putAll(messages);

    expect((await service.previewGroup('large')).count('messages'), 10000);
    expect((await service.deleteGroup('large')).isComplete, isTrue);
    expect(db.messageBox.isEmpty, isTrue);
    expect((await service.deleteGroup('large')).isComplete, isTrue);
  });

  test('character keep-history policy removes references but keeps readable DM',
      () async {
    const characterId = 'c1';
    final conversationId = DirectChatSession.conversationIdFor(characterId);
    final deleted = testCharacter(characterId, gender: CharacterGender.male);
    await db.aiCharacterBox.put(characterId, deleted);
    await db.aiCharacterBox.put('c2', testCharacter('c2'));
    await db.chatGroupBox.put(
      'g1',
      ChatGroup(
        id: 'g1',
        name: '群聊',
        theme: '',
        aiCharacterIds: [characterId, 'c2'],
      ),
    );
    await db.messageBox.putAll({
      'gm': Message(
        id: 'gm',
        groupId: 'g1',
        senderId: characterId,
        senderType: 'ai',
        content: 'history',
        mentionedAiIds: [characterId, 'c2'],
      ),
      'dm': Message(
        id: 'dm',
        groupId: conversationId,
        senderId: characterId,
        senderType: 'ai',
        content: 'private history',
      ),
    });
    await db.characterMemoryBox.put(
      'cm',
      CharacterMemory(id: 'cm', groupId: 'g1', characterId: characterId),
    );
    await db.permanentMemoryBox.putAll({
      'pm-self': testPermanentMemory(
        id: 'pm-self',
        observerCharacterId: characterId,
        originConversationId: 'g1',
      ),
      'pm-about': testPermanentMemory(
        id: 'pm-about',
        observerCharacterId: 'c2',
        subjectIds: [characterId],
        originConversationId: 'g1',
      ),
    });
    await db.relationshipStateBox.put(
      'r',
      RelationshipState(
        id: 'r',
        groupId: 'g1',
        sourceCharacterId: 'c2',
        targetId: characterId,
        targetType: RelationshipTargetType.ai,
      ),
    );
    final sourceRelationshipId = RelationshipState.stableGlobalId(
      characterId,
      RelationshipTargetType.user,
      'user',
    );
    final targetRelationshipId = RelationshipState.stableGlobalId(
      'c2',
      RelationshipTargetType.ai,
      characterId,
    );
    await db.relationshipStateBox.putAll({
      sourceRelationshipId: RelationshipState.global(
        id: sourceRelationshipId,
        sourceCharacterId: characterId,
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        affinity: 10,
      ),
      targetRelationshipId: RelationshipState.global(
        id: targetRelationshipId,
        sourceCharacterId: 'c2',
        targetType: RelationshipTargetType.ai,
        targetId: characterId,
        affinity: 20,
      ),
    });
    await db.relationshipEventBox.putAll({
      'event-source': testRelationshipEvent(
        id: 'event-source',
        sourceCharacterId: characterId,
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        originConversationId: 'g1',
        revision: 1,
        affinityAfter: 10,
      ),
      'event-target': testRelationshipEvent(
        id: 'event-target',
        sourceCharacterId: 'c2',
        targetType: RelationshipTargetType.ai,
        targetId: characterId,
        originConversationId: 'g1',
        revision: 1,
        affinityAfter: 20,
      ),
    });
    await db.characterSkillBox.put(
      's',
      CharacterSkill(
        id: 's',
        characterId: characterId,
        name: 'skill',
        domain: 'test',
        description: 'test',
        instructions: const [],
        requiredPermissions: const [ToolPermission.workspaceRead],
      ),
    );
    await db.agentTaskBox.put(
      't',
      AgentTask(
        id: 't',
        groupId: 'g1',
        characterId: characterId,
        userRequest: 'task',
      ),
    );
    await db.workModeWorkspaceBox.put(
      conversationId,
      WorkModeWorkspace(
        id: 'w',
        conversationId: conversationId,
        conversationType: 'direct',
      ),
    );
    await db.appSettingsBox.put('pinned_character_ids', [characterId]);
    await db.appSettingsBox
        .put('direct_chat_last_proactive_at', {characterId: 'x'});
    await db.appSettingsBox.put('memory_pinned_keys_v1', [
      'legacy:$characterId',
      'character:cm:facts:dGVzdA==',
      'relationship:r',
      'relationship:$sourceRelationshipId',
    ]);

    final result = await service.deleteCharacter(
      characterId,
      policy: CharacterDeletionPolicy.keepMessageHistory,
    );
    expect(result.isComplete, isTrue);
    expect(db.aiCharacterBox.containsKey(characterId), isFalse);
    expect(db.chatGroupBox.get('g1')!.aiCharacterIds, ['c2']);
    expect(db.messageBox.get('gm')!.mentionedAiIds, ['c2']);
    expect(db.messageBox.containsKey('dm'), isTrue);
    expect(db.characterMemoryBox.isEmpty, isTrue);
    expect(db.relationshipStateBox.containsKey('r'), isTrue);
    expect(db.relationshipStateBox.get('r')!.targetId, characterId);
    expect(db.relationshipStateBox.containsKey(targetRelationshipId), isTrue);
    expect(db.relationshipStateBox.containsKey(sourceRelationshipId), isFalse);
    expect(db.permanentMemoryBox.containsKey('pm-self'), isFalse);
    expect(db.permanentMemoryBox.containsKey('pm-about'), isTrue);
    expect(db.relationshipEventBox.containsKey('event-source'), isFalse);
    expect(db.relationshipEventBox.containsKey('event-target'), isTrue);
    expect(db.characterSkillBox.isEmpty, isTrue);
    expect(db.agentTaskBox.isEmpty, isTrue);
    expect(db.workModeWorkspaceBox.isEmpty, isTrue);
    expect(db.appSettingsBox.get('memory_pinned_keys_v1'), ['relationship:r']);
    expect(service.deletedCharacter(characterId)!.name, '角色c1');
    expect(service.deletedCharacter(characterId)!.gender, CharacterGender.male);

    await Hive.close();
    await reopenLifecycleHive(hiveDirectory);
    expect(service.deletedCharacter(characterId)!.gender, CharacterGender.male);

    final loaded = await ChatRoomLoader(db: db, resolveApiConfig: (_) => null)
        .load(conversationId);
    expect(loaded.messages.single.content, 'private history');
    expect(loaded.activeCharacters, isEmpty);
    expect(
        (await service.deleteCharacter(
          characterId,
          policy: CharacterDeletionPolicy.keepMessageHistory,
        ))
            .isComplete,
        isTrue);
  });

  test('group history uses a deleted character identity snapshot', () async {
    const characterId = 'history-character';
    await db.aiCharacterBox.put(characterId, testCharacter(characterId));
    await db.chatGroupBox.put(
      'history-group',
      ChatGroup(
        id: 'history-group',
        name: '历史群',
        theme: '',
        aiCharacterIds: [characterId],
      ),
    );
    await db.messageBox.put(
      'history-message',
      Message(
        id: 'history-message',
        groupId: 'history-group',
        senderId: characterId,
        senderType: 'ai',
        content: '保留历史身份',
      ),
    );

    expect(
      (await service.deleteCharacter(
        characterId,
        policy: CharacterDeletionPolicy.keepMessageHistory,
      ))
          .isComplete,
      isTrue,
    );

    final loaded = await ChatRoomLoader(
      db: db,
      resolveApiConfig: (_) => null,
    ).load('history-group');
    expect(loaded.messages.single.content, '保留历史身份');
    expect(loaded.activeCharacters, isEmpty);
    expect(loaded.allCharacters.single.name, '角色history-character');
    expect(loaded.allCharacters.single.avatar, '角');
  });

  test('group history does not reactivate a character removed from the group',
      () async {
    const currentId = 'current-character';
    const removedId = 'removed-character';
    await db.aiCharacterBox.putAll({
      currentId: testCharacter(currentId),
      removedId: testCharacter(removedId),
    });
    await db.chatGroupBox.put(
      'member-boundary-group',
      ChatGroup(
        id: 'member-boundary-group',
        name: '成员边界群',
        theme: '',
        aiCharacterIds: const [currentId],
      ),
    );
    await db.messageBox.put(
      'removed-member-message',
      Message(
        id: 'removed-member-message',
        groupId: 'member-boundary-group',
        senderId: removedId,
        senderType: 'ai',
        content: '历史发言',
      ),
    );

    final loaded = await ChatRoomLoader(
      db: db,
      resolveApiConfig: (_) => null,
    ).load('member-boundary-group');

    expect(
        loaded.activeCharacters.map((character) => character.id), [currentId]);
    expect(loaded.allCharacters.map((character) => character.id),
        containsAll([currentId, removedId]));
  });
}
