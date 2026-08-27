part of 'backup_restore_service_test.dart';

Future<void> _seedGlobalMemoryData(
  DatabaseService db,
  Directory mediaDirectory,
) async {
  final attachment = File('${mediaDirectory.path}/global.txt');
  await attachment.writeAsString('global');
  await _seedCoreData(db, attachment);
  final seededCharacter = db.aiCharacterBox.get('char-1')!
    ..memorySummary = '跨会话旧摘要机密';
  await db.aiCharacterBox.put(seededCharacter.id, seededCharacter);
  await db.aiCharacterBox.put('char-2', testCharacter('char-2'));
  await db.chatGroupBox.put(
    'group-2',
    ChatGroup(
      id: 'group-2',
      name: '其他群',
      theme: '隔离',
      aiCharacterIds: const ['char-2'],
    ),
  );
  await db.messageBox.put(
    'other-msg',
    Message(
      id: 'other-msg',
      groupId: 'group-2',
      senderId: 'char-2',
      senderType: 'ai',
      content: 'other conversation',
    ),
  );
  final occurredAt = DateTime.utc(2026, 8, 1, 12);
  await db.userProfileBox.put(
    'me',
    UserProfile(
      displayName: '用户',
      preferredAddress: '朋友',
      avatar: '我',
      bio: '备份测试',
      updatedAt: occurredAt,
      createdAt: occurredAt,
    ),
  );
  await db.permanentMemoryBox.put(
    'memory-current',
    PermanentMemory(
      id: 'memory-current',
      observerCharacterId: 'char-1',
      kind: MemoryKind.fact,
      content: '当前会话事实',
      subjectIds: const ['user', 'char-2'],
      participantIds: const ['user', 'char-1', 'char-2'],
      supersedesIds: const ['memory-other'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originConversationId: 'group-1',
      originNameSnapshot: '测试群',
      sourceMessageIds: const ['msg-1'],
      occurredAt: occurredAt,
      createdAt: occurredAt,
      updatedAt: occurredAt,
    ),
  );
  await db.permanentMemoryBox.put(
    'memory-other',
    PermanentMemory(
      id: 'memory-other',
      observerCharacterId: 'char-2',
      kind: MemoryKind.preference,
      content: '其他会话事实',
      subjectIds: const ['user'],
      participantIds: const ['user', 'char-2'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originConversationId: 'group-2',
      originNameSnapshot: '其他群',
      sourceMessageIds: const ['other-msg'],
      occurredAt: occurredAt,
      createdAt: occurredAt,
      updatedAt: occurredAt,
    ),
  );
  await db.relationshipEventBox.put(
    'event-current',
    RelationshipEvent(
      id: 'event-current',
      sourceCharacterId: 'char-1',
      targetType: RelationshipTargetType.user,
      targetId: 'user',
      reason: '当前事件',
      affinityBefore: 0,
      affinityAfter: 5,
      trustBefore: 0,
      trustAfter: 4,
      frictionBefore: 0,
      frictionAfter: 0,
      familiarityBefore: 0,
      familiarityAfter: 5,
      moodBefore: RelationshipMood.neutral,
      moodAfter: RelationshipMood.warm,
      stageBefore: RelationshipStage.stranger,
      stageAfter: RelationshipStage.acquaintance,
      originConversationId: 'group-1',
      originNameSnapshot: '测试群',
      sourceMessageIds: const ['msg-1'],
      revision: 1,
      occurredAt: occurredAt,
      createdBy: RelationshipEventCreator.automatic,
      createdAt: occurredAt,
    ),
  );
  await db.relationshipEventBox.put(
    'event-other',
    RelationshipEvent(
      id: 'event-other',
      sourceCharacterId: 'char-2',
      targetType: RelationshipTargetType.user,
      targetId: 'user',
      reason: '其他事件',
      affinityBefore: 0,
      affinityAfter: 3,
      trustBefore: 0,
      trustAfter: 2,
      frictionBefore: 0,
      frictionAfter: 0,
      familiarityBefore: 0,
      familiarityAfter: 3,
      moodBefore: RelationshipMood.neutral,
      moodAfter: RelationshipMood.warm,
      stageBefore: RelationshipStage.stranger,
      stageAfter: RelationshipStage.acquaintance,
      originConversationId: 'group-2',
      originNameSnapshot: '其他群',
      sourceMessageIds: const ['other-msg'],
      revision: 1,
      occurredAt: occurredAt,
      createdBy: RelationshipEventCreator.automatic,
      createdAt: occurredAt,
    ),
  );
  await db.relationshipStateBox.put(
    'rel:char-1:user:user',
    RelationshipState.global(
      id: 'rel:char-1:user:user',
      sourceCharacterId: 'char-1',
      targetType: RelationshipTargetType.user,
      targetId: 'user',
      affinity: 5,
      trust: 4,
      familiarity: 5,
      recentMood: RelationshipMood.warm,
      stage: RelationshipStage.acquaintance,
      revision: 1,
      lastEventId: 'event-current',
      lastInteractionAt: occurredAt,
      updatedAt: occurredAt,
      createdAt: occurredAt,
    ),
  );
}

bool _containsBytes(List<int> source, List<int> pattern) {
  if (pattern.isEmpty) return true;
  for (var i = 0; i <= source.length - pattern.length; i++) {
    var matches = true;
    for (var j = 0; j < pattern.length; j++) {
      if (source[i + j] != pattern[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Future<void> _seedCoreData(
  DatabaseService db,
  File attachment, {
  String apiKey = '',
}) async {
  await db.apiConfigBox.put(
    'api-1',
    ApiConfig(
      id: 'api-1',
      name: 'DeepSeek',
      provider: 'deepseek',
      apiKey: apiKey,
      customBaseUrl: 'https://example.com/v1?api_key=$apiKey&region=cn#private',
      credentialId: 'secure:api-1',
      hasCredential: true,
    ),
  );
  await db.aiCharacterBox.put(
    'char-1',
    AICharacter(
      id: 'char-1',
      name: '小夏',
      avatar: '夏',
      age: 22,
      role: '朋友',
      personalityTags: const ['真诚'],
      systemPrompt: '自然聊天',
      apiKey: apiKey,
      apiProvider: 'deepseek',
      apiConfigId: 'api-1',
    ),
  );
  await db.chatGroupBox.put(
    'group-1',
    ChatGroup(
      id: 'group-1',
      name: '测试群',
      theme: '恢复',
      aiCharacterIds: const ['char-1'],
    ),
  );
  final media = MediaAttachment(
    id: 'attachment-1',
    type: 'file',
    localPath: attachment.path,
    fileName: 'note.txt',
    fileSize: await attachment.length(),
    mimeType: 'text/plain',
  );
  await db.messageBox.putAll({
    'msg-1': Message(
      id: 'msg-1',
      groupId: 'group-1',
      senderId: 'user',
      senderType: 'user',
      content: 'hello',
      media: [media],
      visibleToCharacterIds: const ['char-1'],
    ),
    'msg-2': Message(
      id: 'msg-2',
      groupId: 'group-1',
      senderId: 'char-1',
      senderType: 'ai',
      content: 'reply',
      replyToMessageId: 'msg-1',
      media: [media],
      visibleToCharacterIds: const ['char-1'],
    ),
  });
  await db.groupMemoryBox.put(
    'group-1_2026-29',
    GroupMemory(groupId: 'group-1', topicSummary: '测试恢复'),
  );
  await db.characterMemoryBox.put(
    'memory-1',
    CharacterMemory(
      id: 'memory-1',
      groupId: 'group-1',
      characterId: 'char-1',
      facts: const ['用户关心备份'],
    ),
  );
  await db.relationshipStateBox.put(
    'relationship-1',
    RelationshipState(
      id: 'relationship-1',
      groupId: 'global',
      sourceCharacterId: 'char-1',
      targetId: 'char-1',
      targetType: RelationshipTargetType.ai,
    ),
  );
  await db.appSettingsBox.putAll({
    'theme_mode': 'dark',
    'pinned_group_ids': ['group-1'],
    'direct_chat_read_at': <String, String>{},
    'message_ids_by_group': {
      'group-1': ['msg-1', 'msg-2'],
    },
    'credential_cache': 'must-not-export',
  });
}
