import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';

import 'backup_entity_codec.dart';
import 'backup_models.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';

class StagedBackupData {
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
  final List<Map<String, dynamic>> userProfiles;
  final List<Map<String, dynamic>> permanentMemories;
  final List<Map<String, dynamic>> relationshipEvents;
  final Map<String, dynamic> settings;

  const StagedBackupData({
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
    required this.userProfiles,
    required this.permanentMemories,
    required this.relationshipEvents,
    required this.settings,
  });

  static Future<StagedBackupData> load(
    Directory staging,
    BackupManifest manifest,
  ) async {
    final data = StagedBackupData(
      apiConfigs: await _records(staging, 'data/api_configs.json'),
      characters: await _records(staging, 'data/characters.json'),
      groups: await _records(staging, 'data/groups.json'),
      messages: await _lines(staging, 'data/messages.jsonl'),
      groupMemories: await _records(staging, 'data/group_memories.json'),
      characterMemories:
          await _records(staging, 'data/character_memories.json'),
      relationships: await _optionalRecords(staging, 'data/relationships.json'),
      skills: await _records(staging, 'data/skills.json'),
      tasks: await _records(staging, 'data/agent_tasks.json'),
      workspaces: await _records(staging, 'data/work_mode.json'),
      userProfiles: manifest.includesGlobalData
          ? await _records(staging, 'data/user_profile.json')
          : await _optionalRecords(staging, 'data/user_profile.json'),
      permanentMemories:
          await _optionalRecords(staging, 'data/permanent_memories.json'),
      relationshipEvents:
          await _optionalRecords(staging, 'data/relationship_events.json'),
      settings: await _map(staging, 'data/settings.json'),
    );
    data._validate(manifest);
    return data;
  }

  int conflicts(DatabaseService db) {
    var count = 0;
    count += _conflicts(apiConfigs, db.apiConfigBox.containsKey);
    count += _conflicts(characters, db.aiCharacterBox.containsKey);
    count += _conflicts(groups, db.chatGroupBox.containsKey);
    count += _conflicts(messages, db.messageBox.containsKey);
    count += _conflicts(groupMemories, db.groupMemoryBox.containsKey);
    count += _conflicts(characterMemories, db.characterMemoryBox.containsKey);
    count += _conflicts(relationships, db.relationshipStateBox.containsKey);
    count += _conflicts(skills, db.characterSkillBox.containsKey);
    count += _conflicts(tasks, db.agentTaskBox.containsKey);
    count += _conflicts(workspaces, db.workModeWorkspaceBox.containsKey);
    count += _conflicts(userProfiles, db.userProfileBox.containsKey);
    count += _conflicts(permanentMemories, db.permanentMemoryBox.containsKey);
    count +=
        _conflicts(relationshipEvents, db.relationshipEventBox.containsKey);
    count += settings.keys.where(db.appSettingsBox.containsKey).length;
    return count;
  }

