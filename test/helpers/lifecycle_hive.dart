import 'dart:io';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
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
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:hive/hive.dart';

class MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  bool failNextDelete = false;

  @override
  Future<void> delete(String key) async {
    if (failNextDelete) {
      failNextDelete = false;
      throw const FileSystemException('simulated failure');
    }
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class MemoryLegacyCredentialStore extends SecureStorageService {
  @override
  Future<void> deleteApiConfigKey(String configId) async {}
}

Future<Directory> openLifecycleHive() async {
  final directory =
      await Directory.systemTemp.createTemp('chat_group_lifecycle_test_');
  Hive.init(directory.path);
  _registerAdapters();
  await Hive.openBox<AICharacter>('ai_characters');
  await Hive.openBox<ApiConfig>('api_configs');
  await Hive.openBox<ChatGroup>('chat_groups');
  await Hive.openBox<Message>('messages');
  await Hive.openBox<GroupMemory>('group_memories');
  await Hive.openBox<CharacterMemory>('character_memories');
  await Hive.openBox<RelationshipState>('relationship_states');
  await Hive.openBox<CharacterSkill>('character_skills');
  await Hive.openBox<AgentTask>('agent_tasks');
  await Hive.openBox<WorkModeWorkspace>('work_mode_workspaces');
  await Hive.openBox<dynamic>('app_settings');
  return directory;
}

Future<void> closeLifecycleHive(Directory directory) async {
  await Hive.close();
  CredentialRepository.clearCache();
  if (await directory.exists()) await directory.delete(recursive: true);
}

CredentialRepository testCredentials(MemoryCredentialStore store) =>
    CredentialRepository(
      store: store,
      legacyStorage: MemoryLegacyCredentialStore(),
      secureStorageAvailable: true,
    );

AICharacter testCharacter(String id, {String apiConfigId = ''}) => AICharacter(
      id: id,
      name: '角色$id',
      avatar: '角',
      age: 20,
      role: '测试角色',
      personalityTags: const [],
      systemPrompt: 'test',
      apiKey: '',
      apiProvider: apiConfigId.isEmpty ? '' : 'deepseek',
      modelName: apiConfigId.isEmpty ? '' : 'deepseek-chat',
      apiConfigId: apiConfigId,
    );

void _registerAdapters() {
  if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(AICharacterAdapter());
  if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(ChatGroupAdapter());
  if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(MessageAdapter());
  if (!Hive.isAdapterRegistered(3)) Hive.registerAdapter(GroupMemoryAdapter());
  if (!Hive.isAdapterRegistered(4)) Hive.registerAdapter(ApiConfigAdapter());
  if (!Hive.isAdapterRegistered(5)) {
    Hive.registerAdapter(CharacterMemoryAdapter());
  }
  if (!Hive.isAdapterRegistered(6)) {
    Hive.registerAdapter(RelationshipTargetTypeAdapter());
  }
  if (!Hive.isAdapterRegistered(7)) {
    Hive.registerAdapter(RelationshipMoodAdapter());
  }
  if (!Hive.isAdapterRegistered(8)) {
    Hive.registerAdapter(RelationshipStateAdapter());
  }
  if (!Hive.isAdapterRegistered(9)) {
    Hive.registerAdapter(MediaAttachmentAdapter());
  }
  if (!Hive.isAdapterRegistered(10)) {
    Hive.registerAdapter(ToolPermissionAdapter());
  }
  if (!Hive.isAdapterRegistered(11)) {
    Hive.registerAdapter(CharacterSkillAdapter());
  }
  if (!Hive.isAdapterRegistered(12)) {
    Hive.registerAdapter(AgentTaskStatusAdapter());
  }
  if (!Hive.isAdapterRegistered(13)) Hive.registerAdapter(AgentTaskAdapter());
  if (!Hive.isAdapterRegistered(16)) {
    Hive.registerAdapter(WorkModeWorkspaceAdapter());
  }
}
