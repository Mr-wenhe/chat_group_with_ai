part of 'data_lifecycle_service_test.dart';

void _registerDataLifecycleServiceTestPart3() {
  test('group associated deletion is exact and rebuilds global state',
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
        content: '删除来源',
      ),
      'm2': Message(
        id: 'm2',
        groupId: 'g2',
        senderId: 'user',
        senderType: 'user',
        content: '保留来源',
      ),
    });
    await db.permanentMemoryBox.putAll({
      'pm-g1': testPermanentMemory(
        id: 'pm-g1',
        originConversationId: 'g1',
      ),
      'pm-g2': testPermanentMemory(
        id: 'pm-g2',
        originConversationId: 'g2',
      ),
      'pm-unknown': testPermanentMemory(
        id: 'pm-unknown',
        originConversationId: null,
        originType: MemoryOriginType.manual,
      ),
    });
    final keepEvent = testRelationshipEvent(
      id: 'event-keep',
      originConversationId: 'g2',
      revision: 1,
      affinityAfter: 11,
      createdBy: RelationshipEventCreator.manual,
      notesBefore: '',
      notesAfter: '保留备注',
    );
    final deleteEvent = testRelationshipEvent(
      id: 'event-delete',
      originConversationId: 'g1',
      revision: 2,
      affinityAfter: 22,
    );
    await db.relationshipEventBox.putAll({
      keepEvent.id: keepEvent,
      deleteEvent.id: deleteEvent,
    });
    final globalId = RelationshipState.stableGlobalId(
      'source',
      RelationshipTargetType.user,
      'user',
    );
    await db.relationshipStateBox.put(
      globalId,
      RelationshipState.global(
        id: globalId,
        sourceCharacterId: 'source',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        affinity: 22,
        notes: '保留备注',
        revision: 2,
        lastEventId: deleteEvent.id,
      ),
    );
    await db.appSettingsBox.put('memory_pinned_keys_v1', [
      'relationship:$globalId',
    ]);

    final plan = await service.previewGroup('g1');
    expect(plan.optionalCount('permanentMemories'), 1);
    expect(plan.optionalCount('relationshipEvents'), 1);

    expect(
      (await service.deleteGroup(
        'g1',
        deleteAssociatedPermanentData: true,
      ))
          .isComplete,
      isTrue,
    );
    expect(db.permanentMemoryBox.containsKey('pm-g1'), isFalse);
    expect(db.permanentMemoryBox.containsKey('pm-g2'), isTrue);
    expect(db.permanentMemoryBox.containsKey('pm-unknown'), isTrue);
    expect(db.relationshipEventBox.containsKey(deleteEvent.id), isFalse);
    expect(db.relationshipEventBox.containsKey(keepEvent.id), isTrue);
    final rebuilt = db.relationshipStateBox.get(globalId)!;
    expect(rebuilt.groupId, 'global');
    expect(rebuilt.affinity, 11);
    expect(rebuilt.revision, 1);
    expect(rebuilt.lastEventId, keepEvent.id);
    expect(rebuilt.notes, '保留备注');
    expect(db.appSettingsBox.get('memory_pinned_keys_v1'), [
      'relationship:$globalId',
    ]);
    expect(
      (await service.deleteGroup(
        'g1',
        deleteAssociatedPermanentData: true,
      ))
          .isComplete,
      isTrue,
    );
    expect(db.relationshipStateBox.get(globalId)!.lastEventId, keepEvent.id);
  });

  test('deleting the latest manual note event restores the previous note',
      () async {
    await db.chatGroupBox.putAll({
      'g1': ChatGroup(id: 'g1', name: '删除群', theme: '', aiCharacterIds: []),
      'g2': ChatGroup(id: 'g2', name: '保留群', theme: '', aiCharacterIds: []),
    });
    final globalId = RelationshipState.stableGlobalId(
      'source',
      RelationshipTargetType.user,
      'user',
    );
    final previousEvent = testRelationshipEvent(
      id: 'event-previous-note',
      originConversationId: 'g2',
      revision: 1,
      createdBy: RelationshipEventCreator.manual,
      affinityAfter: 1,
      notesBefore: '初始备注',
      notesAfter: '旧备注',
    );
    final latestEvent = testRelationshipEvent(
      id: 'event-latest-note',
      originConversationId: 'g1',
      revision: 2,
      createdBy: RelationshipEventCreator.manual,
      affinityAfter: 2,
      notesBefore: '旧备注',
      notesAfter: '已删除备注',
    );
    final followingAutomaticEvent = testRelationshipEvent(
      id: 'event-following-automatic',
      originConversationId: 'g2',
      revision: 3,
      createdBy: RelationshipEventCreator.automatic,
      affinityAfter: 3,
      notesBefore: '已删除备注',
      notesAfter: '已删除备注',
    );
    await db.relationshipEventBox.putAll({
      previousEvent.id: previousEvent,
      latestEvent.id: latestEvent,
      followingAutomaticEvent.id: followingAutomaticEvent,
    });
    await db.relationshipStateBox.put(
      globalId,
      RelationshipState.global(
        id: globalId,
        sourceCharacterId: 'source',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        revision: followingAutomaticEvent.revision,
        lastEventId: followingAutomaticEvent.id,
        notes: latestEvent.notesAfter,
      ),
    );

    final result = await service.deleteGroup(
      'g1',
      deleteAssociatedPermanentData: true,
    );

    expect(result.isComplete, isTrue);
    expect(db.relationshipEventBox.containsKey(latestEvent.id), isFalse);
    expect(db.relationshipEventBox.containsKey(previousEvent.id), isTrue);
    expect(db.relationshipStateBox.get(globalId)!.notes, '旧备注');
  });

  test('conversation clearing matches a complete DM id', () async {
    const conversationId = 'dm:c1';
    const otherConversationId = 'dm:c10';
    await db.messageBox.putAll({
      'dm-c1': Message(
        id: 'dm-c1',
        groupId: conversationId,
        senderId: 'c1',
        senderType: 'ai',
        content: 'c1 私聊',
      ),
      'dm-c10': Message(
        id: 'dm-c10',
        groupId: otherConversationId,
        senderId: 'c10',
        senderType: 'ai',
        content: 'c10 私聊',
      ),
    });
    await db.permanentMemoryBox.putAll({
      'pm-c1': testPermanentMemory(
        id: 'pm-c1',
        originConversationId: conversationId,
        originType: MemoryOriginType.direct,
      ),
      'pm-c10': testPermanentMemory(
        id: 'pm-c10',
        originConversationId: otherConversationId,
        originType: MemoryOriginType.direct,
      ),
    });
    final clearEvent = testRelationshipEvent(
      id: 'event-c1',
      originConversationId: conversationId,
      revision: 1,
      affinityAfter: 5,
    );
    final otherEvent = testRelationshipEvent(
      id: 'event-c10',
      originConversationId: otherConversationId,
      revision: 2,
      affinityAfter: 8,
    );
    await db.relationshipEventBox.putAll({
      clearEvent.id: clearEvent,
      otherEvent.id: otherEvent,
    });
    final globalId = RelationshipState.stableGlobalId(
      'source',
      RelationshipTargetType.user,
      'user',
    );
    await db.relationshipStateBox.putAll({
      'legacy-dm': RelationshipState(
        id: 'legacy-dm',
        groupId: conversationId,
        sourceCharacterId: 'source',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
      ),
      globalId: RelationshipState.global(
        id: globalId,
        sourceCharacterId: 'source',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        affinity: 8,
        revision: 2,
        lastEventId: otherEvent.id,
      ),
    });
    await db.appSettingsBox.putAll({
      'message_ids_by_group': {
        conversationId: ['dm-c1'],
        otherConversationId: ['dm-c10'],
      },
      'conversation_summaries': {
        conversationId: {'preview': 'c1'},
        otherConversationId: {'preview': 'c10'},
      },
      'direct_chat_read_at': {
        conversationId: 'read-c1',
        otherConversationId: 'read-c10',
      },
      'direct_chat_source': {
        conversationId: 'direct',
        otherConversationId: 'proactive',
      },
      'direct_chat_last_proactive_at': {
        'c1': 'p1',
        'c10': 'p10',
      },
      'pinned_character_ids': ['c1', 'c10'],
      'memory_pinned_keys_v1': ['relationship:$globalId'],
      'memory_retry_queue_v1': [
        {
          'messageId': 'dm-c1',
          'observerId': 'c1',
          'conversationId': conversationId,
        },
        {
          'messageId': 'dm-c10',
          'observerId': 'c10',
          'conversationId': otherConversationId,
        },
      ],
      'retry:dm-c1:c1': true,
      'retry:dm-c10:c10': true,
    });

    final plan = await service.previewConversation(conversationId);
    expect(plan.count('messages'), 1);
    expect(plan.optionalCount('permanentMemories'), 1);
    expect(plan.optionalCount('relationshipEvents'), 1);

    expect(
        (await service.clearConversation(conversationId)).isComplete, isTrue);
    expect(db.messageBox.containsKey('dm-c1'), isFalse);
    expect(db.messageBox.containsKey('dm-c10'), isTrue);
    expect(db.permanentMemoryBox.containsKey('pm-c1'), isTrue);
    expect(db.relationshipEventBox.containsKey(clearEvent.id), isTrue);
    expect(db.relationshipStateBox.containsKey('legacy-dm'), isFalse);
    expect(db.appSettingsBox.get('direct_chat_read_at'), {
      otherConversationId: 'read-c10',
    });
    expect(db.appSettingsBox.get('direct_chat_last_proactive_at'), {
      'c10': 'p10',
    });
    expect(db.appSettingsBox.get('pinned_character_ids'), ['c10']);
    expect(db.appSettingsBox.get('memory_retry_queue_v1'), [
      {
        'messageId': 'dm-c10',
        'observerId': 'c10',
        'conversationId': otherConversationId,
      },
    ]);
    expect(db.appSettingsBox.containsKey('retry:dm-c1:c1'), isFalse);
    expect(db.appSettingsBox.containsKey('retry:dm-c10:c10'), isTrue);

    expect(
      (await service.clearConversation(
        conversationId,
        deleteAssociatedPermanentData: true,
      ))
          .isComplete,
      isTrue,
    );
    expect(db.permanentMemoryBox.containsKey('pm-c1'), isFalse);
    expect(db.permanentMemoryBox.containsKey('pm-c10'), isTrue);
    expect(db.relationshipEventBox.containsKey(clearEvent.id), isFalse);
    expect(db.relationshipEventBox.containsKey(otherEvent.id), isTrue);
    expect(db.relationshipStateBox.get(globalId)!.affinity, 8);
    expect(db.relationshipStateBox.get(globalId)!.lastEventId, otherEvent.id);
    expect(db.messageBox.containsKey('dm-c10'), isTrue);
  });

  test('conversation deletion rebuild does not resurrect legacy relationship',
      () async {
    const conversationId = 'g-deleted-relationship';
    final globalId = RelationshipState.stableGlobalId(
      'source',
      RelationshipTargetType.user,
      'user',
    );
    final global = RelationshipState.global(
      id: globalId,
      sourceCharacterId: 'source',
      targetType: RelationshipTargetType.user,
      targetId: 'user',
      affinity: 80,
      notes: 'global relation',
    );
    final legacy = RelationshipState(
      id: 'legacy-deleted-relationship',
      groupId: conversationId,
      sourceCharacterId: 'source',
      targetType: RelationshipTargetType.user,
      targetId: 'user',
      affinity: 20,
      notes: 'legacy relation',
    );
    await db.relationshipStateBox.putAll({
      global.id: global,
      legacy.id: legacy,
    });
    await db.relationshipEventBox.put(
      'event-deleted-relationship',
      testRelationshipEvent(
        id: 'event-deleted-relationship',
        sourceCharacterId: 'source',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        originConversationId: conversationId,
        revision: 1,
        affinityAfter: 80,
      ),
    );

    final selector = MemoryContextSelector(db);
    expect(
      await selector.select(
        observerCharacterId: 'source',
        participantCharacterIds: const ['source'],
        currentTargetId: 'user',
      ),
      contains('真人用户'),
    );

    expect(
      (await service.clearConversation(
        conversationId,
        deleteAssociatedPermanentData: true,
      ))
          .isComplete,
      isTrue,
    );

    expect(db.relationshipStateBox.get(globalId), isNull);
    expect(db.relationshipStateBox.get(legacy.id), isNull);
    expect(
      await selector.select(
        observerCharacterId: 'source',
        participantCharacterIds: const ['source'],
        currentTargetId: 'user',
      ),
      isEmpty,
    );
  });
}
