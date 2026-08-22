part of 'restore_executor.dart';

class _RestorePlan {
  final List<Map<String, dynamic>> apiConfigs;
  final List<Map<String, dynamic>> characters;
  final List<Map<String, dynamic>> groups;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> groupMemories;
  final List<Map<String, dynamic>> characterMemories;
  final List<Map<String, dynamic>> relationships;
  final List<Map<String, dynamic>> userProfiles;
  final List<Map<String, dynamic>> permanentMemories;
  final List<Map<String, dynamic>> relationshipEvents;
  final List<Map<String, dynamic>> skills;
  final List<Map<String, dynamic>> tasks;
  final List<Map<String, dynamic>> workspaces;
  final Map<String, dynamic> settings;
  final Map<String, int> skipped;
  final Map<String, int> remapped;
  final bool isV1;
  final bool isConversation;
  final bool restoreGlobalRelationships;
  final bool requiresImportMarker;

  const _RestorePlan({
    required this.apiConfigs,
    required this.characters,
    required this.groups,
    required this.messages,
    required this.groupMemories,
    required this.characterMemories,
    required this.relationships,
    required this.userProfiles,
    required this.permanentMemories,
    required this.relationshipEvents,
    required this.skills,
    required this.tasks,
    required this.workspaces,
    required this.settings,
    required this.skipped,
    required this.remapped,
    required this.isV1,
    required this.isConversation,
    required this.restoreGlobalRelationships,
    required this.requiresImportMarker,
  });

