import 'dart:io';

import 'package:hive/hive.dart';

import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_planner.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/hive_deletion_runner.dart';
import 'package:chat_group/core/database/managed_media_store.dart';
import 'package:chat_group/core/database/relationship_snapshot_rebuilder.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:flutter/foundation.dart';

/// Owns every destructive cross-box operation.
///
/// Hive has no transaction spanning boxes, so each operation is persisted
/// before it starts and every step is safe to repeat. File cleanup is always
/// last and is restricted to the app-managed `data/media` directory.
class DataLifecycleService {
  static const pendingOperationKey = DataLifecycleSettings.pendingOperationKey;
  final DatabaseService db;
  final Directory? managedMediaDirectory;
  final CredentialRepository credentials;
  final Future<void> Function() clearExternalSettings;
  late final DataLifecycleSettings _settings = DataLifecycleSettings(db);
  late final ManagedMediaStore _media = ManagedMediaStore(
    db: db,
    root: managedMediaDirectory,
  );
  final _runner = const HiveDeletionRunner();
  late final _planner = DataLifecyclePlanner(
    db: db,
    settings: _settings,
    media: _media,
    runner: _runner,
  );
  late final _relationshipRebuilder = RelationshipSnapshotRebuilder(
    db: db,
    settings: _settings,
  );

  DataLifecycleService({
    required this.db,
    Directory? managedMediaDirectory,
    CredentialRepository? credentials,
    Future<void> Function()? clearExternalSettings,
  })  : managedMediaDirectory = managedMediaDirectory ??
            (db.dataDirPath == null
                ? null
                : Directory('${db.dataDirPath}/media')),
        credentials = credentials ?? CredentialRepository(),
        clearExternalSettings = clearExternalSettings ??
            (() => SecureStorageService().deleteWeComAppConfig());

  bool get hasPendingOperation =>
      db.appSettingsBox.get(pendingOperationKey) is Map;

  Future<void> _deleteSecureCredential(String configId) async {
    final config = db.apiConfigBox.get(configId);
    final isDevelopmentHiveCredential = !kReleaseMode &&
        config?.credentialId ==
            CredentialRepository.developmentHiveCredentialId &&
        config?.legacyApiKeyForMigration?.isNotEmpty == true;
    if (!credentials.secureStorageAvailable || isDevelopmentHiveCredential) {
      return;
    }
    final result = await credentials.delete(configId);
    if (!result.isSuccess) throw StateError('credential deletion failed');
  }

  Future<DeletionPlan> previewGroup(
    String groupId, {
    bool deleteAssociatedPermanentData = false,
  }) =>
      _planner.previewGroup(
        groupId,
        deleteAssociatedPermanentData: deleteAssociatedPermanentData,
      );

  Future<DeletionPlan> previewConversation(
    String conversationId, {
    bool deleteAssociatedPermanentData = false,
  }) =>
      _planner.previewConversation(
        conversationId,
        deleteAssociatedPermanentData: deleteAssociatedPermanentData,
      );

  Future<DeletionPlan> previewCharacter(
    String characterId, {
    CharacterDeletionPolicy policy = CharacterDeletionPolicy.keepMessageHistory,
  }) =>
      _planner.previewCharacter(characterId, policy: policy);

  Future<DeletionPlan> previewApiConfig(String configId) =>
      _planner.previewApiConfig(configId);

  Future<DeletionPlan> previewClear(DataClearScope scope) =>
      _planner.previewClear(scope);

  Future<DataLifecycleResult> deleteMessage(
    String messageId, {
    required String groupId,
  }) async {
    final targets = await _planMessage(messageId, groupId);
    if (!await _begin({
      'kind': 'message',
      'id': messageId,
      'groupId': groupId,
      'targets': targets.toMap(),
    })) {
      return _pendingOperationConflict();
    }
    return _runMessageDeletion(messageId, groupId, targets);
  }

