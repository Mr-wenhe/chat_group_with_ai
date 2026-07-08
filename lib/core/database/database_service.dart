import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/direct_chat_source.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';

class DatabaseService {
  static const String _aiCharacterBox = 'ai_characters';
  static const String _apiConfigBox = 'api_configs';
  static const String _chatGroupBox = 'chat_groups';
  static const String _messageBox = 'messages';
  static const String _groupMemoryBox = 'group_memories';
  static const String _characterMemoryBox = 'character_memories';
  static const String _relationshipStateBox = 'relationship_states';
  static const String _appSettingsBox = 'app_settings';
  static const String _releaseTemplateManifestAsset =
      'assets/release_templates/seed_manifest.json';
  static const List<String> _releaseHiveFiles = [
    'ai_characters.hive',
    'api_configs.hive',
    'app_settings.hive',
    'character_memories.hive',
    'chat_groups.hive',
    'group_memories.hive',
    'messages.hive',
    'relationship_states.hive',
  ];

  Directory? _dataDir;
  Timer? _tokenUsageFlushTimer;
  Map<String, dynamic>? _tokenUsageCache;
  Map<String, dynamic>? _messageIdsCache;
  static const Duration _tokenUsageFlushDelay = Duration(seconds: 2);

  Future<void> init() async {
    final dir = await _getDataDir();
    _dataDir = dir;
    debugPrint('[DB] Hive data dir: ${dir.path} (mode: $_storageModeLabel)');
    await Hive.initFlutter(dir.path);
    Hive.registerAdapter(AICharacterAdapter());
    Hive.registerAdapter(ApiConfigAdapter());
    Hive.registerAdapter(ChatGroupAdapter());
    Hive.registerAdapter(MessageAdapter());
    Hive.registerAdapter(GroupMemoryAdapter());
    Hive.registerAdapter(CharacterMemoryAdapter());
    Hive.registerAdapter(RelationshipTargetTypeAdapter());
    Hive.registerAdapter(RelationshipMoodAdapter());
    Hive.registerAdapter(RelationshipStateAdapter());

    await _openBoxSafely<AICharacter>(_aiCharacterBox);
    await _openBoxSafely<ApiConfig>(_apiConfigBox);
    await _openBoxSafely<ChatGroup>(_chatGroupBox);
    await _openBoxSafely<Message>(_messageBox);
    await _openBoxSafely<GroupMemory>(_groupMemoryBox);
    await _openBoxSafely<CharacterMemory>(_characterMemoryBox);
    await _openBoxSafely<RelationshipState>(_relationshipStateBox);
    await _openBoxSafely<dynamic>(_appSettingsBox);
    await _hydrateApiKeysFromSecureStorage();
  }

  Future<void> _hydrateApiKeysFromSecureStorage() async {
    if (apiConfigBox.isEmpty) return;
    final secureStorage = SecureStorageService();
    bool anyChanged = false;
    for (final config in apiConfigBox.values) {
      if (config.apiKey.isNotEmpty) continue;
      final key = await secureStorage.getApiConfigKey(config.id);
      if (key != null && key.isNotEmpty) {
        config.apiKey = key;
        await apiConfigBox.put(config.id, config);
        anyChanged = true;
      }
    }
    if (anyChanged) {
      debugPrint('[DB] Hydrated API keys from secure storage');
    }
  }

  Future<Directory> _getDataDir() async {
    final supportDir = await getApplicationSupportDirectory();
    final userDataDir = Directory('${supportDir.path}/data');
    await _ensureDir(userDataDir);
    await _seedReleaseDataIfNeeded(userDataDir);
    return userDataDir;
  }

  Future<void> _openBoxSafely<T>(String name) async {
    try {
      await Hive.openBox<T>(name);
    } on FileSystemException catch (_) {
      try {
        await Hive.deleteBoxFromDisk(name);
      } on FileSystemException catch (_) {
        // Cleanup failed; try opening anyway.
      }
      await Hive.openBox<T>(name);
    }
  }

  Future<void> _ensureDir(Directory dir) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  Future<void> _seedReleaseDataIfNeeded(Directory userDataDir) async {
    final fileNames = await _loadReleaseTemplateFileNames();
    for (final fileName in fileNames) {
      final target = File('${userDataDir.path}/$fileName');
      if (await target.exists()) continue;
      await target.create(recursive: true);
      debugPrint('[DB] Created empty release hive template: ${target.path}');
    }
  }

