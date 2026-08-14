import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';

class BackupEntityCodec {
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
      );

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

  static Map<String, dynamic> groupMemory(GroupMemory item) => {
        'groupId': item.groupId,
        'topicSummary': item.topicSummary,
        'lastSummaryAt': _date(item.lastSummaryAt),
      };

  static GroupMemory decodeGroupMemory(Map<String, dynamic> json) =>
      GroupMemory(
        groupId: _string(json, 'groupId'),
        topicSummary: json['topicSummary']?.toString() ?? '',
        lastSummaryAt: _dateTime(json, 'lastSummaryAt'),
      );

  static Map<String, dynamic> characterMemory(CharacterMemory item) => {
        'id': item.id,
        'groupId': item.groupId,
        'characterId': item.characterId,
        'facts': item.facts,
        'relationshipNotes': item.relationshipNotes,
        'personaGrowth': item.personaGrowth,
        'lastUpdatedAt': _date(item.lastUpdatedAt),
        'createdAt': _date(item.createdAt),
      };

  static CharacterMemory decodeCharacterMemory(Map<String, dynamic> json) =>
      CharacterMemory(
        id: _string(json, 'id'),
        groupId: _string(json, 'groupId'),
        characterId: _string(json, 'characterId'),
        facts: _strings(json['facts']),
        relationshipNotes: _strings(json['relationshipNotes']),
        personaGrowth: _strings(json['personaGrowth']),
        lastUpdatedAt: _dateTime(json, 'lastUpdatedAt'),
        createdAt: _dateTime(json, 'createdAt'),
      );

  static Map<String, dynamic> relationship(RelationshipState item) => {
        'id': item.id,
        'groupId': item.groupId,
        'sourceCharacterId': item.sourceCharacterId,
        'targetId': item.targetId,
        'targetType': item.targetType.name,
        'affinity': item.affinity,
        'trust': item.trust,
        'friction': item.friction,
        'familiarity': item.familiarity,
        'recentMood': item.recentMood.name,
        'notes': item.notes,
        'lastInteractionAt': _date(item.lastInteractionAt),
        'createdAt': _date(item.createdAt),
        'stage': item.stage.name,
        'revision': item.revision,
        'lastEventId': item.lastEventId,
        'updatedAt': _date(item.updatedAt),
      };

  static Map<String, dynamic> userProfile(UserProfile item) => {
        'id': item.id,
        'displayName': item.displayName,
        'preferredAddress': item.preferredAddress,
        'avatar': item.avatar,
        'pronouns': item.pronouns,
        'age': item.age,
        'bio': item.bio,
        'personality': item.personality,
        'interests': item.interests,
        'importantBackground': item.importantBackground,
        'updatedAt': _date(item.updatedAt),
        'createdAt': _date(item.createdAt),
      };

  static Map<String, dynamic> permanentMemory(
    PermanentMemory item, {
    List<String>? sourceMessageIds,
    List<String>? subjectIds,
    List<String>? participantIds,
    List<String>? supersedesIds,
  }) =>
      {
        'id': item.id,
        'observerCharacterId': item.observerCharacterId,
        'kind': item.kind.name,
        'content': item.content,
        'subjectIds': subjectIds ?? item.subjectIds,
        'status': item.status.name,
        'importance': item.importance,
        'confidence': item.confidence,
        'explicitlyRequested': item.explicitlyRequested,
        'pinned': item.pinned,
        'supersedesIds': supersedesIds ?? item.supersedesIds,
        'originType': item.originType.name,
        'originConversationId': item.originConversationId,
        'originNameSnapshot': item.originNameSnapshot,
        'sourceMessageIds': sourceMessageIds ?? item.sourceMessageIds,
        'participantIds': participantIds ?? item.participantIds,
        'occurredAt': _date(item.occurredAt),
        'createdAt': _date(item.createdAt),
        'updatedAt': _date(item.updatedAt),
        'invalidationReason': item.invalidationReason,
      };

  static Map<String, dynamic> relationshipEvent(
    RelationshipEvent item, {
    List<String>? sourceMessageIds,
  }) =>
      {
        'id': item.id,
        'sourceCharacterId': item.sourceCharacterId,
        'targetType': item.targetType.name,
        'targetId': item.targetId,
        'reason': item.reason,
        'affinityBefore': item.affinityBefore,
        'affinityAfter': item.affinityAfter,
        'trustBefore': item.trustBefore,
        'trustAfter': item.trustAfter,
        'frictionBefore': item.frictionBefore,
        'frictionAfter': item.frictionAfter,
        'familiarityBefore': item.familiarityBefore,
        'familiarityAfter': item.familiarityAfter,
        'moodBefore': item.moodBefore.name,
        'moodAfter': item.moodAfter.name,
        'stageBefore': item.stageBefore.name,
        'stageAfter': item.stageAfter.name,
        'originConversationId': item.originConversationId,
        'originNameSnapshot': item.originNameSnapshot,
        'sourceMessageIds': sourceMessageIds ?? item.sourceMessageIds,
        'revision': item.revision,
        'occurredAt': _date(item.occurredAt),
        'confidence': item.confidence,
        'createdBy': item.createdBy.name,
        'createdAt': _date(item.createdAt),
        'notesBefore': item.notesBefore,
        'notesAfter': item.notesAfter,
      };

  static RelationshipState decodeRelationship(Map<String, dynamic> json) =>
      RelationshipState(
        id: _string(json, 'id'),
        groupId: _string(json, 'groupId'),
        sourceCharacterId: _string(json, 'sourceCharacterId'),
        targetId: _string(json, 'targetId'),
        targetType: _enum(json, 'targetType', RelationshipTargetType.values),
        affinity: _integer(json, 'affinity'),
        trust: _integer(json, 'trust'),
        friction: _integer(json, 'friction'),
        familiarity: _integer(json, 'familiarity'),
        recentMood: _enum(json, 'recentMood', RelationshipMood.values),
        notes: json['notes']?.toString() ?? '',
        lastInteractionAt: _dateTime(json, 'lastInteractionAt'),
        createdAt: _dateTime(json, 'createdAt'),
        stage: _optionalEnum(
              json['stage'],
              RelationshipStage.values,
            ) ??
            RelationshipStage.stranger,
        revision: (json['revision'] as num?)?.toInt() ?? 0,
        lastEventId: json['lastEventId']?.toString(),
        updatedAt: _optionalDate(json['updatedAt']) ??
            _dateTime(json, 'lastInteractionAt'),
      );

  static UserProfile decodeUserProfile(Map<String, dynamic> json) =>
      UserProfile(
        id: _string(json, 'id'),
        displayName: _string(json, 'displayName'),
        preferredAddress: _string(json, 'preferredAddress'),
        avatar: _string(json, 'avatar'),
        pronouns: json['pronouns']?.toString() ?? '',
        age: (json['age'] as num?)?.toInt(),
        bio: _string(json, 'bio'),
        personality: _strings(json['personality']),
        interests: _strings(json['interests']),
        importantBackground: _strings(json['importantBackground']),
        updatedAt: _dateTime(json, 'updatedAt'),
        createdAt: _dateTime(json, 'createdAt'),
      );

  static PermanentMemory decodePermanentMemory(
    Map<String, dynamic> json,
  ) =>
      PermanentMemory(
        id: _string(json, 'id'),
        observerCharacterId: _string(json, 'observerCharacterId'),
        kind: _enum(json, 'kind', MemoryKind.values),
        content: _string(json, 'content'),
        subjectIds: _strings(json['subjectIds']),
        status: _enum(json, 'status', MemoryStatus.values),
        importance: (json['importance'] as num?)?.toInt() ?? 50,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
        explicitlyRequested: json['explicitlyRequested'] as bool? ?? false,
        pinned: json['pinned'] as bool? ?? false,
        supersedesIds: _strings(json['supersedesIds']),
        originType: _enum(json, 'originType', MemoryOriginType.values),
        originConversationId: json['originConversationId']?.toString(),
        originNameSnapshot: _string(json, 'originNameSnapshot'),
        sourceMessageIds: _strings(json['sourceMessageIds']),
        participantIds: _strings(json['participantIds']),
        occurredAt: _dateTime(json, 'occurredAt'),
        createdAt: _dateTime(json, 'createdAt'),
        updatedAt: _dateTime(json, 'updatedAt'),
        invalidationReason: json['invalidationReason']?.toString(),
      );

  static RelationshipEvent decodeRelationshipEvent(
    Map<String, dynamic> json,
  ) =>
      RelationshipEvent(
        id: _string(json, 'id'),
        sourceCharacterId: _string(json, 'sourceCharacterId'),
        targetType: _enum(json, 'targetType', RelationshipTargetType.values),
        targetId: _string(json, 'targetId'),
        reason: _string(json, 'reason'),
        affinityBefore: _integer(json, 'affinityBefore'),
        affinityAfter: _integer(json, 'affinityAfter'),
        trustBefore: _integer(json, 'trustBefore'),
        trustAfter: _integer(json, 'trustAfter'),
        frictionBefore: _integer(json, 'frictionBefore'),
        frictionAfter: _integer(json, 'frictionAfter'),
        familiarityBefore: _integer(json, 'familiarityBefore'),
        familiarityAfter: _integer(json, 'familiarityAfter'),
        moodBefore: _enum(json, 'moodBefore', RelationshipMood.values),
        moodAfter: _enum(json, 'moodAfter', RelationshipMood.values),
        stageBefore: _enum(json, 'stageBefore', RelationshipStage.values),
        stageAfter: _enum(json, 'stageAfter', RelationshipStage.values),
        originConversationId: json['originConversationId']?.toString(),
        originNameSnapshot: _string(json, 'originNameSnapshot'),
        sourceMessageIds: _strings(json['sourceMessageIds']),
        revision: _integer(json, 'revision'),
        occurredAt: _dateTime(json, 'occurredAt'),
        confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
        createdBy: _enum(json, 'createdBy', RelationshipEventCreator.values),
        createdAt: _dateTime(json, 'createdAt'),
        notesBefore: json['notesBefore']?.toString() ?? '',
        notesAfter: json['notesAfter']?.toString() ?? '',
      );

  static Map<String, dynamic> skill(CharacterSkill item) => {
        'id': item.id,
        'characterId': item.characterId,
        'name': item.name,
        'domain': item.domain,
        'description': item.description,
        'instructions': item.instructions,
        'requiredPermissions':
            item.requiredPermissions.map((item) => item.name).toList(),
        'createdAt': _date(item.createdAt),
        'updatedAt': _date(item.updatedAt),
      };

  static CharacterSkill decodeSkill(Map<String, dynamic> json) =>
      CharacterSkill(
        id: _string(json, 'id'),
        characterId: _string(json, 'characterId'),
        name: _string(json, 'name'),
        domain: _string(json, 'domain'),
        description: _string(json, 'description'),
        instructions: _strings(json['instructions']),
        requiredPermissions:
            _enums(json['requiredPermissions'], ToolPermission.values),
        createdAt: _dateTime(json, 'createdAt'),
        updatedAt: _dateTime(json, 'updatedAt'),
      );

  static Map<String, dynamic> task(AgentTask item) => {
        'id': item.id,
        'groupId': item.groupId,
        'characterId': item.characterId,
        'userRequest': item.userRequest,
        'status': item.status.name,
        'requestedPermissions':
            item.requestedPermissions.map((item) => item.name).toList(),
        'plan': item.plan,
        'resultSummary': item.resultSummary,
        'createdAt': _date(item.createdAt),
        'currentStep': item.currentStep,
        'completedOperations': item.completedOperations,
        'pendingToolRequestJson': item.pendingToolRequestJson,
        'updatedAt': item.updatedAt?.toIso8601String(),
        'lastError': item.lastError,
        'workModeTask': item.workModeTask,
      };

  static AgentTask decodeTask(Map<String, dynamic> json) => AgentTask(
        id: _string(json, 'id'),
        groupId: _string(json, 'groupId'),
        characterId: _string(json, 'characterId'),
        userRequest: _string(json, 'userRequest'),
        status: _enum(json, 'status', AgentTaskStatus.values),
        requestedPermissions:
            _enums(json['requestedPermissions'], ToolPermission.values),
        plan: json['plan']?.toString() ?? '',
        resultSummary: json['resultSummary']?.toString() ?? '',
        createdAt: _dateTime(json, 'createdAt'),
        currentStep: (json['currentStep'] as num?)?.toInt() ?? 0,
        completedOperations: _strings(json['completedOperations']),
        pendingToolRequestJson:
            json['pendingToolRequestJson']?.toString() ?? '',
        updatedAt: _optionalDate(json['updatedAt']),
        lastError: json['lastError']?.toString() ?? '',
        workModeTask: json['workModeTask'] as bool? ?? false,
      );

  static Map<String, dynamic> workspace(WorkModeWorkspace item) => {
        'id': item.id,
        'conversationId': item.conversationId,
        'conversationType': item.conversationType,
        'updatedAt': _date(item.updatedAt),
      };

  static WorkModeWorkspace decodeWorkspace(Map<String, dynamic> json) =>
      WorkModeWorkspace(
        id: _string(json, 'id'),
        conversationId: _string(json, 'conversationId'),
        conversationType: _string(json, 'conversationType'),
        // Device-local workspace paths are intentionally not portable.
        workDirPath: '',
        updatedAt: _dateTime(json, 'updatedAt'),
      );

  static String _string(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) throw FormatException('字段 $key 无效');
    return value;
  }

  static int _integer(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! num) throw FormatException('字段 $key 无效');
    return value.toInt();
  }

  static String _date(DateTime value) => value.toUtc().toIso8601String();

  static DateTime _dateTime(Map<String, dynamic> json, String key) =>
      DateTime.parse(_string(json, key));

  static DateTime? _optionalDate(Object? value) =>
      value == null ? null : DateTime.parse(value.toString());

  static List<String> _strings(Object? value) {
    if (value is! List) return const [];
    final result = <String>[];
    for (final item in value) {
      if (item is String) {
        result.add(item);
      }
    }
    return result;
  }

  static T _enum<T extends Enum>(
    Map<String, dynamic> json,
    String key,
    List<T> values,
  ) {
    final raw = json[key];
    if (raw == null) {
      throw FormatException('字段 $key 缺失');
    }
    final name = raw.toString();
    final found = values.where((item) => item.name == name);
    if (found.isEmpty) {
      throw FormatException('字段 $key 值 "$name" 不在已知枚举 $values 中');
    }
    return found.first;
  }

  static T? _optionalEnum<T extends Enum>(Object? raw, List<T> values) {
    if (raw == null) return null;
    final name = raw.toString();
    final found = values.where((item) => item.name == name);
    if (found.isEmpty) {
      throw FormatException('枚举值 "$name" 不在已知枚举 $values 中');
    }
    return found.first;
  }

  static CharacterGender? _decodeGender(Object? raw) {
    if (raw is! String) return null;
    for (final gender in CharacterGender.values) {
      if (gender.name == raw) return gender;
    }
    return null;
  }

  static List<T> _enums<T extends Enum>(Object? value, List<T> values) {
    final strings = _strings(value);
    if (strings.isEmpty || values.isEmpty) return const [];
    return strings.map((name) {
      final found = values.where((item) => item.name == name);
      if (found.isEmpty) {
        throw FormatException('枚举值 "$name" 不在已知枚举 $values 中');
      }
      return found.first;
    }).toList();
  }

  static String _publicUrl(String value) {
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    if (uri == null) return '';
    const secretParameters = {
      'key',
      'apikey',
      'legacyapikey',
      'credential',
      'credentialid',
      'token',
      'accesstoken',
      'authorization',
      'secret',
      'password',
    };
    final query = Map<String, List<String>>.from(uri.queryParametersAll)
      ..removeWhere((key, _) =>
          secretParameters.contains(key.toLowerCase().replaceAll('_', '')));
    final sanitized = uri
        .replace(userInfo: '', queryParameters: query, fragment: '')
        .toString();
    return sanitized.endsWith('#')
        ? sanitized.substring(0, sanitized.length - 1)
        : sanitized;
  }
}