  Future<DataLifecycleResult> deleteGroup(
    String groupId, {
    bool deleteAssociatedPermanentData = false,
  }) async {
    final plan = await _planner.previewGroup(
      groupId,
      deleteAssociatedPermanentData: deleteAssociatedPermanentData,
    );
    if (!await _begin({
      'kind': 'group',
      'id': groupId,
      'deleteAssociatedPermanentData': deleteAssociatedPermanentData,
      'targets': plan.targets.toMap(),
    })) {
      return _pendingOperationConflict();
    }
    return _runGroupDeletion(
      groupId,
      targets: plan.targets,
      deleteAssociatedPermanentData: deleteAssociatedPermanentData,
    );
  }

  Future<DataLifecycleResult> deleteCharacter(
    String characterId, {
    required CharacterDeletionPolicy policy,
  }) async {
    final plan = await _planner.previewCharacter(characterId, policy: policy);
    if (!await _begin({
      'kind': 'character',
      'id': characterId,
      'policy': policy.name,
      'targets': plan.targets.toMap(),
    })) {
      return _pendingOperationConflict();
    }
    return _runCharacterDeletion(
      characterId,
      policy,
      targets: plan.targets,
    );
  }

  Future<DataLifecycleResult> deleteApiConfig(
    String configId, {
    String? replacementConfigId,
  }) async {
    if (replacementConfigId == configId ||
        (replacementConfigId != null &&
            !db.apiConfigBox.containsKey(replacementConfigId))) {
      throw ArgumentError.value(replacementConfigId, 'replacementConfigId');
    }
    final plan = await _planner.previewApiConfig(configId);
    if (!await _begin({
      'kind': 'apiConfig',
      'id': configId,
      if (replacementConfigId != null) 'replacementId': replacementConfigId,
      'targets': plan.targets.toMap(),
    })) {
      return _pendingOperationConflict();
    }
    return _runApiConfigDeletion(
      configId,
      replacementConfigId,
      targets: plan.targets,
    );
  }

  Future<DataLifecycleResult> clear(DataClearScope scope) async {
    final plan = await _planner.previewClear(scope);
    if (!await _begin({
      'kind': 'clear',
      'scope': scope.name,
      'targets': plan.targets.toMap(),
    })) {
      return _pendingOperationConflict();
    }
    return _runClear(scope, plan.targets);
  }

  Future<DataLifecycleResult> clearConversation(
    String conversationId, {
    bool deleteAssociatedPermanentData = false,
  }) async {
    final plan = await _planner.previewConversation(
      conversationId,
      deleteAssociatedPermanentData: deleteAssociatedPermanentData,
    );
    if (!await _begin({
      'kind': 'conversation',
      'id': conversationId,
      'deleteAssociatedPermanentData': deleteAssociatedPermanentData,
      'targets': plan.targets.toMap(),
    })) {
      return _pendingOperationConflict();
    }
    return _runConversationDeletion(
      conversationId,
      targets: plan.targets,
      deleteAssociatedPermanentData: deleteAssociatedPermanentData,
    );
  }

  Future<DataLifecycleResult> retryPendingOperation() async {
    final raw = db.appSettingsBox.get(pendingOperationKey);
    if (raw is! Map) return const DataLifecycleResult();
    final job = Map<String, dynamic>.from(raw);
    final id = job['id']?.toString() ?? '';
    final targets = await _targetsForRetry(job);
    switch (job['kind']) {
      case 'message':
        return _runMessageDeletion(
          id,
          job['groupId']?.toString() ?? '',
          targets,
        );
      case 'group':
        return _runGroupDeletion(
          id,
          targets: targets,
          deleteAssociatedPermanentData:
              job['deleteAssociatedPermanentData'] == true,
        );
      case 'conversation':
        return _runConversationDeletion(
          id,
          targets: targets,
          deleteAssociatedPermanentData:
              job['deleteAssociatedPermanentData'] == true,
        );
      case 'character':
        final policy = CharacterDeletionPolicy.values.firstWhere(
          (value) => value.name == job['policy'],
          orElse: () => CharacterDeletionPolicy.keepMessageHistory,
        );
        return _runCharacterDeletion(id, policy, targets: targets);
      case 'apiConfig':
        return _runApiConfigDeletion(
          id,
          job['replacementId']?.toString(),
          targets: targets,
        );
      case 'clear':
        final scope = DataClearScope.values.firstWhere(
          (value) => value.name == job['scope'],
          orElse: () => DataClearScope.userContent,
        );
        return _runClear(scope, targets);
      default:
        return const DataLifecycleResult(
          incompleteItems: ['删除重试记录无效'],
        );
    }
  }