  Future<List<String>> _loadReleaseTemplateFileNames() async {
    try {
      final raw = await rootBundle.loadString(_releaseTemplateManifestAsset);
      final decoded = jsonDecode(raw);
      final files = decoded is Map<String, dynamic> ? decoded['files'] : null;
      if (files is List) {
        return files.whereType<String>().toList();
      }
    } on FlutterError catch (e) {
      debugPrint(
          '[DB] Missing release template manifest $_releaseTemplateManifestAsset: $e');
    } on FormatException catch (e) {
      debugPrint(
          '[DB] Invalid release template manifest $_releaseTemplateManifestAsset: $e');
    }
    return _releaseHiveFiles;
  }

  Future<void> saveApiConfig(ApiConfig config) async {
    await apiConfigBox.put(config.id, config);
  }

  Future<void> deleteApiConfig(String id) async {
    await apiConfigBox.delete(id);
  }

  Future<void> clearAllData() async {
    await apiConfigBox.clear();
    await aiCharacterBox.clear();
    await chatGroupBox.clear();
    await messageBox.clear();
    await groupMemoryBox.clear();
    await characterMemoryBox.clear();
    await relationshipStateBox.clear();
    await appSettingsBox.delete(_messageIdsByGroupKey);
    await appSettingsBox.delete(_directChatReadAtKey);
    await appSettingsBox.delete(_directChatSourceKey);
    await appSettingsBox.delete(_directChatLastProactiveAtKey);
    await appSettingsBox.delete(_groupChatReadAtKey);
    await appSettingsBox.delete(_pinnedCharacterIdsKey);
    await appSettingsBox.delete(_pinnedGroupIdsKey);
    _tokenUsageCache = _emptyTokenUsage();
    _messageIdsCache = null;
    _tokenUsageFlushTimer?.cancel();
  }

  Box<AICharacter> get aiCharacterBox => Hive.box<AICharacter>(_aiCharacterBox);
  Box<ApiConfig> get apiConfigBox => Hive.box<ApiConfig>(_apiConfigBox);
  Box<ChatGroup> get chatGroupBox => Hive.box<ChatGroup>(_chatGroupBox);
  Box<Message> get messageBox => Hive.box<Message>(_messageBox);
  Box<GroupMemory> get groupMemoryBox => Hive.box<GroupMemory>(_groupMemoryBox);
  Box<CharacterMemory> get characterMemoryBox =>
      Hive.box<CharacterMemory>(_characterMemoryBox);
  Box<RelationshipState> get relationshipStateBox =>
      Hive.box<RelationshipState>(_relationshipStateBox);
  Box<dynamic> get appSettingsBox => Hive.box(_appSettingsBox);
  String? get dataDirPath => _dataDir?.path;
  String get _storageModeLabel =>
      kReleaseMode ? 'release-user-dir' : 'project-data';

  static const String _messageIdsByGroupKey = 'message_ids_by_group';