  factory _RestorePlan.build(
    DatabaseService db,
    StagedBackupData data,
    RestoreConflictStrategy strategy,
    BackupManifest manifest,
  ) {
    final skipped = <String, int>{};
    final remapped = <String, int>{};
    final apiMap = _mapping(data.apiConfigs, db.apiConfigBox.containsKey,
        strategy, 'apiConfigs', skipped, remapped);
    final characterMap = _mapping(
        data.characters,
        db.aiCharacterBox.containsKey,
        strategy,
        'characters',
        skipped,
        remapped);
    final groupMap = _mapping(data.groups, db.chatGroupBox.containsKey,
        strategy, 'groups', skipped, remapped);
    final skillMap = _mapping(data.skills, db.characterSkillBox.containsKey,
        strategy, 'skills', skipped, remapped);
    final messageMap = _mapping(data.messages, db.messageBox.containsKey,
        strategy, 'messages', skipped, remapped);
    final characterMemoryMap = _mapping(
        data.characterMemories,
        db.characterMemoryBox.containsKey,
        strategy,
        'characterMemories',
        skipped,
        remapped);
    final permanentMemoryMap = _mapping(
        data.permanentMemories,
        db.permanentMemoryBox.containsKey,
        strategy,
        'permanentMemories',
        skipped,
        remapped);
    final relationshipMap = _mapping(
        data.relationships,
        db.relationshipStateBox.containsKey,
        strategy,
        'relationships',
        skipped,
        remapped);
    final eventMap = _mapping(
        data.relationshipEvents,
        db.relationshipEventBox.containsKey,
        strategy,
        'relationshipEvents',
        skipped,
        remapped);
    for (final record in data.relationships) {
      final value = BackupEntityCodec.value(record);
      if (value['groupId']?.toString() != 'global') continue;
      final oldId = value['id'].toString();
      final source = characterMap[value['sourceCharacterId']] ??
          value['sourceCharacterId'].toString();
      final targetType = RelationshipTargetType.values.firstWhere(
        (type) => type.name == value['targetType'],
      );
      final target = targetType == RelationshipTargetType.ai
          ? characterMap[value['targetId']] ?? value['targetId'].toString()
          : 'user';
      final stableId =
          RelationshipState.stableGlobalId(source, targetType, target);
      if (relationshipMap[oldId] == oldId && stableId != oldId) {
        remapped['relationships'] = (remapped['relationships'] ?? 0) + 1;
      }
      relationshipMap[oldId] = stableId;
    }
    final taskMap = _mapping(data.tasks, db.agentTaskBox.containsKey, strategy,
        'agentTasks', skipped, remapped);
    final isConversation = manifest.backupKind == BackupKind.conversation;

    String conversation(String id) => id.startsWith('dm:')
        ? 'dm:${characterMap[id.substring(3)] ?? id.substring(3)}'
        : groupMap[id] ?? id;
    String? optionalConversation(Object? value) =>
        value == null ? null : conversation(value.toString());

    final apiConfigs =
        _rewrite(data.apiConfigs, apiMap, db.apiConfigBox.containsKey, strategy,
            (value) {
      value['id'] = apiMap[value['id']]!;
    });
    final skills = _rewrite(
        data.skills, skillMap, db.characterSkillBox.containsKey, strategy,
        (value) {
      value['id'] = skillMap[value['id']]!;
      value['characterId'] =
          characterMap[value['characterId']] ?? value['characterId'];
    });
    final characters = _rewrite(
        data.characters, characterMap, db.aiCharacterBox.containsKey, strategy,
        (value) {
      value['id'] = characterMap[value['id']]!;
      value['apiConfigId'] =
          apiMap[value['apiConfigId']] ?? value['apiConfigId'];
      value['skillIds'] = _mapList(value['skillIds'], skillMap);
    });
    final groups = _rewrite(
        data.groups, groupMap, db.chatGroupBox.containsKey, strategy, (value) {
      value['id'] = groupMap[value['id']]!;
      value['aiCharacterIds'] = _mapList(value['aiCharacterIds'], characterMap);
    });
    final messages =
        _rewrite(data.messages, messageMap, db.messageBox.containsKey, strategy,
            (value) {
      value['id'] = messageMap[value['id']]!;
      value['groupId'] = conversation(value['groupId'].toString());
      value['senderId'] = characterMap[value['senderId']] ?? value['senderId'];
      value['replyToMessageId'] =
          messageMap[value['replyToMessageId']] ?? value['replyToMessageId'];
      value['mentionedAiIds'] = _mapList(value['mentionedAiIds'], characterMap);
      value['visibleToCharacterIds'] =
          _mapList(value['visibleToCharacterIds'], characterMap);
    });
    final groupMemories = _rewriteStorage(
        data.groupMemories,
        db.groupMemoryBox.containsKey,
        strategy,
        'groupMemories',
        skipped,
        remapped, (key, value) {
      final oldGroup = value['groupId'].toString();
      final newGroup = groupMap[oldGroup] ?? oldGroup;
      value['groupId'] = newGroup;
      if (oldGroup == newGroup) return key;
      if (key == oldGroup) return newGroup;
      if (key.startsWith('${oldGroup}_')) {
        return '$newGroup${key.substring(oldGroup.length)}';
      }
      return '${newGroup}_${const Uuid().v4()}';
    });
    final characterMemories = _rewrite(
        data.characterMemories,
        characterMemoryMap,
        db.characterMemoryBox.containsKey,
        strategy, (value) {
      value['id'] = characterMemoryMap[value['id']]!;
      value['groupId'] = conversation(value['groupId'].toString());
      value['characterId'] =
          characterMap[value['characterId']] ?? value['characterId'];
    });
    final permanentMemories = _rewrite(
        data.permanentMemories,
        permanentMemoryMap,
        db.permanentMemoryBox.containsKey,
        strategy, (value) {
      value['id'] = permanentMemoryMap[value['id']]!;
      value['observerCharacterId'] =
          characterMap[value['observerCharacterId']] ??
              value['observerCharacterId'];
      value['subjectIds'] = _mapList(value['subjectIds'], characterMap);
      value['participantIds'] = _mapList(value['participantIds'], characterMap);
      value['sourceMessageIds'] =
          _mapList(value['sourceMessageIds'], messageMap);
      value['supersedesIds'] =
          _mapList(value['supersedesIds'], permanentMemoryMap);
      value['originConversationId'] =
          optionalConversation(value['originConversationId']);
    });
    final relationships = _rewrite(data.relationships, relationshipMap,
        db.relationshipStateBox.containsKey, strategy, (value) {
      value['id'] = relationshipMap[value['id']]!;
      final oldGroup = value['groupId']?.toString() ?? '';
      value['groupId'] =
          oldGroup == 'global' ? 'global' : conversation(oldGroup);
      value['sourceCharacterId'] = characterMap[value['sourceCharacterId']] ??
          value['sourceCharacterId'];
      if (value['targetType'] == RelationshipTargetType.ai.name) {
        value['targetId'] =
            characterMap[value['targetId']] ?? value['targetId'];
      } else {
        value['targetId'] = 'user';
      }
      value['lastEventId'] =
          eventMap[value['lastEventId']] ?? value['lastEventId'];
    });
    final relationshipEvents = _rewrite(data.relationshipEvents, eventMap,
        db.relationshipEventBox.containsKey, strategy, (value) {
      value['id'] = eventMap[value['id']]!;
      value['sourceCharacterId'] = characterMap[value['sourceCharacterId']] ??
          value['sourceCharacterId'];
      if (value['targetType'] == RelationshipTargetType.ai.name) {
        value['targetId'] =
            characterMap[value['targetId']] ?? value['targetId'];
      } else {
        value['targetId'] = 'user';
      }
      value['sourceMessageIds'] =
          _mapList(value['sourceMessageIds'], messageMap);
      value['originConversationId'] =
          optionalConversation(value['originConversationId']);
    });
    final userProfiles = _rewriteUserProfiles(data.userProfiles, db, skipped);
    final tasks = _rewrite(
        data.tasks, taskMap, db.agentTaskBox.containsKey, strategy, (value) {
      value['id'] = taskMap[value['id']]!;
      value['groupId'] = conversation(value['groupId'].toString());
      value['characterId'] =
          characterMap[value['characterId']] ?? value['characterId'];
    });
    final workspaces = _rewriteStorage(
        data.workspaces,
        db.workModeWorkspaceBox.containsKey,
        strategy,
        'workMode',
        skipped,
        remapped, (key, value) {
      final mappedConversation =
          conversation(value['conversationId'].toString());
      value['id'] = mappedConversation == value['conversationId']
          ? value['id']
          : const Uuid().v4();
      value['conversationId'] = mappedConversation;
      return mappedConversation;
    });
    final settings = _remapSettings(
      data.settings,
      characterMap,
      groupMap,
      characterMemoryMap,
      relationshipMap,
      conversation,
      db,
      strategy,
      skipped,
    );
    return _RestorePlan(
      apiConfigs: apiConfigs,
      characters: characters,
      groups: groups,
      messages: messages,
      groupMemories: groupMemories,
      characterMemories: characterMemories,
      relationships: relationships,
      userProfiles: userProfiles,
      permanentMemories: permanentMemories,
      relationshipEvents: relationshipEvents,
      skills: skills,
      tasks: tasks,
      workspaces: workspaces,
      settings: settings,
      skipped: skipped,
      remapped: remapped,
      isV1: manifest.schemaVersion == 1,
      isConversation: isConversation,
      restoreGlobalRelationships: !isConversation,
      requiresImportMarker: manifest.schemaVersion == 1 ||
          data.permanentMemories.isNotEmpty ||
          data.relationshipEvents.isNotEmpty,
    );
  }