  List<AICharacter> deletedCharacters() => _settings.deletedCharacters();

  AICharacter? deletedCharacter(String characterId) {
    return _settings.deletedCharacter(characterId);
  }

  /// Resolves a character for historical display before falling back to its
  /// persisted deletion snapshot.
  AICharacter? characterOrDeleted(String characterId) {
    return db.aiCharacterBox.get(characterId) ?? deletedCharacter(characterId);
  }

  /// Resolves only the referenced characters so deleted snapshots from other
  /// conversations do not leak into a member or audit list.
  List<AICharacter> charactersForIds(Iterable<String> characterIds) {
    final resolved = <String, AICharacter>{};
    for (final characterId in characterIds) {
      final normalizedId = characterId.trim();
      if (normalizedId.isEmpty) continue;
      final character = characterOrDeleted(normalizedId);
      if (character != null) resolved[character.id] = character;
    }
    final characters = resolved.values.toList()
      ..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    return List.unmodifiable(characters);
  }

  Future<MediaUsage> mediaUsage() => _media.usage();

  Future<DataLifecycleResult> cleanupOrphanMedia() async {
    final result = await _media.cleanup();
    DocumentUnderstandingService.clearCache();
    return result;
  }

  Future<DataLifecycleResult> cleanupMediaPaths(Iterable<String> paths) async {
    final values = paths.toList(growable: false);
    final result = await _media.cleanupPaths(values);
    DocumentUnderstandingService.evictPaths(values);
    return result;
  }

  Future<DataLifecycleResult> _runMessageDeletion(
    String messageId,
    String groupId,
    DeletionTargets targets,
  ) async {
    final incomplete = <String>[];
    final mediaPaths = db.messageBox
            .get(messageId)
            ?.media
            ?.map((attachment) => attachment.localPath)
            .toList(growable: false) ??
        const <String>[];
    await _runner.attempt('消息删除失败', incomplete, () async {
      if (targets.keysFor(DeletionTargetNames.messages).isEmpty) return;
      await db.deleteMessageRecordAndIndex(messageId, groupId: groupId);
      await _clearReplyReferences(
        targets.keysFor(DeletionTargetNames.replyReferences),
      );
    });
    return _finish(incomplete, await cleanupMediaPaths(mediaPaths));
  }

