part of 'data_lifecycle_planner.dart';

extension DataLifecyclePlannerClear on DataLifecyclePlanner {
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
    final searchConfigs = scope == DataClearScope.chatContent
        ? const <dynamic>[]
        : _searchProviderConfigRecords();
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
      DeletionTargetNames.searchProviderConfigs: searchConfigs
          .map((config) => config['id'])
          .whereType<String>()
          .toList(growable: false),
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
      'searchProviderConfigs': searchConfigs.length,
      'searchCredentials': searchConfigs
          .where(
            (config) =>
                config['hasCredential'] == true ||
                config['credentialRequired'] == true ||
                (config['credentialId']?.toString().isNotEmpty ?? false),
          )
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
            'searchProviderConfigs': _searchProviderConfigRecords().length,
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

  List<Map<String, dynamic>> _searchProviderConfigRecords() {
    final raw = db.appSettingsBox.get('web_search_provider_configs_v1');
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        // Hive data is user-controlled and can contain non-string keys after
        // a damaged import. Convert records independently so one bad record
        // does not abort the whole deletion preview.
        .map(_safeStringDynamicMap)
        .whereType<Map<String, dynamic>>()
        .where((item) => item['id']?.toString().trim().isNotEmpty == true)
        .toList(growable: false);
  }

  Map<String, dynamic>? _safeStringDynamicMap(Map<dynamic, dynamic> raw) {
    final result = <String, dynamic>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) return null;
      result[entry.key as String] = entry.value;
    }
    return result;
  }

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
            'ai_processing_dir',
            'work_mode_folder_grants_v1',
            'work_mode_agent_settings_v1',
          }
        : const {
            'theme_mode',
            'app_skin_mode',
            'tts_enabled',
            'ai_processing_dir',
            'work_mode_folder_grants_v1',
            'work_mode_agent_settings_v1',
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
