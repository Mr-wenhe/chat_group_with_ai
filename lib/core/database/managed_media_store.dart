import 'dart:io';

import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/hive_deletion_runner.dart';
import 'package:flutter/foundation.dart';

class ManagedMediaStore {
  final DatabaseService db;
  final Directory? root;

  ManagedMediaStore({required this.db, Directory? root})
      : root = root ??
            (db.dataDirPath == null
                ? null
                : Directory('${db.dataDirPath}/media'));

  Future<MediaUsage> usage({Set<String> excludedMessageIds = const {}}) async {
    final rootPath = await _safeRootPath();
    if (rootPath == null) return MediaUsage.empty;
    final referenced = <String>{};
    var scannedMessages = 0;
    for (final message in db.messageBox.values) {
      if (!excludedMessageIds.contains(message.id)) {
        for (final attachment in message.media ?? const []) {
          try {
            final file = File(attachment.localPath);
            if (!await file.exists()) continue;
            final path = await file.resolveSymbolicLinks();
            if (_isInside(rootPath, path)) referenced.add(path);
          } on Object {
            // An unreadable path is never a deletion candidate.
          }
        }
      }
      if (++scannedMessages % HiveDeletionRunner.batchSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    var totalFiles = 0;
    var totalBytes = 0;
    var orphanBytes = 0;
    final orphans = <String>[];
    await for (final entity
        in root!.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        final path = await entity.resolveSymbolicLinks();
        if (!_isInside(rootPath, path)) continue;
        final length = await entity.length();
        totalFiles++;
        totalBytes += length;
        if (!referenced.contains(path)) {
          orphans.add(entity.path);
          orphanBytes += length;
        }
      } on Object {
        // Unreadable and symlinked-outside files are deliberately skipped.
      }
    }
    return MediaUsage(
      totalFiles: totalFiles,
      totalBytes: totalBytes,
      orphanFiles: orphans.length,
      orphanBytes: orphanBytes,
      orphanPaths: orphans,
    );
  }

  Future<DataLifecycleResult> cleanup() async {
    final incomplete = <String>[];
    final current = await usage();
    var files = 0;
    var bytes = 0;
    for (final path in current.orphanPaths) {
      try {
        final file = File(path);
        final length = await file.length();
        await file.delete();
        files++;
        bytes += length;
      } on Object {
        if (!incomplete.contains('附件回收失败')) {
          incomplete.add('附件回收失败');
        }
      }
    }
    return DataLifecycleResult(
      incompleteItems: incomplete,
      reclaimedFiles: files,
      reclaimedBytes: bytes,
    );
  }

  /// Reclaims only the supplied app-managed files without walking the media
  /// directory. Remaining message references still win over deletion.
  Future<DataLifecycleResult> cleanupPaths(Iterable<String> paths) async {
    final candidates = paths.toSet();
    if (candidates.isEmpty) {
      return const DataLifecycleResult();
    }
    final rootPath = await _safeRootPath();
    if (rootPath == null) return const DataLifecycleResult();
    final referenced = <String>{};
    var scannedMessages = 0;
    // ponytail: scan message references only; add an attachment-reference
    // index in phase 03 if message-volume profiling shows this is still hot.
    for (final message in db.messageBox.values) {
      for (final attachment in message.media ?? const []) {
        if (candidates.contains(attachment.localPath)) {
          referenced.add(attachment.localPath);
        }
      }
      if (++scannedMessages % HiveDeletionRunner.batchSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    final incomplete = <String>[];
    var files = 0;
    var bytes = 0;
    for (final path in candidates.difference(referenced)) {
      try {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        final file = File(path);
        final resolvedPath = await file.resolveSymbolicLinks();
        if (!_isInside(rootPath, resolvedPath)) continue;
        final length = await file.length();
        await file.delete();
        files++;
        bytes += length;
      } on Object {
        if (!incomplete.contains('附件回收失败')) {
          incomplete.add('附件回收失败');
        }
      }
    }
    return DataLifecycleResult(
      incompleteItems: incomplete,
      reclaimedFiles: files,
      reclaimedBytes: bytes,
    );
  }

  Future<String?> _safeRootPath() async {
    if (kIsWeb || root == null || !await root!.exists()) return null;
    try {
      final rootPath = await root!.resolveSymbolicLinks();
      final parentPath = await root!.parent.resolveSymbolicLinks();
      final rootName = root!.absolute.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      return rootPath == '$parentPath${Platform.pathSeparator}$rootName'
          ? rootPath
          : null;
    } on Object {
      return null;
    }
  }

  bool _isInside(String rootPath, String path) =>
      path == rootPath || path.startsWith('$rootPath${Platform.pathSeparator}');
}
