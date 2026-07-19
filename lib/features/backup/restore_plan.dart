part of 'restore_executor.dart';

class _RestorePlan {
  final List<Map<String, dynamic>> apiConfigs;
  final List<Map<String, dynamic>> characters;
  final List<Map<String, dynamic>> groups;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> groupMemories;
  final List<Map<String, dynamic>> characterMemories;
  final List<Map<String, dynamic>> relationships;
  final List<Map<String, dynamic>> skills;
  final List<Map<String, dynamic>> tasks;
  final List<Map<String, dynamic>> workspaces;
  final Map<String, dynamic> settings;
  final Map<String, int> skipped;
  final Map<String, int> remapped;

  const _RestorePlan({
    required this.apiConfigs,
    required this.characters,
    required this.groups,
    required this.messages,
    required this.groupMemories,
    required this.characterMemories,
    required this.relationships,
    required this.skills,
    required this.tasks,
    required this.workspaces,
    required this.settings,
    required this.skipped,
    required this.remapped,
  });

  factory _RestorePlan.build(
    DatabaseService db,
    StagedBackupData data,
    RestoreConflictStrategy strategy,
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
    final memoryMap = _mapping(
        data.characterMemories,
        db.characterMemoryBox.containsKey,
        strategy,
        'characterMemories',
        skipped,
        remapped);
    final relationshipMap = _mapping(
        data.relationships,
        db.relationshipStateBox.containsKey,
        strategy,
        'relationships',
        skipped,
        remapped);
    final taskMap = _mapping(data.tasks, db.agentTaskBox.containsKey, strategy,
        'agentTasks', skipped, remapped);
    String conversation(String id) => id.startsWith('dm:')
        ? 'dm:${characterMap[id.substring(3)] ?? id.substring(3)}'
        : groupMap[id] ?? id;

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
    final characterMemories = _rewrite(data.characterMemories, memoryMap,
        db.characterMemoryBox.containsKey, strategy, (value) {
      value['id'] = memoryMap[value['id']]!;
      value['groupId'] = groupMap[value['groupId']] ?? value['groupId'];
      value['characterId'] =
          characterMap[value['characterId']] ?? value['characterId'];
    });
    final relationships = _rewrite(data.relationships, relationshipMap,
        db.relationshipStateBox.containsKey, strategy, (value) {
      value['id'] = relationshipMap[value['id']]!;
      value['groupId'] = groupMap[value['groupId']] ?? value['groupId'];
      value['sourceCharacterId'] = characterMap[value['sourceCharacterId']] ??
          value['sourceCharacterId'];
      if (value['targetType'] == RelationshipTargetType.ai.name) {
        value['targetId'] =
            characterMap[value['targetId']] ?? value['targetId'];
      }
    });
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
      memoryMap,
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
      skills: skills,
      tasks: tasks,
      workspaces: workspaces,
      settings: settings,
      skipped: skipped,
      remapped: remapped,
    );
  }

  Set<String> get attachmentPaths => messages
      .expand((record) =>
          BackupEntityCodec.value(record)['media'] as List? ?? const [])
      .map((item) => Map<String, dynamic>.from(item as Map)['path'].toString())
      .toSet();

  void validate(DatabaseService db) {
    final charactersAvailable = {
      ...db.aiCharacterBox.keys.map((key) => key.toString()),
      ...characters.map((record) => BackupEntityCodec.key(record)),
    };
    final groupsAvailable = {
      ...db.chatGroupBox.keys.map((key) => key.toString()),
      ...groups.map((record) => BackupEntityCodec.key(record)),
    };
    final messagesAvailable = {
      ...db.messageBox.keys.map((key) => key.toString()),
      ...messages.map((record) => BackupEntityCodec.key(record)),
    };
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
      final conversation = value['groupId'].toString();
      final validConversation = conversation.startsWith('dm:')
          ? charactersAvailable.contains(conversation.substring(3))
          : groupsAvailable.contains(conversation);
      if (!validConversation) throw BackupException('恢复计划会话引用无效：$conversation');
      final reply = value['replyToMessageId']?.toString();
      if (reply != null && !messagesAvailable.contains(reply)) {
        throw BackupException('恢复计划回复引用无效：$reply');
      }
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
      if (contains(newKey)) newKey = '${newKey}_${const Uuid().v4()}';
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
    for (final entry in source.entries) {
      var key = entry.key;
      dynamic value = entry.value;
      if (key == 'pinned_character_ids') value = _mapList(value, characters);
      if (key == 'pinned_group_ids') value = _mapList(value, groups);
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
      if (db.appSettingsBox.containsKey(key) &&
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
