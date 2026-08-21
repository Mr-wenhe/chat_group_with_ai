import 'dart:io';

import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/features/chat_group/chat_room_loader.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory hiveDirectory;
  late Directory mediaDirectory;
  late DatabaseService db;
  late MemoryCredentialStore credentialStore;
  late DataLifecycleService service;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    mediaDirectory = Directory('${hiveDirectory.path}/media');
    await mediaDirectory.create();
    db = DatabaseService();
    credentialStore = MemoryCredentialStore();
    service = DataLifecycleService(
      db: db,
      managedMediaDirectory: mediaDirectory,
      credentials: testCredentials(credentialStore),
      clearExternalSettings: () async {},
    );
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

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

  test('clear scopes preserve only their documented preference set', () async {
    final attachment = File('${mediaDirectory.path}/chat.txt');
    await attachment.writeAsString('chat');
    final character = testCharacter('c1')..memorySummary = 'remember';
    final config = ApiConfig(
      id: 'a1',
      name: 'api',
      provider: 'deepseek',
      hasCredential: true,
    );
    await db.aiCharacterBox.put('c1', character);
    await db.apiConfigBox.put('a1', config);
    credentialStore.values[service.credentials.credentialIdFor('a1')] =
        'secret';
    await db.chatGroupBox.put(
      'g1',
      ChatGroup(id: 'g1', name: 'group', theme: '', aiCharacterIds: ['c1']),
    );
    await db.characterSkillBox.put(
      's1',
      CharacterSkill(
        id: 's1',
        characterId: 'c1',
        name: 'skill',
        domain: 'test',
        description: '',
        instructions: const [],
        requiredPermissions: const [],
      ),
    );
    await db.userProfileBox.put(
      'me',
      UserProfile(
        displayName: '用户',
        preferredAddress: '你',
        avatar: '我',
        bio: 'profile',
      ),
    );
    await db.permanentMemoryBox.put(
      'pm-g1',
      testPermanentMemory(id: 'pm-g1', originConversationId: 'g1'),
    );
    final globalId = RelationshipState.stableGlobalId(
      'c1',
      RelationshipTargetType.user,
      'user',
    );
    await db.relationshipEventBox.put(
      'event-g1',
      testRelationshipEvent(
        id: 'event-g1',
        sourceCharacterId: 'c1',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        originConversationId: 'g1',
        revision: 1,
        affinityAfter: 3,
      ),
    );
    await db.relationshipStateBox.putAll({
      'legacy-g1': RelationshipState(
        id: 'legacy-g1',
        groupId: 'g1',
        sourceCharacterId: 'c1',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
      ),
      globalId: RelationshipState.global(
        id: globalId,
        sourceCharacterId: 'c1',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        affinity: 3,
        revision: 1,
        lastEventId: 'event-g1',
      ),
    });
    await db.messageBox.put(
      'm1',
      Message(
        id: 'm1',
        groupId: 'g1',
        senderId: 'c1',
        senderType: 'ai',
        content: 'chat',
        media: [MediaAttachment(type: 'file', localPath: attachment.path)],
      ),
    );
    await db.appSettingsBox.putAll({
      'theme_mode': 'light',
      DatabaseService.appSkinModeKey: 'golden',
      'tts_enabled': false,
      'ai_processing_dir': '/user/workspace',
      'pinned_group_ids': ['g1'],
      'work_mode_enabled:g1': true,
      'message_ids_by_group': {
        'g1': ['m1']
      },
    });

    expect(
        (await service.clear(DataClearScope.chatContent)).isComplete, isTrue);
    expect(db.messageBox.isEmpty, isTrue);
    expect(db.aiCharacterBox.get('c1')!.memorySummary, isEmpty);
    expect(db.aiCharacterBox.length, 1);
    expect(db.chatGroupBox.length, 1);
    expect(db.apiConfigBox.length, 1);
    expect(db.characterSkillBox.length, 1);
    expect(db.permanentMemoryBox.containsKey('pm-g1'), isTrue);
    expect(db.relationshipEventBox.containsKey('event-g1'), isTrue);
    expect(db.relationshipStateBox.containsKey(globalId), isTrue);
    expect(db.relationshipStateBox.containsKey('legacy-g1'), isFalse);
    expect(db.userProfileBox.containsKey('me'), isTrue);
    expect(credentialStore.values, isNotEmpty);
    expect(db.appSettingsBox.get('theme_mode'), 'light');
    expect(db.appSettingsBox.get('tts_enabled'), isFalse);
    expect(db.appSettingsBox.get('pinned_group_ids'), ['g1']);
    expect(db.appSettingsBox.containsKey('work_mode_enabled:g1'), isFalse);
    expect(await attachment.exists(), isFalse);

    expect(
        (await service.clear(DataClearScope.userContent)).isComplete, isTrue);
    expect(db.aiCharacterBox.isEmpty, isTrue);
    expect(db.chatGroupBox.isEmpty, isTrue);
    expect(db.apiConfigBox.isEmpty, isTrue);
    expect(db.characterSkillBox.isEmpty, isTrue);
    expect(db.permanentMemoryBox.isEmpty, isTrue);
    expect(db.relationshipEventBox.isEmpty, isTrue);
    expect(db.relationshipStateBox.isEmpty, isTrue);
    expect(db.userProfileBox.isEmpty, isTrue);
    expect(credentialStore.values, isEmpty);
    expect(db.appSettingsBox.get('theme_mode'), 'light');
    expect(db.appSettingsBox.get('tts_enabled'), isFalse);
    expect(db.appSettingsBox.get('ai_processing_dir'), '/user/workspace');
    expect(db.appSettingsBox.containsKey('pinned_group_ids'), isFalse);

    await Hive.close();
    await reopenLifecycleHive(hiveDirectory);
    expect(db.aiCharacterBox.isEmpty, isTrue);
    expect(db.chatGroupBox.isEmpty, isTrue);
    expect(db.messageBox.isEmpty, isTrue);
    expect(db.permanentMemoryBox.isEmpty, isTrue);
    expect(db.relationshipEventBox.isEmpty, isTrue);
    expect(db.relationshipStateBox.isEmpty, isTrue);
    expect(db.userProfileBox.isEmpty, isTrue);

    expect(
        (await service.clear(DataClearScope.factoryReset)).isComplete, isTrue);
    expect(db.appSettingsBox.isEmpty, isTrue);
    expect(
        (await service.clear(DataClearScope.factoryReset)).isComplete, isTrue);
  });
}

