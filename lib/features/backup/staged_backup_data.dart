import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';

import 'backup_entity_codec.dart';
import 'backup_models.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';

part 'staged_backup_data_json_guard.dart';
part 'staged_backup_data_validation.dart';
part 'staged_backup_data_io.dart';

class StagedBackupData {
  /// Import limits apply before JSON materialization. Backup files are
  /// untrusted input, so the archive-level limits alone are not sufficient to
  /// prevent a large JSON tree or one pathological JSONL record from exhausting
  /// the app process.
  static const int maxRecordsPerFile = 100000;

  /// Keep the per-file cap well below the archive entry limit so a malformed
  /// document cannot consume the mobile process before record validation.
  static const int maxJsonFileBytes = 32 * 1024 * 1024;

  /// Bound the combined input as well as each individual file. The staged
  /// model still retains validated records for the restore plan, so this cap
  /// limits the maximum amount of trusted materialized data as well.
  static const int maxAggregateJsonBytes = 128 * 1024 * 1024;
  static const int maxJsonLineBytes = 2 * 1024 * 1024;
  static const int maxJsonDepth = 32;
  static const int maxJsonStringCharacters = 4 * 1024 * 1024;

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
      Directory staging, BackupManifest manifest,
      {int maxAggregateBytes = maxAggregateJsonBytes}) async {
    if (maxAggregateBytes < 0) {
      throw ArgumentError.value(maxAggregateBytes, 'maxAggregateBytes');
    }
    await _checkAggregateJsonSize(staging, maxAggregateBytes);
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
    _validateBackupData(data, manifest);
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
    for (final id in _stagedBackupStrings(value)) {
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
    for (final id in _stagedBackupStrings(value)) {
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
      SearchProviderConfigStore.runtimeSettingsKey,
      AiGovernanceStore.globalSearchPolicyKey,
      AiGovernanceStore.conversationSearchPoliciesKey,
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
    final result = <Map<String, dynamic>>[];
    await for (final text
        in _jsonArrayRecords(File('${root.path}/$path'), path)) {
      result.add(
        _stagedBackupRecord(
          _decodeBoundedJson(
            text,
            path,
            maxBytes: maxJsonFileBytes,
          ),
        ),
      );
    }
    return result;
  }

  /// Validates a record-array file without reading the whole JSON document.
  /// Export validation uses this same path so a large backup is never
  /// materialized twice merely to verify its staging directory.
  static Future<void> validateRecordFile(File file, String path) async {
    await for (final text in _jsonArrayRecords(file, path)) {
      _decodeBoundedJson(text, path, maxBytes: maxJsonFileBytes);
    }
  }

  /// Validates a JSONL file with the same byte, record-count, and JSON-shape
  /// limits used during import. The line splitter operates on raw bytes so a
  /// malformed or unterminated line cannot grow without bound before the
  /// limit is checked.
  static Future<void> validateJsonLinesFile(File file, String path) async {
    await for (final text in _boundedJsonLines(file, path)) {
      _decodeBoundedJson(
        text,
        path,
        maxBytes: maxJsonLineBytes,
        textAlreadyByteBounded: true,
      );
    }
  }

  /// Checks the aggregate size of JSON/JSONL data files before the exporter
  /// creates a package that the importer would reject later.
  static Future<void> validateJsonDataAggregate(Iterable<File> files) async {
    var total = 0;
    for (final file in files) {
      total += await file.length();
      if (total > maxAggregateJsonBytes) {
        throw const BackupException('备份数据总大小超过限制');
      }
    }
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
    final file = File('${root.path}/$path');
    await for (final line in _boundedJsonLines(file, path)) {
      result.add(
        _stagedBackupRecord(
          _decodeBoundedJson(
            line,
            path,
            maxBytes: maxJsonLineBytes,
            textAlreadyByteBounded: true,
          ),
        ),
      );
    }
    return result;
  }

  /// Emits bounded, UTF-8 decoded JSONL records without allowing an
  /// unterminated byte sequence to accumulate beyond [maxJsonLineBytes].
  static Stream<String> _boundedJsonLines(File file, String path) async* {
    final fileBytes = await file.length();
    if (fileBytes > maxJsonFileBytes) {
      throw BackupException('备份数据文件过大：$path');
    }

    final lineBytes = <int>[];
    var pendingCarriageReturn = false;
    var recordCount = 0;

    String? decodeLine() {
      if (lineBytes.isEmpty) return null;
      try {
        final decoded = utf8.decode(lineBytes);
        lineBytes.clear();
        return decoded;
      } on FormatException {
        throw BackupException('备份记录格式无效：$path');
      }
    }

    void checkRecordCount(String text) {
      if (text.trim().isEmpty) return;
      recordCount++;
      if (recordCount > maxRecordsPerFile) {
        throw BackupException('备份记录数量超出限制：$path');
      }
    }

    await for (final chunk in file.openRead()) {
      for (final byte in chunk) {
        if (pendingCarriageReturn) {
          final text = decodeLine();
          if (text != null) {
            checkRecordCount(text);
            yield text;
          }
          pendingCarriageReturn = false;
          if (byte == 0x0a) continue;
        }
        if (byte == 0x0d) {
          pendingCarriageReturn = true;
          continue;
        }
        if (byte == 0x0a) {
          final text = decodeLine();
          if (text != null) {
            checkRecordCount(text);
            yield text;
          }
          continue;
        }
        if (lineBytes.length >= maxJsonLineBytes) {
          throw BackupException('备份记录行过长：$path');
        }
        lineBytes.add(byte);
      }
    }

    if (pendingCarriageReturn) {
      final text = decodeLine();
      if (text != null) {
        checkRecordCount(text);
        yield text;
      }
    } else if (lineBytes.isNotEmpty) {
      final text = decodeLine();
      if (text != null) {
        checkRecordCount(text);
        yield text;
      }
    }
  }

  static Future<Map<String, dynamic>> _map(
    Directory root,
    String path,
  ) async {
    final decoded = _decodeBoundedJson(
      await _readBoundedText(root, path),
      path,
      maxMapEntries: maxRecordsPerFile,
      textAlreadyByteBounded: true,
    );
    if (decoded is! Map) throw BackupException('数据文件格式无效：$path');
    return Map<String, dynamic>.from(decoded);
  }

  static Stream<String> _jsonArrayRecords(File file, String path) async* {
    final fileBytes = await file.length();
    if (fileBytes > maxJsonFileBytes) {
      throw BackupException('备份数据文件过大：$path');
    }
    final parser = _BackupJsonArrayStreamParser(
      path: path,
      maxRecords: maxRecordsPerFile,
    );
    await for (final chunk in file.openRead().transform(utf8.decoder)) {
      for (final record in parser.add(chunk)) {
        yield record;
      }
    }
    for (final record in parser.finish()) {
      yield record;
    }
  }

  static dynamic _decodeBoundedJson(
    String text,
    String path, {
    int maxBytes = maxJsonFileBytes,
    int? maxArrayItems,
    int? maxMapEntries,
    bool textAlreadyByteBounded = false,
  }) {
    if (!textAlreadyByteBounded && utf8.encode(text).length > maxBytes) {
      throw BackupException('备份数据文件过大：$path');
    }
    _BackupJsonGuard(
      text: text,
      path: path,
      maxArrayItems: maxArrayItems,
      maxMapEntries: maxMapEntries,
    ).validate();
    try {
      return jsonDecode(text);
    } on FormatException {
      throw BackupException('数据文件格式无效：$path');
    }
  }

  /// Decodes a bounded JSON document after the caller has optionally checked
  /// its file length. [textAlreadyByteBounded] avoids encoding the same large
  /// string a second time when that length check already happened on disk.
  static dynamic decodeBoundedJsonText(
    String text,
    String path, {
    int maxBytes = maxJsonFileBytes,
    int? maxArrayItems,
    int? maxMapEntries,
    bool textAlreadyByteBounded = false,
  }) =>
      _decodeBoundedJson(
        text,
        path,
        maxBytes: maxBytes,
        maxArrayItems: maxArrayItems,
        maxMapEntries: maxMapEntries,
        textAlreadyByteBounded: textAlreadyByteBounded,
      );

  static Future<String> _readBoundedText(
    Directory root,
    String path,
  ) async {
    final file = File('${root.path}/$path');
    final bytes = await file.length();
    if (bytes > maxJsonFileBytes) {
      throw BackupException('备份数据文件过大：$path');
    }
    return file.readAsString();
  }
}
