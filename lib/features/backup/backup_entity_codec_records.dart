part of 'backup_entity_codec.dart';

class _BackupEntityRecordCodec {
  static Map<String, dynamic> record(Object key, Map<String, dynamic> value) =>
      {'key': key.toString(), 'value': value};

  static String key(Map<String, dynamic> record) => record['key'].toString();

  static Map<String, dynamic> value(Map<String, dynamic> record) =>
      Map<String, dynamic>.from(record['value'] as Map);

  static Map<String, dynamic> apiConfig(ApiConfig item) => {
        'id': item.id,
        'name': item.name,
        'provider': item.provider,
        'modelName': item.modelName,
        'customBaseUrl': _publicUrl(item.customBaseUrl),
        'createdAt': _date(item.createdAt),
        'credentialRequired': item.hasCredential ||
            item.legacyApiKeyForMigration?.isNotEmpty == true,
      };

  static ApiConfig decodeApiConfig(Map<String, dynamic> json) => ApiConfig(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        provider: _string(json, 'provider'),
        modelName: _string(json, 'modelName'),
        customBaseUrl: json['customBaseUrl']?.toString() ?? '',
        createdAt: _dateTime(json, 'createdAt'),
        apiKey: '',
        credentialId: '',
        hasCredential: false,
      );

  static Map<String, dynamic> character(AICharacter item) {
    final value = <String, dynamic>{
      'id': item.id,
      'name': item.name,
      'avatar': item.avatar,
      'age': item.age,
      'role': item.role,
      'personalityTags': item.personalityTags,
      'systemPrompt': item.systemPrompt,
      'memorySummary': item.memorySummary,
      'apiProvider': item.apiProvider,
      'modelName': item.modelName,
      'customBaseUrl': _publicUrl(item.customBaseUrl),
      'hourlyReplyLimit': item.hourlyReplyLimit,
      'hourlyReplyCount': item.hourlyReplyCount,
      'lastReplyTimestamp': item.lastReplyTimestamp?.toIso8601String(),
      'isActive': item.isActive,
      'createdAt': _date(item.createdAt),
      'apiConfigId': item.apiConfigId,
      'agenticEnabled': item.agenticEnabled,
      'skillIds': item.skillIds,
      'toolPermissions': item.toolPermissions.map((item) => item.name).toList(),
    };
    if (item.hasKnownGender) value['gender'] = item.gender.name;
    return value;
  }

  static Map<String, dynamic> characterForBackup(
    AICharacter item, {
    required bool includeMemorySummary,
  }) {
    final value = character(item);
    if (!includeMemorySummary) value['memorySummary'] = '';
    return value;
  }

  static AICharacter decodeCharacter(Map<String, dynamic> json) {
    final gender = _decodeGender(json['gender']);
    return AICharacter(
      id: _string(json, 'id'),
      name: _string(json, 'name'),
      avatar: _string(json, 'avatar'),
      age: _integer(json, 'age'),
      role: _string(json, 'role'),
      personalityTags: _strings(json['personalityTags']),
      systemPrompt: _string(json, 'systemPrompt'),
      memorySummary: json['memorySummary']?.toString() ?? '',
      apiKey: '',
      apiProvider: json['apiProvider']?.toString() ?? '',
      modelName: json['modelName']?.toString(),
      customBaseUrl: json['customBaseUrl']?.toString() ?? '',
      hourlyReplyLimit: (json['hourlyReplyLimit'] as num?)?.toInt() ?? 60,
      hourlyReplyCount: (json['hourlyReplyCount'] as num?)?.toInt() ?? 0,
      lastReplyTimestamp: _optionalDate(json['lastReplyTimestamp']),
      isActive: json['isActive'] as bool? ?? true,
      createdAt: _dateTime(json, 'createdAt'),
      apiConfigId: json['apiConfigId']?.toString(),
      agenticEnabled: json['agenticEnabled'] as bool? ?? true,
      skillIds: _strings(json['skillIds']),
      toolPermissions: _enums(json['toolPermissions'], ToolPermission.values),
      gender: gender ?? CharacterGender.female,
      hasKnownGender: gender != null,
    );
  }