DateTime testLifecycleDate(int second) =>
    DateTime.utc(2026, 8, 1, 0, 0, second);

PermanentMemory testPermanentMemory({
  required String id,
  String observerCharacterId = 'observer',
  MemoryKind kind = MemoryKind.fact,
  String content = 'memory',
  List<String> subjectIds = const [],
  MemoryStatus status = MemoryStatus.active,
  MemoryOriginType originType = MemoryOriginType.group,
  String? originConversationId,
  String originNameSnapshot = '',
  List<String> sourceMessageIds = const [],
}) {
  final timestamp = testLifecycleDate(id.hashCode.abs() % 50);
  return PermanentMemory(
    id: id,
    observerCharacterId: observerCharacterId,
    kind: kind,
    content: content,
    subjectIds: subjectIds,
    status: status,
    originType: originType,
    originConversationId: originConversationId,
    originNameSnapshot: originNameSnapshot,
    sourceMessageIds: sourceMessageIds,
    occurredAt: timestamp,
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}

RelationshipEvent testRelationshipEvent({
  required String id,
  String sourceCharacterId = 'source',
  RelationshipTargetType targetType = RelationshipTargetType.user,
  String targetId = 'user',
  String reason = 'test',
  int affinityBefore = 0,
  required int affinityAfter,
  int trustBefore = 0,
  int trustAfter = 0,
  int frictionBefore = 0,
  int frictionAfter = 0,
  int familiarityBefore = 0,
  int familiarityAfter = 0,
  RelationshipMood moodBefore = RelationshipMood.neutral,
  RelationshipMood moodAfter = RelationshipMood.neutral,
  RelationshipStage stageBefore = RelationshipStage.stranger,
  RelationshipStage stageAfter = RelationshipStage.acquaintance,
  String? originConversationId,
  String originNameSnapshot = '',
  List<String> sourceMessageIds = const [],
  required int revision,
  RelationshipEventCreator createdBy = RelationshipEventCreator.automatic,
  String notesBefore = '',
  String notesAfter = '',
}) {
  final timestamp = testLifecycleDate(revision);
  return RelationshipEvent(
    id: id,
    sourceCharacterId: sourceCharacterId,
    targetType: targetType,
    targetId: targetId,
    reason: reason,
    affinityBefore: affinityBefore,
    affinityAfter: affinityAfter,
    trustBefore: trustBefore,
    trustAfter: trustAfter,
    frictionBefore: frictionBefore,
    frictionAfter: frictionAfter,
    familiarityBefore: familiarityBefore,
    familiarityAfter: familiarityAfter,
    moodBefore: moodBefore,
    moodAfter: moodAfter,
    stageBefore: stageBefore,
    stageAfter: stageAfter,
    originConversationId: originConversationId,
    originNameSnapshot: originNameSnapshot,
    sourceMessageIds: sourceMessageIds,
    revision: revision,
    occurredAt: timestamp,
    createdBy: createdBy,
    createdAt: timestamp,
    notesBefore: notesBefore,
    notesAfter: notesAfter,
  );
}
