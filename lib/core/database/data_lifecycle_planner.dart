import 'package:hive/hive.dart';

import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/hive_deletion_runner.dart';
import 'package:chat_group/core/database/managed_media_store.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

/// Resolves destructive targets before any write begins.
///
/// The plan is also used as the persisted pending-operation target set. This
/// keeps retries bounded to the original operation even if new records appear
/// while a partial delete is waiting for user retry.
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

  Future<DeletionPlan> previewGroup(
    String groupId, {
    bool deleteAssociatedPermanentData = false,
  }) async {
    final messages = await _keys<Message>(
      db.messageBox,
      (message) => message.groupId == groupId,
    );
    final messageIds = messages.whereType<String>().toSet();
    final groupMemories = await _keys(
      db.groupMemoryBox,
      (item) => item.groupId == groupId,
    );
    final characterMemories = await _keys(
      db.characterMemoryBox,
      (item) => item.groupId == groupId,
    );
    final legacyRelationships = await _keys(
      db.relationshipStateBox,
      (item) => item.groupId == groupId,
    );
    final tasks = await _keys(
      db.agentTaskBox,
      (item) => item.groupId == groupId,
    );
    final workspaces = await _keys(
      db.workModeWorkspaceBox,
      (item) => item.conversationId == groupId,
    );
    final permanentMemories = await _keys(
      db.permanentMemoryBox,
      (item) => item.originConversationId == groupId,
    );
    final relationshipEvents = await _keys(
      db.relationshipEventBox,
      (item) => item.originConversationId == groupId,
    );
    final eventValues = relationshipEvents
        .map(db.relationshipEventBox.get)
        .whereType<RelationshipEvent>()
        .toList(growable: false);
    final replyReferences = await _keys<Message>(
      db.messageBox,
      (message) =>
          message.replyToMessageId != null &&
          messageIds.contains(message.replyToMessageId),
    );
    final usage = await media.usage(excludedMessageIds: messageIds);
    final legacyCount = legacyRelationships.length;
    final sessionIndexCount = settings.conversationSessionIndexCount(
      groupId,
      isGroup: true,
    );
    final memoryPinCount = settings.conversationMemoryPinCount(
      groupId,
      isGroup: true,
      characterMemoryKeys: characterMemories,
    );
    final retryRecordCount = settings.conversationRetryRecordCount(groupId);
    final targets = DeletionTargets(
      boxKeys: {
        DeletionTargetNames.chatGroups: db.chatGroupBox.containsKey(groupId)
            ? [groupId]
            : const <dynamic>[],
        DeletionTargetNames.messages: messages,
        DeletionTargetNames.groupMemories: groupMemories,
        DeletionTargetNames.characterMemories: characterMemories,
        DeletionTargetNames.relationshipStates: legacyRelationships,
        DeletionTargetNames.agentTasks: tasks,
        DeletionTargetNames.workspaces: workspaces,
        DeletionTargetNames.permanentMemories: permanentMemories,
        DeletionTargetNames.relationshipEvents: relationshipEvents,
        DeletionTargetNames.replyReferences: replyReferences,
      },
      relationshipIds: eventValues
          .map(RelationshipSnapshotRebuilderId.fromEvent)
          .toSet()
          .toList()
        ..sort(),
      appSettings: settings.planConversation(
        groupId,
        isGroup: true,
        characterMemoryKeys: characterMemories,
      ),
    );
    return DeletionPlan(
      title: '删除群聊',
      counts: {
        'groups': db.chatGroupBox.containsKey(groupId) ? 1 : 0,
        'messages': messages.length,
        'groupMemories': groupMemories.length,
        'characterMemories': characterMemories.length,
        'legacyRelationshipStates': legacyCount,
        'relationshipStates': legacyCount,
        'relationships': legacyCount,
        'tasks': tasks.length,
        'workspaces': workspaces.length,
        'settings': settings.conversationSettingCount(groupId, isGroup: true),
        'sessionIndexes': sessionIndexCount,
        'memoryPins': memoryPinCount,
        'retryRecords': retryRecordCount,
        'attachments': usage.orphanFiles,
        if (deleteAssociatedPermanentData) ...{
          'permanentMemories': permanentMemories.length,
          'relationshipEvents': relationshipEvents.length,
        },
      },
      optionalCounts: deleteAssociatedPermanentData
          ? const {}
          : {
              'permanentMemories': permanentMemories.length,
              'relationshipEvents': relationshipEvents.length,
            },
      retainedCounts: {
        'permanentMemories': db.permanentMemoryBox.length -
            (deleteAssociatedPermanentData ? permanentMemories.length : 0),
        'relationshipEvents': db.relationshipEventBox.length -
            (deleteAssociatedPermanentData ? relationshipEvents.length : 0),
        'globalRelationshipStates': db.relationshipStateBox.values
            .where((state) => state.groupId == 'global')
            .length,
      },
      targets: targets,
    );
  }

  Future<DeletionPlan> previewConversation(
    String conversationId, {
    bool deleteAssociatedPermanentData = false,
  }) async {
    final isGroup = !DirectChatSession.isDirectConversationId(conversationId);
    final messages = await _keys<Message>(
      db.messageBox,
      (message) => message.groupId == conversationId,
    );
    final messageIds = messages.whereType<String>().toSet();
    final groupMemories = await _keys(
      db.groupMemoryBox,
      (item) => item.groupId == conversationId,
    );
    final characterMemories = await _keys(
      db.characterMemoryBox,
      (item) => item.groupId == conversationId,
    );
    final legacyRelationships = await _keys(
      db.relationshipStateBox,
      (item) => item.groupId == conversationId,
    );
    final tasks = await _keys(
      db.agentTaskBox,
      (item) => item.groupId == conversationId,
    );
    final workspaces = await _keys(
      db.workModeWorkspaceBox,
      (item) => item.conversationId == conversationId,
    );
    final permanentMemories = await _keys(
      db.permanentMemoryBox,
      (item) => item.originConversationId == conversationId,
    );
    final relationshipEvents = await _keys(
      db.relationshipEventBox,
      (item) => item.originConversationId == conversationId,
    );
    final eventValues = relationshipEvents
        .map(db.relationshipEventBox.get)
        .whereType<RelationshipEvent>()
        .toList(growable: false);
    final replyReferences = await _keys<Message>(
      db.messageBox,
      (message) =>
          message.replyToMessageId != null &&
          messageIds.contains(message.replyToMessageId),
    );
    final usage = await media.usage(excludedMessageIds: messageIds.toSet());
    final legacyCount = legacyRelationships.length;
    final sessionIndexCount = settings.conversationSessionIndexCount(
      conversationId,
      isGroup: isGroup,
    );
    final memoryPinCount = settings.conversationMemoryPinCount(
      conversationId,
      isGroup: isGroup,
      characterMemoryKeys: characterMemories,
    );
    final retryRecordCount =
        settings.conversationRetryRecordCount(conversationId);
    final targets = DeletionTargets(
      boxKeys: {
        DeletionTargetNames.messages: messages,
        DeletionTargetNames.groupMemories: groupMemories,
        DeletionTargetNames.characterMemories: characterMemories,
        DeletionTargetNames.relationshipStates: legacyRelationships,
        DeletionTargetNames.agentTasks: tasks,
        DeletionTargetNames.workspaces: workspaces,
        DeletionTargetNames.permanentMemories: permanentMemories,
        DeletionTargetNames.relationshipEvents: relationshipEvents,
        DeletionTargetNames.replyReferences: replyReferences,
      },
      relationshipIds: eventValues
          .map(RelationshipSnapshotRebuilderId.fromEvent)
          .toSet()
          .toList()
        ..sort(),
      appSettings: settings.planConversation(
        conversationId,
        isGroup: isGroup,
        characterMemoryKeys: characterMemories,
      ),
    );
    final defaultCounts = <String, int>{
      'groups': isGroup && db.chatGroupBox.containsKey(conversationId) ? 1 : 0,
      'messages': messages.length,
      'groupMemories': groupMemories.length,
      'characterMemories': characterMemories.length,
      'legacyRelationshipStates': legacyCount,
      'relationshipStates': legacyCount,
      'relationships': legacyCount,
      'tasks': tasks.length,
      'workspaces': workspaces.length,
      'settings': settings.conversationSettingCount(
        conversationId,
        isGroup: isGroup,
      ),
      'sessionIndexes': sessionIndexCount,
      'memoryPins': memoryPinCount,
      'retryRecords': retryRecordCount,
      'attachments': usage.orphanFiles,
    };
    if (deleteAssociatedPermanentData) {
      defaultCounts['permanentMemories'] = permanentMemories.length;
      defaultCounts['relationshipEvents'] = relationshipEvents.length;
    }
    return DeletionPlan(
      title: isGroup ? '清空群聊' : '清空私聊',
      counts: defaultCounts,
      optionalCounts: deleteAssociatedPermanentData
          ? const {}
          : {
              'permanentMemories': permanentMemories.length,
              'relationshipEvents': relationshipEvents.length,
            },
      retainedCounts: {
        'permanentMemories': db.permanentMemoryBox.length -
            (deleteAssociatedPermanentData ? permanentMemories.length : 0),
        'relationshipEvents': db.relationshipEventBox.length -
            (deleteAssociatedPermanentData ? relationshipEvents.length : 0),
        'globalRelationshipStates': db.relationshipStateBox.values
            .where((state) => state.groupId == 'global')
            .length,
      },
      targets: targets,
    );
  }

  Future<DeletionPlan> previewCharacter(
    String characterId, {
    CharacterDeletionPolicy policy = CharacterDeletionPolicy.keepMessageHistory,
  }) async {
    final conversationId = DirectChatSession.conversationIdFor(characterId);
    final directMessages = await _keys<Message>(
      db.messageBox,
      (message) => message.groupId == conversationId,
    );
    final directIds = directMessages.whereType<String>().toSet();
    final mentionReferences = await _keys<Message>(
      db.messageBox,
      (message) => message.mentionedAiIds.contains(characterId),
    );
    final replyReferences = await _keys<Message>(
      db.messageBox,
      (message) =>
          message.replyToMessageId != null &&
          directIds.contains(message.replyToMessageId),
    );
    final groups = await _keys(
      db.chatGroupBox,
      (group) => group.aiCharacterIds.contains(characterId),
    );
    final skills = await _keys(
      db.characterSkillBox,
      (skill) => skill.characterId == characterId,
    );
    final tasks = await _keys(
      db.agentTaskBox,
      (task) => task.characterId == characterId,
    );
    final characterMemories = await _keys(
      db.characterMemoryBox,
      (memory) => memory.characterId == characterId,
    );
    final observerPermanentMemoryKeys = await _keys(
      db.permanentMemoryBox,
      (memory) => memory.observerCharacterId == characterId,
    );
    final subjectPermanentMemoryKeys = await _keys(
      db.permanentMemoryBox,
      (memory) => memory.subjectIds.contains(characterId),
    );
    final permanentMemories = await _keys(
      db.permanentMemoryBox,
      (memory) => policy == CharacterDeletionPolicy.deleteRelatedData
          ? memory.observerCharacterId == characterId ||
              memory.subjectIds.contains(characterId)
          : memory.observerCharacterId == characterId,
    );
    final relationshipStates = await _keys(
      db.relationshipStateBox,
      (relation) => _relationReferencesCharacter(relation, characterId,
          includeTarget: policy == CharacterDeletionPolicy.deleteRelatedData),
    );
    final sourceRelationshipStateKeys = await _keys(
      db.relationshipStateBox,
      (relation) => relation.sourceCharacterId == characterId,
    );
    final targetRelationshipStateKeys = await _keys(
      db.relationshipStateBox,
      (relation) =>
          relation.targetType == RelationshipTargetType.ai &&
          relation.targetId == characterId,
    );
    final relationshipEvents = await _keys(
      db.relationshipEventBox,
      (event) => _eventReferencesCharacter(event, characterId,
          includeTarget: policy == CharacterDeletionPolicy.deleteRelatedData),
    );
    final sourceRelationshipEventKeys = await _keys(
      db.relationshipEventBox,
      (event) => event.sourceCharacterId == characterId,
    );
    final targetRelationshipEventKeys = await _keys(
      db.relationshipEventBox,
      (event) =>
          event.targetType == RelationshipTargetType.ai &&
          event.targetId == characterId,
    );
    final eventValues = relationshipEvents
        .map(db.relationshipEventBox.get)
        .whereType<RelationshipEvent>()
        .toList(growable: false);
    final relationIds = <String>{
      ...relationshipStates
          .map(db.relationshipStateBox.get)
          .whereType<RelationshipState>()
          .map(RelationshipSnapshotRebuilderId.fromState),
      ...eventValues.map(RelationshipSnapshotRebuilderId.fromEvent),
    }..removeWhere((id) => id.isEmpty);
    final workspaceKeys = await _keys(
      db.workModeWorkspaceBox,
      (workspace) => workspace.conversationId == conversationId,
    );
    final usage = await media.usage(
      excludedMessageIds: policy == CharacterDeletionPolicy.deleteRelatedData
          ? directIds
          : const {},
    );
    final directSettings = settings.conversationSettingCount(
      conversationId,
      isGroup: false,
    );
    final sessionIndexCount = settings.conversationSessionIndexCount(
      conversationId,
      isGroup: false,
    );
    final rolePins = _countRelationshipPins(relationIds, characterId);
    final memoryPinCount = settings.characterMemoryPinCount(
      characterId,
      characterMemoryKeys: characterMemories,
      relationshipIds: relationIds,
    );
    final retryRecordCount =
        settings.characterRetryRecordCount(characterId, conversationId);
    final fullDelete = policy == CharacterDeletionPolicy.deleteRelatedData;
    final targets = DeletionTargets(
      boxKeys: {
        DeletionTargetNames.aiCharacters:
            db.aiCharacterBox.containsKey(characterId)
                ? [characterId]
                : const <dynamic>[],
        DeletionTargetNames.chatGroups: groups,
        DeletionTargetNames.messages: directMessages,
        DeletionTargetNames.characterMemories: characterMemories,
        DeletionTargetNames.characterSkills: skills,
        DeletionTargetNames.agentTasks: tasks,
        DeletionTargetNames.workspaces: workspaceKeys,
        DeletionTargetNames.permanentMemories: permanentMemories,
        DeletionTargetNames.relationshipStates: relationshipStates,
        DeletionTargetNames.relationshipEvents: relationshipEvents,
        DeletionTargetNames.mentionReferences: mentionReferences,
        DeletionTargetNames.replyReferences: replyReferences,
      },
      relationshipIds: relationIds.toList()..sort(),
      appSettings: settings.planCharacter(
        characterId,
        conversationId,
        removeConversation: fullDelete,
        characterMemoryKeys: characterMemories,
      ),
    );
    final counts = <String, int>{
      'characters': db.aiCharacterBox.containsKey(characterId) ? 1 : 0,
      'groups': groups.length,
      'directMessages': fullDelete ? directMessages.length : 0,
      'skills': skills.length,
      'tasks': tasks.length,
      'characterMemories': characterMemories.length,
      'memories': permanentMemories.length,
      'observerPermanentMemories': observerPermanentMemoryKeys.length,
      'subjectPermanentMemories': subjectPermanentMemoryKeys.length,
      'relationships': relationshipStates.length,
      'relationshipStates': relationshipStates.length,
      'relationshipEvents': relationshipEvents.length,
      'sourceRelationshipStates': sourceRelationshipStateKeys.length,
      'targetRelationshipStates': targetRelationshipStateKeys.length,
      'sourceRelationshipEvents': sourceRelationshipEventKeys.length,
      'targetRelationshipEvents': targetRelationshipEventKeys.length,
      'workspaces': workspaceKeys.length,
      'settings': fullDelete ? directSettings : 0,
      'sessionIndexes': fullDelete ? sessionIndexCount : 0,
      'memoryPins': memoryPinCount,
      'retryRecords': retryRecordCount,
      'pins': rolePins,
      'mentions': mentionReferences.length,
      'attachments': fullDelete ? usage.orphanFiles : 0,
    };
    final optionalCounts = fullDelete
        ? const <String, int>{}
        : {
            'directMessages': directMessages.length,
            'settings': directSettings,
            'attachments': usage.orphanFiles,
          };
    return DeletionPlan(
      title: '删除角色',
      counts: counts,
      optionalCounts: optionalCounts,
      retainedCounts: {
        'directMessages': fullDelete ? 0 : directMessages.length,
        'permanentMemories':
            db.permanentMemoryBox.length - permanentMemories.length,
        'relationshipEvents':
            db.relationshipEventBox.length - relationshipEvents.length,
        'groupMessages': db.messageBox.values
            .where((message) => message.groupId != conversationId)
            .length,
      },
      targets: targets,
    );
  }

  Future<DeletionPlan> previewApiConfig(String configId) async {
    final characters = await _keys(
      db.aiCharacterBox,
      (character) => character.apiConfigId == configId,
    );
    return DeletionPlan(
      title: '删除 API 配置',
      counts: {'characters': characters.length},
      targets: DeletionTargets(
        boxKeys: {
          DeletionTargetNames.apiConfigs: db.apiConfigBox.containsKey(configId)
              ? [configId]
              : const <dynamic>[],
          DeletionTargetNames.aiCharacters: characters,
        },
      ),
    );
  }

  Future<DeletionPlan> previewClear(DataClearScope scope) async {
    final messages = await _allKeys(db.messageBox);
    final groupMemories = await _allKeys(db.groupMemoryBox);
    final characterMemories = await _allKeys(db.characterMemoryBox);
    final relationshipStates = await _keys(
      db.relationshipStateBox,
      (state) =>
          scope != DataClearScope.chatContent || state.groupId != 'global',
    );
    final relationshipEvents = scope == DataClearScope.chatContent
        ? const <dynamic>[]
        : await _allKeys(db.relationshipEventBox);
    final permanentMemories = scope == DataClearScope.chatContent
        ? const <dynamic>[]
        : await _allKeys(db.permanentMemoryBox);
    final tasks = await _allKeys(db.agentTaskBox);
    final workspaces = await _allKeys(db.workModeWorkspaceBox);
    final skills = scope == DataClearScope.chatContent
        ? const <dynamic>[]
        : await _allKeys(db.characterSkillBox);
    final groups = scope == DataClearScope.chatContent
        ? const <dynamic>[]
        : await _allKeys(db.chatGroupBox);
    final characters = scope == DataClearScope.chatContent
        ? await _keys(db.aiCharacterBox,
            (character) => character.memorySummary.trim().isNotEmpty)
        : await _allKeys(db.aiCharacterBox);
    final configs = scope == DataClearScope.chatContent
        ? const <dynamic>[]
        : await _allKeys(db.apiConfigBox);
    final profiles = scope == DataClearScope.chatContent
        ? const <dynamic>[]
        : await _allKeys(db.userProfileBox);
    final allMessageIds = messages.whereType<String>().toSet();
    final usage = await media.usage(excludedMessageIds: allMessageIds);
    final sessionIndexCount = settings.allSessionIndexCount();
    final memoryPinCount = settings.clearMemoryPinCount(
      preserveGlobalRelationshipPins: scope == DataClearScope.chatContent,
    );
    final retryRecordCount = settings.allRetryRecordCount();
    final targetMap = <String, List<dynamic>>{
      DeletionTargetNames.messages: messages,
      DeletionTargetNames.groupMemories: groupMemories,
      DeletionTargetNames.characterMemories: characterMemories,
      DeletionTargetNames.relationshipStates: relationshipStates,
      DeletionTargetNames.relationshipEvents: relationshipEvents,
      DeletionTargetNames.permanentMemories: permanentMemories,
      DeletionTargetNames.agentTasks: tasks,
      DeletionTargetNames.workspaces: workspaces,
      DeletionTargetNames.characterSkills: skills,
      DeletionTargetNames.chatGroups: groups,
      DeletionTargetNames.aiCharacters: characters,
      DeletionTargetNames.apiConfigs: configs,
      DeletionTargetNames.userProfiles: profiles,
    };
    final counts = <String, int>{
      'messages': messages.length,
      'groupMemories': groupMemories.length,
      'characterMemories': characterMemories.length,
      'relationshipStates': relationshipStates.length,
      'relationships': relationshipStates.length,
      'relationshipEvents': relationshipEvents.length,
      'permanentMemories': permanentMemories.length,
      'tasks': tasks.length,
      'agentTasks': tasks.length,
      'workspaces': workspaces.length,
      'characterSkills': skills.length,
      'skills': skills.length,
      'groups': groups.length,
      'aiCharacters':
          scope == DataClearScope.chatContent ? 0 : characters.length,
      'characters': scope == DataClearScope.chatContent ? 0 : characters.length,
      'apiConfigs': configs.length,
      'credentials': configs
          .map(db.apiConfigBox.get)
          .whereType()
          .where((config) => config.hasCredential)
          .length,
      'userProfiles': profiles.length,
      'legacySummaries': scope == DataClearScope.chatContent
          ? characters.length
          : db.aiCharacterBox.values
              .where((character) => character.memorySummary.trim().isNotEmpty)
              .length,
      'settings': _settingsCountForClear(scope),
      'sessionIndexes': sessionIndexCount,
      'memoryPins': memoryPinCount,
      'retryRecords': retryRecordCount,
      'attachments': usage.orphanFiles,
    };
    final retainedCounts = scope == DataClearScope.chatContent
        ? {
            'aiCharacters': db.aiCharacterBox.length,
            'groups': db.chatGroupBox.length,
            'apiConfigs': db.apiConfigBox.length,
            'permanentMemories': db.permanentMemoryBox.length,
            'relationshipEvents': db.relationshipEventBox.length,
            'globalRelationshipStates': db.relationshipStateBox.values
                .where((state) => state.groupId == 'global')
                .length,
            'userProfiles': db.userProfileBox.length,
          }
        : const <String, int>{};
    return DeletionPlan(
      title: switch (scope) {
        DataClearScope.chatContent => '清除聊天内容',
        DataClearScope.userContent => '清除全部用户内容',
        DataClearScope.factoryReset => '恢复出厂设置',
      },
      counts: counts,
      retainedCounts: retainedCounts,
      targets: DeletionTargets(
        boxKeys: targetMap,
        appSettings: settings.planClear(scope),
      ),
    );
  }

  Future<List<dynamic>> _allKeys<T>(Box<T> box) async =>
      List<dynamic>.from(box.keys);

  Future<List<dynamic>> _keys<T>(
    Box<T> box,
    bool Function(T value) matches,
  ) async =>
      await runner.matchingKeys(box, matches);

  bool _relationReferencesCharacter(
    RelationshipState relation,
    String characterId, {
    required bool includeTarget,
  }) {
    return relation.sourceCharacterId == characterId ||
        (includeTarget &&
            relation.targetType == RelationshipTargetType.ai &&
            relation.targetId == characterId);
  }

  bool _eventReferencesCharacter(
    dynamic event,
    String characterId, {
    required bool includeTarget,
  }) {
    return event.sourceCharacterId == characterId ||
        (includeTarget &&
            event.targetType == RelationshipTargetType.ai &&
            event.targetId == characterId);
  }

  int _countRelationshipPins(Set<String> relationshipIds, String characterId) {
    final raw = db.appSettingsBox.get('memory_pinned_keys_v1');
    if (raw is! List) return 0;
    return raw.whereType<String>().where((pin) {
      if (pin == 'legacy:$characterId') return true;
      return pin.startsWith('relationship:') &&
          relationshipIds.contains(pin.substring('relationship:'.length));
    }).length;
  }

  int _settingsCountForClear(DataClearScope scope) {
    if (scope == DataClearScope.factoryReset) return db.appSettingsBox.length;
    final preserved = scope == DataClearScope.chatContent
        ? const {
            'theme_mode',
            'app_skin_mode',
            'tts_enabled',
            'ai_processing_dir'
          }
        : const {
            'theme_mode',
            'app_skin_mode',
            'tts_enabled',
            'ai_processing_dir'
          };
    return db.appSettingsBox.keys
        .where((key) => !preserved.contains(key.toString()))
        .length;
  }
}

/// Keeps planner code independent from the feature-level relationship service.
class RelationshipSnapshotRebuilderId {
  const RelationshipSnapshotRebuilderId._();

  static String fromEvent(dynamic event) => RelationshipState.stableGlobalId(
        event.sourceCharacterId,
        event.targetType,
        event.targetId,
      );

  static String fromState(RelationshipState state) =>
      RelationshipState.stableGlobalId(
        state.sourceCharacterId,
        state.targetType,
        state.targetId,
      );
}