  void _validate(BackupManifest manifest) {
    _validateRecordKeys();
    _validateSettingKeys();
    final ids = <String, Set<String>>{
      'apiConfigs': _ids(apiConfigs),
      'characters': _ids(characters),
      'groups': _ids(groups),
      'messages': _ids(messages),
      'characterMemories': _ids(characterMemories),
      'relationships': _ids(relationships),
      'skills': _ids(skills),
      'agentTasks': _ids(tasks),
      'userProfiles': _ids(userProfiles),
      'permanentMemories': _ids(permanentMemories),
      'relationshipEvents': _ids(relationshipEvents),
    };
    _expectCounts(manifest);
    final apiIds = ids['apiConfigs']!;
    final characterIds = ids['characters']!;
    final groupIds = ids['groups']!;
    final messageIds = ids['messages']!;
    final memoryIds = ids['permanentMemories']!;
    final eventIds = ids['relationshipEvents']!;

    if (manifest.schemaVersion >= 2 &&
        manifest.backupKind == BackupKind.conversation &&
        (userProfiles.isNotEmpty || relationships.isNotEmpty)) {
      throw const BackupException('会话备份不得包含 UserProfile 或全局关系快照');
    }

    for (final record in characters) {
      final value = BackupEntityCodec.value(record);
      final apiConfigId = value['apiConfigId']?.toString() ?? '';
      if (apiConfigId.isNotEmpty && !apiIds.contains(apiConfigId)) {
        throw BackupException('角色引用了不存在的 API 配置：$apiConfigId');
      }
      for (final skillId in _strings(value['skillIds'])) {
        if (!ids['skills']!.contains(skillId)) {
          throw BackupException('角色引用了不存在的技能：$skillId');
        }
      }
    }
    for (final record in groups) {
      for (final characterId
          in _strings(BackupEntityCodec.value(record)['aiCharacterIds'])) {
        if (!characterIds.contains(characterId)) {
          throw BackupException('群聊引用了不存在的角色：$characterId');
        }
      }
    }
    for (final record in messages) {
      final value = BackupEntityCodec.value(record);
      _validateConversation(value['groupId'], groupIds, characterIds);
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
    for (final record in groupMemories) {
      _validateConversation(
        BackupEntityCodec.value(record)['groupId'],
        groupIds,
        characterIds,
      );
    }
    for (final record in characterMemories) {
      final value = BackupEntityCodec.value(record);
      _validateConversation(value['groupId'], groupIds, characterIds);
      _require(ids: characterIds, value: value['characterId']);
    }
    for (final record in relationships) {
      final value = BackupEntityCodec.value(record);
      if (manifest.schemaVersion >= 2 && value['groupId'] != 'global') {
        throw const BackupException('v2 relationships 必须是全局快照');
      }
      if (manifest.schemaVersion < 2) {
        _validateConversation(value['groupId'], groupIds, characterIds);
      }
      _require(ids: characterIds, value: value['sourceCharacterId']);
      if (value['targetType'] == 'ai') {
        _require(ids: characterIds, value: value['targetId']);
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
    for (final record in userProfiles) {
      if (BackupEntityCodec.key(record) != 'me') {
        throw const BackupException('user_profile.json 只能包含 me');
      }
    }
    for (final record in permanentMemories) {
      final value = BackupEntityCodec.value(record);
      _require(ids: characterIds, value: value['observerCharacterId']);
      _validateSubjectIds(value['subjectIds'], characterIds);
      _validateSubjectIds(value['participantIds'], characterIds);
      _validateSourceMessageIds(
        value['sourceMessageIds'],
        messageIds,
        manifest,
      );
      for (final supersedesId in _strings(value['supersedesIds'])) {
        if (!memoryIds.contains(supersedesId)) {
          throw BackupException('永久记忆引用了不存在的 supersedes 记录：$supersedesId');
        }
      }
      _validateOriginConversation(
        value['originConversationId'],
        manifest,
        groupIds,
        characterIds,
      );
    }
    for (final record in relationshipEvents) {
      final value = BackupEntityCodec.value(record);
      _require(ids: characterIds, value: value['sourceCharacterId']);
      if (value['targetType'] == 'ai') {
        _require(ids: characterIds, value: value['targetId']);
      } else if (value['targetType'] == 'user') {
        if (value['targetId'] != 'user') {
          throw const BackupException('关系事件的 user targetId 必须保持 user');
        }
      } else {
        throw BackupException('关系事件 targetType 无效：${value['targetType']}');
      }
      _validateSourceMessageIds(
        value['sourceMessageIds'],
        messageIds,
        manifest,
      );
      _validateOriginConversation(
        value['originConversationId'],
        manifest,
        groupIds,
        characterIds,
      );
    }
    for (final record in skills) {
      final characterId = BackupEntityCodec.value(record)['characterId'];
      if (characterId != '' && !characterIds.contains(characterId)) {
        throw BackupException('技能引用了不存在的角色：$characterId');
      }
    }
    for (final record in tasks) {
      final value = BackupEntityCodec.value(record);
      _validateConversation(value['groupId'], groupIds, characterIds);
      _require(ids: characterIds, value: value['characterId']);
    }
    for (final record in workspaces) {
      _validateConversation(
        BackupEntityCodec.value(record)['conversationId'],
        groupIds,
        characterIds,
      );
    }
  }

  void _expectCounts(BackupManifest manifest) {
    final actual = {
      'apiConfigs': apiConfigs.length,
      'characters': characters.length,
      'groups': groups.length,
      'messages': messages.length,
      'groupMemories': groupMemories.length,
      'characterMemories': characterMemories.length,
      'relationships': relationships.length,
      'skills': skills.length,
      'agentTasks': tasks.length,
      'workMode': workspaces.length,
      'settings': settings.length,
      'userProfiles': userProfiles.length,
      'permanentMemories': permanentMemories.length,
      'relationshipEvents': relationshipEvents.length,
    };
    for (final entry in actual.entries) {
      if (manifest.counts.containsKey(entry.key) &&
          manifest.counts[entry.key] != entry.value) {
        throw BackupException('条目计数不一致：${entry.key}');
      }
    }
  }

  static void _validateConversation(
    Object? value,
    Set<String> groupIds,
    Set<String> characterIds,
  ) {
    final id = value?.toString() ?? '';
    final valid = id.startsWith('dm:')
        ? characterIds.contains(id.substring(3))
        : groupIds.contains(id);
    if (!valid) throw BackupException('会话引用无效：$id');
  }

  static void _require({required Set<String> ids, required Object? value}) {
    if (!ids.contains(value)) throw BackupException('引用无效：$value');
  }

  static void _validateSubjectIds(Object? value, Set<String> characterIds) {
    for (final id in _strings(value)) {
      if (id != 'user' && !characterIds.contains(id)) {
        throw BackupException('永久数据引用了不存在的角色：$id');
      }
    }
  }

  static void _validateSourceMessageIds(
    Object? value,
    Set<String> messageIds,
    BackupManifest manifest,
  ) {
    // Deleted conversations intentionally leave auditable evidence IDs in
    // global memories/events; those IDs are external to a later full backup.
    if (manifest.backupKind == BackupKind.full) return;
    for (final id in _strings(value)) {
      _require(ids: messageIds, value: id);
    }
  }

  static void _validateOriginConversation(
    Object? value,
    BackupManifest manifest,
    Set<String> groupIds,
    Set<String> characterIds,
  ) {
    final conversationId = value?.toString();
    if (manifest.backupKind == BackupKind.conversation &&
        conversationId != manifest.conversationId) {
      throw const BackupException('会话全局数据来源场合不匹配');
    }
  }

  static Set<String> _ids(List<Map<String, dynamic>> records) {
    final result = <String>{};
    for (final record in records) {
      final id = BackupEntityCodec.value(record)['id']?.toString();
      if (id == null ||
          id.isEmpty ||
          BackupEntityCodec.key(record) != id ||
          !result.add(id)) {
        throw const BackupException('备份包含无效或重复 ID');
      }
    }
    return result;
  }

  void _validateRecordKeys() {
    for (final records in [
      apiConfigs,
      characters,
      groups,
      messages,
      groupMemories,
      characterMemories,
      relationships,
      skills,
      tasks,
      workspaces,
      userProfiles,
      permanentMemories,
      relationshipEvents,
    ]) {
      final keys = <String>{};
      for (final record in records) {
        if (!keys.add(BackupEntityCodec.key(record))) {
          throw const BackupException('备份包含重复存储键');
        }
      }
    }
  }

  void _validateSettingKeys() {
    const allowed = {
      'theme_mode',
      'app_skin_mode',
      'tts_enabled',
      'direct_chat_read_at',
      'direct_chat_source',
      'direct_chat_last_proactive_at',
      'group_chat_read_at',
      'group_chat_last_proactive_at',
      'pinned_character_ids',
      'pinned_group_ids',
      'memory_pinned_keys_v1',
      'token_usage',
      SearchProviderConfigStore.configsKey,
      SearchProviderConfigStore.defaultProviderKey,
    };
    for (final key in settings.keys) {
      if (!allowed.contains(key) &&
          !key.startsWith('work_mode_enabled:') &&
          !key.startsWith('context_compressed_through:')) {
        throw BackupException('备份包含不允许的设置：$key');
      }
    }
  }

  static int _conflicts(
    List<Map<String, dynamic>> records,
    bool Function(Object key) contains,
  ) =>
      records.where((record) => contains(BackupEntityCodec.key(record))).length;

  static Future<List<Map<String, dynamic>>> _records(
    Directory root,
    String path,
  ) async {
    final decoded = jsonDecode(await File('${root.path}/$path').readAsString());
    if (decoded is! List) throw BackupException('数据文件格式无效：$path');
    return decoded.map(_record).toList(growable: false);
  }

  static Future<List<Map<String, dynamic>>> _optionalRecords(
    Directory root,
    String path,
  ) async {
    final file = File('${root.path}/$path');
    if (!await file.exists()) return const [];
    return _records(root, path);
  }

  static Future<List<Map<String, dynamic>>> _lines(
    Directory root,
    String path,
  ) async {
    final result = <Map<String, dynamic>>[];
    await for (final line in File('${root.path}/$path')
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.trim().isNotEmpty) result.add(_record(jsonDecode(line)));
    }
    return result;
  }

  static Future<Map<String, dynamic>> _map(
    Directory root,
    String path,
  ) async {
    final decoded = jsonDecode(await File('${root.path}/$path').readAsString());
    if (decoded is! Map) throw BackupException('数据文件格式无效：$path');
    return Map<String, dynamic>.from(decoded);
  }

  static Map<String, dynamic> _record(Object? value) {
    if (value is! Map || value['key'] is! String || value['value'] is! Map) {
      throw const BackupException('备份记录格式无效');
    }
    return Map<String, dynamic>.from(value);
  }

  static List<String> _strings(Object? value) =>
      (value as List? ?? const []).map((item) => item.toString()).toList();
}
