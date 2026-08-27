import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/legacy_api_credential_migrator.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/direct_chat_source.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/features/work_mode/work_mode_v1_migrator.dart';

/// Indicates that an existing Hive box could not be opened safely.
///
/// This exception is intentionally surfaced to the app. A failed open can
/// mean corruption, a lock conflict, or a permission problem; deleting the
/// box would destroy the only copy of the user's data.
class DatabaseOpenException implements Exception {
  final String boxName;
  final String? dataDirPath;
  final Object cause;
  final StackTrace stackTrace;

  const DatabaseOpenException({
    required this.boxName,
    required this.dataDirPath,
    required this.cause,
    required this.stackTrace,
  });

  @override
  String toString() => '无法打开数据库 box "$boxName"：$cause';
}

class MessagePage {
  final List<Message> messages;
  final bool hasOlder;
  final int totalCount;

  const MessagePage({
    required this.messages,
    required this.hasOlder,
    required this.totalCount,
  });
}

/// Rebuildable inbox cache. The message box remains the source of truth.
class ConversationSummaryRecord {
  final String conversationId;
  final String? lastMessageId;
  final String preview;
  final DateTime? timestamp;
  final int messageCount;
  final int unreadCount;
  final int mentionCount;
  final DateTime? lastReadAt;
  final DateTime? lastUserMessageAt;

  const ConversationSummaryRecord({
    required this.conversationId,
    this.lastMessageId,
    this.preview = '',
    this.timestamp,
    this.messageCount = 0,
    this.unreadCount = 0,
    this.mentionCount = 0,
    this.lastReadAt,
    this.lastUserMessageAt,
  });

  factory ConversationSummaryRecord.fromMap(
    String conversationId,
    Map<dynamic, dynamic> map,
  ) {
    return ConversationSummaryRecord(
      conversationId: conversationId,
      lastMessageId: map['lastMessageId']?.toString(),
      preview: map['preview']?.toString() ?? '',
      timestamp: DateTime.tryParse(map['timestamp']?.toString() ?? ''),
      messageCount: (map['messageCount'] as num?)?.toInt() ?? 0,
      unreadCount: (map['unreadCount'] as num?)?.toInt() ?? 0,
      mentionCount: (map['mentionCount'] as num?)?.toInt() ?? 0,
      lastReadAt: DateTime.tryParse(map['lastReadAt']?.toString() ?? ''),
      lastUserMessageAt:
          DateTime.tryParse(map['lastUserMessageAt']?.toString() ?? ''),
    );
  }