  static List<Map<String, dynamic>> _rewriteUserProfiles(
    List<Map<String, dynamic>> records,
    DatabaseService db,
    Map<String, int> skipped,
  ) {
    final result = <Map<String, dynamic>>[];
    for (final record in records) {
      final key = BackupEntityCodec.key(record);
      if (db.userProfileBox.containsKey(key)) {
        skipped['userProfiles'] = (skipped['userProfiles'] ?? 0) + 1;
        continue;
      }
      final value = BackupEntityCodec.value(record);
      value['id'] = 'me';
      result.add(BackupEntityCodec.record('me', value));
    }
    return result;
  }

  Set<String> get attachmentPaths => messages
      .expand((record) =>
          BackupEntityCodec.value(record)['media'] as List? ?? const [])
      .map((item) => Map<String, dynamic>.from(item as Map)['path'].toString())
      .toSet();

  void validate(DatabaseService db) {
    _validateUniqueKeys();
    final charactersAvailable = _available(
      db.aiCharacterBox.keys,
      characters,
    );
    final groupsAvailable = _available(db.chatGroupBox.keys, groups);
    final messagesAvailable = _available(db.messageBox.keys, messages);
    final apiConfigsAvailable = _available(db.apiConfigBox.keys, apiConfigs);
    final skillsAvailable = _available(db.characterSkillBox.keys, skills);
    final memoriesAvailable = _available(
      db.permanentMemoryBox.keys,
      permanentMemories,
    );
    final eventsAvailable = _available(
      db.relationshipEventBox.keys,
      relationshipEvents,
    );

    for (final record in characters) {
      final value = BackupEntityCodec.value(record);
      final apiConfigId = value['apiConfigId']?.toString() ?? '';
      if (apiConfigId.isNotEmpty &&
          !apiConfigsAvailable.contains(apiConfigId)) {
        throw BackupException('恢复计划 API 配置引用无效：$apiConfigId');
      }
      for (final skillId in _strings(value['skillIds'])) {
        if (!skillsAvailable.contains(skillId)) {
          throw BackupException('恢复计划技能引用无效：$skillId');
        }
      }
    }
    for (final record in skills) {
      final characterId = BackupEntityCodec.value(record)['characterId'];
      if (characterId != '' && !charactersAvailable.contains(characterId)) {
        throw BackupException('恢复计划技能角色引用无效：$characterId');
      }
    }
    for (final record in groups) {
      for (final id
          in _strings(BackupEntityCodec.value(record)['aiCharacterIds'])) {
        if (!charactersAvailable.contains(id)) {
          throw BackupException('恢复计划角色引用无效：$id');
        }
      }
    }
    for (final record in messages) {
      final value = BackupEntityCodec.value(record);
      _validateConversation(
        value['groupId'],
        groupsAvailable,
        charactersAvailable,
      );
      if (value['senderType'] == 'ai' &&
          !charactersAvailable.contains(value['senderId'])) {
        throw BackupException('恢复计划消息角色引用无效：${value['senderId']}');
      }
      for (final id in _strings(value['mentionedAiIds'])) {
        if (!charactersAvailable.contains(id)) {
          throw BackupException('恢复计划提及角色引用无效：$id');
        }
      }
      final reply = value['replyToMessageId']?.toString();
      if (reply != null && !messagesAvailable.contains(reply)) {
        throw BackupException('恢复计划回复引用无效：$reply');
      }
    }
    for (final record in groupMemories) {
      _validateConversation(
        BackupEntityCodec.value(record)['groupId'],
        groupsAvailable,
        charactersAvailable,
      );
    }
    for (final record in characterMemories) {
      final value = BackupEntityCodec.value(record);
      _validateConversation(
          value['groupId'], groupsAvailable, charactersAvailable);
      _require(charactersAvailable, value['characterId']);
    }
    for (final record in relationships) {
      final value = BackupEntityCodec.value(record);
      final groupId = value['groupId']?.toString() ?? '';
      if (isV1 || groupId != 'global') {
        _validateConversation(groupId, groupsAvailable, charactersAvailable);
      }
      _validateRelationshipTarget(value, charactersAvailable, '关系');
      _require(charactersAvailable, value['sourceCharacterId']);
      final eventId = value['lastEventId']?.toString();
      if (eventId != null &&
          eventId.isNotEmpty &&
          !eventsAvailable.contains(eventId)) {
        throw BackupException('恢复计划 lastEventId 引用无效：$eventId');
      }
    }
    for (final record in permanentMemories) {
      final value = BackupEntityCodec.value(record);
      _require(charactersAvailable, value['observerCharacterId']);
      _validateSubjects(value['subjectIds'], charactersAvailable);
      _validateSubjects(value['participantIds'], charactersAvailable);
      _validateSourceMessageIds(value['sourceMessageIds'], messagesAvailable);
      for (final id in _strings(value['supersedesIds'])) {
        _require(memoriesAvailable, id);
      }
      if (isConversation) {
        _validateOriginConversation(value['originConversationId'],
            groupsAvailable, charactersAvailable);
      }
    }
    for (final record in relationshipEvents) {
      final value = BackupEntityCodec.value(record);
      _require(charactersAvailable, value['sourceCharacterId']);
      _validateRelationshipTarget(value, charactersAvailable, '关系事件');
      _validateSourceMessageIds(value['sourceMessageIds'], messagesAvailable);
      if (isConversation) {
        _validateOriginConversation(value['originConversationId'],
            groupsAvailable, charactersAvailable);
      }
    }
    for (final record in tasks) {
      final value = BackupEntityCodec.value(record);
      _validateConversation(
          value['groupId'], groupsAvailable, charactersAvailable);
      _require(charactersAvailable, value['characterId']);
    }
    for (final record in workspaces) {
      _validateConversation(
        BackupEntityCodec.value(record)['conversationId'],
        groupsAvailable,
        charactersAvailable,
      );
    }
    if (isConversation) {
      _validateConversationBoundary(groupsAvailable, charactersAvailable);
    }
  }

