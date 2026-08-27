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

  Set<String> get attachmentPaths => messages
      .expand((record) =>
          BackupEntityCodec.value(record)['media'] as List? ?? const [])
      .map((item) => Map<String, dynamic>.from(item as Map)['path'].toString())
      .toSet();
}
