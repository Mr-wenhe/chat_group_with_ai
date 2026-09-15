import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_task_action_message_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _CredentialResolver implements ApiCredentialResolver {
  final String? value;

  const _CredentialResolver(this.value);

  @override
  Future<String?> resolve(ApiConfig config) async => value;
}

class _MapCredentialResolver implements ApiCredentialResolver {
  final Map<String, String?> values;

  const _MapCredentialResolver(this.values);

  @override
  Future<String?> resolve(ApiConfig config) async => values[config.id];
}

class _GateCredentialResolver implements ApiCredentialResolver {
  final Completer<String?> gate = Completer<String?>();
  var calls = 0;

  @override
  Future<String?> resolve(ApiConfig config) {
    calls++;
    return gate.future;
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('chat_group_action_message_');
    Hive.init(tempDir.path);
    _registerAdapters();
    await _openBoxes();
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('persists one role reminder and deduplicates it after restart',
      () async {
    final db = DatabaseService();
    final group = ChatGroup(
      id: 'group-action-message',
      name: '产品群',
      theme: '工作讨论',
      aiCharacterIds: const [],
      ownerName: '小明',
    );
    await db.chatGroupBox.put(group.id, group);
    await db.userProfileBox.put(
      'me',
      UserProfile(
        id: 'me',
        displayName: '小明',
        preferredAddress: '小明',
        avatar: '',
        bio: '',
      ),
    );
    final task = _roleBlockedTask(group.id);
    await db.agentTaskBox.put(task.id, task);
    final service = WorkTaskActionMessageService(
      database: db,
      clock: () => DateTime.utc(2026, 9, 14, 12),
    );

    await service.notify(task);
    await service.notify(task);

    final actionId = 'work-task-action:${task.id}:missingQualifiedRole:';
    expect(db.messageBox.values, hasLength(1));
    expect(db.messageBox.values.single.id, startsWith(actionId));
    expect(db.messageBox.values.single.senderType, 'system');
    expect(db.messageBox.values.single.content, contains('@小明'));
    expect(db.conversationSummaries()[group.id]?.mentionCount, 1);

    // Reopen the same Hive files to model an app restart. The stable message
    // id is the dedupe key, so a new service instance cannot add a second row.
    await Hive.close();
    Hive.init(tempDir.path);
    _registerAdapters();
    await _openBoxes();
    final restartedDb = DatabaseService();
    final restartedTask = restartedDb.agentTaskBox.get(task.id)!;
    await WorkTaskActionMessageService(
      database: restartedDb,
      clock: () => DateTime.utc(2026, 9, 14, 12, 1),
    ).notify(restartedTask);

    expect(restartedDb.messageBox.values, hasLength(1));
    expect(restartedDb.messageBox.values.single.id,
        db.messageBox.values.single.id);
  });

  test('uses a real qualified group member when one is available', () async {
    final db = DatabaseService();
    final config = ApiConfig(
      id: 'config-action-message',
      name: '测试网关',
      provider: 'deepseek',
      apiKey: 'development-key',
      credentialId: CredentialRepository.developmentHiveCredentialId,
      hasCredential: true,
    );
    final character = AICharacter(
      id: 'frontend-action-message',
      name: '前端角色',
      avatar: '前',
      age: 28,
      role: '前端开发',
      personalityTags: const [],
      systemPrompt: '负责前端实现。',
      apiKey: '',
      apiProvider: 'deepseek',
      apiConfigId: config.id,
    );
    final group = ChatGroup(
      id: 'group-qualified-action-message',
      name: '前端群',
      theme: '网页方案',
      aiCharacterIds: [character.id],
    );
    await db.apiConfigBox.put(config.id, config);
    await db.aiCharacterBox.put(character.id, character);
    await db.chatGroupBox.put(group.id, group);
    final task = _roleBlockedTask(group.id);
    await db.agentTaskBox.put(task.id, task);

    await WorkTaskActionMessageService(database: db).notify(task);

    final message = db.messageBox.values.single;
    expect(message.senderType, 'ai');
    expect(message.senderId, character.id);
    expect(message.content, contains('@我'));
  });

  test('resolves a legacy character binding by provider and model', () async {
    final db = DatabaseService();
    final config = ApiConfig(
      id: 'config-legacy-binding',
      name: '旧绑定网关',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-legacy-binding',
    );
    final character = AICharacter(
      id: 'legacy-binding-role',
      name: '旧绑定前端',
      avatar: '旧',
      age: 28,
      role: '前端开发',
      personalityTags: const [],
      systemPrompt: '负责前端实现。',
      apiKey: '',
      apiProvider: 'deepseek',
      modelName: 'deepseek-chat',
      // Old records can lack the explicit apiConfigId field.
      apiConfigId: '',
    );
    final group = ChatGroup(
      id: 'group-legacy-binding',
      name: '旧绑定群',
      theme: '网页方案',
      aiCharacterIds: [character.id],
    );
    await db.apiConfigBox.put(config.id, config);
    await db.aiCharacterBox.put(character.id, character);
    await db.chatGroupBox.put(group.id, group);
    final task = _roleBlockedTask(group.id);
    await db.agentTaskBox.put(task.id, task);

    await WorkTaskActionMessageService(
      database: db,
      credentials: const _CredentialResolver('legacy-binding-key'),
    ).notify(task);

    final message = db.messageBox.values.single;
    expect(message.senderType, 'ai');
    expect(message.senderId, character.id);
  });

  test('does not persist an action after its task checkpoint changes',
      () async {
    final db = DatabaseService();
    final config = ApiConfig(
      id: 'config-stale-action',
      name: '延迟网关',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-stale-action',
    );
    final character = AICharacter(
      id: 'stale-action-role',
      name: '延迟前端',
      avatar: '延',
      age: 28,
      role: '前端开发',
      personalityTags: const [],
      systemPrompt: '负责前端实现。',
      apiKey: '',
      apiProvider: 'deepseek',
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
    );
    final group = ChatGroup(
      id: 'group-stale-action',
      name: '延迟动作群',
      theme: '网页方案',
      aiCharacterIds: [character.id],
    );
    await db.apiConfigBox.put(config.id, config);
    await db.aiCharacterBox.put(character.id, character);
    await db.chatGroupBox.put(group.id, group);
    final task = _roleBlockedTask(group.id)
      ..assignedCharacterIds = [character.id];
    await db.agentTaskBox.put(task.id, task);
    final resolver = _GateCredentialResolver();
    final pending = WorkTaskActionMessageService(
      database: db,
      credentials: resolver,
    ).notify(task);
    for (var attempt = 0; attempt < 100 && resolver.calls == 0; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(resolver.calls, 1);
    task.status = AgentTaskStatus.completed;
    await db.agentTaskBox.put(task.id, task);
    resolver.gate.complete('stale-action-key');
    await pending;

    expect(db.messageBox.values, isEmpty);
  });

  test('falls back to a system reminder when the sender leaves mid-write',
      () async {
    final db = DatabaseService();
    final config = ApiConfig(
      id: 'config-membership-race',
      name: '成员变更网关',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      hasCredential: true,
      credentialId: 'credential-membership-race',
    );
    final character = AICharacter(
      id: 'membership-race-role',
      name: '待移除角色',
      avatar: '移',
      age: 28,
      role: '前端开发',
      personalityTags: const [],
      systemPrompt: '负责前端实现。',
      apiKey: '',
      apiProvider: 'deepseek',
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
    );
    final group = ChatGroup(
      id: 'group-membership-race',
      name: '成员变更群',
      theme: '网页方案',
      aiCharacterIds: [character.id],
    );
    await db.apiConfigBox.put(config.id, config);
    await db.aiCharacterBox.put(character.id, character);
    await db.chatGroupBox.put(group.id, group);
    final task = _roleBlockedTask(group.id)
      ..assignedCharacterIds = [character.id];
    await db.agentTaskBox.put(task.id, task);
    final resolver = _GateCredentialResolver();
    final pending = WorkTaskActionMessageService(
      database: db,
      credentials: resolver,
    ).notify(task);
    for (var attempt = 0; attempt < 100 && resolver.calls == 0; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(resolver.calls, 1);
    group.aiCharacterIds = <String>[];
    await db.chatGroupBox.put(group.id, group);
    resolver.gate.complete('membership-race-key');
    await pending;

    final message = db.messageBox.values.single;
    expect(message.senderType, 'system');
    expect(message.senderId, 'system');
  });

  test('does not project group action reminders into direct chats', () async {
    final db = DatabaseService();
    final task = _roleBlockedTask('dm:frontend-action-message');

    await WorkTaskActionMessageService(database: db).notify(task);

    expect(db.messageBox.values, isEmpty);
  });

  test('uses a system reminder when a role credential was revoked', () async {
    final db = DatabaseService();
    final config = ApiConfig(
      id: 'config-revoked-action-message',
      name: '已撤销网关',
      provider: 'deepseek',
      credentialId: 'credential.api-config.revoked',
      hasCredential: true,
    );
    final character = AICharacter(
      id: 'revoked-action-message',
      name: '失效角色',
      avatar: '失',
      age: 28,
      role: '前端开发',
      personalityTags: const [],
      systemPrompt: '负责前端实现。',
      apiKey: '',
      apiProvider: 'deepseek',
      apiConfigId: config.id,
    );
    final group = ChatGroup(
      id: 'group-revoked-action-message',
      name: '失效凭据群',
      theme: '网页方案',
      aiCharacterIds: [character.id],
    );
    await db.apiConfigBox.put(config.id, config);
    await db.aiCharacterBox.put(character.id, character);
    await db.chatGroupBox.put(group.id, group);
    final task = _roleBlockedTask(group.id);
    await db.agentTaskBox.put(task.id, task);

    await WorkTaskActionMessageService(
      database: db,
      credentials: const _CredentialResolver(null),
    ).notify(task);

    expect(db.messageBox.values.single.senderType, 'system');
    expect(db.messageBox.values.single.senderId, 'system');
  });

  test('does not attribute an unavailable named executor reminder to a backup',
      () async {
    final db = DatabaseService();
    final namedConfig = ApiConfig(
      id: 'config-named-unavailable',
      name: '指定角色网关',
      provider: 'deepseek',
      credentialId: 'credential-named-unavailable',
      hasCredential: true,
    );
    final backupConfig = ApiConfig(
      id: 'config-backup-available',
      name: '备用角色网关',
      provider: 'deepseek',
      credentialId: 'credential-backup-available',
      hasCredential: true,
    );
    final named = AICharacter(
      id: 'named-executor',
      name: '指定前端',
      avatar: '指',
      age: 30,
      role: '前端开发',
      personalityTags: const [],
      systemPrompt: '负责前端实现。',
      apiKey: '',
      apiProvider: 'deepseek',
      apiConfigId: namedConfig.id,
    );
    final backup = AICharacter(
      id: 'backup-executor',
      name: '备用前端',
      avatar: '备',
      age: 30,
      role: '前端开发',
      personalityTags: const [],
      systemPrompt: '负责前端实现。',
      apiKey: '',
      apiProvider: 'deepseek',
      apiConfigId: backupConfig.id,
    );
    final group = ChatGroup(
      id: 'group-named-unavailable',
      name: '指定执行人群',
      theme: '网页方案',
      aiCharacterIds: [named.id, backup.id],
    );
    await db.apiConfigBox.put(namedConfig.id, namedConfig);
    await db.apiConfigBox.put(backupConfig.id, backupConfig);
    await db.aiCharacterBox.put(named.id, named);
    await db.aiCharacterBox.put(backup.id, backup);
    await db.chatGroupBox.put(group.id, group);
    final discussion = WorkDiscussionState.initial(
      conversationId: group.id,
      executorId: named.id,
      candidateCharacterIds: [named.id, backup.id],
      participantCharacterIds: [named.id, backup.id],
      blockers: const ['executorUnavailable'],
      deliverableContract: const <String, dynamic>{
        'deliverableType': 'document',
        'format': 'docx',
        'location': 'desktop',
        'contentScope': '输出 Word 文档',
        'explicitExecutorId': 'named-executor',
        'revisionTarget': '',
        'requestRevision': 1,
      },
    );
    final task = AgentTask(
      id: 'named-unavailable-task',
      groupId: group.id,
      characterId: named.id,
      userRequest: '输出 Word 文档',
      status: AgentTaskStatus.paused,
      workModeTask: true,
      executionStateJson: WorkDiscussionState.mergeIntoExecutionState(
        jsonEncode(<String, dynamic>{}),
        discussion,
      ),
    );
    await db.agentTaskBox.put(task.id, task);

    await WorkTaskActionMessageService(
      database: db,
      credentials: const _MapCredentialResolver({
        'config-named-unavailable': null,
        'config-backup-available': 'backup-key',
      }),
    ).notify(task);

    final message = db.messageBox.values.single;
    expect(message.senderType, 'system');
    expect(message.senderId, 'system');
  });
}

AgentTask _roleBlockedTask(String groupId) {
  final discussion = WorkDiscussionState.initial(
    conversationId: groupId,
    requestRevision: 1,
    executorId: null,
    candidateCharacterIds: const [],
    participantCharacterIds: const [],
    deliverableContract: const <String, dynamic>{
      'deliverableType': 'document',
      'format': 'docx',
      'location': 'desktop',
      'contentScope': '输出 Word 文档',
      'explicitExecutorId': null,
      'revisionTarget': '',
      'requestRevision': 1,
    },
    blockers: const ['missingQualifiedRole'],
  );
  return AgentTask(
    id: 'action-message-task',
    groupId: groupId,
    characterId: '',
    userRequest: '输出 Word 文档',
    status: AgentTaskStatus.paused,
    workModeTask: true,
    executionStateJson: WorkDiscussionState.mergeIntoExecutionState(
      jsonEncode(<String, dynamic>{}),
      discussion,
    ),
  );
}

void _registerAdapters() {
  if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(AICharacterAdapter());
  if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(ChatGroupAdapter());
  if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(MessageAdapter());
  if (!Hive.isAdapterRegistered(4)) Hive.registerAdapter(ApiConfigAdapter());
  if (!Hive.isAdapterRegistered(9)) {
    Hive.registerAdapter(MediaAttachmentAdapter());
  }
  if (!Hive.isAdapterRegistered(10)) {
    Hive.registerAdapter(ToolPermissionAdapter());
  }
  if (!Hive.isAdapterRegistered(22)) Hive.registerAdapter(UserProfileAdapter());
  if (!Hive.isAdapterRegistered(24)) {
    Hive.registerAdapter(CharacterGenderAdapter());
  }
  if (!Hive.isAdapterRegistered(12)) {
    Hive.registerAdapter(AgentTaskStatusAdapter());
  }
  if (!Hive.isAdapterRegistered(13)) Hive.registerAdapter(AgentTaskAdapter());
}

Future<void> _openBoxes() async {
  await Hive.openBox<AICharacter>('ai_characters');
  await Hive.openBox<ApiConfig>('api_configs');
  await Hive.openBox<ChatGroup>('chat_groups');
  await Hive.openBox<Message>('messages');
  await Hive.openBox<AgentTask>('agent_tasks');
  await Hive.openBox<UserProfile>('user_profile');
  await Hive.openBox<dynamic>('app_settings');
}
