import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';

class DatabaseService {
  static const String _aiCharacterBox = 'ai_characters';
  static const String _apiConfigBox = 'api_configs';
  static const String _chatGroupBox = 'chat_groups';
  static const String _messageBox = 'messages';
  static const String _groupMemoryBox = 'group_memories';
  final SecureStorageService _secureStorage = SecureStorageService();

  Future<void> init() async {
    final dir = await _getDataDir();
    await Hive.initFlutter(dir.path);
    Hive.registerAdapter(AICharacterAdapter());
    Hive.registerAdapter(ApiConfigAdapter());
    Hive.registerAdapter(ChatGroupAdapter());
    Hive.registerAdapter(MessageAdapter());
    Hive.registerAdapter(GroupMemoryAdapter());

    await _openBoxSafely<AICharacter>(_aiCharacterBox);
    await _openBoxSafely<ApiConfig>(_apiConfigBox);
    await _openBoxSafely<ChatGroup>(_chatGroupBox);
    await _openBoxSafely<Message>(_messageBox);
    await _openBoxSafely<GroupMemory>(_groupMemoryBox);
    await _migrateAndHydrateApiConfigKeys();
  }

  Future<Directory> _getDataDir() async {
    // Use project-local data/ if it has hive files (git-managed)
    final exe = Platform.resolvedExecutable;
    // On macOS debug: .../build/macos/Build/Products/Debug/chat_group.app/Contents/MacOS/chat_group
    // Project root is 6 levels up
    final possibleProject =
        Directory(exe).parent.parent.parent.parent.parent.parent;
    final projectData = Directory('${possibleProject.path}/data');
    if (await projectData.exists() &&
        await File('${projectData.path}/ai_characters.hive').exists()) {
      // Sync project data to app documents for this run
      final docs = await getApplicationDocumentsDirectory();
      final appData = Directory('${docs.path}/data');
      if (!await appData.exists()) {
        await appData.create(recursive: true);
      }
      final files = await projectData.list().toList();
      for (final f in files) {
        if (f is File &&
            !await File('${appData.path}/${f.uri.pathSegments.last}')
                .exists()) {
          await f.copy('${appData.path}/${f.uri.pathSegments.last}');
        }
      }
      return appData;
    }

    // Fallback
    final docs = await getApplicationDocumentsDirectory();
    final dataDir = Directory('${docs.path}/data');
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }
    return dataDir;
  }

  Future<void> _openBoxSafely<T>(String name) async {
    try {
      await Hive.openBox<T>(name);
    } on FileSystemException catch (_) {
      await Hive.deleteBoxFromDisk(name);
      await Hive.openBox<T>(name);
    }
  }

  Future<void> _migrateAndHydrateApiConfigKeys() async {
    for (final config in apiConfigBox.values) {
      final plainTextKey = config.apiKey;
      if (plainTextKey.isNotEmpty) {
        final saved =
            await _secureStorage.saveApiConfigKey(config.id, plainTextKey);
        if (!saved) continue;
        config.apiKey = '';
        await apiConfigBox.put(config.id, config);
        config.apiKey = plainTextKey;
        continue;
      }

      final storedKey = await _secureStorage.getApiConfigKey(config.id);
      if (storedKey != null && storedKey.isNotEmpty) {
        config.apiKey = storedKey;
      }
    }
  }

  Future<void> saveApiConfig(ApiConfig config) async {
    final apiKey = config.apiKey;
    final savedSecurely = apiKey.isNotEmpty
        ? await _secureStorage.saveApiConfigKey(config.id, apiKey)
        : false;
    final storedConfig = ApiConfig(
      id: config.id,
      name: config.name,
      provider: config.provider,
      modelName: config.modelName,
      apiKey: savedSecurely ? '' : apiKey,
      customBaseUrl: config.customBaseUrl,
      createdAt: config.createdAt,
    );
    await apiConfigBox.put(storedConfig.id, storedConfig);
    final runtimeConfig = apiConfigBox.get(storedConfig.id);
    if (runtimeConfig != null) {
      runtimeConfig.apiKey = apiKey;
    }
  }

  Future<void> deleteApiConfig(String id) async {
    await _secureStorage.deleteApiConfigKey(id);
    await apiConfigBox.delete(id);
  }

  Future<void> clearAllData() async {
    for (final config in apiConfigBox.values) {
      await _secureStorage.deleteApiConfigKey(config.id);
    }
    await apiConfigBox.clear();
    await aiCharacterBox.clear();
    await chatGroupBox.clear();
    await messageBox.clear();
    await groupMemoryBox.clear();
  }

  Box<AICharacter> get aiCharacterBox => Hive.box<AICharacter>(_aiCharacterBox);
  Box<ApiConfig> get apiConfigBox => Hive.box<ApiConfig>(_apiConfigBox);
  Box<ChatGroup> get chatGroupBox => Hive.box<ChatGroup>(_chatGroupBox);
  Box<Message> get messageBox => Hive.box<Message>(_messageBox);
  Box<GroupMemory> get groupMemoryBox => Hive.box<GroupMemory>(_groupMemoryBox);
}
