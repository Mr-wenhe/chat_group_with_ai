part of 'data_lifecycle_service_test.dart';

/// 批量删除与「清空聊天记录」都只动消息本身。
///
/// 用户要的是把气泡清干净，不是顺手把角色的记忆、心情和工作任务一起抹掉：
/// 两者都必须保留场合记忆、关系、任务与工作区，否则"清空聊天记录"会变成
/// 一次用户没同意的记忆清除。
void _registerDataLifecycleServiceTestPart6() {
  Message messageOf(String id, String groupId, {String? replyTo}) => Message(
        id: id,
        groupId: groupId,
        senderId: 'user',
        senderType: 'user',
        content: id,
        replyToMessageId: replyTo,
      );

  Future<void> seedGroup(String groupId, {String characterId = 'c1'}) async {
    await db.aiCharacterBox.put(characterId, testCharacter(characterId));
    await db.chatGroupBox.put(
      groupId,
      ChatGroup(
        id: groupId,
        name: '群 $groupId',
        theme: '',
        aiCharacterIds: [characterId],
      ),
    );
  }

  test('批量删除只移除选中的消息，群记忆与其余消息都保留', () async {
    const groupId = 'batch-delete-group';
    await seedGroup(groupId);
    await db.messageBox.putAll({
      'batch-1': messageOf('batch-1', groupId),
      'batch-2': messageOf('batch-2', groupId),
      'batch-3': messageOf('batch-3', groupId),
    });
    await db.groupMemoryBox.put(
      'batch-memory',
      GroupMemory(groupId: groupId, topicSummary: '删除前生成的摘要'),
    );

    final result = await service.deleteMessages(
      ['batch-1', 'batch-2'],
      groupId: groupId,
    );

    expect(result.isComplete, isTrue);
    expect(db.messageBox.get('batch-1'), isNull);
    expect(db.messageBox.get('batch-2'), isNull);
    expect(db.messageBox.get('batch-3'), isNotNull);
    expect(
      db.groupMemoryBox.get('batch-memory'),
      isNotNull,
      reason: '删几条气泡不该让整个群的记忆一起失效',
    );
  });

  test('批量删除忽略不属于本会话的消息 id', () async {
    await seedGroup('batch-scope-a');
    await seedGroup('batch-scope-b');
    await db.messageBox.putAll({
      'scope-a-message': messageOf('scope-a-message', 'batch-scope-a'),
      'scope-b-message': messageOf('scope-b-message', 'batch-scope-b'),
    });

    final result = await service.deleteMessages(
      ['scope-a-message', 'scope-b-message'],
      groupId: 'batch-scope-a',
    );

    expect(result.isComplete, isTrue);
    expect(db.messageBox.get('scope-a-message'), isNull);
    expect(
      db.messageBox.get('scope-b-message'),
      isNotNull,
      reason: '传入的 id 属于别的会话时必须被过滤掉，不能跟着一起删',
    );
  });

  test('批量删除保留引用指针并重建会话消息索引', () async {
    const groupId = 'batch-index-group';
    await seedGroup(groupId);
    await db.messageBox.putAll({
      'index-quoted': messageOf('index-quoted', groupId),
      'index-quoting': messageOf(
        'index-quoting',
        groupId,
        replyTo: 'index-quoted',
      ),
      'index-kept': messageOf('index-kept', groupId),
    });

    final result = await service.deleteMessages(
      ['index-quoted'],
      groupId: groupId,
    );

    expect(result.isComplete, isTrue);
    expect(
      db.messageBox.get('index-quoting')!.replyToMessageId,
      'index-quoted',
      reason: '引用指针要留着，渲染层据此显示「原消息已删除」',
    );
    final indexed = await db.messageIdsForConversation(groupId);
    expect(indexed, isNot(contains('index-quoted')));
    expect(indexed, contains('index-kept'));
  });

  test('批量删除收到空集合时什么都不删', () async {
    const groupId = 'batch-empty-group';
    await seedGroup(groupId);
    await db.messageBox.put('batch-kept', messageOf('batch-kept', groupId));

    final result = await service.deleteMessages(const [], groupId: groupId);

    expect(result.isComplete, isTrue);
    expect(db.messageBox.get('batch-kept'), isNotNull);
  });

  test('清空聊天记录只删消息，记忆、关系、任务与工作区全部保留', () async {
    const groupId = 'clear-messages-group';
    const characterId = 'c1';
    await seedGroup(groupId, characterId: characterId);
    await db.messageBox.putAll({
      'clear-1': messageOf('clear-1', groupId),
      'clear-2': messageOf('clear-2', groupId),
    });
    await db.groupMemoryBox.put(
      'clear-group-memory',
      GroupMemory(groupId: groupId, topicSummary: '群摘要'),
    );
    await db.characterMemoryBox.put(
      'clear-character-memory',
      CharacterMemory(
        id: 'clear-character-memory',
        groupId: groupId,
        characterId: characterId,
      ),
    );
    await db.relationshipStateBox.put(
      'clear-relationship',
      RelationshipState(
        id: 'clear-relationship',
        groupId: groupId,
        sourceCharacterId: characterId,
        targetId: 'user',
        targetType: RelationshipTargetType.user,
      ),
    );
    await db.agentTaskBox.put(
      'clear-task',
      AgentTask(
        id: 'clear-task',
        groupId: groupId,
        characterId: characterId,
        userRequest: '任务',
      ),
    );
    await db.workModeWorkspaceBox.put(
      'clear-workspace',
      WorkModeWorkspace(
        id: 'clear-workspace',
        conversationId: groupId,
        conversationType: 'group',
      ),
    );
    await db.permanentMemoryBox.put(
      'clear-permanent',
      testPermanentMemory(id: 'clear-permanent', originConversationId: groupId),
    );

    final result = await service.clearConversationMessages(groupId);

    expect(result.isComplete, isTrue);
    expect(
      db.messageBox.values.where((message) => message.groupId == groupId),
      isEmpty,
    );
    expect(db.groupMemoryBox.get('clear-group-memory'), isNotNull);
    expect(db.characterMemoryBox.get('clear-character-memory'), isNotNull);
    expect(db.relationshipStateBox.get('clear-relationship'), isNotNull);
    expect(
      db.agentTaskBox.get('clear-task'),
      isNotNull,
      reason: '任务面板还挂着这条任务，清空聊天记录不能把它一起删掉',
    );
    expect(db.workModeWorkspaceBox.get('clear-workspace'), isNotNull);
    expect(db.permanentMemoryBox.get('clear-permanent'), isNotNull);
  });

  test('清空聊天记录不碰其它会话的消息与设置', () async {
    await seedGroup('clear-scope-a');
    await seedGroup('clear-scope-b');
    await db.messageBox.putAll({
      'clear-a': messageOf('clear-a', 'clear-scope-a'),
      'clear-b': messageOf('clear-b', 'clear-scope-b'),
    });
    await db.appSettingsBox.put('group_chat_read_at', {
      'clear-scope-a': '2026-07-01',
      'clear-scope-b': '2026-07-02',
    });

    await service.clearConversationMessages('clear-scope-a');

    expect(db.messageBox.get('clear-a'), isNull);
    expect(db.messageBox.get('clear-b'), isNotNull);
    final readAt = db.appSettingsBox.get('group_chat_read_at') as Map;
    expect(
      readAt.containsKey('clear-scope-a'),
      isFalse,
      reason: '消息都没了，已读位置留着只会在收件箱里算出错误的未读',
    );
    expect(readAt['clear-scope-b'], '2026-07-02');
  });

  test('清空聊天记录清掉指向已删消息的重试记录', () async {
    const groupId = 'clear-retry-group';
    await seedGroup(groupId);
    await db.messageBox.put(
      'clear-retry-message',
      messageOf('clear-retry-message', groupId),
    );
    final queue = ObservationRetryQueue(db);
    await queue.enqueue(
      messageId: 'clear-retry-message',
      observerId: 'c1',
      conversationId: groupId,
      conversationNameSnapshot: '群',
    );

    await service.clearConversationMessages(groupId);

    expect(
      queue.load(),
      isEmpty,
      reason: '消息已经不在了，留着这条重试记录只会在下一轮空转',
    );
    expect(
      db.appSettingsBox.get('retry:clear-retry-message:c1'),
      isNull,
    );
  });

  test('中断的批量删除按落盘的计划重试，不会卡住后续操作', () async {
    const groupId = 'batch-retry-group';
    await seedGroup(groupId);
    await db.messageBox.putAll({
      'retry-1': messageOf('retry-1', groupId),
      'retry-2': messageOf('retry-2', groupId),
    });
    // 模拟"计划已落盘、执行前被打断"：缺了这个 kind 的分支，这条待办既重试
    // 不了又会让此后所有生命周期操作都被 _begin 挡下。
    await db.appSettingsBox.put(
      DataLifecycleService.pendingOperationKey,
      {
        'kind': 'messages',
        'groupId': groupId,
        'targets': const DeletionTargets(
          boxKeys: {
            DeletionTargetNames.messages: ['retry-1', 'retry-2'],
          },
        ).toMap(),
      },
    );

    final result = await service.retryPendingOperation();

    expect(result.isComplete, isTrue);
    expect(db.messageBox.get('retry-1'), isNull);
    expect(db.messageBox.get('retry-2'), isNull);
    expect(service.hasPendingOperation, isFalse);
  });

  test('中断的清空聊天记录按落盘的计划重试，消息与设置一起清完', () async {
    const groupId = 'clear-retry-resume-group';
    await seedGroup(groupId);
    await db.messageBox.put('resume-message', messageOf('resume-message', groupId));
    await db.appSettingsBox.put('group_chat_read_at', {
      groupId: '2026-07-01',
      'other-conversation': '2026-07-02',
    });
    await db.appSettingsBox.put(
      DataLifecycleService.pendingOperationKey,
      {
        'kind': 'conversationMessages',
        'id': groupId,
        'targets': const DeletionTargets(
          boxKeys: {
            DeletionTargetNames.messages: ['resume-message'],
          },
          appSettings: AppSettingsDeletionTargets(
            mapEntries: {
              'group_chat_read_at': {groupId: '2026-07-01'},
            },
          ),
        ).toMap(),
      },
    );

    final result = await service.retryPendingOperation();

    expect(result.isComplete, isTrue);
    expect(db.messageBox.get('resume-message'), isNull);
    final readAt = db.appSettingsBox.get('group_chat_read_at') as Map;
    expect(readAt.containsKey(groupId), isFalse);
    expect(readAt['other-conversation'], '2026-07-02');
    expect(service.hasPendingOperation, isFalse);
  });

  test('单条删除也清掉指向它的重试记录', () async {
    const groupId = 'single-retry-record-group';
    await seedGroup(groupId);
    await db.messageBox.putAll({
      'single-record-kept': messageOf('single-record-kept', groupId),
      'single-record-deleted': messageOf('single-record-deleted', groupId),
    });
    final queue = ObservationRetryQueue(db);
    for (final id in const [
      'single-record-kept',
      'single-record-deleted',
    ]) {
      await queue.enqueue(
        messageId: id,
        observerId: 'c1',
        conversationId: groupId,
        conversationNameSnapshot: '群',
      );
    }

    await service.deleteMessage('single-record-deleted', groupId: groupId);

    expect(
      queue.load().map((item) => (item as Map)['messageId']).toList(),
      ['single-record-kept'],
      reason: '消息已经不在了，留着这条记录只会在下一轮空转到被丢弃',
    );
    expect(db.appSettingsBox.get('retry:single-record-deleted:c1'), isNull);
    expect(db.appSettingsBox.get('retry:single-record-kept:c1'), isTrue);
  });

  test('批量删除只清掉被删消息的重试记录', () async {
    const groupId = 'batch-retry-record-group';
    await seedGroup(groupId);
    const ids = ['batch-record-a', 'batch-record-b', 'batch-record-kept'];
    await db.messageBox.putAll({
      for (final id in ids) id: messageOf(id, groupId),
    });
    final queue = ObservationRetryQueue(db);
    for (final id in ids) {
      await queue.enqueue(
        messageId: id,
        observerId: 'c1',
        conversationId: groupId,
        conversationNameSnapshot: '群',
      );
    }

    await service.deleteMessages(const ['batch-record-a', 'batch-record-b'],
        groupId: groupId);

    expect(
      queue.load().map((item) => (item as Map)['messageId']).toList(),
      ['batch-record-kept'],
    );
    expect(db.appSettingsBox.get('retry:batch-record-a:c1'), isNull);
    expect(db.appSettingsBox.get('retry:batch-record-kept:c1'), isTrue);
  });
}
