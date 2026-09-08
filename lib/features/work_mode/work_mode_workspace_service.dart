import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/features/work_mode/work_mode_directory_service.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter/foundation.dart';

class WorkModeWorkspaceService {
  final DatabaseService db;
  final WorkModeDirectoryService directories;
  final WorkFolderGrantService? grantService;

  const WorkModeWorkspaceService({
    required this.db,
    this.directories = const WorkModeDirectoryService(),
    this.grantService,
  });

  Future<WorkModeWorkspace> loadOrCreate({
    required String conversationId,
    required bool isDirectChat,
    bool requireWritable = false,
  }) async {
    final existing = db.workModeWorkspaceBox.get(conversationId);
    final folder = directories.conversationFolderName(
      conversationId: conversationId,
      isDirectChat: isDirectChat,
    );
    final path = kIsWeb
        ? 'browser://agentic_output/conversations/$folder'
        : await _resolveWorkspacePath(
            existing: existing,
            conversationId: conversationId,
            isDirectChat: isDirectChat,
            requireWritable: requireWritable,
          );
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

  /// Rebinds a conversation to the directory explicitly selected during
  /// reauthorization.
  ///
  /// A stale path must not be silently redirected by [loadOrCreate], and an
  /// empty workspace must not pick an unrelated alphabetically-first grant.
  /// The coordinator calls this only after the native picker and disclosure
  /// consent both succeed, so the selected capability becomes the durable
  /// workspace while all other restart/retry paths remain fail-closed.
  Future<void> rebindConversationWorkspace({
    required String conversationId,
    required bool isDirectChat,
    required String grantedPath,
  }) async {
    final existing = db.workModeWorkspaceBox.get(conversationId);
    final expectedType = isDirectChat ? 'direct' : 'group';
    final normalizedPath = grantedPath.trim();
    if (normalizedPath.isEmpty) return;
    final workspace = existing?.conversationType == expectedType
        ? existing!
        : WorkModeWorkspace(
            conversationId: conversationId,
            conversationType: expectedType,
          );
    workspace
      ..workDirPath = normalizedPath
      ..updatedAt = DateTime.now();
    await db.workModeWorkspaceBox.put(conversationId, workspace);
  }

  Future<String> _resolveWorkspacePath({
    required WorkModeWorkspace? existing,
    required String conversationId,
    required bool isDirectChat,
    required bool requireWritable,
  }) async {
    final persistedPath = existing?.workDirPath.trim();
    if (persistedPath != null && persistedPath.isNotEmpty) {
      final persistedDirectory = Directory(persistedPath);
      if (await _isPersistedWorkspaceAuthorized(persistedPath)) {
        if (requireWritable &&
            grantService != null &&
            !await grantService!.isPathWritableResolved(persistedPath)) {
          // A read-only grant is sufficient for inspection, but it must not
          // remain the workspace after a later write approval. Resolve a new
          // conversation directory under a confirmed writable grant so the
          // resumed task cannot loop on the old read-only path.
          final writableRoot = await _workspaceRoot(requireWritable: true);
          return (await directories.conversationDir(
            root: writableRoot,
            conversationId: conversationId,
            isDirectChat: isDirectChat,
          ))
              .path;
        }
        if (!await persistedDirectory.exists()) {
          final canCreate = grantService == null ||
              await grantService!.isPathWritableResolved(persistedPath);
          if (canCreate) {
            await persistedDirectory.create(recursive: true);
          } else {
            // The old conversation directory may have disappeared while the
            // app only has a read grant. Fall back to the existing granted
            // root instead of creating anything under a read-only capability.
            return (await _workspaceRoot()).path;
          }
        } else if (await FileSystemEntity.type(
              persistedPath,
              followLinks: true,
            ) !=
            FileSystemEntityType.directory) {
          throw WorkspacePathException(
            WorkspacePathErrorKind.notAuthorized,
            '已保存的工作目录不是目录，请重新选择目录。',
            path: persistedPath,
          );
        }
        // workDirPath is already the conversation directory. Returning it
        // directly prevents repeated loadOrCreate calls from nesting another
        // `conversations/<folder>` suffix into the persisted path.
        return persistedDirectory.path;
      }
      // Legacy callers that do not provide the app-wide grant service only
      // have the configured processing root as their capability boundary. Keep
      // their historical recovery behavior; production work-mode wiring always
      // supplies a grant service and therefore takes the fail-closed branch.
      if (grantService == null) {
        final root = await _workspaceRoot(requireWritable: requireWritable);
        return (await directories.conversationDir(
          root: root,
          conversationId: conversationId,
          isDirectChat: isDirectChat,
        ))
            .path;
      }
      // A previously selected workspace is a capability boundary. Falling
      // back to another grant would silently redirect a follow-up write to a
      // different directory, so require explicit re-authorization instead.
      throw WorkspacePathException(
        WorkspacePathErrorKind.notAuthorized,
        '已保存的工作目录不再受授权覆盖，请重新选择目录。',
        path: persistedPath,
      );
    }

    final root = await _workspaceRoot(requireWritable: requireWritable);
    // A read-only grant is a valid capability for inspection commands. Do not
    // create an app-owned conversation directory under it; using the granted
    // directory itself keeps `pwd`, listing and search usable without turning
    // a read grant into an implicit write request.
    if (grantService != null &&
        !requireWritable &&
        !grantService!.hasConfirmedWritableGrant()) {
      return root.path;
    }
    return (await directories.conversationDir(
      root: root,
      conversationId: conversationId,
      isDirectChat: isDirectChat,
    ))
        .path;
  }

  Future<bool> _isPersistedWorkspaceAuthorized(String path) async {
    final grants = grantService;
    if (grants != null) {
      await grants.load();
      // Resolve symlinked ancestors (notably macOS /var -> /private/var)
      // before checking the persisted conversation directory. A lexical
      // comparison would incorrectly force reauthorization after restart.
      return grants.isPathAuthorizedResolved(path);
    }

    final fallbackRoot = await db.aiProcessingDir;
    return WorkspacePathPolicy.isWithinRoot(
      fallbackRoot.path,
      path,
      isWindows: Platform.isWindows,
    );
  }

  Future<Directory> _workspaceRoot({bool requireWritable = false}) async {
    final grants = grantService;
    if (grants != null) {
      await grants.load();
      final confirmed = grants.grants.where(
        (grant) =>
            grant.available &&
            grant.cloudDisclosureConfirmedAt != null &&
            (!requireWritable || grant.writable),
      );
      final first = confirmed.isEmpty
          ? null
          : (requireWritable
              ? confirmed.first
              : confirmed.firstWhere(
                  (grant) => grant.writable,
                  orElse: () => confirmed.first,
                ));
      if (first != null) {
        final directory = Directory(first.path);
        if (first.writable && !await directory.exists()) {
          await directory.create(recursive: true);
        }
        return directory;
      }
      throw const WorkspacePathException(
        WorkspacePathErrorKind.notAuthorized,
        '工作模式需要至少一个已确认且可访问的授权目录。',
      );
    }
    return db.aiProcessingDir;
  }
}