  void _validateConversationBoundary(
    Set<String> groupsAvailable,
    Set<String> charactersAvailable,
  ) {
    if (userProfiles.isNotEmpty || relationships.isNotEmpty) {
      throw const BackupException('会话恢复计划包含禁止的全局数据');
    }
    final conversations = <String>{
      ...messages.map(
          (record) => BackupEntityCodec.value(record)['groupId'].toString()),
    };
    for (final record in [...permanentMemories, ...relationshipEvents]) {
      final origin =
          BackupEntityCodec.value(record)['originConversationId']?.toString();
      if (origin != null) conversations.add(origin);
    }
    if (conversations.length > 1) {
      throw const BackupException('会话恢复计划跨越多个场合');
    }
    for (final conversation in conversations) {
      _validateConversation(conversation, groupsAvailable, charactersAvailable);
    }
  }

  void _validateUniqueKeys() {
    for (final records in [
      apiConfigs,
      characters,
      groups,
      messages,
      groupMemories,
      characterMemories,
      relationships,
      userProfiles,
      permanentMemories,
      relationshipEvents,
      skills,
      tasks,
      workspaces,
    ]) {
      final keys = <String>{};
      for (final record in records) {
        if (!keys.add(BackupEntityCodec.key(record))) {
          throw const BackupException('恢复计划包含重复存储键');
        }
      }
    }
  }

