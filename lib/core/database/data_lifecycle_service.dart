import 'dart:io';

import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_planner.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/hive_deletion_runner.dart';
import 'package:chat_group/core/database/managed_media_store.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

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

  Future<DeletionPlan> previewGroup(String groupId) =>
      _planner.previewGroup(groupId);

  Future<DeletionPlan> previewCharacter(
    String characterId, {
    CharacterDeletionPolicy policy = CharacterDeletionPolicy.keepMessageHistory,
  }) =>
      _planner.previewCharacter(characterId, policy: policy);

  Future<DeletionPlan> previewApiConfig(String configId) =>
      _planner.previewApiConfig(configId);

  Future<DataLifecycleResult> deleteMessage(
    String messageId, {
    required String groupId,
  }) async {
    if (!await _begin(
        {'kind': 'message', 'id': messageId, 'groupId': groupId})) {
      return _pendingOperationConflict();
    }
    return _runMessageDeletion(messageId, groupId);
  }

  Future<DataLifecycleResult> deleteGroup(String groupId) async {
    if (!await _begin({'kind': 'group', 'id': groupId})) {
      return _pendingOperationConflict();
    }
    return _runGroupDeletion(groupId);
  }

  Future<DataLifecycleResult> deleteCharacter(
    String characterId, {
    required CharacterDeletionPolicy policy,
  }) async {
    if (!await _begin({
      'kind': 'character',
      'id': characterId,
      'policy': policy.name,
    })) {
      return _pendingOperationConflict();
    }
    return _runCharacterDeletion(characterId, policy);
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
    if (!await _begin({
      'kind': 'apiConfig',
      'id': configId,
      if (replacementConfigId != null) 'replacementId': replacementConfigId,
    })) {
      return _pendingOperationConflict();
    }
    return _runApiConfigDeletion(configId, replacementConfigId);
  }

  Future<DataLifecycleResult> clear(DataClearScope scope) async {
    final configIds = db.apiConfigBox.keys.whereType<String>().toList();
    if (!await _begin({
      'kind': 'clear',
      'scope': scope.name,
      'configIds': configIds,
    })) {
      return _pendingOperationConflict();
    }
    return _runClear(scope, configIds);
  }

  Future<DataLifecycleResult> retryPendingOperation() async {
    final raw = db.appSettingsBox.get(pendingOperationKey);
    if (raw is! Map) return const DataLifecycleResult();
    final job = Map<String, dynamic>.from(raw);
    final id = job['id']?.toString() ?? '';
    switch (job['kind']) {
      case 'message':
        return _runMessageDeletion(id, job['groupId']?.toString() ?? '');
      case 'group':
        return _runGroupDeletion(id);
      case 'character':
        final policy = CharacterDeletionPolicy.values.firstWhere(
          (value) => value.name == job['policy'],
          orElse: () => CharacterDeletionPolicy.keepMessageHistory,
        );
        return _runCharacterDeletion(id, policy);
      case 'apiConfig':
        return _runApiConfigDeletion(
          id,
          job['replacementId']?.toString(),
        );
      case 'clear':
        final scope = DataClearScope.values.firstWhere(
          (value) => value.name == job['scope'],
          orElse: () => DataClearScope.userContent,
        );
        final ids = (job['configIds'] as List?)?.whereType<String>().toList() ??
            const <String>[];
        return _runClear(scope, ids);
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

  Future<MediaUsage> mediaUsage() => _media.usage();

  Future<DataLifecycleResult> cleanupOrphanMedia() => _media.cleanup();

  Future<DataLifecycleResult> cleanupMediaPaths(Iterable<String> paths) =>
      _media.cleanupPaths(paths);

  Future<DataLifecycleResult> _runMessageDeletion(
    String messageId,
    String groupId,
  ) async {
    final incomplete = <String>[];
    final mediaPaths = db.messageBox
            .get(messageId)
            ?.media
            ?.map((attachment) => attachment.localPath)
            .toList(growable: false) ??
        const <String>[];
    await _runner.attempt('消息删除失败', incomplete, () async {
      await db.deleteMessageRecordAndIndex(messageId, groupId: groupId);
      await _clearReplyReferences({messageId});
    });
    return _finish(incomplete, await cleanupMediaPaths(mediaPaths));
  }

  Future<DataLifecycleResult> _runGroupDeletion(String groupId) async {
    final incomplete = <String>[];
    final messageKeys = await _runner.matchingKeys<Message>(
      db.messageBox,
      (message) => message.groupId == groupId,
    );
    final messageIds = messageKeys.whereType<String>().toSet();
    await _runner.deleteKeys('群消息删除失败', db.messageBox, messageKeys, incomplete);
    await _runner.deleteWhere('群记忆删除失败', db.groupMemoryBox,
        (item) => item.groupId == groupId, incomplete);
    await _runner.deleteWhere('角色群记忆删除失败', db.characterMemoryBox,
        (item) => item.groupId == groupId, incomplete);
    await _runner.deleteWhere('群关系删除失败', db.relationshipStateBox,
        (item) => item.groupId == groupId, incomplete);
    await _runner.deleteWhere('群任务删除失败', db.agentTaskBox,
        (item) => item.groupId == groupId, incomplete);
    await _runner.deleteWhere('群工作区记录删除失败', db.workModeWorkspaceBox,
        (item) => item.conversationId == groupId, incomplete);
    await _runner.attempt('群设置清理失败', incomplete, () async {
      await _settings.removeConversation(groupId, isGroup: true);
      await _clearReplyReferences(messageIds);
    });
    await _runner.attempt(
      '群聊删除失败',
      incomplete,
      () => db.chatGroupBox.delete(groupId),
    );
    return _finish(incomplete, await cleanupOrphanMedia());
  }

  Future<DataLifecycleResult> _runCharacterDeletion(
    String characterId,
    CharacterDeletionPolicy policy,
  ) async {
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
        ? await _runner.matchingKeys<Message>(
            db.messageBox,
            (message) => message.groupId == conversationId,
          )
        : <dynamic>[];

    await _runner.attempt('群成员引用清理失败', incomplete, () async {
      var scanned = 0;
      for (final group in db.chatGroupBox.values) {
        if (group.aiCharacterIds.contains(characterId)) {
          group.aiCharacterIds = group.aiCharacterIds
              .where((id) => id != characterId)
              .toList(growable: false);
          await db.chatGroupBox.put(group.id, group);
        }
        if (++scanned % HiveDeletionRunner.batchSize == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    });
    await _runner.attempt('消息提及引用清理失败', incomplete, () async {
      var scanned = 0;
      for (final message in db.messageBox.values) {
        if (message.mentionedAiIds.contains(characterId)) {
          message.mentionedAiIds = message.mentionedAiIds
              .where((id) => id != characterId)
              .toList(growable: false);
          await db.messageBox.put(message.id, message);
        }
        if (++scanned % HiveDeletionRunner.batchSize == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    });
    await _runner.deleteWhere('角色记忆删除失败', db.characterMemoryBox,
        (item) => item.characterId == characterId, incomplete);
    await _runner.deleteWhere(
      '角色关系删除失败',
      db.relationshipStateBox,
      (item) =>
          item.sourceCharacterId == characterId ||
          (item.targetType == RelationshipTargetType.ai &&
              item.targetId == characterId),
      incomplete,
    );
    await _runner.deleteWhere('角色技能删除失败', db.characterSkillBox,
        (item) => item.characterId == characterId, incomplete);
    await _runner.deleteWhere('角色任务删除失败', db.agentTaskBox,
        (item) => item.characterId == characterId, incomplete);
    await _runner.deleteWhere('私聊工作区记录删除失败', db.workModeWorkspaceBox,
        (item) => item.conversationId == conversationId, incomplete);
    if (deleteMessages) {
      await _runner.deleteKeys(
        '私聊消息删除失败',
        db.messageBox,
        deletedMessageKeys,
        incomplete,
      );
      await _runner.attempt('私聊回复引用清理失败', incomplete, () {
        return _clearReplyReferences(
            deletedMessageKeys.whereType<String>().toSet());
      });
    }
    await _runner.attempt('角色设置清理失败', incomplete, () async {
      await _settings.removeCharacter(
        characterId,
        conversationId,
        removeConversation: deleteMessages,
      );
      if (deleteMessages) await _settings.removeDeletedCharacter(characterId);
    });
    await _runner.attempt(
      '角色删除失败',
      incomplete,
      () => db.aiCharacterBox.delete(characterId),
    );
    return _finish(incomplete, await cleanupOrphanMedia());
  }

  Future<DataLifecycleResult> _runApiConfigDeletion(
    String configId,
    String? replacementConfigId,
  ) async {
    final incomplete = <String>[];
    final credentialDeleted = await _runner.attempt(
      'API 凭据删除失败',
      incomplete,
      () async {
        if (!credentials.secureStorageAvailable) return;
        final result = await credentials.delete(configId);
        if (!result.isSuccess) throw StateError('credential deletion failed');
      },
    );
    if (!credentialDeleted) return _finish(incomplete);
    final replacement = replacementConfigId == null
        ? null
        : db.apiConfigBox.get(replacementConfigId);
    await _runner.attempt('角色配置解绑失败', incomplete, () async {
      var scanned = 0;
      for (final character in db.aiCharacterBox.values) {
        if (character.apiConfigId == configId) {
          _applyApiConfig(character, replacement);
          await db.aiCharacterBox.put(character.id, character);
        }
        if (++scanned % HiveDeletionRunner.batchSize == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    });
    await _runner.attempt(
      'API 配置删除失败',
      incomplete,
      () => db.apiConfigBox.delete(configId),
    );
    return _finish(incomplete);
  }

  Future<DataLifecycleResult> _runClear(
    DataClearScope scope,
    List<String> configIds,
  ) async {
    final incomplete = <String>[];
    await _runner.deleteKeys(
      '消息清理失败',
      db.messageBox,
      db.messageBox.keys.toList(),
      incomplete,
    );
    await _runner.deleteKeys('群记忆清理失败', db.groupMemoryBox,
        db.groupMemoryBox.keys.toList(), incomplete);
    await _runner.deleteKeys('角色记忆清理失败', db.characterMemoryBox,
        db.characterMemoryBox.keys.toList(), incomplete);
    await _runner.deleteKeys('关系清理失败', db.relationshipStateBox,
        db.relationshipStateBox.keys.toList(), incomplete);
    await _runner.deleteKeys(
        '任务清理失败', db.agentTaskBox, db.agentTaskBox.keys.toList(), incomplete);
    await _runner.deleteKeys('工作区记录清理失败', db.workModeWorkspaceBox,
        db.workModeWorkspaceBox.keys.toList(), incomplete);
    await _runner.attempt('角色长期记忆重置失败', incomplete, () async {
      var scanned = 0;
      for (final character in db.aiCharacterBox.values) {
        character.memorySummary = '';
        character.hourlyReplyCount = 0;
        character.lastReplyTimestamp = null;
        await db.aiCharacterBox.put(character.id, character);
        if (++scanned % HiveDeletionRunner.batchSize == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    });

    if (scope != DataClearScope.chatContent) {
      await _runner.deleteKeys('技能清理失败', db.characterSkillBox,
          db.characterSkillBox.keys.toList(), incomplete);
      await _runner.deleteKeys(
          '群聊清理失败', db.chatGroupBox, db.chatGroupBox.keys.toList(), incomplete);
      await _runner.deleteKeys('角色清理失败', db.aiCharacterBox,
          db.aiCharacterBox.keys.toList(), incomplete);
      final deletableConfigIds = <String>[];
      for (final configId in configIds) {
        final deleted = await _runner.attempt(
          'API 凭据删除失败',
          incomplete,
          () async {
            if (!credentials.secureStorageAvailable) return;
            final result = await credentials.delete(configId);
            if (!result.isSuccess) {
              throw StateError('credential deletion failed');
            }
          },
        );
        if (deleted) {
          deletableConfigIds.add(configId);
        }
      }
      await _runner.deleteKeys(
          'API 配置清理失败', db.apiConfigBox, deletableConfigIds, incomplete);
      await _runner.attempt('外部配置清理失败', incomplete, clearExternalSettings);
    }

    await _runner.attempt('设置清理失败', incomplete, () async {
      switch (scope) {
        case DataClearScope.chatContent:
          await _settings.clearConversationSettings();
        case DataClearScope.userContent:
          await _settings.clearExceptPreferences();
        case DataClearScope.factoryReset:
          await _settings.clearExceptPendingOperation();
      }
      db.resetLifecycleCaches();
    });
    return _finish(incomplete, await cleanupOrphanMedia());
  }

  Future<void> _clearReplyReferences(Set<String> deletedMessageIds) async {
    if (deletedMessageIds.isEmpty) return;
    var scanned = 0;
    for (final message in db.messageBox.values) {
      if (deletedMessageIds.contains(message.replyToMessageId)) {
        message.replyToMessageId = null;
        await db.messageBox.put(message.id, message);
      }
      if (++scanned % HiveDeletionRunner.batchSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
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
