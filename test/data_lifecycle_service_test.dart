import 'dart:io';

import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/features/chat_group/chat_room_loader.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:flutter_test/flutter_test.dart';

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
    await db.aiCharacterBox.put(characterId, testCharacter(characterId));
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
    expect(db.relationshipStateBox.isEmpty, isTrue);
    expect(db.characterSkillBox.isEmpty, isTrue);
    expect(db.agentTaskBox.isEmpty, isTrue);
    expect(db.workModeWorkspaceBox.isEmpty, isTrue);
    expect(db.appSettingsBox.get('memory_pinned_keys_v1'), isEmpty);
    expect(service.deletedCharacter(characterId)!.name, '角色c1');

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
    final conflict = await service.deleteGroup('unrelated');
    expect(conflict.incompleteItems, ['请先在设置中重试未完成删除']);

    final retried = await service.retryPendingOperation();
    expect(retried.isComplete, isTrue);
    expect(service.hasPendingOperation, isFalse);
    expect(credentialStore.values, isEmpty);
    expect(db.apiConfigBox.containsKey('new'), isFalse);
    expect(character.apiConfigId, isEmpty);
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
    expect(db.appSettingsBox.get('theme_mode'), 'light');
    expect(db.appSettingsBox.get('tts_enabled'), isFalse);
    expect(db.appSettingsBox.get('ai_processing_dir'), '/user/workspace');
    expect(db.appSettingsBox.containsKey('pinned_group_ids'), isFalse);

    expect(
        (await service.clear(DataClearScope.factoryReset)).isComplete, isTrue);
    expect(db.appSettingsBox.isEmpty, isTrue);
    expect(
        (await service.clear(DataClearScope.factoryReset)).isComplete, isTrue);
  });
}
