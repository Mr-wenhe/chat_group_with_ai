import 'dart:io';

import 'package:hive/hive.dart';

import 'package:chat_group/core/database/database_mutation_gate.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_planner.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/database/hive_deletion_runner.dart';
import 'package:chat_group/core/database/managed_media_store.dart';
import 'package:chat_group/core/database/relationship_snapshot_rebuilder.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/debug_credential_cache.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/agentic/skill_resource_pack_store.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/settings/ai_speaker_picker_settings.dart';
import 'package:chat_group/features/web_search/application/search_cache_controller.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:flutter/foundation.dart';

part 'data_lifecycle_service_deletion.dart';
part 'data_lifecycle_service_character.dart';
part 'data_lifecycle_service_clear.dart';
part 'data_lifecycle_service_helpers.dart';

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
  final SearchProviderConfigStore? searchProviderConfigStore;
  final Future<void> Function() clearExternalSettings;

  /// Work-mode services are app-scoped and therefore must be quiesced before
  /// a global clear removes their event/snapshot directories. These callbacks
  /// are optional so focused lifecycle operations and non-work-mode callers do
  /// not need to construct the coordinator graph.
  final Future<void> Function()? stopWorkModeTasks;
  final Future<void> Function()? clearWorkModeArtifacts;
  final Future<void> Function()? resumeWorkModeTasks;
  final Future<DataLifecycleResult> Function(Iterable<String> paths)?
      cleanupMediaPathsOverride;
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
  late final AiGovernanceStore _governance = AiGovernanceStore.forDatabase(db);
  late final DatabaseMutationGate _mutationGate =
      DatabaseMutationGate.forBox(db.appSettingsBox);

  SearchProviderConfigStore get _searchSettings =>
      searchProviderConfigStore ?? SearchProviderConfigStore(db: db);

  DataLifecycleService({
    required this.db,
    Directory? managedMediaDirectory,
    CredentialRepository? credentials,
    Future<void> Function()? clearExternalSettings,
    this.stopWorkModeTasks,
    this.clearWorkModeArtifacts,
    this.resumeWorkModeTasks,
    this.searchProviderConfigStore,
    this.cleanupMediaPathsOverride,
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
    if (config == null) return;
    final hasCredentialBinding =
        config.hasCredential || config.credentialId.trim().isNotEmpty;
    final isDevelopmentHiveCredential = !kReleaseMode &&
        config.credentialId ==
            CredentialRepository.developmentHiveCredentialId &&
        config.legacyApiKeyForMigration?.isNotEmpty == true;
    if (!hasCredentialBinding || isDevelopmentHiveCredential) {
      // 开发回退的密钥存在记录自身的 `_legacyApiKey` 里，随记录一起删。但调试
      // 镜像可能已有一份来自种子化的副本，必须一并丢掉，否则机密留在磁盘上。
      await DebugCredentialCache.forget(credentials.credentialIdFor(configId));
      return;
    }
    // Only repository-owned identifiers can be deleted from secure storage.
    // Deleting the canonical key for hand-edited/corrupt metadata would remove
    // an unrelated credential while still leaving the unknown key orphaned.
    if (config.credentialId.isNotEmpty &&
        config.credentialId != credentials.credentialIdFor(config.id)) {
      throw StateError('unknown credential binding');
    }
    if (!credentials.secureStorageAvailable) {
      throw StateError('credential storage unavailable');
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
    bool invalidateGroupMemory = true,
    bool keepReplyReferences = false,
  }) =>
      _runLifecycleMutation(
        () => _deleteMessage(
          messageId,
          groupId: groupId,
          invalidateGroupMemory: invalidateGroupMemory,
          keepReplyReferences: keepReplyReferences,
        ),
      );

  /// 批量删除同一个会话里的多条消息。
  ///
  /// 语义与 [deleteMessage] 完全一致：不动群记忆、角色记忆与心情，引用指针
  /// 原样保留（被引用方据此显示「原消息已删除」）。计划阶段只接受确实存在且
  /// 属于 [groupId] 的 id —— 传入集合里混进一个越界 id 就会删掉别的会话的消息。
  Future<DataLifecycleResult> deleteMessages(
    Iterable<String> messageIds, {
    required String groupId,
  }) =>
      _runLifecycleMutation(
        () => _deleteMessages(messageIds, groupId: groupId),
      );

  /// 清空一个会话的消息，记忆、关系、任务与工作区全部保留。
  ///
  /// 与 [clearConversation] 的分界就在这里：那条路连场合记忆、关系、任务和
  /// 工作区一起删，这条只把气泡清干净。
  Future<DataLifecycleResult> clearConversationMessages(
    String conversationId,
  ) =>
      _runLifecycleMutation(
        () => _clearConversationMessages(conversationId),
      );

  Future<DataLifecycleResult> deleteGroup(
    String groupId, {
    bool deleteAssociatedPermanentData = false,
  }) =>
      _runLifecycleMutation(
        () => _deleteGroup(
          groupId,
          deleteAssociatedPermanentData: deleteAssociatedPermanentData,
        ),
      );

  Future<DataLifecycleResult> deleteCharacter(
    String characterId, {
    required CharacterDeletionPolicy policy,
  }) =>
      _runLifecycleMutation(
        () => _deleteCharacter(characterId, policy: policy),
      );

  Future<DataLifecycleResult> deleteApiConfig(
    String configId, {
    String? replacementConfigId,
  }) =>
      _runLifecycleMutation(
        () => _deleteApiConfig(
          configId,
          replacementConfigId: replacementConfigId,
        ),
      );

  Future<DataLifecycleResult> clear(DataClearScope scope) =>
      _runLifecycleMutation(() => _clear(scope));

  Future<DataLifecycleResult> clearConversation(
    String conversationId, {
    bool deleteAssociatedPermanentData = false,
  }) =>
      _runLifecycleMutation(
        () => _clearConversation(
          conversationId,
          deleteAssociatedPermanentData: deleteAssociatedPermanentData,
        ),
      );

  Future<DataLifecycleResult> retryPendingOperation() =>
      _runLifecycleMutation(_retryPendingOperation);

  Future<T> _runLifecycleMutation<T>(Future<T> Function() operation) =>
      _mutationGate.run(operation, invalidateEpoch: true);

  Future<DataLifecycleResult> _deleteMessage(
    String messageId, {
    required String groupId,
    bool invalidateGroupMemory = true,
    bool keepReplyReferences = false,
  }) async {
    final targets = await _planMessage(
      messageId,
      groupId,
      invalidateGroupMemory: invalidateGroupMemory,
      keepReplyReferences: keepReplyReferences,
    );
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

  Future<DataLifecycleResult> _deleteMessages(
    Iterable<String> messageIds, {
    required String groupId,
  }) async {
    final targets = await _planMessages(messageIds, groupId);
    if (!await _begin({
      'kind': 'messages',
      'groupId': groupId,
      'targets': targets.toMap(),
    })) {
      return _pendingOperationConflict();
    }
    return _runMessagesDeletion(groupId, targets: targets);
  }

  Future<DataLifecycleResult> _clearConversationMessages(
    String conversationId,
  ) async {
    final targets = await _planConversationMessages(conversationId);
    if (!await _begin({
      'kind': 'conversationMessages',
      'id': conversationId,
      'targets': targets.toMap(),
    })) {
      return _pendingOperationConflict();
    }
    return _runConversationMessageClear(conversationId, targets: targets);
  }

  Future<DataLifecycleResult> _deleteGroup(
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

  Future<DataLifecycleResult> _deleteCharacter(
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

  Future<DataLifecycleResult> _deleteApiConfig(
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

  Future<DataLifecycleResult> _clear(DataClearScope scope) async {
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

  Future<DataLifecycleResult> _clearConversation(
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

  Future<DataLifecycleResult> _retryPendingOperation() async {
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
      case 'messages':
        // 计划（含 mediaPaths）在 _begin 时就一起落盘了，所以崩溃后能原样重试：
        // 少了这个分支，一次中断的批量删除会留下永远无法重试的待办标记，
        // 而它会让此后所有生命周期操作都被 _begin 挡下。
        return _runMessagesDeletion(
          job['groupId']?.toString() ?? '',
          targets: targets,
        );
      case 'conversationMessages':
        return _runConversationMessageClear(id, targets: targets);
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
    final result = cleanupMediaPathsOverride == null
        ? await _media.cleanupPaths(values)
        : await cleanupMediaPathsOverride!(values);
    DocumentUnderstandingService.evictPaths(values);
    return result;
  }
}
