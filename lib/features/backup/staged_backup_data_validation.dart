part of 'staged_backup_data.dart';

void _validateBackupData(StagedBackupData data, BackupManifest manifest) {
  data._validateRecordKeys();
  data._validateSettingKeys();
  final ids = <String, Set<String>>{
    'apiConfigs': StagedBackupData._ids(data.apiConfigs),
    'characters': StagedBackupData._ids(data.characters),
    'groups': StagedBackupData._ids(data.groups),
    'messages': StagedBackupData._ids(data.messages),
    'characterMemories': StagedBackupData._ids(data.characterMemories),
    'relationships': StagedBackupData._ids(data.relationships),
    'skills': StagedBackupData._ids(data.skills),
    'agentTasks': StagedBackupData._ids(data.tasks),
    'userProfiles': StagedBackupData._ids(data.userProfiles),
    'permanentMemories': StagedBackupData._ids(data.permanentMemories),
    'relationshipEvents': StagedBackupData._ids(data.relationshipEvents),
  };
  _expectBackupCounts(data, manifest);
  final apiIds = ids['apiConfigs']!;
  final characterIds = ids['characters']!;
  final groupIds = ids['groups']!;
  final messageIds = ids['messages']!;
  final memoryIds = ids['permanentMemories']!;
  final eventIds = ids['relationshipEvents']!;

  if (manifest.schemaVersion >= 2 &&
      manifest.backupKind == BackupKind.conversation &&
      (data.userProfiles.isNotEmpty || data.relationships.isNotEmpty)) {
    throw const BackupException('会话备份不得包含 UserProfile 或全局关系快照');
  }

  for (final record in data.characters) {
    final value = BackupEntityCodec.value(record);
    final apiConfigId = value['apiConfigId']?.toString() ?? '';
    if (apiConfigId.isNotEmpty && !apiIds.contains(apiConfigId)) {
      throw BackupException('角色引用了不存在的 API 配置：$apiConfigId');
    }
    for (final skillId in _stagedBackupStrings(value['skillIds'])) {
      if (!ids['skills']!.contains(skillId)) {
        throw BackupException('角色引用了不存在的技能：$skillId');
      }
    }
  }
  for (final record in data.groups) {
    for (final characterId in _stagedBackupStrings(
        BackupEntityCodec.value(record)['aiCharacterIds'])) {
      if (!characterIds.contains(characterId)) {
        throw BackupException('群聊引用了不存在的角色：$characterId');
      }
    }
  }
  for (final record in data.messages) {
    final value = BackupEntityCodec.value(record);
    StagedBackupData._validateConversation(
      value['groupId'],
      groupIds,
      characterIds,
    );
    if (value['senderType'] == 'ai' &&
        !characterIds.contains(value['senderId'])) {
      throw BackupException('消息引用了不存在的角色：${value['senderId']}');
    }
    final replyId = value['replyToMessageId']?.toString();
    if (replyId != null && !messageIds.contains(replyId)) {
      throw BackupException('消息引用了不存在的回复：$replyId');
    }
    for (final media in value['media'] as List? ?? const []) {
      final path = Map<String, dynamic>.from(media as Map)['path'].toString();
      if (!manifest.files.containsKey(path) ||
          !path.startsWith('attachments/')) {
        throw BackupException('附件引用无效：$path');
      }
    }
  }
  for (final record in data.groupMemories) {
    StagedBackupData._validateConversation(
      BackupEntityCodec.value(record)['groupId'],
      groupIds,
      characterIds,
    );
  }
  for (final record in data.characterMemories) {
    final value = BackupEntityCodec.value(record);
    StagedBackupData._validateConversation(
      value['groupId'],
      groupIds,
      characterIds,
    );
    StagedBackupData._require(ids: characterIds, value: value['characterId']);
  }
  for (final record in data.relationships) {
    final value = BackupEntityCodec.value(record);
    if (manifest.schemaVersion >= 2 && value['groupId'] != 'global') {
      throw const BackupException('v2 relationships 必须是全局快照');
    }
    if (manifest.schemaVersion < 2) {
      StagedBackupData._validateConversation(
        value['groupId'],
        groupIds,
        characterIds,
      );
    }
    StagedBackupData._require(
      ids: characterIds,
      value: value['sourceCharacterId'],
    );
    if (value['targetType'] == 'ai') {
      StagedBackupData._require(ids: characterIds, value: value['targetId']);
    } else if (value['targetType'] == 'user') {
      if (value['targetId'] != 'user') {
        throw const BackupException('关系的 user targetId 必须保持 user');
      }
    } else {
      throw BackupException('关系 targetType 无效：${value['targetType']}');
    }
    final lastEventId = value['lastEventId']?.toString();
    if (lastEventId != null &&
        lastEventId.isNotEmpty &&
        !eventIds.contains(lastEventId)) {
      throw BackupException('关系引用了不存在的 lastEventId：$lastEventId');
    }
  }
  for (final record in data.userProfiles) {
    if (BackupEntityCodec.key(record) != 'me') {
      throw const BackupException('user_profile.json 只能包含 me');
    }
  }
  for (final record in data.permanentMemories) {
    final value = BackupEntityCodec.value(record);
    StagedBackupData._require(
      ids: characterIds,
      value: value['observerCharacterId'],
    );
    StagedBackupData._validateSubjectIds(value['subjectIds'], characterIds);
    StagedBackupData._validateSubjectIds(value['participantIds'], characterIds);
    StagedBackupData._validateSourceMessageIds(
      value['sourceMessageIds'],
      messageIds,
      manifest,
    );
    for (final supersedesId in _stagedBackupStrings(value['supersedesIds'])) {
      if (!memoryIds.contains(supersedesId)) {
        throw BackupException('永久记忆引用了不存在的 supersedes 记录：$supersedesId');
      }
    }
    StagedBackupData._validateOriginConversation(
      value['originConversationId'],
      manifest,
      groupIds,
      characterIds,
    );
  }
  for (final record in data.relationshipEvents) {
    final value = BackupEntityCodec.value(record);
    StagedBackupData._require(
      ids: characterIds,
      value: value['sourceCharacterId'],
    );
    if (value['targetType'] == 'ai') {
      StagedBackupData._require(ids: characterIds, value: value['targetId']);
    } else if (value['targetType'] == 'user') {
      if (value['targetId'] != 'user') {
        throw const BackupException('关系事件的 user targetId 必须保持 user');
      }
    } else {
      throw BackupException('关系事件 targetType 无效：${value['targetType']}');
    }
    StagedBackupData._validateSourceMessageIds(
      value['sourceMessageIds'],
      messageIds,
      manifest,
    );
    StagedBackupData._validateOriginConversation(
      value['originConversationId'],
      manifest,
      groupIds,
      characterIds,
    );
  }
  for (final record in data.skills) {
    final characterId = BackupEntityCodec.value(record)['characterId'];
    if (characterId != '' && !characterIds.contains(characterId)) {
      throw BackupException('技能引用了不存在的角色：$characterId');
    }
  }
  for (final record in data.tasks) {
    final value = BackupEntityCodec.value(record);
    StagedBackupData._validateConversation(
      value['groupId'],
      groupIds,
      characterIds,
    );
    StagedBackupData._require(ids: characterIds, value: value['characterId']);
  }
  for (final record in data.workspaces) {
    StagedBackupData._validateConversation(
      BackupEntityCodec.value(record)['conversationId'],
      groupIds,
      characterIds,
    );
  }
}

void _expectBackupCounts(StagedBackupData data, BackupManifest manifest) {
  final actual = {
    'apiConfigs': data.apiConfigs.length,
    'characters': data.characters.length,
    'groups': data.groups.length,
    'messages': data.messages.length,
    'groupMemories': data.groupMemories.length,
    'characterMemories': data.characterMemories.length,
    'relationships': data.relationships.length,
    'skills': data.skills.length,
    'agentTasks': data.tasks.length,
    'workMode': data.workspaces.length,
    'settings': data.settings.length,
    'userProfiles': data.userProfiles.length,
    'permanentMemories': data.permanentMemories.length,
    'relationshipEvents': data.relationshipEvents.length,
  };
  for (final entry in actual.entries) {
    if (manifest.counts.containsKey(entry.key) &&
        manifest.counts[entry.key] != entry.value) {
      throw BackupException('条目计数不一致：${entry.key}');
    }
  }
}
