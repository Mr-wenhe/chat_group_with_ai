import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/features/work_mode/work_mode_directory_service.dart';
import 'package:flutter/foundation.dart';

class WorkModeWorkspaceService {
  final DatabaseService db;
  final WorkModeDirectoryService directories;

  const WorkModeWorkspaceService({
    required this.db,
    this.directories = const WorkModeDirectoryService(),
  });

  Future<WorkModeWorkspace> loadOrCreate({
    required String conversationId,
    required bool isDirectChat,
  }) async {
    final existing = db.workModeWorkspaceBox.get(conversationId);
    final folder = directories.conversationFolderName(
      conversationId: conversationId,
      isDirectChat: isDirectChat,
    );
    final path = kIsWeb
        ? 'browser://agentic_output/conversations/$folder'
        : (await directories.conversationDir(
            root: await db.aiProcessingDir,
            conversationId: conversationId,
            isDirectChat: isDirectChat,
          ))
            .path;
    final conversationType = isDirectChat ? 'direct' : 'group';
    if (existing != null &&
        existing.workDirPath == path &&
        existing.conversationType == conversationType) {
      return existing;
    }
    final workspace = existing?.conversationType == conversationType
        ? existing!
        : WorkModeWorkspace(
            conversationId: conversationId,
            conversationType: conversationType,
          );
    workspace
      ..workDirPath = path
      ..updatedAt = DateTime.now();
    await db.workModeWorkspaceBox.put(conversationId, workspace);
    return workspace;
  }
}