  static Set<String> _available(
    Iterable<dynamic> existingKeys,
    List<Map<String, dynamic>> records,
  ) =>
      {
        ...existingKeys.map((key) => key.toString()),
        ...records.map(BackupEntityCodec.key),
      };

  static void _validateRelationshipTarget(
    Map<String, dynamic> value,
    Set<String> characters,
    String label,
  ) {
    final type = value['targetType']?.toString();
    final target = value['targetId']?.toString();
    if (type == RelationshipTargetType.ai.name) {
      _require(characters, target);
    } else if (type == RelationshipTargetType.user.name) {
      if (target != 'user') {
        throw BackupException('$label 的 user targetId 必须保持 user');
      }
    } else {
      throw BackupException('$label targetType 无效：$type');
    }
  }

  static void _validateOriginConversation(
    Object? value,
    Set<String> groups,
    Set<String> characters,
  ) {
    final id = value?.toString();
    if (id == null || id.isEmpty) return;
    _validateConversation(id, groups, characters);
  }

  static void _validateSubjects(Object? value, Set<String> characters) {
    for (final id in _strings(value)) {
      if (id != 'user' && !characters.contains(id)) {
        throw BackupException('主体引用无效：$id');
      }
    }
  }

  void _validateSourceMessageIds(
    Object? value,
    Set<String> messages,
  ) {
    if (!isConversation) return;
    for (final id in _strings(value)) {
      _require(messages, id);
    }
  }

  static void _validateConversation(
    Object? value,
    Set<String> groups,
    Set<String> characters,
  ) {
    final id = value?.toString() ?? '';
    final valid = id.startsWith('dm:')
        ? characters.contains(id.substring(3))
        : groups.contains(id);
    if (!valid) throw BackupException('恢复计划会话引用无效：$id');
  }

  static void _require(Set<String> ids, Object? value) {
    if (!ids.contains(value?.toString())) {
      throw BackupException('恢复计划引用无效：$value');
    }
  }

  static Map<String, String> _mapping(
    List<Map<String, dynamic>> records,
    bool Function(Object key) contains,
    RestoreConflictStrategy strategy,
    String countKey,
    Map<String, int> skipped,
    Map<String, int> remapped,
  ) {
    final result = <String, String>{};
    for (final record in records) {
      final old = BackupEntityCodec.value(record)['id'].toString();
      if (!contains(BackupEntityCodec.key(record))) {
        result[old] = old;
      } else if (strategy == RestoreConflictStrategy.copyWithNewIds) {
        result[old] = const Uuid().v4();
        remapped[countKey] = (remapped[countKey] ?? 0) + 1;
      } else {
        result[old] = old;
        skipped[countKey] = (skipped[countKey] ?? 0) + 1;
      }
    }
    return result;
  }

