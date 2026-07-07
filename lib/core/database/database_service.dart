import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/group_memory.dart';

class DatabaseService {
  static const String _aiCharacterBox = 'ai_characters';
  static const String _apiConfigBox = 'api_configs';
  static const String _chatGroupBox = 'chat_groups';
  static const String _messageBox = 'messages';
  static const String _groupMemoryBox = 'group_memories';

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
  }

  Future<Directory> _getDataDir() async {
    if (kDebugMode) {
      final projectDir = Directory.current;
      final dataDir = Directory('${projectDir.path}/data');
      if (!await dataDir.exists()) {
        await dataDir.create(recursive: true);
      }
      return dataDir;
    }
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

  Box<AICharacter> get aiCharacterBox =>
      Hive.box<AICharacter>(_aiCharacterBox);
  Box<ApiConfig> get apiConfigBox =>
      Hive.box<ApiConfig>(_apiConfigBox);
  Box<ChatGroup> get chatGroupBox => Hive.box<ChatGroup>(_chatGroupBox);
  Box<Message> get messageBox => Hive.box<Message>(_messageBox);
  Box<GroupMemory> get groupMemoryBox => Hive.box<GroupMemory>(_groupMemoryBox);
}