  Future<DataLifecycleResult> _runGroupDeletion(
    String groupId, {
    required DeletionTargets targets,
    required bool deleteAssociatedPermanentData,
  }) async {
    final incomplete = <String>[];
    final messageKeys = targets.keysFor(DeletionTargetNames.messages);
    await _deleteTargetKeys(
      '群消息删除失败',
      db.messageBox,
      messageKeys,
      incomplete,
    );
    await _deleteTargetKeys(
      '群记忆删除失败',
      db.groupMemoryBox,
      targets.keysFor(DeletionTargetNames.groupMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色群记忆删除失败',
      db.characterMemoryBox,
      targets.keysFor(DeletionTargetNames.characterMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '群关系删除失败',
      db.relationshipStateBox,
      targets.keysFor(DeletionTargetNames.relationshipStates),
      incomplete,
    );
    await _deleteTargetKeys(
      '群任务删除失败',
      db.agentTaskBox,
      targets.keysFor(DeletionTargetNames.agentTasks),
      incomplete,
    );
    await _deleteTargetKeys(
      '群工作区记录删除失败',
      db.workModeWorkspaceBox,
      targets.keysFor(DeletionTargetNames.workspaces),
      incomplete,
    );
    if (deleteAssociatedPermanentData) {
      await _deleteTargetKeys(
        '群来源永久记忆删除失败',
        db.permanentMemoryBox,
        targets.keysFor(DeletionTargetNames.permanentMemories),
        incomplete,
      );
      await _deleteTargetKeys(
        '群来源关系事件删除失败',
        db.relationshipEventBox,
        targets.keysFor(DeletionTargetNames.relationshipEvents),
        incomplete,
      );
      await _rebuildRelationships(targets.relationshipIds, incomplete);
    }
    await _runner.attempt('群设置清理失败', incomplete, () async {
      await _settings.removeConversation(
        groupId,
        isGroup: true,
        targets: targets.appSettings,
      );
      await _clearReplyReferences(
        targets.keysFor(DeletionTargetNames.replyReferences),
      );
    });
    await _runner.attempt(
      '群聊删除失败',
      incomplete,
      () async {
        if (targets.keysFor(DeletionTargetNames.chatGroups).isNotEmpty) {
          await db.chatGroupBox.delete(groupId);
        }
      },
    );
    return _finish(incomplete, await cleanupOrphanMedia());
  }

  Future<DataLifecycleResult> _runConversationDeletion(
    String conversationId, {
    required DeletionTargets targets,
    required bool deleteAssociatedPermanentData,
  }) async {
    final incomplete = <String>[];
    await _deleteTargetKeys(
      '会话消息删除失败',
      db.messageBox,
      targets.keysFor(DeletionTargetNames.messages),
      incomplete,
    );
    await _deleteTargetKeys(
      '会话群记忆删除失败',
      db.groupMemoryBox,
      targets.keysFor(DeletionTargetNames.groupMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '会话角色记忆删除失败',
      db.characterMemoryBox,
      targets.keysFor(DeletionTargetNames.characterMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '会话关系删除失败',
      db.relationshipStateBox,
      targets.keysFor(DeletionTargetNames.relationshipStates),
      incomplete,
    );
    await _deleteTargetKeys(
      '会话任务删除失败',
      db.agentTaskBox,
      targets.keysFor(DeletionTargetNames.agentTasks),
      incomplete,
    );
    await _deleteTargetKeys(
      '会话工作区记录删除失败',
      db.workModeWorkspaceBox,
      targets.keysFor(DeletionTargetNames.workspaces),
      incomplete,
    );
    if (deleteAssociatedPermanentData) {
      await _deleteTargetKeys(
        '会话来源永久记忆删除失败',
        db.permanentMemoryBox,
        targets.keysFor(DeletionTargetNames.permanentMemories),
        incomplete,
      );
      await _deleteTargetKeys(
        '会话来源关系事件删除失败',
        db.relationshipEventBox,
        targets.keysFor(DeletionTargetNames.relationshipEvents),
        incomplete,
      );
      await _rebuildRelationships(targets.relationshipIds, incomplete);
    }
    await _runner.attempt('会话设置清理失败', incomplete, () async {
      await _settings.removeConversation(
        conversationId,
        isGroup: !DirectChatSession.isDirectConversationId(conversationId),
        targets: targets.appSettings,
      );
      await _clearReplyReferences(
        targets.keysFor(DeletionTargetNames.replyReferences),
      );
    });
    return _finish(incomplete, await cleanupOrphanMedia());
  }

  Future<DataLifecycleResult> _runCharacterDeletion(
    String characterId,
    CharacterDeletionPolicy policy, {
    required DeletionTargets targets,
  }) async {
    final incomplete = <String>[];
    final character = db.aiCharacterBox.get(characterId);
    if (character != null &&
        policy == CharacterDeletionPolicy.keepMessageHistory) {
      final saved = await _runner.attempt(
        '历史身份快照保存失败',
        incomplete,
        () => _settings.saveDeletedCharacter(character),
      );
      if (!saved) return _finish(incomplete);
    }
    final conversationId = DirectChatSession.conversationIdFor(characterId);
    final deleteMessages = policy == CharacterDeletionPolicy.deleteRelatedData;
    final deletedMessageKeys = deleteMessages
        ? targets.keysFor(DeletionTargetNames.messages)
        : const <dynamic>[];

    await _runner.attempt('群成员引用清理失败', incomplete, () async {
      for (final key in targets.keysFor(DeletionTargetNames.chatGroups)) {
        final group = db.chatGroupBox.get(key);
        if (group == null) continue;
        if (group.aiCharacterIds.contains(characterId)) {
          group.aiCharacterIds = group.aiCharacterIds
              .where((id) => id != characterId)
              .toList(growable: false);
          await db.chatGroupBox.put(group.id, group);
        }
      }
    });
    await _runner.attempt('消息提及引用清理失败', incomplete, () async {
      for (final key
          in targets.keysFor(DeletionTargetNames.mentionReferences)) {
        final message = db.messageBox.get(key);
        if (message == null) continue;
        if (message.mentionedAiIds.contains(characterId)) {
          message.mentionedAiIds = message.mentionedAiIds
              .where((id) => id != characterId)
              .toList(growable: false);
          await db.messageBox.put(message.id, message);
        }
      }
    });
    await _deleteTargetKeys(
      '角色记忆删除失败',
      db.characterMemoryBox,
      targets.keysFor(DeletionTargetNames.characterMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色关系删除失败',
      db.relationshipStateBox,
      targets.keysFor(DeletionTargetNames.relationshipStates),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色关系事件删除失败',
      db.relationshipEventBox,
      targets.keysFor(DeletionTargetNames.relationshipEvents),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色永久记忆删除失败',
      db.permanentMemoryBox,
      targets.keysFor(DeletionTargetNames.permanentMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色技能删除失败',
      db.characterSkillBox,
      targets.keysFor(DeletionTargetNames.characterSkills),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色任务删除失败',
      db.agentTaskBox,
      targets.keysFor(DeletionTargetNames.agentTasks),
      incomplete,
    );
    await _deleteTargetKeys(
      '私聊工作区记录删除失败',
      db.workModeWorkspaceBox,
      targets.keysFor(DeletionTargetNames.workspaces),
      incomplete,
    );
    if (deleteMessages) {
      await _runner.deleteKeys(
        '私聊消息删除失败',
        db.messageBox,
        deletedMessageKeys,
        incomplete,
      );
      await _runner.attempt('私聊回复引用清理失败', incomplete, () {
        return _clearReplyReferences(
          targets.keysFor(DeletionTargetNames.replyReferences),
        );
      });
    }
    await _rebuildRelationships(targets.relationshipIds, incomplete);
    await _cleanupRelationshipPins(targets.relationshipIds, incomplete);
    await _runner.attempt('角色设置清理失败', incomplete, () async {
      await _settings.removeCharacter(
        characterId,
        conversationId,
        removeConversation: deleteMessages,
        targets: targets.appSettings,
      );
      if (deleteMessages) await _settings.removeDeletedCharacter(characterId);
    });
    await _runner.attempt(
      '角色删除失败',
      incomplete,
      () async {
        if (targets.keysFor(DeletionTargetNames.aiCharacters).isNotEmpty) {
          await db.aiCharacterBox.delete(characterId);
        }
      },
    );
    return _finish(incomplete, await cleanupOrphanMedia());
  }

  Future<DataLifecycleResult> _runApiConfigDeletion(
    String configId,
    String? replacementConfigId, {
    required DeletionTargets targets,
  }) async {
    final incomplete = <String>[];
    final credentialDeleted = await _runner.attempt(
      'API 凭据删除失败',
      incomplete,
      () => _deleteSecureCredential(configId),
    );
    if (!credentialDeleted) return _finish(incomplete);
    final replacement = replacementConfigId == null
        ? null
        : db.apiConfigBox.get(replacementConfigId);
    await _runner.attempt('角色配置解绑失败', incomplete, () async {
      for (final key in targets.keysFor(DeletionTargetNames.aiCharacters)) {
        final character = db.aiCharacterBox.get(key);
        if (character == null) continue;
        if (character.apiConfigId == configId) {
          _applyApiConfig(character, replacement);
          await db.aiCharacterBox.put(character.id, character);
        }
      }
    });
    await _runner.attempt(
      'API 配置删除失败',
      incomplete,
      () async {
        if (targets.keysFor(DeletionTargetNames.apiConfigs).isNotEmpty) {
          await db.apiConfigBox.delete(configId);
        }
      },
    );
    return _finish(incomplete);
  }

  Future<DataLifecycleResult> _runClear(
    DataClearScope scope,
    DeletionTargets targets,
  ) async {
    final incomplete = <String>[];
    await _deleteTargetKeys(
      '消息清理失败',
      db.messageBox,
      targets.keysFor(DeletionTargetNames.messages),
      incomplete,
    );
    await _deleteTargetKeys(
      '群记忆清理失败',
      db.groupMemoryBox,
      targets.keysFor(DeletionTargetNames.groupMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色记忆清理失败',
      db.characterMemoryBox,
      targets.keysFor(DeletionTargetNames.characterMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '关系清理失败',
      db.relationshipStateBox,
      targets.keysFor(DeletionTargetNames.relationshipStates),
      incomplete,
    );
    await _deleteTargetKeys(
      '关系事件清理失败',
      db.relationshipEventBox,
      targets.keysFor(DeletionTargetNames.relationshipEvents),
      incomplete,
    );
    await _deleteTargetKeys(
      '永久记忆清理失败',
      db.permanentMemoryBox,
      targets.keysFor(DeletionTargetNames.permanentMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '任务清理失败',
      db.agentTaskBox,
      targets.keysFor(DeletionTargetNames.agentTasks),
      incomplete,
    );
    await _deleteTargetKeys(
      '工作区记录清理失败',
      db.workModeWorkspaceBox,
      targets.keysFor(DeletionTargetNames.workspaces),
      incomplete,
    );
    await _runner.attempt('角色长期记忆重置失败', incomplete, () async {
      for (final key in targets.keysFor(DeletionTargetNames.aiCharacters)) {
        final character = db.aiCharacterBox.get(key);
        if (character == null) continue;
        character.memorySummary = '';
        character.hourlyReplyCount = 0;
        character.lastReplyTimestamp = null;
        await db.aiCharacterBox.put(character.id, character);
      }
    });

    if (scope != DataClearScope.chatContent) {
      await _deleteTargetKeys(
        '技能清理失败',
        db.characterSkillBox,
        targets.keysFor(DeletionTargetNames.characterSkills),
        incomplete,
      );
      await _deleteTargetKeys(
        '群聊清理失败',
        db.chatGroupBox,
        targets.keysFor(DeletionTargetNames.chatGroups),
        incomplete,
      );
      await _deleteTargetKeys(
        '角色清理失败',
        db.aiCharacterBox,
        targets.keysFor(DeletionTargetNames.aiCharacters),
        incomplete,
      );
      await _deleteTargetKeys(
        '用户资料清理失败',
        db.userProfileBox,
        targets.keysFor(DeletionTargetNames.userProfiles),
        incomplete,
      );
      final deletableConfigIds = <String>[];
      for (final configId in targets
          .keysFor(DeletionTargetNames.apiConfigs)
          .whereType<String>()) {
        final deleted = await _runner.attempt(
          'API 凭据删除失败',
          incomplete,
          () => _deleteSecureCredential(configId),
        );
        if (deleted) {
          deletableConfigIds.add(configId);
        }
      }
      await _deleteTargetKeys(
        'API 配置清理失败',
        db.apiConfigBox,
        deletableConfigIds,
        incomplete,
      );
      await _runner.attempt('外部配置清理失败', incomplete, clearExternalSettings);
    }

    await _runner.attempt('设置清理失败', incomplete, () async {
      switch (scope) {
        case DataClearScope.chatContent:
          await _settings.clearConversationSettings(
            targets: targets.appSettings,
          );
        case DataClearScope.userContent:
          await _settings.clearExceptPreferences(
            targets: targets.appSettings,
          );
        case DataClearScope.factoryReset:
          await _settings.clearExceptPendingOperation(
            targets: targets.appSettings,
          );
      }
      db.resetLifecycleCaches();
    });
    return _finish(incomplete, await cleanupOrphanMedia());
  }

  Future<void> _clearReplyReferences(Iterable<dynamic> messageKeys) async {
    for (final key in messageKeys) {
      final message = db.messageBox.get(key);
      if (message != null && message.replyToMessageId != null) {
        message.replyToMessageId = null;
        await db.messageBox.put(message.id, message);
      }
    }
  }

  Future<void> _deleteTargetKeys<T>(
    String failure,
    Box<T> box,
    List<dynamic> keys,
    List<String> incomplete,
  ) =>
      _runner.deleteKeys(failure, box, keys, incomplete);

  Future<void> _rebuildRelationships(
    Iterable<String> relationshipIds,
    List<String> incomplete,
  ) async {
    if (relationshipIds.isEmpty) return;
    await _runner.attempt(
      '关系快照重建失败',
      incomplete,
      () => _relationshipRebuilder.rebuildFor(relationshipIds),
    );
  }

  Future<void> _cleanupRelationshipPins(
    Iterable<String> relationshipIds,
    List<String> incomplete,
  ) async {
    await _runner.attempt('关系 pin 清理失败', incomplete, () async {
      for (final relationshipId in relationshipIds) {
        final stillExists = db.relationshipStateBox.values.any((state) {
          final stableId = RelationshipState.stableGlobalId(
            state.sourceCharacterId,
            state.targetType,
            state.targetId,
          );
          return stableId == relationshipId;
        });
        if (!stillExists) {
          await _settings.removeRelationshipPin(relationshipId);
        }
      }
    });
  }

  Future<DeletionTargets> _planMessage(
    String messageId,
    String groupId,
  ) async {
    final messageKeys = await _runner.matchingKeys<Message>(
      db.messageBox,
      (message) => message.id == messageId && message.groupId == groupId,
    );
    final replyReferences = await _runner.matchingKeys<Message>(
      db.messageBox,
      (message) => message.replyToMessageId == messageId,
    );
    return DeletionTargets(
      boxKeys: {
        DeletionTargetNames.messages: messageKeys,
        DeletionTargetNames.replyReferences: replyReferences,
      },
    );
  }

  Future<DeletionTargets> _targetsForRetry(Map<String, dynamic> job) async {
    if (job.containsKey('targets')) {
      return DeletionTargets.fromMap(job['targets']);
    }
    final id = job['id']?.toString() ?? '';
    switch (job['kind']) {
      case 'message':
        return _planMessage(id, job['groupId']?.toString() ?? '');
      case 'group':
        return (await _planner.previewGroup(
          id,
          deleteAssociatedPermanentData:
              job['deleteAssociatedPermanentData'] == true,
        ))
            .targets;
      case 'conversation':
        return (await _planner.previewConversation(
          id,
          deleteAssociatedPermanentData:
              job['deleteAssociatedPermanentData'] == true,
        ))
            .targets;
      case 'character':
        final policy = CharacterDeletionPolicy.values.firstWhere(
          (value) => value.name == job['policy'],
          orElse: () => CharacterDeletionPolicy.keepMessageHistory,
        );
        return (await _planner.previewCharacter(id, policy: policy)).targets;
      case 'apiConfig':
        return (await _planner.previewApiConfig(id)).targets;
      case 'clear':
        final scope = DataClearScope.values.firstWhere(
          (value) => value.name == job['scope'],
          orElse: () => DataClearScope.userContent,
        );
        return (await _planner.previewClear(scope)).targets;
      default:
        return const DeletionTargets();
    }
  }

  void _applyApiConfig(AICharacter character, ApiConfig? replacement) {
    character.apiConfigId = replacement?.id ?? '';
    character.apiKey = '';
    character.apiProvider = replacement?.provider ?? '';
    character.modelName = replacement?.modelName ?? '';
    character.customBaseUrl = replacement?.customBaseUrl ?? '';
  }

  Future<bool> _begin(Map<String, dynamic> operation) async {
    if (hasPendingOperation) return false;
    await db.appSettingsBox.put(pendingOperationKey, operation);
    return true;
  }

  DataLifecycleResult _pendingOperationConflict() =>
      const DataLifecycleResult(incompleteItems: ['请先在设置中重试未完成删除']);

  Future<DataLifecycleResult> _finish(
    List<String> incomplete, [
    DataLifecycleResult media = const DataLifecycleResult(),
  ]) async {
    incomplete.addAll(media.incompleteItems);
    if (incomplete.isEmpty) {
      try {
        await db.appSettingsBox.delete(pendingOperationKey);
      } on Object {
        incomplete.add('删除完成状态保存失败');
      }
    }
    return DataLifecycleResult(
      incompleteItems: incomplete,
      reclaimedFiles: media.reclaimedFiles,
      reclaimedBytes: media.reclaimedBytes,
    );
  }
}