  static List<Map<String, dynamic>> _rewrite(
    List<Map<String, dynamic>> records,
    Map<String, String> mapping,
    bool Function(Object key) contains,
    RestoreConflictStrategy strategy,
    void Function(Map<String, dynamic> value) mutate,
  ) =>
      records
          .where((record) =>
              !contains(BackupEntityCodec.key(record)) ||
              strategy == RestoreConflictStrategy.copyWithNewIds)
          .map((record) {
        final value = BackupEntityCodec.value(record);
        final old = value['id'].toString();
        mutate(value);
        return BackupEntityCodec.record(mapping[old]!, value);
      }).toList();

  static List<Map<String, dynamic>> _rewriteStorage(
    List<Map<String, dynamic>> records,
    bool Function(Object key) contains,
    RestoreConflictStrategy strategy,
    String countKey,
    Map<String, int> skipped,
    Map<String, int> remapped,
    String Function(String key, Map<String, dynamic> value) mutate,
  ) {
    final result = <Map<String, dynamic>>[];
    for (final record in records) {
      final oldKey = BackupEntityCodec.key(record);
      if (contains(oldKey) &&
          strategy != RestoreConflictStrategy.copyWithNewIds) {
        skipped[countKey] = (skipped[countKey] ?? 0) + 1;
        continue;
      }
      final value = BackupEntityCodec.value(record);
      var newKey = mutate(oldKey, value);
      if (contains(newKey) ||
          result.any((item) => BackupEntityCodec.key(item) == newKey)) {
        newKey = '${newKey}_${const Uuid().v4()}';
      }
      if (newKey != oldKey) remapped[countKey] = (remapped[countKey] ?? 0) + 1;
      result.add(BackupEntityCodec.record(newKey, value));
    }
    return result;
  }

  static Map<String, dynamic> _remapSettings(
    Map<String, dynamic> source,
    Map<String, String> characters,
    Map<String, String> groups,
    Map<String, String> memories,
    Map<String, String> relationships,
    String Function(String) conversation,
    DatabaseService db,
    RestoreConflictStrategy strategy,
    Map<String, int> skipped,
  ) {
    final result = <String, dynamic>{};
    final searchConfigIdRemap =
        strategy == RestoreConflictStrategy.copyWithNewIds
            ? _searchConfigIdRemap(source[SearchProviderConfigStore.configsKey])
            : const <String, String>{};
    for (final entry in source.entries) {
      var key = entry.key;
      dynamic value = entry.value;
      if (key == 'pinned_character_ids') value = _mapList(value, characters);
      if (key == 'pinned_group_ids') value = _mapList(value, groups);
      if (key == SearchProviderConfigStore.configsKey) {
        value = _restoreSearchConfigs(
          value,
          db.appSettingsBox.get(key),
          strategy,
          searchConfigIdRemap,
        );
      }
      if (key == SearchProviderConfigStore.defaultProviderKey &&
          strategy == RestoreConflictStrategy.copyWithNewIds) {
        final remapped = searchConfigIdRemap[value?.toString()];
        if (remapped == null) continue;
        value = remapped;
      }
      if (key == 'memory_pinned_keys_v1') {
        value = _strings(value)
            .map((pin) => _mapMemoryPin(
                  pin,
                  characters,
                  groups,
                  memories,
                  relationships,
                ))
            .toList(growable: false);
      }
      if (value is Map &&
          (key == 'direct_chat_read_at' || key == 'direct_chat_source')) {
        value = _mapKeys(value, conversation);
      }
      if (value is Map && key == 'direct_chat_last_proactive_at') {
        value = _mapKeys(value, (id) => characters[id] ?? id);
      }
      if (value is Map &&
          (key == 'group_chat_read_at' ||
              key == 'group_chat_last_proactive_at')) {
        value = _mapKeys(value, (id) => groups[id] ?? id);
      }
      if (value is Map && key == 'token_usage') {
        final usage = Map<String, dynamic>.from(value);
        if (usage['byCharacter'] is Map) {
          usage['byCharacter'] = _mapKeys(
            usage['byCharacter'] as Map,
            (id) => characters[id] ?? id,
          );
        }
        if (usage['byGroup'] is Map) {
          usage['byGroup'] = _mapKeys(
            usage['byGroup'] as Map,
            (id) => groups[id] ?? id,
          );
        }
        value = usage;
      }
      if (key.startsWith('work_mode_enabled:')) {
        key = 'work_mode_enabled:${conversation(key.substring(18))}';
      }
      const checkpointPrefix = 'context_compressed_through:';
      if (key.startsWith(checkpointPrefix)) {
        final payload = key.substring(checkpointPrefix.length);
        final separator = payload.lastIndexOf(':');
        if (separator > 0) {
          final oldConversation = payload.substring(0, separator);
          final oldCharacter = payload.substring(separator + 1);
          key = '$checkpointPrefix${conversation(oldConversation)}:'
              '${characters[oldCharacter] ?? oldCharacter}';
        }
      }
      if (key != SearchProviderConfigStore.configsKey &&
          db.appSettingsBox.containsKey(key) &&
          strategy != RestoreConflictStrategy.emptyOnly) {
        final existing = db.appSettingsBox.get(key);
        if (existing is List && value is List) {
          value = {...existing, ...value}.toList();
        } else if (existing is Map && value is Map) {
          final merged = Map<dynamic, dynamic>.from(existing);
          for (final imported in value.entries) {
            merged.putIfAbsent(imported.key, () => imported.value);
          }
          value = merged;
        } else {
          skipped['settings'] = (skipped['settings'] ?? 0) + 1;
          continue;
        }
      }
      result[key] = value;
    }
    return result;
  }

