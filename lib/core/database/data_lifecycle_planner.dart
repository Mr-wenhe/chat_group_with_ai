import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/hive_deletion_runner.dart';
import 'package:chat_group/core/database/managed_media_store.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

class DataLifecyclePlanner {
  final DatabaseService db;
  final DataLifecycleSettings settings;
  final ManagedMediaStore media;
  final HiveDeletionRunner runner;

  const DataLifecyclePlanner({
    required this.db,
    required this.settings,
    required this.media,
    required this.runner,
  });

  Future<DeletionPlan> previewGroup(String groupId) async {
    final messageKeys = await runner.matchingKeys<Message>(
      db.messageBox,
      (message) => message.groupId == groupId,
    );
    final groupMemories = await runner.matchingKeys(
      db.groupMemoryBox,
      (item) => item.groupId == groupId,
    );
    final characterMemories = await runner.matchingKeys(
      db.characterMemoryBox,
      (item) => item.groupId == groupId,
    );
    final relationships = await runner.matchingKeys(
      db.relationshipStateBox,
      (item) => item.groupId == groupId,
    );
    final tasks = await runner.matchingKeys(
      db.agentTaskBox,
      (item) => item.groupId == groupId,
    );
    final workspaces = await runner.matchingKeys(
      db.workModeWorkspaceBox,
      (item) => item.conversationId == groupId,
    );
    final usage = await media.usage(
      excludedMessageIds: messageKeys.whereType<String>().toSet(),
    );
    return DeletionPlan(title: '删除群聊', counts: {
      'groups': db.chatGroupBox.containsKey(groupId) ? 1 : 0,
      'messages': messageKeys.length,
      'groupMemories': groupMemories.length,
      'characterMemories': characterMemories.length,
      'relationships': relationships.length,
      'tasks': tasks.length,
      'workspaces': workspaces.length,
      'settings': settings.conversationSettingCount(groupId, isGroup: true),
      'attachments': usage.orphanFiles,
    });
  }

  Future<DeletionPlan> previewCharacter(
    String characterId, {
    CharacterDeletionPolicy policy = CharacterDeletionPolicy.keepMessageHistory,
  }) async {
    final conversationId = DirectChatSession.conversationIdFor(characterId);
    final directMessages = await runner.matchingKeys<Message>(
      db.messageBox,
      (message) => message.groupId == conversationId,
    );
    final groups = await runner.matchingKeys(
      db.chatGroupBox,
      (group) => group.aiCharacterIds.contains(characterId),
    );
    final skills = await runner.matchingKeys(
      db.characterSkillBox,
      (skill) => skill.characterId == characterId,
    );
    final tasks = await runner.matchingKeys(
      db.agentTaskBox,
      (task) => task.characterId == characterId,
    );
    final memories = await runner.matchingKeys(
      db.characterMemoryBox,
      (memory) => memory.characterId == characterId,
    );
    final relationships = await runner.matchingKeys(
      db.relationshipStateBox,
      (relation) =>
          relation.sourceCharacterId == characterId ||
          (relation.targetType == RelationshipTargetType.ai &&
              relation.targetId == characterId),
    );
    final usage = await media.usage(
      excludedMessageIds: policy == CharacterDeletionPolicy.deleteRelatedData
          ? directMessages.whereType<String>().toSet()
          : const {},
    );
    return DeletionPlan(title: '删除角色', counts: {
      'groups': groups.length,
      'directMessages': directMessages.length,
      'skills': skills.length,
      'tasks': tasks.length,
      'memories': memories.length,
      'relationships': relationships.length,
      'attachments': usage.orphanFiles,
    });
  }

  Future<DeletionPlan> previewApiConfig(String configId) async {
    final characters = await runner.matchingKeys(
      db.aiCharacterBox,
      (character) => character.apiConfigId == configId,
    );
    return DeletionPlan(
      title: '删除 API 配置',
      counts: {'characters': characters.length},
    );
  }
}
