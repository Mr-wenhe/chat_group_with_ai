part of 'restore_executor.dart';

extension _RestorePlanValidation on _RestorePlan {
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

  void _validateSourceMessageIds(
    Object? value,
    Set<String> messages,
  ) {
    if (!isConversation) return;
    for (final id in _strings(value)) {
      _require(messages, id);
    }
  }
}

Set<String> _available(
  Iterable<dynamic> existingKeys,
  List<Map<String, dynamic>> records,
) =>
    {
      ...existingKeys.map((key) => key.toString()),
      ...records.map(BackupEntityCodec.key),
    };

void _validateRelationshipTarget(
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

void _validateOriginConversation(
  Object? value,
  Set<String> groups,
  Set<String> characters,
) {
  final id = value?.toString();
  if (id == null || id.isEmpty) return;
  _validateConversation(id, groups, characters);
}

void _validateSubjects(Object? value, Set<String> characters) {
  for (final id in _strings(value)) {
    if (id != 'user' && !characters.contains(id)) {
      throw BackupException('主体引用无效：$id');
    }
  }
}

void _validateConversation(
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

void _require(Set<String> ids, Object? value) {
  if (!ids.contains(value?.toString())) {
    throw BackupException('恢复计划引用无效：$value');
  }
}