  static List<Map<String, dynamic>> _restoreSearchConfigs(
    Object? raw,
    Object? existingRaw,
    RestoreConflictStrategy strategy,
    Map<String, String> idRemap,
  ) {
    final restored = SearchProviderConfigStore.restoreValue(raw);
    if (strategy == RestoreConflictStrategy.emptyOnly) return restored;

    final existing = _mapRecords(existingRaw);
    final existingIds = existing
        .map((item) => item['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    if (strategy == RestoreConflictStrategy.skipExisting) {
      return [
        ...existing,
        ...restored.where(
          (item) => !existingIds.contains(item['id']?.toString()),
        ),
      ];
    }

    return [
      ...existing,
      ...restored.map(
        (item) => {
          ...item,
          'id': idRemap[item['id']?.toString()] ?? item['id'],
          // A copied configuration must not silently replace the current
          // default. The remapped default key below can still select it when
          // the destination has no existing default.
          'isDefault': false,
        },
      ),
    ];
  }

  static Map<String, String> _searchConfigIdRemap(Object? raw) {
    final result = <String, String>{};
    if (raw is! List) return result;
    for (final item in raw.whereType<Map>()) {
      final id = item['id']?.toString() ?? '';
      if (id.isNotEmpty) result[id] = const Uuid().v4();
    }
    return result;
  }

  static List<Map<String, dynamic>> _mapRecords(Object? raw) {
    return SearchProviderConfigStore.normalizeExistingValue(raw);
  }

  static List<String> _mapList(Object? value, Map<String, String> mapping) =>
      _strings(value).map((id) => mapping[id] ?? id).toList();

  static String _mapMemoryPin(
    String pin,
    Map<String, String> characters,
    Map<String, String> groups,
    Map<String, String> memories,
    Map<String, String> relationships,
  ) {
    if (pin.startsWith('character:')) {
      final payload = pin.substring(10);
      final separator = payload.indexOf(':');
      final id = separator < 0 ? payload : payload.substring(0, separator);
      return 'character:${memories[id] ?? id}'
          '${separator < 0 ? '' : payload.substring(separator)}';
    }
    if (pin.startsWith('legacy:')) {
      final id = pin.substring(7);
      return 'legacy:${characters[id] ?? id}';
    }
    if (pin.startsWith('relationship:')) {
      final id = pin.substring(13);
      return 'relationship:${relationships[id] ?? id}';
    }
    if (pin.startsWith('group:')) {
      final payload = pin.substring(6);
      final separator = payload.indexOf(':');
      if (separator < 0) return pin;
      final oldGroup = payload.substring(0, separator);
      final newGroup = groups[oldGroup] ?? oldGroup;
      var memoryKey = payload.substring(separator + 1);
      if (memoryKey == oldGroup) {
        memoryKey = newGroup;
      } else if (memoryKey.startsWith('${oldGroup}_')) {
        memoryKey = '$newGroup${memoryKey.substring(oldGroup.length)}';
      }
      return 'group:$newGroup:$memoryKey';
    }
    return pin;
  }

  static Map<String, dynamic> _mapKeys(
    Map source,
    String Function(String id) map,
  ) =>
      source.map((key, value) => MapEntry(map(key.toString()), value));

  static List<String> _strings(Object? value) =>
      (value as List? ?? const []).map((item) => item.toString()).toList();
}