  static bool hasValidGender(Map<String, dynamic> json) =>
      _decodeGender(json['gender']) != null;

  static Map<String, dynamic> group(ChatGroup item) => {
        'id': item.id,
        'name': item.name,
        'theme': item.theme,
        'description': item.description,
        'aiCharacterIds': item.aiCharacterIds,
        'createdAt': _date(item.createdAt),
        'ownerName': item.ownerName,
        'announcement': item.announcement,
        'replyIntervalSeconds': item.replyIntervalSeconds,
      };

  static ChatGroup decodeGroup(Map<String, dynamic> json) => ChatGroup(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        theme: _string(json, 'theme'),
        description: json['description']?.toString() ?? '',
        aiCharacterIds: _strings(json['aiCharacterIds']),
        createdAt: _dateTime(json, 'createdAt'),
        ownerName: json['ownerName']?.toString(),
        announcement: json['announcement']?.toString(),
        replyIntervalSeconds: (json['replyIntervalSeconds'] as num?)?.toInt(),
      );

  static Map<String, dynamic> message(
    Message item,
    List<Map<String, dynamic>> media,
  ) =>
      {
        'id': item.id,
        'groupId': item.groupId,
        'senderId': item.senderId,
        'senderType': item.senderType,
        'content': item.content,
        'timestamp': _date(item.timestamp),
        'replyToMessageId': item.replyToMessageId,
        'isMention': item.isMention,
        'mentionedAiIds': item.mentionedAiIds,
        'media': media,
        'visibleToCharacterIds': item.visibleToCharacterIds,
        'webSearchSnapshot': _snapshotMap(item.webSearchSnapshot),
      };

  static Message decodeMessage(
    Map<String, dynamic> json,
    String Function(String path) resolveAttachment,
  ) =>
      Message(
        id: _string(json, 'id'),
        groupId: _string(json, 'groupId'),
        senderId: _string(json, 'senderId'),
        senderType: _string(json, 'senderType'),
        content: _string(json, 'content'),
        timestamp: _dateTime(json, 'timestamp'),
        replyToMessageId: json['replyToMessageId']?.toString(),
        isMention: json['isMention'] as bool? ?? false,
        mentionedAiIds: _strings(json['mentionedAiIds']),
        media: (json['media'] as List? ?? const [])
            .map((item) => decodeAttachment(
                  Map<String, dynamic>.from(item as Map),
                  resolveAttachment,
                ))
            .toList(),
        visibleToCharacterIds: _strings(json['visibleToCharacterIds']),
        webSearchSnapshot: _snapshotMap(json['webSearchSnapshot']),
      );

  static Map<String, dynamic>? _snapshotMap(Object? raw) {
    if (raw is! Map) return null;
    final snapshot = WebSearchSnapshot.fromMap(raw);
    return snapshot?.toMap();
  }

  static Map<String, dynamic> attachment(
    MediaAttachment item,
    String archivePath,
  ) =>
      {
        'id': item.id,
        'type': item.type,
        'path': archivePath,
        'fileName': item.fileName,
        'fileSize': item.fileSize,
        'mimeType': item.mimeType,
        'durationMs': item.durationMs,
      };

  static MediaAttachment decodeAttachment(
    Map<String, dynamic> json,
    String Function(String path) resolveAttachment,
  ) =>
      MediaAttachment(
        id: _string(json, 'id'),
        type: _string(json, 'type'),
        localPath: resolveAttachment(_string(json, 'path')),
        fileName: json['fileName']?.toString(),
        fileSize: (json['fileSize'] as num?)?.toInt(),
        mimeType: json['mimeType']?.toString(),
        durationMs: (json['durationMs'] as num?)?.toInt(),
      );
}