  Future<List<Message>> messagesForGroup(String groupId) async {
    final indexedIds = _messageIdsForGroup(groupId);
    if (indexedIds != null) {
      final indexedMessages = indexedIds
          .map((id) => messageBox.get(id))
          .whereType<Message>()
          .where((m) => m.groupId == groupId)
          .toList();
      if (indexedMessages.length == indexedIds.length) {
        indexedMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        return indexedMessages;
      }
    }

    final messages = messageBox.values
        .where((m) => m.groupId == groupId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    await _saveMessageIdsForGroup(
      groupId,
      messages.map((message) => message.id).toList(),
    );
    return messages;
  }

  Future<void> addMessageToGroupIndex(Message message) async {
    final byGroup = _messageIdsByGroup();
    final ids = List<String>.from(byGroup[message.groupId] ?? const <String>[]);
    if (ids.contains(message.id)) return;
    ids.add(message.id);
    byGroup[message.groupId] = ids;
    _messageIdsCache = Map<String, dynamic>.from(byGroup);
    await appSettingsBox.put(_messageIdsByGroupKey, _messageIdsCache);
  }

  Map<String, dynamic> _messageIdsByGroup() {
    if (_messageIdsCache != null) return _messageIdsCache!;
    final raw = appSettingsBox.get(_messageIdsByGroupKey);
    final map =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    _messageIdsCache = map;
    return map;
  }

  List<String>? _messageIdsForGroup(String groupId) {
    final ids = _messageIdsByGroup()[groupId];
    if (ids is! List) return null;
    return ids.whereType<String>().toList();
  }

  Future<void> _saveMessageIdsForGroup(
    String groupId,
    List<String> ids,
  ) async {
    final byGroup = _messageIdsByGroup();
    byGroup[groupId] = ids;
    _messageIdsCache = Map<String, dynamic>.from(byGroup);
    await appSettingsBox.put(_messageIdsByGroupKey, _messageIdsCache);
  }

  static const String _directChatReadAtKey = 'direct_chat_read_at';
  static const String _directChatSourceKey = 'direct_chat_source';
  static const String _directChatLastProactiveAtKey =
      'direct_chat_last_proactive_at';
  static const String _groupChatReadAtKey = 'group_chat_read_at';
  static const String _pinnedCharacterIdsKey = 'pinned_character_ids';
  static const String _pinnedGroupIdsKey = 'pinned_group_ids';

  Map<String, DateTime> directChatReadAtByConversation() {
    return _dateTimeMapFromSettings(_directChatReadAtKey);
  }

  Future<void> markDirectChatRead(
    String conversationId, {
    DateTime? readAt,
  }) async {
    final map = Map<String, String>.from(
      appSettingsBox.get(_directChatReadAtKey) is Map
          ? Map<String, dynamic>.from(appSettingsBox.get(_directChatReadAtKey))
              .map((key, value) => MapEntry(key, value.toString()))
          : const <String, String>{},
    );
    map[conversationId] = (readAt ?? DateTime.now()).toIso8601String();
    await appSettingsBox.put(_directChatReadAtKey, map);
  }

  Map<String, DateTime> groupChatReadAtByGroup() {
    return _dateTimeMapFromSettings(_groupChatReadAtKey);
  }

  Future<void> markGroupChatRead(
    String groupId, {
    DateTime? readAt,
  }) async {
    final map = Map<String, String>.from(
      appSettingsBox.get(_groupChatReadAtKey) is Map
          ? Map<String, dynamic>.from(appSettingsBox.get(_groupChatReadAtKey))
              .map((key, value) => MapEntry(key, value.toString()))
          : const <String, String>{},
    );
    map[groupId] = (readAt ?? DateTime.now()).toIso8601String();
    await appSettingsBox.put(_groupChatReadAtKey, map);
  }

  Map<String, DirectChatSource> directChatSourceByConversation() {
    final raw = appSettingsBox.get(_directChatSourceKey);
    final map =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    return map.map((key, value) {
      final source = value == DirectChatSource.group.name
          ? DirectChatSource.group
          : DirectChatSource.direct;
      return MapEntry(key, source);
    });
  }

  Future<void> saveDirectChatSource(
    String conversationId,
    DirectChatSource source,
  ) async {
    final raw = appSettingsBox.get(_directChatSourceKey);
    final map =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    map[conversationId] = source.name;
    await appSettingsBox.put(_directChatSourceKey, map);
  }

  Map<String, DateTime> directChatLastProactiveAtByCharacter() {
    return _dateTimeMapFromSettings(_directChatLastProactiveAtKey);
  }

  Future<void> saveDirectChatLastProactiveAt(
    String characterId,
    DateTime timestamp,
  ) async {
    final raw = appSettingsBox.get(_directChatLastProactiveAtKey);
    final map =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    map[characterId] = timestamp.toIso8601String();
    await appSettingsBox.put(_directChatLastProactiveAtKey, map);
  }

  Map<String, DateTime> _dateTimeMapFromSettings(String key) {
    final raw = appSettingsBox.get(key);
    final map =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    return map.map((entryKey, value) {
      return MapEntry(
        entryKey,
        DateTime.tryParse(value.toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    });
  }

  Set<String> pinnedCharacterIds() =>
      _stringSetFromSettings(_pinnedCharacterIdsKey);

  Future<void> togglePinnedCharacter(String id) async {
    await _toggleStringSetValue(_pinnedCharacterIdsKey, id);
  }

  Set<String> pinnedGroupIds() => _stringSetFromSettings(_pinnedGroupIdsKey);

  Future<void> togglePinnedGroup(String id) async {
    await _toggleStringSetValue(_pinnedGroupIdsKey, id);
  }

  Set<String> _stringSetFromSettings(String key) {
    final raw = appSettingsBox.get(key);
    if (raw is! List) return <String>{};
    return raw.whereType<String>().toSet();
  }

  Future<void> _toggleStringSetValue(String key, String value) async {
    final values = _stringSetFromSettings(key);
    if (values.contains(value)) {
      values.remove(value);
    } else {
      values.add(value);
    }
    await appSettingsBox.put(key, values.toList()..sort());
  }

  static const String _themeModeKey = 'theme_mode';

  ThemeMode get savedThemeMode {
    final val = appSettingsBox.get(_themeModeKey);
    if (val == 'light') return ThemeMode.light;
    if (val == 'system') return ThemeMode.system;
    return ThemeMode.dark;
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    final val = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      _ => 'dark',
    };
    await appSettingsBox.put(_themeModeKey, val);
  }

  static const String _tokenUsageKey = 'token_usage';

  Map<String, dynamic> getTokenUsage() {
    if (_tokenUsageCache != null) {
      return Map<String, dynamic>.from(_tokenUsageCache!);
    }
    final raw = appSettingsBox.get(_tokenUsageKey);
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return _emptyTokenUsage();
  }

  Map<String, dynamic> _mutableTokenUsage() {
    _tokenUsageCache ??= getTokenUsage();
    return _tokenUsageCache!;
  }

  Map<String, dynamic> _emptyTokenUsage() {
    return {
      'totalInput': 0,
      'totalOutput': 0,
      'totalCachedInput': 0,
      'requestCount': 0,
      'byCharacter': <String, Map<String, int>>{},
      'byGroup': <String, Map<String, int>>{},
    };
  }

  Future<void> recordTokenUsage({
    required String characterId,
    String? groupId,
    required int inputTokens,
    required int outputTokens,
    int cachedTokens = 0,
  }) async {
    final usage = _mutableTokenUsage();
    usage['totalInput'] = (usage['totalInput'] ?? 0) + inputTokens;
    usage['totalOutput'] = (usage['totalOutput'] ?? 0) + outputTokens;
    usage['totalCachedInput'] = (usage['totalCachedInput'] ?? 0) + cachedTokens;
    usage['requestCount'] = (usage['requestCount'] ?? 0) + 1;
    final byChar = Map<String, dynamic>.from(usage['byCharacter'] ?? {});
    final entry = Map<String, int>.from(byChar[characterId] ??
        {'input': 0, 'output': 0, 'cached': 0, 'count': 0});
    entry['input'] = (entry['input'] ?? 0) + inputTokens;
    entry['output'] = (entry['output'] ?? 0) + outputTokens;
    entry['cached'] = (entry['cached'] ?? 0) + cachedTokens;
    entry['count'] = (entry['count'] ?? 0) + 1;
    byChar[characterId] = entry;
    usage['byCharacter'] = byChar;
    if (groupId != null && groupId.isNotEmpty) {
      final byGroup = Map<String, dynamic>.from(usage['byGroup'] ?? {});
      final groupEntry = Map<String, int>.from(byGroup[groupId] ??
          {'input': 0, 'output': 0, 'cached': 0, 'count': 0});
      groupEntry['input'] = (groupEntry['input'] ?? 0) + inputTokens;
      groupEntry['output'] = (groupEntry['output'] ?? 0) + outputTokens;
      groupEntry['cached'] = (groupEntry['cached'] ?? 0) + cachedTokens;
      groupEntry['count'] = (groupEntry['count'] ?? 0) + 1;
      byGroup[groupId] = groupEntry;
      usage['byGroup'] = byGroup;
    }
    _scheduleTokenUsageFlush();
  }

  Future<void> clearTokenUsage() async {
    _tokenUsageFlushTimer?.cancel();
    _tokenUsageCache = _emptyTokenUsage();
    await appSettingsBox.put(_tokenUsageKey, _tokenUsageCache);
  }

  void _scheduleTokenUsageFlush() {
    _tokenUsageFlushTimer?.cancel();
    _tokenUsageFlushTimer =
        Timer(_tokenUsageFlushDelay, () => _flushTokenUsage());
  }

  Future<void> _flushTokenUsage() async {
    final usage = _tokenUsageCache;
    if (usage == null) return;
    await appSettingsBox.put(_tokenUsageKey, Map<String, dynamic>.from(usage));
  }

  static const String _ttsEnabledKey = 'tts_enabled';

  bool get isTtsEnabled => appSettingsBox.get(_ttsEnabledKey) ?? true;

  Future<void> saveTtsEnabled(bool enabled) async {
    await appSettingsBox.put(_ttsEnabledKey, enabled);
  }
}
