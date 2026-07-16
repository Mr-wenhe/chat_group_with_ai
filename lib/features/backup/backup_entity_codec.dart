import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
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
        'credentialRequired':
            item.hasCredential || item.legacyApiKey.isNotEmpty,
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

  static Map<String, dynamic> character(AICharacter item) => {
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
        'toolPermissions':
            item.toolPermissions.map((item) => item.name).toList(),
      };

  static AICharacter decodeCharacter(Map<String, dynamic> json) => AICharacter(
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
      );

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

  static List<String> _strings(Object? value) =>
      (value as List? ?? const []).map((item) => item.toString()).toList();

  static T _enum<T extends Enum>(
    Map<String, dynamic> json,
    String key,
    List<T> values,
  ) =>
      values.firstWhere(
        (item) => item.name == json[key],
        orElse: () => throw FormatException('字段 $key 无效'),
      );

  static List<T> _enums<T extends Enum>(Object? value, List<T> values) =>
      _strings(value)
          .map((name) => values.firstWhere(
                (item) => item.name == name,
                orElse: () => throw FormatException('枚举值 $name 无效'),
              ))
          .toList();

  static String _publicUrl(String value) {
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    if (uri == null) return '';
    const secretParameters = {
      'key',
      'apikey',
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
