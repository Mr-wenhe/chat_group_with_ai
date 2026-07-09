import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/autonomous_conversation_config.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/autonomous/autonomous_directory_service.dart';

class AutonomousConversationConfigService {
  final DatabaseService db;
  final AutonomousDirectoryService directories;

  const AutonomousConversationConfigService({
    required this.db,
    this.directories = const AutonomousDirectoryService(),
  });

  Future<AutonomousConversationConfig> loadOrCreate({
    required String conversationId,
    required bool isDirectChat,
  }) async {
    final existing = db.autonomousConversationConfigBox.get(conversationId);
    final root = await db.aiProcessingDir;
    final workDir = await directories.conversationDir(
      root: root,
      conversationId: conversationId,
      isDirectChat: isDirectChat,
    );
    if (existing != null) {
      if (existing.workDirPath.isEmpty) {
        existing.workDirPath = workDir.path;
        existing.updatedAt = DateTime.now();
        await existing.save();
      }
      return existing;
    }
    final config = AutonomousConversationConfig(
      conversationId: conversationId,
      conversationType: isDirectChat ? 'direct' : 'group',
      workDirPath: workDir.path,
    );
    await db.autonomousConversationConfigBox.put(conversationId, config);
    return config;
  }

  Future<AutonomousConversationConfig> setEnabled({
    required String conversationId,
    required bool isDirectChat,
    required bool enabled,
  }) async {
    final config = await loadOrCreate(
      conversationId: conversationId,
      isDirectChat: isDirectChat,
    );
    config
      ..enabled = enabled
      ..updatedAt = DateTime.now();
    await db.autonomousConversationConfigBox.put(conversationId, config);
    return config;
  }

  Future<AutonomousConversationConfig> authorizeProject({
    required String conversationId,
    required bool isDirectChat,
    required String projectPath,
  }) async {
    final config = await loadOrCreate(
      conversationId: conversationId,
      isDirectChat: isDirectChat,
    );
    final dir = Directory(projectPath).absolute;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    config
      ..authorizedProjectPath = dir.path
      ..sourceWriteAuthorized = true
      ..authorizedAt = DateTime.now()
      ..updatedAt = DateTime.now();
    await db.autonomousConversationConfigBox.put(conversationId, config);
    return config;
  }

  Future<void> grantFullPermissions(Iterable<String> characterIds) async {
    final full = ToolPermission.values.toList();
    for (final id in characterIds) {
      final character = db.aiCharacterBox.get(id);
      if (character == null) continue;
      final existing = character.toolPermissions.map((p) => p.name).toSet();
      final changed = full.any((p) => !existing.contains(p.name)) ||
          !character.agenticEnabled;
      if (!changed) continue;
      character
        ..agenticEnabled = true
        ..toolPermissions = full;
      await db.aiCharacterBox.put(character.id, character);
    }
  }
}