  Map<String, dynamic> toMap() => {
        'lastMessageId': lastMessageId,
        'preview': preview,
        'timestamp': timestamp?.toIso8601String(),
        'messageCount': messageCount,
        'unreadCount': unreadCount,
        'mentionCount': mentionCount,
        'lastReadAt': lastReadAt?.toIso8601String(),
        'lastUserMessageAt': lastUserMessageAt?.toIso8601String(),
      };
}

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
  static const String workModeWorkspaceBoxName = 'work_mode_workspaces';
  static const String aiGovernanceLedgerBoxName = 'ai_governance_ledger';
  static const String _userProfileBox = 'user_profile';
  static const String _permanentMemoryBox = 'permanent_memories';
  static const String _relationshipEventBox = 'relationship_events';
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
    'work_mode_workspaces.hive',
    'group_memories.hive',
    'messages.hive',
    'relationship_states.hive',
    'user_profile.hive',
    'permanent_memories.hive',
    'relationship_events.hive',
  ];

  Directory? _dataDir;
  Timer? _tokenUsageFlushTimer;
  Map<String, dynamic>? _tokenUsageCache;
  Map<String, dynamic>? _messageIdsCache;
  Map<String, ConversationSummaryRecord>? _conversationSummaryCache;
  final Map<String, Future<void>> _replyUsageWrites = {};
  int? _messageIndexCountCache;
  Future<void>? _messageIndexBuildFuture;
  static const Duration _tokenUsageFlushDelay = Duration(seconds: 2);

  Future<void> init() async {
    if (kIsWeb) {
      // Web 端由 Hive 使用 IndexedDB，不存在应用支持目录。
      await Hive.initFlutter();
    } else {
      final dir = await _getDataDir();
      _dataDir = dir;
      await Hive.initFlutter(dir.path);
    }
    Hive.registerAdapter(AICharacterAdapter());
    Hive.registerAdapter(CharacterGenderAdapter());
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
    Hive.registerAdapter(WorkModeWorkspaceAdapter());
    Hive.registerAdapter(UserProfileAdapter());
    Hive.registerAdapter(MemoryKindAdapter());
    Hive.registerAdapter(MemoryOriginTypeAdapter());
    Hive.registerAdapter(MemoryStatusAdapter());
    Hive.registerAdapter(PermanentMemoryAdapter());
    Hive.registerAdapter(RelationshipStageAdapter());
    Hive.registerAdapter(RelationshipEventCreatorAdapter());
    Hive.registerAdapter(RelationshipEventAdapter());

    await _openBoxSafely<AICharacter>(_aiCharacterBox);
    await _openBoxSafely<ApiConfig>(_apiConfigBox);
    await _openBoxSafely<ChatGroup>(_chatGroupBox);
    await _openBoxSafely<Message>(_messageBox);
    await _openBoxSafely<GroupMemory>(_groupMemoryBox);
    await _openBoxSafely<CharacterMemory>(_characterMemoryBox);
    await _openBoxSafely<RelationshipState>(_relationshipStateBox);
    await _openBoxSafely<CharacterSkill>(agentSkillBoxName);
    await _openBoxSafely<AgentTask>(agentTaskBoxName);
    await _openBoxSafely<WorkModeWorkspace>(workModeWorkspaceBoxName);
    await _openBoxSafely<dynamic>(_appSettingsBox);
    await _openBoxSafely<dynamic>(aiGovernanceLedgerBoxName);
    await _openBoxSafely<UserProfile>(_userProfileBox);
    await _openBoxSafely<PermanentMemory>(_permanentMemoryBox);
    await _openBoxSafely<RelationshipEvent>(_relationshipEventBox);
    await _migrateApiConfigCredentials();
    final workModeMigrator = WorkModeV1Migrator(
      taskBox: agentTaskBox,
      workspaceBox: workModeWorkspaceBox,
      appSettingsBox: appSettingsBox,
    );
    await workModeMigrator.migrate();
    await workModeMigrator.markInFlightWorkTasksInterrupted();
  }

  /// Never clears a legacy value until the new secure entry can be read back.
  /// This updates individual records only; it never recreates or clears a box.
  Future<void> _migrateApiConfigCredentials() async {
    await LegacyApiCredentialMigrator(CredentialRepository()).migrate(
      configs: apiConfigBox.values,
      characters: aiCharacterBox.values,
      saveConfig: (config) => apiConfigBox.put(config.id, config),
      saveCharacter: (character) => aiCharacterBox.put(character.id, character),
    );
  }

  Future<Directory> _getDataDir() async {
    final supportDir = await getApplicationSupportDirectory();
    final userDataDir = Directory('${supportDir.path}/data');
    await _ensureDir(userDataDir);
    await _seedReleaseDataIfNeeded(userDataDir);
    return userDataDir;
  }

  /// 安全地打开一个 box。
  ///
  /// 若打开时抛文件系统异常（常见于进程被强杀导致文件截断、
  /// 或多进程并发访问同一目录造成锁冲突），旧实现会直接删除并重建
  /// 整个 box —— 这正是数据"凭空消失"的根因。
  /// 现改为：保留原文件，并将失败向上抛出交给界面处理。
  ///
  /// 这里可以创建一个只读副本供人工备份/排障，但绝不删除、清空或
  /// 重建原 box。自动删除会让数据库损坏、锁冲突和权限错误都变成
  /// 不可逆的数据丢失。
  Future<void> _openBoxSafely<T>(String name) async {
    try {
      await Hive.openBox<T>(name);
      return;
    } on Object catch (error, stackTrace) {
      // 只做不影响原文件的副本，便于用户在界面提示后进行人工备份。
      // 副本失败也不能改变“原文件不动、初始化失败”的安全策略。
      final dir = _dataDir;
      if (dir != null) {
        final file = File('${dir.path}/$name.hive');
        if (await file.exists()) {
          final backup = File(
            '${dir.path}/$name.corrupt_${DateTime.now().millisecondsSinceEpoch}.hive',
          );
          try {
            await file.copy(backup.path);
          } on Object {
            // 副本失败不影响原数据库文件和后续保护性报错。
          }
        }
      }

      throw DatabaseOpenException(
        boxName: name,
        dataDirPath: _dataDir?.path,
        cause: error,
        stackTrace: stackTrace,
      );
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
    } on FlutterError {
      // Fall back to the built-in file list when the optional asset is absent.
    } on FormatException {
      // Fall back to the built-in file list when the manifest is invalid.
    }
    return _releaseHiveFiles;
  }

  Future<void> saveApiConfig(ApiConfig config) async {
    final existing = apiConfigBox.get(config.id);
    if (config.legacyApiKeyForMigration?.isNotEmpty ?? false) {
      final credentials = CredentialRepository();
      final saved = credentials.secureStorageAvailable
          ? await credentials.save(
              config.id, config.legacyApiKeyForMigration ?? '')
          : const CredentialWriteResult.failed(CredentialFailure.unavailable);
      if (saved.isSuccess) {
        config.setLegacyApiKeyForMigration('');
        config.hasCredential = true;
        config.credentialId = credentials.credentialIdFor(config.id);
      } else if (kReleaseMode) {
        throw StateError('凭据不可用，未保存配置');
      } else {
        // macOS debug builds can lack Keychain access. Keep the development
        // credential in Hive so local runs remain usable; release never does.
        config.hasCredential = true;
        config.credentialId = CredentialRepository.developmentHiveCredentialId;
      }
    } else if (existing?.hasCredential == true) {
      // 编辑元数据时不要求重新输入密钥；保留已验证的安全存储映射。
      config.hasCredential = true;
      config.credentialId = existing!.credentialId;
      if (!kReleaseMode &&
          existing.credentialId ==
              CredentialRepository.developmentHiveCredentialId &&
          (existing.legacyApiKeyForMigration?.isNotEmpty ?? false)) {
        config.setLegacyApiKeyForMigration(
          existing.legacyApiKeyForMigration ?? '',
        );
      }
    }
    await apiConfigBox.put(config.id, config);
  }

  /// Serializes reply-usage updates per character so chat and proactive
  /// services cannot overwrite each other's read-modify-write result.
  Future<void> recordCharacterReplyUsage(String characterId) {
    final previous = _replyUsageWrites[characterId] ?? Future<void>.value();
    final next = previous.then<void>(
      (_) => _persistCharacterReplyUsage(characterId),
      onError: (Object _, StackTrace __) =>
          _persistCharacterReplyUsage(characterId),
    );
    _replyUsageWrites[characterId] = next;
    next.then<void>(
      (_) => _removeReplyUsageWrite(characterId, next),
      onError: (Object _, StackTrace __) {
        _removeReplyUsageWrite(characterId, next);
      },
    );
    return next;
  }

  Future<void> _persistCharacterReplyUsage(String characterId) async {
    final character = aiCharacterBox.get(characterId);
    if (character == null) return;
    final current = DateTime.now();
    final last = character.lastReplyTimestamp;
    final withinHour = last != null && current.difference(last).inMinutes < 60;
    final sameDay = last != null &&
        last.year == current.year &&
        last.month == current.month &&
        last.day == current.day;
    if (!sameDay || !withinHour) {
      character.hourlyReplyCount = 1;
    } else {
      character.hourlyReplyCount += 1;
    }
    character.lastReplyTimestamp = current;
    await aiCharacterBox.put(character.id, character);
  }

  void _removeReplyUsageWrite(String characterId, Future<void> write) {
    if (identical(_replyUsageWrites[characterId], write)) {
      _replyUsageWrites.remove(characterId);
    }
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
  Box<WorkModeWorkspace> get workModeWorkspaceBox =>
      Hive.box<WorkModeWorkspace>(workModeWorkspaceBoxName);
  Box<dynamic> get appSettingsBox => Hive.box(_appSettingsBox);
  Box<UserProfile> get userProfileBox => Hive.box<UserProfile>(_userProfileBox);
  Box<PermanentMemory> get permanentMemoryBox =>
      Hive.box<PermanentMemory>(_permanentMemoryBox);
  Box<RelationshipEvent> get relationshipEventBox =>
      Hive.box<RelationshipEvent>(_relationshipEventBox);

  /// 从用户人物信息卡获取显示名，空则返回默认值。
  String ownerNameFromProfile({String fallback = '我'}) {
    try {
      final profile = userProfileBox.get('me');
      if (profile?.displayName.trim().isNotEmpty ?? false) {
        return profile!.displayName.trim();
      }
    } on Object {
      // Box not yet opened in test environments.
    }
    return fallback;
  }

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
    final dir =
        _debugProjectAgentOutputDir() ?? Directory('${base.path}/ai_files');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Directory? _debugProjectAgentOutputDir() {
    if (kReleaseMode) return null;
    Directory? findGitRoot(Directory start) {
      var dir = start.absolute;
      while (true) {
        if (Directory('${dir.path}/.git').existsSync()) return dir;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
      return null;
    }

    final cwdRoot = findGitRoot(Directory.current);
    if (cwdRoot != null) {
      return Directory('${cwdRoot.path}/agentic_output');
    }

    final executable = File(Platform.resolvedExecutable);
    final executableRoot = findGitRoot(executable.parent);
    if (executableRoot != null) {
      return Directory('${executableRoot.path}/agentic_output');
    }

    final script = Platform.script;
    if (script.isScheme('file')) {
      final scriptRoot = findGitRoot(File.fromUri(script).parent);
      if (scriptRoot != null) {
        return Directory('${scriptRoot.path}/agentic_output');
      }
    }

    var dir = Directory.current.absolute;
    while (true) {
      if (Directory('${dir.path}/.git').existsSync()) {
        return Directory('${dir.path}/agentic_output');
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
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
    final resolvedMimeType = mimeType ?? _guessMimeType(fileName, type);
    if (kIsWeb) {
      return MediaAttachment(
        type: type,
        localPath: encodeAttachmentDataUri(bytes, resolvedMimeType),
        fileName: fileName,
        fileSize: bytes.lengthInBytes,
        mimeType: resolvedMimeType,
      );
    }
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
      mimeType: resolvedMimeType,
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
    final mimeType = _guessMimeType(fileName, type);
    if (kIsWeb) {
      return createDataUriAttachment(
        bytes: bytes,
        fileName: fileName,
        mimeType: mimeType,
        type: type,
      );
    }
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
      mimeType: mimeType,
    );
  }

  /// 用 video_player 初始化一次以读取视频时长，随后立即释放资源。
  Future<int?> _probeVideoDuration(File file) async {
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.file(file);
      await controller.initialize();
      return controller.value.duration.inMilliseconds;
    } catch (_) {
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
      'java': 'text/x-java-source',
      'c': 'text/x-c',
      'cc': 'text/x-c++src',
      'cpp': 'text/x-c++src',
      'h': 'text/x-c',
      'hpp': 'text/x-c++hdr',
      'yaml': 'text/yaml',
      'yml': 'text/yaml',
    };
    return fileMap[ext] ?? 'application/octet-stream';
  }

  static const String _messageIdsByGroupKey = 'message_ids_by_group';
  static const String _messageIndexCountKey = 'message_index_count';
  static const String _conversationSummariesKey = 'conversation_summaries';

  Future<void> persistMessage(Message message) async {
    await messageBox.put(message.id, message);
    await addMessageToGroupIndex(message);
  }

  Future<void> updateMessage(Message message) async {
    await messageBox.put(message.id, message);
    final summaries = Map<String, ConversationSummaryRecord>.from(
      conversationSummaries(),
    );
    final current = summaries[message.groupId];
    if (current?.lastMessageId != message.id) return;
    summaries[message.groupId] = ConversationSummaryRecord(
      conversationId: message.groupId,
      lastMessageId: message.id,
      preview: message.content,
      timestamp: message.timestamp,
      messageCount: current!.messageCount,
      unreadCount: current.unreadCount,
      mentionCount: current.mentionCount,
      lastReadAt: current.lastReadAt,
      lastUserMessageAt: current.lastUserMessageAt,
    );
    _conversationSummaryCache = summaries;
    await appSettingsBox.put(_conversationSummariesKey, {
      for (final entry in summaries.entries) entry.key: entry.value.toMap(),
    });
  }

  Future<void> ensureMessageIndex() async {
    final storedCount = appSettingsBox.get(_messageIndexCountKey);
    _messageIndexCountCache ??= storedCount is int ? storedCount : -1;
    if (_messageIndexCountCache != messageBox.length) {
      // Use a Completer to prevent concurrent rebuilds from multiple callers.
      final existing = _messageIndexBuildFuture;
      if (existing != null) {
        await existing;
        return;
      }
      final completer = Completer<void>();
      _messageIndexBuildFuture = completer.future;
      try {
        await _rebuildMessageIndexOnce();
        completer.complete();
      } on Object catch (e) {
        completer.completeError(e);
        rethrow;
      } finally {
        _messageIndexBuildFuture = null;
      }
    }
  }

  Future<void> _rebuildMessageIndexOnce() async {
    await rebuildMessageIndex();
  }

  Future<void> rebuildMessageIndex() async {
    final messagesByGroup = <String, List<Message>>{};
    for (final message in messageBox.values) {
      messagesByGroup.putIfAbsent(message.groupId, () => []).add(message);
    }
    final idsByGroup = <String, dynamic>{};
    final summaries = <String, ConversationSummaryRecord>{};
    for (final entry in messagesByGroup.entries) {
      entry.value.sort(_compareMessages);
      idsByGroup[entry.key] = entry.value.map((message) => message.id).toList();
      summaries[entry.key] = _summaryFor(entry.key, entry.value);
    }
    _messageIdsCache = idsByGroup;
    _conversationSummaryCache = summaries;
    _messageIndexCountCache = messageBox.length;
    await appSettingsBox.putAll({
      _messageIdsByGroupKey: idsByGroup,
      _conversationSummariesKey: {
        for (final entry in summaries.entries) entry.key: entry.value.toMap(),
      },
      _messageIndexCountKey: messageBox.length,
    });
  }

  Future<MessagePage> loadLatestMessages(
    String groupId, {
    int limit = 80,
  }) async {
    await ensureMessageIndex();
    final ids = _messageIdsForGroup(groupId) ?? const <String>[];
    final start = max(0, ids.length - limit);
    return _pageFromIds(ids, start, ids.length);
  }

  Future<MessagePage> loadMessagesBefore(
    String groupId, {
    required String beforeMessageId,
    int limit = 80,
  }) async {
    await ensureMessageIndex();
    final ids = _messageIdsForGroup(groupId) ?? const <String>[];
    final end = ids.indexOf(beforeMessageId);
    if (end < 0) return loadLatestMessages(groupId, limit: limit);
    return _pageFromIds(ids, max(0, end - limit), end);
  }

  Future<MessagePage> loadMessagesAround(
    String groupId,
    String messageId, {
    int limit = 80,
  }) async {
    await ensureMessageIndex();
    final ids = _messageIdsForGroup(groupId) ?? const <String>[];
    final target = ids.indexOf(messageId);
    if (target < 0) return loadLatestMessages(groupId, limit: limit);
    final start = max(0, min(target - limit ~/ 2, ids.length - limit));
    return _pageFromIds(ids, start, min(ids.length, start + limit));
  }

  Future<List<Message>> searchMessages(String groupId, String query) async {
    await ensureMessageIndex();
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];
    return (_messageIdsForGroup(groupId) ?? const <String>[])
        .map(messageBox.get)
        .whereType<Message>()
        .where((message) => message.content.toLowerCase().contains(normalized))
        .toList(growable: false);
  }

  MessagePage _pageFromIds(List<String> ids, int start, int end) {
    final messages = ids
        .sublist(start, end)
        .map(messageBox.get)
        .whereType<Message>()
        .toList(growable: false);
    return MessagePage(
      messages: messages,
      hasOlder: start > 0,
      totalCount: ids.length,
    );
  }

  Map<String, ConversationSummaryRecord> conversationSummaries() {
    if (_conversationSummaryCache != null) {
      return Map.unmodifiable(_conversationSummaryCache!);
    }
    final raw = appSettingsBox.get(_conversationSummariesKey);
    final map = raw is Map ? raw : const {};
    _conversationSummaryCache = {
      for (final entry in map.entries)
        entry.key.toString(): ConversationSummaryRecord.fromMap(
          entry.key.toString(),
          entry.value is Map ? entry.value as Map : const {},
        ),
    };
    return Map.unmodifiable(_conversationSummaryCache!);
  }

  Future<List<Message>> messagesForGroup(String groupId) async {
    await ensureMessageIndex();
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
    final insertionIndex = ids.indexWhere((id) {
      final existing = messageBox.get(id);
      return existing != null && _compareMessages(message, existing) < 0;
    });
    insertionIndex < 0
        ? ids.add(message.id)
        : ids.insert(insertionIndex, message.id);
    byGroup[message.groupId] = ids;
    _messageIdsCache = Map<String, dynamic>.from(byGroup);
    _messageIndexCountCache = messageBox.length;
    await _updateConversationSummaryForAdded(message);
    await appSettingsBox.putAll({
      _messageIdsByGroupKey: _messageIdsCache,
      _messageIndexCountKey: _messageIndexCountCache,
    });
  }

  /// Low-level primitive for the data lifecycle service; feature code must use
  /// that service so attachment garbage collection also runs.
  Future<void> deleteMessageRecordAndIndex(
    String messageId, {
    required String groupId,
  }) async {
    await messageBox.delete(messageId);
    final byGroup = _messageIdsByGroup();
    final ids = List<String>.from(byGroup[groupId] ?? const <String>[])
      ..remove(messageId);
    byGroup[groupId] = ids;
    _messageIdsCache = Map<String, dynamic>.from(byGroup);
    _messageIndexCountCache = messageBox.length;
    await _updateConversationSummary(groupId, ids);
    await appSettingsBox.putAll({
      _messageIdsByGroupKey: _messageIdsCache,
      _messageIndexCountKey: _messageIndexCountCache,
    });
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
    _messageIndexCountCache = messageBox.length;
    await _updateConversationSummary(groupId, ids);
    await appSettingsBox.putAll({
      _messageIdsByGroupKey: _messageIdsCache,
      _messageIndexCountKey: _messageIndexCountCache,
    });
  }

  Future<void> _updateConversationSummary(
    String groupId,
    List<String> ids,
  ) async {
    final messages =
        ids.map(messageBox.get).whereType<Message>().toList(growable: false);
    final summaries = Map<String, ConversationSummaryRecord>.from(
      conversationSummaries(),
    );
    if (messages.isEmpty) {
      summaries.remove(groupId);
    } else {
      summaries[groupId] = _summaryFor(groupId, messages);
    }
    _conversationSummaryCache = summaries;
    await appSettingsBox.put(_conversationSummariesKey, {
      for (final entry in summaries.entries) entry.key: entry.value.toMap(),
    });
  }

  Future<void> _updateConversationSummaryForAdded(Message message) async {
    final summaries = Map<String, ConversationSummaryRecord>.from(
      conversationSummaries(),
    );
    final current = summaries[message.groupId];
    final direct = message.groupId.startsWith('dm:');
    final readAt = current?.lastReadAt ??
        (direct
            ? directChatReadAtByConversation()
            : groupChatReadAtByGroup())[message.groupId];
    final isUnread = message.senderType == 'ai' &&
        (readAt == null || message.timestamp.isAfter(readAt));
    final ownerName = !direct ? ownerNameFromProfile() : '我';
    final mentionNames = {'我', if (ownerName.isNotEmpty) ownerName};
    final isMention = isUnread &&
        !direct &&
        RegExp(r'@([^@\s，。！？!?、；;：:,.]+)')
            .allMatches(message.content)
            .any((match) => mentionNames.contains(match.group(1)?.trim()));
    final isLatest = current?.timestamp == null ||
        !message.timestamp.isBefore(current!.timestamp!);
    summaries[message.groupId] = ConversationSummaryRecord(
      conversationId: message.groupId,
      lastMessageId: isLatest ? message.id : current.lastMessageId,
      preview: isLatest ? message.content : current.preview,
      timestamp: isLatest ? message.timestamp : current.timestamp,
      messageCount: (current?.messageCount ?? 0) + 1,
      unreadCount: (current?.unreadCount ?? 0) + (isUnread ? 1 : 0),
      mentionCount: (current?.mentionCount ?? 0) + (isMention ? 1 : 0),
      lastReadAt: readAt,
      lastUserMessageAt: message.senderType == 'user'
          ? message.timestamp
          : current?.lastUserMessageAt,
    );
    _conversationSummaryCache = summaries;
    await appSettingsBox.put(_conversationSummariesKey, {
      for (final entry in summaries.entries) entry.key: entry.value.toMap(),
    });
  }

  ConversationSummaryRecord _summaryFor(
    String groupId,
    List<Message> messages,
  ) {
    final sorted = messages.toList(growable: false)..sort(_compareMessages);
    final last = sorted.isEmpty ? null : sorted.last;
    final direct = groupId.startsWith('dm:');
    final readAt = (direct
        ? directChatReadAtByConversation()
        : groupChatReadAtByGroup())[groupId];
    final unread = sorted.where((message) {
      return message.senderType == 'ai' &&
          (readAt == null || message.timestamp.isAfter(readAt));
    }).toList(growable: false);
    final ownerName = !direct ? ownerNameFromProfile() : '我';
    final mentionCount = direct
        ? 0
        : unread.where((message) {
            final names = {'我', if (ownerName.isNotEmpty) ownerName};
            return RegExp(r'@([^@\s，。！？!?、；;：:,.]+)')
                .allMatches(message.content)
                .any((match) => names.contains(match.group(1)?.trim()));
          }).length;
    DateTime? lastUserMessageAt;
    for (final message in sorted.reversed) {
      if (message.senderType == 'user') {
        lastUserMessageAt = message.timestamp;
        break;
      }
    }
    return ConversationSummaryRecord(
      conversationId: groupId,
      lastMessageId: last?.id,
      preview: last?.content ?? '',
      timestamp: last?.timestamp,
      messageCount: sorted.length,
      unreadCount: unread.length,
      mentionCount: mentionCount,
      lastReadAt: readAt,
      lastUserMessageAt: lastUserMessageAt,
    );
  }

  static int _compareMessages(Message a, Message b) {
    final byTime = a.timestamp.compareTo(b.timestamp);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  }

  void invalidateMessageIndexCache() {
    _messageIdsCache = null;
    _conversationSummaryCache = null;
    _messageIndexCountCache = null;
  }

  /// Keeps in-memory indexes from restoring content removed by the lifecycle
  /// service after a later delayed flush.
  void resetLifecycleCaches() {
    _tokenUsageFlushTimer?.cancel();
    _tokenUsageCache = null;
    _messageIdsCache = null;
    _conversationSummaryCache = null;
    _messageIndexCountCache = null;
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
    final timestamp = (readAt ?? DateTime.now()).toIso8601String();
    final summaries = Map<String, ConversationSummaryRecord>.from(
      conversationSummaries(),
    );
    final current = summaries[conversationId];
    if (current != null) {
      summaries[conversationId] = ConversationSummaryRecord(
        conversationId: conversationId,
        lastMessageId: current.lastMessageId,
        preview: current.preview,
        timestamp: current.timestamp,
        messageCount: current.messageCount,
        unreadCount: 0,
        mentionCount: 0,
        lastReadAt: DateTime.tryParse(timestamp),
        lastUserMessageAt: current.lastUserMessageAt,
      );
    }
    _conversationSummaryCache = summaries;
    await appSettingsBox.put(_conversationSummariesKey, {
      for (final entry in summaries.entries) entry.key: entry.value.toMap(),
    });
    final map = Map<String, String>.from(
      appSettingsBox.get(_directChatReadAtKey) is Map
          ? Map<String, dynamic>.from(appSettingsBox.get(_directChatReadAtKey))
              .map((key, value) => MapEntry(key, value.toString()))
          : const <String, String>{},
    );
    map[conversationId] = timestamp;
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
    await _markSummaryRead(groupId, map[groupId]!);
  }

  Future<void> _markSummaryRead(String conversationId, String value) async {
    final summaries = Map<String, ConversationSummaryRecord>.from(
      conversationSummaries(),
    );
    final current = summaries[conversationId];
    if (current == null) return;
    summaries[conversationId] = ConversationSummaryRecord(
      conversationId: conversationId,
      lastMessageId: current.lastMessageId,
      preview: current.preview,
      timestamp: current.timestamp,
      messageCount: current.messageCount,
      unreadCount: 0,
      mentionCount: 0,
      lastReadAt: DateTime.tryParse(value),
      lastUserMessageAt: current.lastUserMessageAt,
    );
    _conversationSummaryCache = summaries;
    await appSettingsBox.put(_conversationSummariesKey, {
      for (final entry in summaries.entries) entry.key: entry.value.toMap(),
    });
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
  static const String appSkinModeKey = 'app_skin_mode';

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

  AppSkinMode get savedAppSkinMode {
    final skin = appSettingsBox.get(appSkinModeKey);
    if (skin == 'golden') return AppSkinMode.golden;
    if (skin == 'light') return AppSkinMode.light;
    if (skin == 'system') return AppSkinMode.system;
    if (skin == 'dark') return AppSkinMode.dark;
    return switch (savedThemeMode) {
      ThemeMode.light => AppSkinMode.light,
      ThemeMode.system => AppSkinMode.system,
      ThemeMode.dark => AppSkinMode.dark,
    };
  }

  Future<void> saveAppSkinMode(AppSkinMode mode) async {
    final val = switch (mode) {
      AppSkinMode.light => 'light',
      AppSkinMode.system => 'system',
      AppSkinMode.dark => 'dark',
      AppSkinMode.golden => 'golden',
    };
    await appSettingsBox.put(appSkinModeKey, val);
    if (mode != AppSkinMode.golden) {
      await saveThemeMode(AppTheme.materialThemeModeFor(mode));
    }
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
    // Skip flush timers in debug mode — they are only needed in production
    // for debounced writes. In tests, late timer callbacks after Hive.close()
    // crash the test runner with "Box not found" errors.
    if (!kReleaseMode) return;
    _tokenUsageFlushTimer =
        Timer(_tokenUsageFlushDelay, () => _flushTokenUsage());
  }

  Future<void> _flushTokenUsage() async {
    final usage = _tokenUsageCache;
    if (usage == null) return;
    try {
      await appSettingsBox.put(
          _tokenUsageKey, Map<String, dynamic>.from(usage));
    } on Object {
      // Box may be closed during test teardown.
    }
  }

  static const String _ttsEnabledKey = 'tts_enabled';

  bool get isTtsEnabled => appSettingsBox.get(_ttsEnabledKey) ?? true;

  Future<void> saveTtsEnabled(bool enabled) async {
    await appSettingsBox.put(_ttsEnabledKey, enabled);
  }

  /// Cancel pending token-usage flush timer. Must be called in test
  /// tearDown after `Hive.close()` to prevent late timer callbacks from
  /// crashing the test runner.
  void dispose() {
    _tokenUsageFlushTimer?.cancel();
    _tokenUsageFlushTimer = null;
  }
}
