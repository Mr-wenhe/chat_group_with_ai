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
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';

part 'backup_entity_codec_records.dart';
part 'backup_entity_codec_memory.dart';

class BackupEntityCodec {
  static Map<String, dynamic> record(
    Object key,
    Map<String, dynamic> value,
  ) =>
      _BackupEntityRecordCodec.record(key, value);

  static String key(Map<String, dynamic> record) =>
      _BackupEntityRecordCodec.key(record);

  static Map<String, dynamic> value(Map<String, dynamic> record) =>
      _BackupEntityRecordCodec.value(record);

  static Map<String, dynamic> apiConfig(ApiConfig item) =>
      _BackupEntityRecordCodec.apiConfig(item);

  static ApiConfig decodeApiConfig(Map<String, dynamic> json) =>
      _BackupEntityRecordCodec.decodeApiConfig(json);

  static Map<String, dynamic> character(AICharacter item) =>
      _BackupEntityRecordCodec.character(item);

  static Map<String, dynamic> characterForBackup(
    AICharacter item, {
    required bool includeMemorySummary,
  }) =>
      _BackupEntityRecordCodec.characterForBackup(
        item,
        includeMemorySummary: includeMemorySummary,
      );

  static AICharacter decodeCharacter(Map<String, dynamic> json) =>
      _BackupEntityRecordCodec.decodeCharacter(json);

  static bool hasValidGender(Map<String, dynamic> json) =>
      _BackupEntityRecordCodec.hasValidGender(json);

  static Map<String, dynamic> group(ChatGroup item) =>
      _BackupEntityRecordCodec.group(item);

  static ChatGroup decodeGroup(Map<String, dynamic> json) =>
      _BackupEntityRecordCodec.decodeGroup(json);

  static Map<String, dynamic> message(
    Message item,
    List<Map<String, dynamic>> media,
  ) =>
      _BackupEntityRecordCodec.message(item, media);

  static Message decodeMessage(
    Map<String, dynamic> json,
    String Function(String path) resolveAttachment,
  ) =>
      _BackupEntityRecordCodec.decodeMessage(json, resolveAttachment);

  static Map<String, dynamic> attachment(
    MediaAttachment item,
    String archivePath,
  ) =>
      _BackupEntityRecordCodec.attachment(item, archivePath);

  static MediaAttachment decodeAttachment(
    Map<String, dynamic> json,
    String Function(String path) resolveAttachment,
  ) =>
      _BackupEntityRecordCodec.decodeAttachment(json, resolveAttachment);

  static Map<String, dynamic> groupMemory(GroupMemory item) =>
      _BackupEntityMemoryCodec.groupMemory(item);

  static GroupMemory decodeGroupMemory(Map<String, dynamic> json) =>
      _BackupEntityMemoryCodec.decodeGroupMemory(json);

  static Map<String, dynamic> characterMemory(CharacterMemory item) =>
      _BackupEntityMemoryCodec.characterMemory(item);

  static CharacterMemory decodeCharacterMemory(Map<String, dynamic> json) =>
      _BackupEntityMemoryCodec.decodeCharacterMemory(json);

  static Map<String, dynamic> relationship(RelationshipState item) =>
      _BackupEntityMemoryCodec.relationship(item);

  static Map<String, dynamic> userProfile(UserProfile item) =>
      _BackupEntityMemoryCodec.userProfile(item);

  static Map<String, dynamic> permanentMemory(
    PermanentMemory item, {
    List<String>? sourceMessageIds,
    List<String>? subjectIds,
    List<String>? participantIds,
    List<String>? supersedesIds,
  }) =>
      _BackupEntityMemoryCodec.permanentMemory(
        item,
        sourceMessageIds: sourceMessageIds,
        subjectIds: subjectIds,
        participantIds: participantIds,
        supersedesIds: supersedesIds,
      );

  static Map<String, dynamic> relationshipEvent(
    RelationshipEvent item, {
    List<String>? sourceMessageIds,
  }) =>
      _BackupEntityMemoryCodec.relationshipEvent(
        item,
        sourceMessageIds: sourceMessageIds,
      );

  static RelationshipState decodeRelationship(Map<String, dynamic> json) =>
      _BackupEntityMemoryCodec.decodeRelationship(json);

  static UserProfile decodeUserProfile(Map<String, dynamic> json) =>
      _BackupEntityMemoryCodec.decodeUserProfile(json);

  static PermanentMemory decodePermanentMemory(
    Map<String, dynamic> json,
  ) =>
      _BackupEntityMemoryCodec.decodePermanentMemory(json);

  static RelationshipEvent decodeRelationshipEvent(
    Map<String, dynamic> json,
  ) =>
      _BackupEntityMemoryCodec.decodeRelationshipEvent(json);

  static Map<String, dynamic> skill(CharacterSkill item) =>
      _BackupEntityMemoryCodec.skill(item);

  static CharacterSkill decodeSkill(Map<String, dynamic> json) =>
      _BackupEntityMemoryCodec.decodeSkill(json);

  static Map<String, dynamic> task(AgentTask item) =>
      _BackupEntityMemoryCodec.task(item);

  static AgentTask decodeTask(Map<String, dynamic> json) =>
      _BackupEntityMemoryCodec.decodeTask(json);

  static Map<String, dynamic> workspace(WorkModeWorkspace item) =>
      _BackupEntityMemoryCodec.workspace(item);

  static WorkModeWorkspace decodeWorkspace(Map<String, dynamic> json) =>
      _BackupEntityMemoryCodec.decodeWorkspace(json);
}
