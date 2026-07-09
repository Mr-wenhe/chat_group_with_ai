import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/autonomous_conversation_config.dart';
import 'package:chat_group/core/models/autonomous_task.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/direct_chat_source.dart';
import 'package:chat_group/core/models/evidence_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';

class DatabaseService {
  static const String _aiCharacterBox = 'ai_characters';
  static const String _apiConfigBox = 'api_configs';
  static const String _chatGroupBox = 'chat_groups';
  static const String _messageBox = 'messages';
  static const String _groupMemoryBox = 'group_memories';
  static const String _characterMemoryBox = 'character_memories';
  static const String _relationshipStateBox = 'relationship_states';
  static const String _appSettingsBox = 'app_settings';
  static const String agentSkillBoxName = 'character_skills';
  static const String agentTaskBoxName = 'agent_tasks';
  static const String autonomousConversationConfigBoxName =
      'autonomous_conversation_configs';
  static const String autonomousTaskBoxName = 'autonomous_tasks';
  static const String autonomousTaskStepBoxName = 'autonomous_task_steps';
  static const String evidenceMemoryBoxName = 'evidence_memories';
  static const String _releaseTemplateManifestAsset =
      'assets/release_templates/seed_manifest.json';
  static const List<String> _releaseHiveFiles = [
    'ai_characters.hive',
    'api_configs.hive',
    'app_settings.hive',
    'character_memories.hive',
    'chat_groups.hive',
    'character_skills.hive',
    'agent_tasks.hive',
    'autonomous_conversation_configs.hive',
    'autonomous_tasks.hive',
    'autonomous_task_steps.hive',
    'evidence_memories.hive',
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
    Hive.registerAdapter(MediaAttachmentAdapter());
    Hive.registerAdapter(ToolPermissionAdapter());
    Hive.registerAdapter(CharacterSkillAdapter());
    Hive.registerAdapter(AgentTaskStatusAdapter());
    Hive.registerAdapter(AgentTaskAdapter());
    Hive.registerAdapter(AutonomousTaskStatusAdapter());
    Hive.registerAdapter(AutonomousTaskPhaseAdapter());
    Hive.registerAdapter(AutonomousConversationConfigAdapter());
    Hive.registerAdapter(AutonomousTaskAdapter());
    Hive.registerAdapter(AutonomousTaskStepAdapter());
    Hive.registerAdapter(EvidenceMemoryTypeAdapter());
    Hive.registerAdapter(EvidenceMemoryAdapter());

    await _openBoxSafely<AICharacter>(_aiCharacterBox);
    await _openBoxSafely<ApiConfig>(_apiConfigBox);
    await _openBoxSafely<ChatGroup>(_chatGroupBox);
    await _openBoxSafely<Message>(_messageBox);
    await _openBoxSafely<GroupMemory>(_groupMemoryBox);
    await _openBoxSafely<CharacterMemory>(_characterMemoryBox);
    await _openBoxSafely<RelationshipState>(_relationshipStateBox);
    await _openBoxSafely<CharacterSkill>(agentSkillBoxName);
    await _openBoxSafely<AgentTask>(agentTaskBoxName);
    await _openBoxSafely<AutonomousConversationConfig>(
        autonomousConversationConfigBoxName);
    await _openBoxSafely<AutonomousTask>(autonomousTaskBoxName);
    await _openBoxSafely<AutonomousTaskStep>(autonomousTaskStepBoxName);
    await _openBoxSafely<EvidenceMemory>(evidenceMemoryBoxName);
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
    await characterSkillBox.clear();
    await agentTaskBox.clear();
    await autonomousConversationConfigBox.clear();
    await autonomousTaskBox.clear();
    await autonomousTaskStepBox.clear();
    await evidenceMemoryBox.clear();
    await appSettingsBox.delete(_messageIdsByGroupKey);
    await appSettingsBox.delete(_directChatReadAtKey);
    await appSettingsBox.delete(_directChatSourceKey);
    await appSettingsBox.delete(_directChatLastProactiveAtKey);
    await appSettingsBox.delete(_groupChatReadAtKey);
    await appSettingsBox.delete(_groupChatLastProactiveAtKey);
    await appSettingsBox.delete(_pinnedCharacterIdsKey);
    await appSettingsBox.delete(_pinnedGroupIdsKey);
    await appSettingsBox.delete(_aiProcessingDirKey);
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
  Box<CharacterSkill> get characterSkillBox =>
      Hive.box<CharacterSkill>(agentSkillBoxName);
  Box<AgentTask> get agentTaskBox => Hive.box<AgentTask>(agentTaskBoxName);
  Box<AutonomousConversationConfig> get autonomousConversationConfigBox =>
      Hive.box<AutonomousConversationConfig>(
          autonomousConversationConfigBoxName);
  Box<AutonomousTask> get autonomousTaskBox =>
      Hive.box<AutonomousTask>(autonomousTaskBoxName);
  Box<AutonomousTaskStep> get autonomousTaskStepBox =>
      Hive.box<AutonomousTaskStep>(autonomousTaskStepBoxName);
  Box<EvidenceMemory> get evidenceMemoryBox =>
      Hive.box<EvidenceMemory>(evidenceMemoryBoxName);
  Box<dynamic> get appSettingsBox => Hive.box(_appSettingsBox);
  String? get dataDirPath => _dataDir?.path;

  static const String _aiProcessingDirKey = 'ai_processing_dir';

  /// 媒体目录：`<dataDir>/media/`，确保存在后返回。
  Future<Directory> get mediaDir async {
    final base = _dataDir;
    if (base == null) {
      throw StateError('DatabaseService 尚未初始化，无法访问媒体目录');
    }
    final dir = Directory('${base.path}/media');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> get defaultAiProcessingDir async {
    final base = _dataDir;
    if (base == null) {
      throw StateError('DatabaseService 尚未初始化，无法访问 AI 处理目录');
    }
    final dir = Directory('${base.path}/ai_files');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> get aiProcessingDir async {
    final saved = aiProcessingDirPath;
    if (saved != null && saved.trim().isNotEmpty) {
      final dir = Directory(saved).absolute;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    return defaultAiProcessingDir;
  }

  String? get aiProcessingDirPath {
    final raw = appSettingsBox.get(_aiProcessingDirKey);
    return raw is String && raw.trim().isNotEmpty ? raw : null;
  }

  Future<String> effectiveAiProcessingDirPath() async {
    return (await aiProcessingDir).absolute.path;
  }

  Future<void> saveAiProcessingDirPath(String path) async {
    await appSettingsBox.put(
        _aiProcessingDirKey, Directory(path).absolute.path);
  }

  Future<void> resetAiProcessingDirPath() async {
    await appSettingsBox.delete(_aiProcessingDirKey);
  }

  /// 把用户选择的文件复制到媒体目录，并返回附件记录（含 mimeType / 大小 / 视频时长探测）。
  ///
  /// - [source] 原始文件（如相册导出的临时文件）。
  /// - [type] 附件类型：'image' | 'video' | 'file'。
  Future<MediaAttachment> copyToMedia(
    File source,
    String type, {
    String? fileName,
  }) async {
    final dir = await mediaDir;
    final ext = _extensionOf(source.path);
    final id = const Uuid().v4();
    final target = File('${dir.path}/$id$ext');
    await source.copy(target.path);

    final size = await target.length();
    final mimeType = _guessMimeType(target.path, type);

    // 视频探测时长；失败不影响复制结果，仅置空 durationMs。
    int? durationMs;
    if (type == 'video') {
      durationMs = await _probeVideoDuration(target);
    }

    return MediaAttachment(
      id: id,
      type: type,
      localPath: target.path,
      fileName: fileName ?? _fileNameOf(source.path),
      fileSize: size,
      mimeType: mimeType,
      durationMs: durationMs,
    );
  }

  Future<MediaAttachment> copyBytesToMedia(
    Uint8List bytes,
    String type, {
    required String fileName,
    String? mimeType,
  }) async {
    final dir = await mediaDir;
    final ext = _extensionOf(fileName);
    final id = const Uuid().v4();
    final target = File('${dir.path}/$id$ext');
    await target.writeAsBytes(bytes, flush: true);

    int? durationMs;
    if (type == 'video') {
      durationMs = await _probeVideoDuration(target);
    }

    return MediaAttachment(
      id: id,
      type: type,
      localPath: target.path,
      fileName: fileName,
      fileSize: bytes.lengthInBytes,
      mimeType: mimeType ?? _guessMimeType(fileName, type),
      durationMs: durationMs,
    );
  }

  Future<MediaAttachment> copyToAiCharacterDir({
    required File source,
    required String characterId,
    required String characterName,
    String type = 'file',
  }) async {
    final root = await aiProcessingDir;
    final dirName = _safePathSegment(
      '${characterName.trim().isEmpty ? characterId : characterName}_$characterId',
    );
    final dir = Directory('${root.path}/$dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final sourceName = _fileNameOf(source.path);
    final stampedName = '${DateTime.now().millisecondsSinceEpoch}_$sourceName';
    final target = File('${dir.path}/${_safePathSegment(stampedName)}');
    await source.copy(target.path);
    final size = await target.length();

    return MediaAttachment(
      type: type,
      localPath: target.path,
      fileName: sourceName,
      fileSize: size,
      mimeType: _guessMimeType(sourceName, type),
    );
  }

  Future<MediaAttachment> writeBytesToAiCharacterDir({
    required List<int> bytes,
    required String fileName,
    required String characterId,
    required String characterName,
    String type = 'file',
  }) async {
    final root = await aiProcessingDir;
    final dirName = _safePathSegment(
      '${characterName.trim().isEmpty ? characterId : characterName}_$characterId',
    );
    final dir = Directory('${root.path}/$dirName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final stampedName =
        '${DateTime.now().millisecondsSinceEpoch}_${_safePathSegment(fileName)}';
    final target = File('${dir.path}/$stampedName');
    await target.writeAsBytes(bytes, flush: true);
    return MediaAttachment(
      type: type,
      localPath: target.path,
      fileName: fileName,
      fileSize: bytes.length,
      mimeType: _guessMimeType(fileName, type),
    );
  }

  /// 用 video_player 初始化一次以读取视频时长，随后立即释放资源。
  Future<int?> _probeVideoDuration(File file) async {
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.file(file);
      await controller.initialize();
      return controller.value.duration.inMilliseconds;
    } catch (e) {
      debugPrint('[DB] 探测视频时长失败：$e');
      return null;
    } finally {
      await controller?.dispose();
    }
  }

  String _extensionOf(String path) {
    final idx = path.lastIndexOf('.');
    if (idx >= 0 && idx < path.length - 1) return path.substring(idx);
    return '';
  }

  String _fileNameOf(String path) {
    final segments = path.split(RegExp(r'[/\\]'));
    return segments.isNotEmpty ? segments.last : path;
  }

  String _safePathSegment(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  /// 依据扩展名猜测 MIME 类型（不引入额外依赖，覆盖常见图片/视频格式）。
  String _guessMimeType(String path, String type) {
    final ext = path.toLowerCase().split('.').last;
    const imageMap = <String, String>{
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'heic': 'image/heic',
      'bmp': 'image/bmp',
    };
    const videoMap = <String, String>{
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'avi': 'video/x-msvideo',
      'mkv': 'video/x-matroska',
      'webm': 'video/webm',
      'm4v': 'video/mp4',
    };
    if (type == 'video') return videoMap[ext] ?? 'video/mp4';
    if (type == 'image') return imageMap[ext] ?? 'image/jpeg';
    const fileMap = <String, String>{
      'txt': 'text/plain',
      'md': 'text/markdown',
      'json': 'application/json',
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'zip': 'application/zip',
      'csv': 'text/csv',
      'html': 'text/html',
      'dart': 'text/plain',
      'yaml': 'text/yaml',
      'yml': 'text/yaml',
    };
    return fileMap[ext] ?? 'application/octet-stream';
  }

  String get _storageModeLabel =>
      kReleaseMode ? 'release-user-dir' : 'project-data';

  static const String _messageIdsByGroupKey = 'message_ids_by_group';

  Future<List<Message>> messagesForGroup(String groupId) async {
    final indexedIds = _messageIdsForGroup(groupId);
    if (indexedIds != null && indexedIds.isNotEmpty) {
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
    final ids = messages.map((message) => message.id).toList();
    final existingIndexedIds = _messageIdsForGroup(groupId);
    if (existingIndexedIds == null ||
        !_sameStringList(existingIndexedIds, ids)) {
      await _saveMessageIdsForGroup(groupId, ids);
    }
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

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
  static const String _groupChatLastProactiveAtKey =
      'group_chat_last_proactive_at';
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

  Map<String, DateTime> groupChatLastProactiveAtByGroup() {
    return _dateTimeMapFromSettings(_groupChatLastProactiveAtKey);
  }

  Future<void> saveGroupChatLastProactiveAt(
    String groupId,
    DateTime timestamp,
  ) async {
    final raw = appSettingsBox.get(_groupChatLastProactiveAtKey);
    final map =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    map[groupId] = timestamp.toIso8601String();
    await appSettingsBox.put(_groupChatLastProactiveAtKey, map);
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
