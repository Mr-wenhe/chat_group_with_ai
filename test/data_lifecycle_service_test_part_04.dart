part of 'data_lifecycle_service_test.dart';

void _registerDataLifecycleServiceTestPart4() {
  test('full character deletion removes observer and target references',
      () async {
    const characterId = 'c1';
    const otherCharacterId = 'c2';
    final conversationId = DirectChatSession.conversationIdFor(characterId);
    final otherConversationId =
        DirectChatSession.conversationIdFor(otherCharacterId);
    await db.aiCharacterBox.putAll({
      characterId: testCharacter(characterId),
      otherCharacterId: testCharacter(otherCharacterId),
    });
    await db.chatGroupBox.put(
      'g1',
      ChatGroup(
        id: 'g1',
        name: '群聊',
        theme: '',
        aiCharacterIds: [characterId, otherCharacterId],
      ),
    );
    await db.messageBox.putAll({
      'group': Message(
        id: 'group',
        groupId: 'g1',
        senderId: otherCharacterId,
        senderType: 'ai',
        content: '提及',
        mentionedAiIds: [characterId, otherCharacterId],
      ),
      'dm-c1': Message(
        id: 'dm-c1',
        groupId: conversationId,
        senderId: characterId,
        senderType: 'ai',
        content: '删除私聊',
      ),
      'dm-c2': Message(
        id: 'dm-c2',
        groupId: otherConversationId,
        senderId: otherCharacterId,
        senderType: 'ai',
        content: '其他私聊',
      ),
    });
    await db.permanentMemoryBox.putAll({
      'pm-observer': testPermanentMemory(
        id: 'pm-observer',
        observerCharacterId: characterId,
        subjectIds: [otherCharacterId],
      ),
      'pm-subject': testPermanentMemory(
        id: 'pm-subject',
        observerCharacterId: otherCharacterId,
        subjectIds: [characterId],
      ),
      'pm-unrelated': testPermanentMemory(
        id: 'pm-unrelated',
        observerCharacterId: otherCharacterId,
        subjectIds: ['user'],
      ),
    });
    final sourceEvent = testRelationshipEvent(
      id: 'event-source-c1',
      sourceCharacterId: characterId,
      targetType: RelationshipTargetType.user,
      targetId: 'user',
      revision: 1,
      affinityAfter: 10,
    );
    final targetEvent = testRelationshipEvent(
      id: 'event-target-c1',
      sourceCharacterId: otherCharacterId,
      targetType: RelationshipTargetType.ai,
      targetId: characterId,
      revision: 1,
      affinityAfter: 20,
    );
    final unrelatedEvent = testRelationshipEvent(
      id: 'event-unrelated',
      sourceCharacterId: otherCharacterId,
      targetType: RelationshipTargetType.user,
      targetId: 'user',
      revision: 1,
      affinityAfter: 30,
    );
    await db.relationshipEventBox.putAll({
      sourceEvent.id: sourceEvent,
      targetEvent.id: targetEvent,
      unrelatedEvent.id: unrelatedEvent,
    });
    final sourceRelationId = RelationshipState.stableGlobalId(
      characterId,
      RelationshipTargetType.user,
      'user',
    );
    final targetRelationId = RelationshipState.stableGlobalId(
      otherCharacterId,
      RelationshipTargetType.ai,
      characterId,
    );
    final unrelatedRelationId = RelationshipState.stableGlobalId(
      otherCharacterId,
      RelationshipTargetType.user,
      'user',
    );
    await db.relationshipStateBox.putAll({
      sourceRelationId: RelationshipState.global(
        id: sourceRelationId,
        sourceCharacterId: characterId,
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        affinity: 10,
      ),
      targetRelationId: RelationshipState.global(
        id: targetRelationId,
        sourceCharacterId: otherCharacterId,
        targetType: RelationshipTargetType.ai,
        targetId: characterId,
        affinity: 20,
      ),
      unrelatedRelationId: RelationshipState.global(
        id: unrelatedRelationId,
        sourceCharacterId: otherCharacterId,
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        affinity: 30,
      ),
    });
    await db.appSettingsBox.putAll({
      'direct_chat_read_at': {conversationId: 'read'},
      'direct_chat_source': {conversationId: 'direct'},
      'direct_chat_last_proactive_at': {characterId: 'proactive'},
      'pinned_character_ids': [characterId, otherCharacterId],
      'memory_pinned_keys_v1': [
        'relationship:$sourceRelationId',
        'relationship:$targetRelationId',
        'relationship:$unrelatedRelationId',
      ],
    });

    final plan = await service.previewCharacter(
      characterId,
      policy: CharacterDeletionPolicy.deleteRelatedData,
    );
    expect(plan.count('observerPermanentMemories'), 1);
    expect(plan.count('subjectPermanentMemories'), 1);
    expect(plan.count('sourceRelationshipStates'), 1);
    expect(plan.count('targetRelationshipStates'), 1);
    expect(plan.count('sourceRelationshipEvents'), 1);
    expect(plan.count('targetRelationshipEvents'), 1);

    expect(
      (await service.deleteCharacter(
        characterId,
        policy: CharacterDeletionPolicy.deleteRelatedData,
      ))
          .isComplete,
      isTrue,
    );
    expect(db.aiCharacterBox.containsKey(characterId), isFalse);
    expect(db.chatGroupBox.get('g1')!.aiCharacterIds, [otherCharacterId]);
    expect(db.messageBox.get('group')!.mentionedAiIds, [otherCharacterId]);
    expect(db.messageBox.containsKey('dm-c1'), isFalse);
    expect(db.messageBox.containsKey('dm-c2'), isTrue);
    expect(db.permanentMemoryBox.containsKey('pm-observer'), isFalse);
    expect(db.permanentMemoryBox.containsKey('pm-subject'), isFalse);
    expect(db.permanentMemoryBox.containsKey('pm-unrelated'), isTrue);
    expect(db.relationshipEventBox.containsKey(sourceEvent.id), isFalse);
    expect(db.relationshipEventBox.containsKey(targetEvent.id), isFalse);
    expect(db.relationshipEventBox.containsKey(unrelatedEvent.id), isTrue);
    expect(db.relationshipStateBox.containsKey(sourceRelationId), isFalse);
    expect(db.relationshipStateBox.containsKey(targetRelationId), isFalse);
    expect(db.relationshipStateBox.containsKey(unrelatedRelationId), isTrue);
    expect(db.appSettingsBox.get('pinned_character_ids'), [otherCharacterId]);
    expect(db.appSettingsBox.get('memory_pinned_keys_v1'), [
      'relationship:$unrelatedRelationId',
    ]);
    expect(service.deletedCharacter(characterId), isNull);
  });

  test('pending retry keeps app settings created after planning', () async {
    await db.chatGroupBox.put(
      'g1',
      ChatGroup(id: 'g1', name: '旧群', theme: '', aiCharacterIds: const []),
    );
    await db.appSettingsBox.putAll({
      'message_ids_by_group': {
        'g1': ['old-message'],
      },
      'group_chat_read_at': {'g1': 'old-read'},
      'pinned_group_ids': ['g1'],
      'work_mode_enabled:g1': true,
      'memory_pinned_keys_v1': ['group:g1:old'],
      'memory_retry_queue_v1': [
        {
          'messageId': 'old-message',
          'observerId': 'c1',
          'conversationId': 'g1',
        },
      ],
      'retry:old-message:c1': true,
    });

    final plan = await service.previewGroup('g1');
    await db.appSettingsBox.put(
      DataLifecycleService.pendingOperationKey,
      {
        'kind': 'group',
        'id': 'g1',
        'deleteAssociatedPermanentData': false,
        'targets': plan.targets.toMap(),
      },
    );

    await db.appSettingsBox.put('message_ids_by_group', {
      'g1': ['old-message'],
      'g2': ['new-message'],
    });
    await db.appSettingsBox.put('group_chat_read_at', {
      'g1': 'old-read',
      'g2': 'new-read',
    });
    await db.appSettingsBox.put('pinned_group_ids', ['g1', 'g2']);
    await db.appSettingsBox.put('work_mode_enabled:g2', true);
    await db.appSettingsBox.put('memory_pinned_keys_v1', [
      'group:g1:old',
      'group:g2:new',
    ]);
    await db.appSettingsBox.put('memory_retry_queue_v1', [
      {
        'messageId': 'old-message',
        'observerId': 'c1',
        'conversationId': 'g1',
      },
      {
        'messageId': 'new-message',
        'observerId': 'c2',
        'conversationId': 'g2',
      },
    ]);
    await db.appSettingsBox.putAll({
      'retry:old-message:c1': true,
      'retry:new-message:c2': true,
    });

    expect((await service.retryPendingOperation()).isComplete, isTrue);
    expect(db.appSettingsBox.get('message_ids_by_group'), {
      'g2': ['new-message'],
    });
    expect(db.appSettingsBox.get('group_chat_read_at'), {
      'g2': 'new-read',
    });
    expect(db.appSettingsBox.get('pinned_group_ids'), ['g2']);
    expect(db.appSettingsBox.get('work_mode_enabled:g2'), isTrue);
    expect(db.appSettingsBox.get('memory_pinned_keys_v1'), ['group:g2:new']);
    expect(db.appSettingsBox.get('memory_retry_queue_v1'), [
      {
        'messageId': 'new-message',
        'observerId': 'c2',
        'conversationId': 'g2',
      },
    ]);
    expect(db.appSettingsBox.containsKey('retry:old-message:c1'), isFalse);
    expect(db.appSettingsBox.containsKey('retry:new-message:c2'), isTrue);
    expect(service.hasPendingOperation, isFalse);
  });

  test('message deletion retry retains media paths after the message is gone',
      () async {
    const groupId = 'media-retry-group';
    final attachment = File('${mediaDirectory.path}/retry.txt');
    await attachment.writeAsString('retry me');
    await db.chatGroupBox.put(
      groupId,
      ChatGroup(id: groupId, name: '媒体重试', theme: '', aiCharacterIds: const []),
    );
    await db.messageBox.put(
      'media-retry-message',
      Message(
        id: 'media-retry-message',
        groupId: groupId,
        senderId: 'user',
        senderType: 'user',
        content: '带附件',
        media: [MediaAttachment(type: 'file', localPath: attachment.path)],
      ),
    );

    var cleanupCalls = 0;
    final observedPaths = <List<String>>[];
    service = DataLifecycleService(
      db: db,
      managedMediaDirectory: mediaDirectory,
      credentials: testCredentials(credentialStore),
      clearExternalSettings: () async {},
      cleanupMediaPathsOverride: (paths) async {
        cleanupCalls++;
        final values = paths.toList(growable: false);
        observedPaths.add(values);
        if (cleanupCalls == 1) {
          return const DataLifecycleResult(incompleteItems: ['附件回收失败']);
        }
        for (final path in values) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
        return const DataLifecycleResult(reclaimedFiles: 1);
      },
    );

    final first = await service.deleteMessage(
      'media-retry-message',
      groupId: groupId,
    );
    expect(first.isComplete, isFalse);
    expect(service.hasPendingOperation, isTrue);
    expect(await attachment.exists(), isTrue);

    final retry = await service.retryPendingOperation();
    expect(retry.isComplete, isTrue);
    expect(service.hasPendingOperation, isFalse);
    expect(observedPaths, hasLength(2));
    expect(observedPaths.first, [attachment.path]);
    expect(observedPaths.last, [attachment.path]);
    expect(await attachment.exists(), isFalse);
  });

  test('API config supports replacement, unlink, credential deletion and retry',
      () async {
    final old = ApiConfig(
      id: 'old',
      name: 'old',
      provider: 'deepseek',
      modelName: 'old-model',
      hasCredential: true,
    );
    final replacement = ApiConfig(
      id: 'new',
      name: 'new',
      provider: 'custom',
      modelName: 'new-model',
      customBaseUrl: 'https://example.test',
      hasCredential: true,
    );
    await db.apiConfigBox.putAll({'old': old, 'new': replacement});
    await db.aiCharacterBox.put('c1', testCharacter('c1', apiConfigId: 'old'));
    credentialStore.values[service.credentials.credentialIdFor('old')] = 'key';

    expect((await service.previewApiConfig('old')).count('characters'), 1);
    expect(
        (await service.deleteApiConfig('old', replacementConfigId: 'new'))
            .isComplete,
        isTrue);
    final character = db.aiCharacterBox.get('c1')!;
    expect(character.apiConfigId, 'new');
    expect(character.apiProvider, 'custom');
    expect(character.modelName, 'new-model');
    expect(character.customBaseUrl, 'https://example.test');
    expect(credentialStore.values, isEmpty);

    credentialStore.values[service.credentials.credentialIdFor('new')] = 'key';
    credentialStore.failNextDelete = true;
    final partial = await service.deleteApiConfig('new');
    expect(partial.isComplete, isFalse);
    expect(service.hasPendingOperation, isTrue);
    expect(db.apiConfigBox.containsKey('new'), isTrue);
    expect(character.apiConfigId, 'new');
    expect(character.apiProvider, 'custom');
    expect(character.modelName, 'new-model');
    expect(character.customBaseUrl, 'https://example.test');
    await db.aiCharacterBox.put('c2', testCharacter('c2', apiConfigId: 'new'));
    final conflict = await service.deleteGroup('unrelated');
    expect(conflict.incompleteItems, ['请先在设置中重试未完成删除']);

    final retried = await service.retryPendingOperation();
    expect(retried.isComplete, isTrue);
    expect(service.hasPendingOperation, isFalse);
    expect(credentialStore.values, isEmpty);
    expect(db.apiConfigBox.containsKey('new'), isFalse);
    expect(character.apiConfigId, isEmpty);
    expect(db.aiCharacterBox.get('c2')!.apiConfigId, 'new');
  });

  test('API config deletion retains unknown credential bindings', () async {
    final config = ApiConfig(
      id: 'unknown-binding',
      name: 'Unknown binding',
      provider: 'deepseek',
      hasCredential: true,
      credentialId: 'credential.unmanaged.unknown-binding',
    );
    await db.apiConfigBox.put(config.id, config);
    credentialStore.values[config.credentialId] = 'unmanaged-secret';

    final result = await service.deleteApiConfig(config.id);

    expect(result.isComplete, isFalse);
    expect(result.incompleteItems, contains('API 凭据删除失败'));
    expect(db.apiConfigBox.containsKey(config.id), isTrue);
    expect(credentialStore.values[config.credentialId], 'unmanaged-secret');
    expect(service.hasPendingOperation, isTrue);
  });
}
