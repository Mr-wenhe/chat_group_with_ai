import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_snapshot_manifest.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:crypto/crypto.dart';

typedef WorkSnapshotSizeResolver = Future<int> Function(Directory directory);
typedef WorkSnapshotActivityResolver = FutureOr<bool> Function(String taskId);

enum WorkSnapshotUndoStatus { success, conflict, unavailable, notFound, failed }

class WorkSnapshotConflict {
  final int sequence;
  final String path;
  final String reason;

  const WorkSnapshotConflict({
    required this.sequence,
    required this.path,
    required this.reason,
  });
}

/// A display-safe item used by the task panel's confirmation dialog.
class WorkSnapshotUndoItem {
  final int sequence;
  final String operation;
  final String path;
  final String? targetPath;

  const WorkSnapshotUndoItem({
    required this.sequence,
    required this.operation,
    required this.path,
    this.targetPath,
  });

  String get label => targetPath == null
      ? '$operation：$path'
      : '$operation：$targetPath → $path';
}

class WorkSnapshotUndoResult {
  final String taskId;
  final WorkSnapshotUndoStatus status;
  final String reason;
  final List<String> restoredPaths;
  final List<String> deletedPaths;
  final List<WorkSnapshotConflict> conflicts;

  const WorkSnapshotUndoResult({
    required this.taskId,
    required this.status,
    required this.reason,
    this.restoredPaths = const [],
    this.deletedPaths = const [],
    this.conflicts = const [],
  });

  bool get succeeded => status == WorkSnapshotUndoStatus.success;
}

class WorkSnapshotCleanupResult {
  final List<String> expiredTaskIds;
  final List<String> sizeEvictedTaskIds;

  /// Tasks whose manifest was present but could not be decoded. They are
  /// intentionally retained so cleanup never destroys the only recovery
  /// evidence; callers can surface a retry/export/repair action instead of
  /// treating the task as if it never had a snapshot.
  final List<String> corruptedTaskIds;
  final int remainingBytes;

  const WorkSnapshotCleanupResult({
    this.expiredTaskIds = const [],
    this.sizeEvictedTaskIds = const [],
    this.corruptedTaskIds = const [],
    this.remainingBytes = 0,
  });

  List<String> get deletedTaskIds => [
        ...expiredTaskIds,
        ...sizeEvictedTaskIds,
      ];
}

class _SnapshotReservation {
  final String taskId;
  final int sequence;
  final WorkSnapshotAction action;

  const _SnapshotReservation({
    required this.taskId,
    required this.sequence,
    required this.action,
  });
}

class _SnapshotTaskRecord {
  final String taskId;
  final WorkSnapshotManifest manifest;
  final Directory directory;
  final int size;

  const _SnapshotTaskRecord({
    required this.taskId,
    required this.manifest,
    required this.directory,
    required this.size,
  });
}

/// Minimal digest sink kept local so the snapshot package does not depend on
/// crypto's transitive `convert` package at the application boundary.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest event) => value = event;

  @override
  void close() {}
}

/// Stores pre-images in an app-managed directory and owns task-level undo.
///
/// ponytail: Keep snapshot persistence separate from mutation I/O. The
/// mutation service asks this class for a durable reservation immediately
/// before touching a user file, while undo and retention stay explicit APIs.
class WorkSnapshotService
    implements
        WorkspaceMutationSnapshotPort,
        WorkspaceMutationSnapshotAvailabilityPort,
        WorkspaceMutationSnapshotCompletionPort,
        WorkspaceMutationSnapshotAbortPort {
  static const int defaultRetentionDays =
      WorkModeAgentSettings.defaultRetentionDays;
  static const int defaultSnapshotLimitBytes =
      WorkModeAgentSettings.defaultSnapshotLimitBytes;
  static const String _manifestName = 'manifest.json';

  final Directory appSupportDirectory;
  final WorkspacePathPolicy? pathPolicy;
  final WorkTaskEventStore? eventStore;
  final DateTime Function() clock;
  final int retentionDays;
  final int snapshotLimitBytes;
  final WorkSnapshotSizeResolver _sizeResolver;
  final WorkSnapshotActivityResolver? _activityResolver;
  final WorkResourceLockManager? resourceLockManager;
  final Map<String, _SnapshotReservation> _reservations =
      <String, _SnapshotReservation>{};
  int _temporaryFileSequence = 0;
  // Manifest/quota updates share one directory across conversations. Serialise
  // those updates so two tasks cannot allocate the same sequence or both pass
  // the quota check before either backup is visible on disk.
  Future<void> _storageQueue = Future<void>.value();

  WorkSnapshotService({
    required this.appSupportDirectory,
    this.pathPolicy,
    this.eventStore,
    DateTime Function()? clock,
    this.retentionDays = defaultRetentionDays,
    this.snapshotLimitBytes = defaultSnapshotLimitBytes,
    WorkSnapshotSizeResolver? snapshotSizeResolver,
    WorkSnapshotActivityResolver? taskActivityResolver,
    this.resourceLockManager,
  })  : clock = clock ?? DateTime.now,
        _sizeResolver = snapshotSizeResolver ?? _directorySize,
        _activityResolver = taskActivityResolver {
    if (retentionDays <= 0) {
      throw ArgumentError.value(retentionDays, 'retentionDays');
    }
    if (snapshotLimitBytes <= 0) {
      throw ArgumentError.value(snapshotLimitBytes, 'snapshotLimitBytes');
    }
  }

  Directory get snapshotsDirectory =>
      Directory('${appSupportDirectory.path}/work_mode_agent/snapshots');

  Directory snapshotDirectoryFor(String taskId) {
    _validateTaskId(taskId);
    return Directory('${snapshotsDirectory.path}/$taskId');
  }

  Future<int> currentUsageBytes() async {
    if (!await _ensureSnapshotsDirectory(create: false)) return 0;
    return _sizeResolver(snapshotsDirectory);
  }

  /// Deletes only the app-managed snapshot tree. The no-follow walk removes a
  /// symlink itself instead of traversing its target, so clearing App data can
  /// never delete a file from an authorized user project directory.
  Future<int> clearAll() => _serializeStorage(() async {
        _reservations.clear();
        if (!await _ensureManagedParents(create: false)) return 0;
        return _deleteTreeNoFollow(snapshotsDirectory);
      });

  File manifestFileFor(String taskId) =>
      File('${snapshotDirectoryFor(taskId).path}/$_manifestName');

  Future<WorkSnapshotManifest?> readManifest(String taskId) async {
    final file = manifestFileFor(taskId);
    try {
      if (!await _ensureManagedParents(create: false)) return null;
      final rootType = await FileSystemEntity.type(
        snapshotsDirectory.path,
        followLinks: false,
      );
      if (rootType != FileSystemEntityType.directory) return null;
      final taskDirectory = snapshotDirectoryFor(taskId);
      final taskType = await FileSystemEntity.type(
        taskDirectory.path,
        followLinks: false,
      );
      if (taskType != FileSystemEntityType.directory) return null;
      final fileType = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (fileType != FileSystemEntityType.file) return null;
    } on Object {
      // A missing or untrusted app-support path is never read as a snapshot.
      return null;
    }
    try {
      final manifest =
          WorkSnapshotManifest.fromJsonString(await file.readAsString());
      return manifest.taskId == taskId ? manifest : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<WorkspaceSnapshotReservation> reserve({
    required WorkChangePlan plan,
    required List<String> paths,
  }) {
    return _serializeStorage(
      () => _reserveUnlocked(plan: plan, paths: paths),
    );
  }

  @override
  Future<bool> canReserve({
    required WorkChangePlan plan,
    required List<String> paths,
  }) {
    return _serializeStorage(() async {
      if (paths.isEmpty ||
          plan.actionType == WorkChangeActionType.command ||
          !plan.snapshotAvailable ||
          !plan.reversible) {
        return false;
      }
      final expected = plan.actionType == WorkChangeActionType.rename ? 2 : 1;
      if (paths.length != expected) {
        return false;
      }
      try {
        // The first mutation has no snapshot directory yet. Creating this
        // empty App-managed directory is safe and keeps the availability
        // probe from falsely forcing an irreversible approval on every new
        // task; symlinked or non-directory parents still fail closed.
        if (!await _ensureSnapshotsDirectory(create: true)) return false;
        final captured = await _capture(plan, paths);
        final current = await _sizeResolver(snapshotsDirectory);
        return current + (captured.bytes?.length ?? 0) <= snapshotLimitBytes;
      } on Object {
        return false;
      }
    });
  }

  Future<WorkspaceSnapshotReservation> _reserveUnlocked({
    required WorkChangePlan plan,
    required List<String> paths,
  }) async {
    if (paths.isEmpty ||
        plan.actionType == WorkChangeActionType.command ||
        !plan.snapshotAvailable ||
        !plan.reversible) {
      return const WorkspaceSnapshotReservation(available: false);
    }
    final expectedPathCount =
        plan.actionType == WorkChangeActionType.rename ? 2 : 1;
    if (paths.length != expectedPathCount) {
      return const WorkspaceSnapshotReservation(available: false);
    }
    File? backup;
    try {
      await _ensureSnapshotsDirectory(create: true);
      final directory = snapshotDirectoryFor(plan.taskId);
      final directoryType = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (directoryType == FileSystemEntityType.link ||
          (directoryType != FileSystemEntityType.notFound &&
              directoryType != FileSystemEntityType.directory)) {
        throw StateError('任务快照目录不是普通目录');
      }
      if (directoryType == FileSystemEntityType.notFound) {
        await directory.create(recursive: false);
      }
      final manifestFile = manifestFileFor(plan.taskId);
      final current =
          await _readManifestForReservation(manifestFile, plan.taskId);
      if (current == null) {
        return const WorkspaceSnapshotReservation(available: false);
      }
      final sequence =
          current.actions.isEmpty ? 1 : current.actions.last.sequence + 1;
      final captured = await _capture(plan, paths);
      final existingSnapshotBytes = await _sizeResolver(snapshotsDirectory);
      final incomingBytes = captured.bytes?.length ?? 0;
      if (existingSnapshotBytes + incomingBytes > snapshotLimitBytes) {
        return const WorkspaceSnapshotReservation(available: false);
      }
      final backupRelativePath = captured.bytes == null
          ? null
          : 'backups/${sequence.toString().padLeft(8, '0')}.bin';
      if (captured.bytes != null) {
        final candidate = File('${directory.path}/$backupRelativePath');
        if (await candidate.exists()) {
          throw StateError('快照备份目标已存在');
        }
        final existingParentType = await FileSystemEntity.type(
          candidate.parent.path,
          followLinks: false,
        );
        if (existingParentType != FileSystemEntityType.notFound &&
            existingParentType != FileSystemEntityType.directory) {
          throw StateError('快照备份目录不是普通目录');
        }
        backup = candidate;
        await backup.parent.create(recursive: true);
        await _writeFlushed(backup, captured.bytes!);
      }
      final action = WorkSnapshotAction(
        sequence: sequence,
        actionType: plan.actionType,
        originalPath: paths.first,
        targetPath: paths.length > 1 ? paths[1] : null,
        mtime: captured.mtime,
        size: captured.size,
        sha256: captured.sha256,
        backupRelativePath: backupRelativePath,
        existedBefore: captured.existed,
        postMtime: null,
        postSize: null,
        postSha256: null,
        completed: false,
        undone: false,
      );
      final updated = current.copyWith(
        updatedAt: clock(),
        taskStatus: WorkSnapshotTaskStatus.active,
        actions: [...current.actions, action],
      );
      await _writeManifest(directory, updated);
      final reservationId = '${plan.taskId}:$sequence';
      _reservations[reservationId] = _SnapshotReservation(
        taskId: plan.taskId,
        sequence: sequence,
        action: action,
      );
      return WorkspaceSnapshotReservation(
        available: true,
        reservationId: reservationId,
      );
    } on Object {
      if (backup != null) {
        try {
          if (await backup.exists()) await backup.delete();
        } on Object {
          // A failed snapshot is still a hard stop; cleanup is best effort.
        }
      }
      return const WorkspaceSnapshotReservation(available: false);
    }
  }

  Future<WorkSnapshotManifest?> _readManifestForReservation(
    File manifestFile,
    String taskId,
  ) async {
    final fileType = await FileSystemEntity.type(
      manifestFile.path,
      followLinks: false,
    );
    if (fileType == FileSystemEntityType.notFound) {
      return WorkSnapshotManifest.empty(taskId, clock());
    }
    if (fileType != FileSystemEntityType.file) return null;
    try {
      final manifest = WorkSnapshotManifest.fromJsonString(
        await manifestFile.readAsString(),
      );
      return manifest.taskId == taskId ? manifest : null;
    } on Object {
      // Never replace a malformed existing manifest with a new empty one.
      return null;
    }
  }

  @override
  Future<void> complete({
    required WorkspaceSnapshotReservation reservation,
    required WorkChangePlan plan,
    required List<String> paths,
    required WorkspaceMutationResult result,
  }) {
    return _serializeStorage(
      () => _completeUnlocked(
        reservation: reservation,
        plan: plan,
        paths: paths,
        result: result,
      ),
    );
  }

  Future<void> _completeUnlocked({
    required WorkspaceSnapshotReservation reservation,
    required WorkChangePlan plan,
    required List<String> paths,
    required WorkspaceMutationResult result,
  }) async {
    final id = reservation.reservationId;
    if (id == null) return;
    // Keep the reservation live until the durable manifest update succeeds.
    // If completion fails after the file has been replaced, the mutation
    // service can still call abort() and mark the pre-image as non-complete
    // instead of silently losing the only recovery handle.
    final pending = _reservations[id];
    if (pending == null) return;
    if (!result.succeeded) return;
    final manifest = await readManifest(pending.taskId);
    if (manifest == null) throw StateError('快照 manifest 不存在');
    // The mutation has already committed when completion is called. If an
    // external actor removes or replaces the target before we can inspect it,
    // keep the durable pre-image and mark the action complete with an unknown
    // post-condition so undo reports a conflict instead of hiding the action.
    late final _CapturedState post;
    String? completionFailure;
    try {
      post = await _postCondition(plan, paths);
    } on Object catch (error) {
      post = const _CapturedState();
      completionFailure = '完成后状态无法读取：${sanitizeWorkTaskError(error)}';
    }
    final actionIndex = manifest.actions.indexWhere(
      (item) => item.sequence == pending.sequence,
    );
    if (actionIndex < 0) throw StateError('快照动作不存在');
    final actions = List<WorkSnapshotAction>.from(manifest.actions);
    actions[actionIndex] = actions[actionIndex].copyWith(
      postMtime: post.mtime,
      postSize: post.size,
      postSha256: post.sha256,
      completed: true,
      failureReason: completionFailure,
      clearFailureReason: completionFailure == null,
    );
    await _writeManifest(
      snapshotDirectoryFor(pending.taskId),
      manifest.copyWith(updatedAt: clock(), actions: actions),
    );
    _reservations.remove(id);
  }

  @override
  Future<void> abort({
    required WorkspaceSnapshotReservation reservation,
    required WorkChangePlan plan,
    required List<String> paths,
    required WorkspaceMutationResult result,
  }) {
    return _serializeStorage(
      () => _abortUnlocked(
        reservation: reservation,
        plan: plan,
        paths: paths,
        result: result,
      ),
    );
  }

  Future<void> _abortUnlocked({
    required WorkspaceSnapshotReservation reservation,
    required WorkChangePlan plan,
    required List<String> paths,
    required WorkspaceMutationResult result,
  }) async {
    final id = reservation.reservationId;
    if (id == null) return;
    // Keep the reservation until the failure marker itself is durable. If
    // manifest writing fails transiently, the in-memory handle remains
    // available for a later retry instead of silently losing the pre-image.
    final pending = _reservations[id];
    if (pending == null) return;
    final manifest = await readManifest(pending.taskId);
    if (manifest == null) return;
    final actionIndex = manifest.actions.indexWhere(
      (item) => item.sequence == pending.sequence,
    );
    if (actionIndex < 0) return;
    final actions = List<WorkSnapshotAction>.from(manifest.actions);
    actions[actionIndex] = actions[actionIndex].copyWith(
      failureReason: sanitizeWorkTaskError(result.reason),
      // A committed mutation whose completion bookkeeping failed must remain
      // visible to undo. Its post-condition is intentionally unknown, so a
      // later undo will fail closed with a conflict rather than overwrite an
      // externally changed target. Pre-commit failures stay uncompleted.
      completed: result.mutationCommitted,
    );
    await _writeManifest(
      snapshotDirectoryFor(pending.taskId),
      manifest.copyWith(
        updatedAt: clock(),
        taskStatus: WorkSnapshotTaskStatus.failed,
        actions: actions,
      ),
    );
    _reservations.remove(id);
  }

  /// Updates the task lifecycle used by retention; no user content is added.
  Future<void> markTaskStatus(
    String taskId,
    WorkSnapshotTaskStatus status,
  ) {
    return _serializeStorage(() => _markTaskStatusUnlocked(taskId, status));
  }

  Future<void> _markTaskStatusUnlocked(
    String taskId,
    WorkSnapshotTaskStatus status,
  ) async {
    final manifest = await readManifest(taskId);
    if (manifest == null) return;
    await _writeManifest(
      snapshotDirectoryFor(taskId),
      manifest.copyWith(updatedAt: clock(), taskStatus: status),
    );
  }

  List<WorkSnapshotUndoItem> previewUndoSync(String taskId) {
    final file = manifestFileFor(taskId);
    if (FileSystemEntity.typeSync(
          appSupportDirectory.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      return const [];
    }
    final container = Directory(
      '${appSupportDirectory.path}/work_mode_agent',
    );
    if (FileSystemEntity.typeSync(container.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return const [];
    }
    final snapshotsType = FileSystemEntity.typeSync(
      snapshotsDirectory.path,
      followLinks: false,
    );
    if (snapshotsType != FileSystemEntityType.directory) return const [];
    final taskType = FileSystemEntity.typeSync(
      snapshotDirectoryFor(taskId).path,
      followLinks: false,
    );
    if (taskType != FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return const [];
    }
    try {
      final manifest =
          WorkSnapshotManifest.fromJsonString(file.readAsStringSync());
      return _previewItems(manifest);
    } on Object {
      // A present-but-invalid manifest is not equivalent to "nothing to
      // undo". Surface the corruption so a synchronous UI caller can show a
      // retry/cleanup action instead of silently hiding the recovery state.
      throw StateError('任务快照损坏，无法读取撤销范围，请重试或清理该任务快照。');
    }
  }

  Future<List<WorkSnapshotUndoItem>> previewUndo(String taskId) async {
    final manifestFile = manifestFileFor(taskId);
    final manifest = await readManifest(taskId);
    if (manifest == null) {
      if (await _isRegularFile(manifestFile)) {
        throw StateError('任务快照损坏，无法读取撤销范围，请重试或清理该任务快照。');
      }
      return const [];
    }
    return _previewItems(manifest);
  }

  Future<WorkSnapshotUndoResult> undo(
    String taskId, {
    WorkspacePathPolicy? authorization,
  }) async {
    final manifestFile = manifestFileFor(taskId);
    final manifest = await readManifest(taskId);
    if (manifest == null) {
      final manifestPresent = await _isRegularFile(manifestFile);
      return WorkSnapshotUndoResult(
        taskId: taskId,
        status: manifestPresent
            ? WorkSnapshotUndoStatus.unavailable
            : WorkSnapshotUndoStatus.notFound,
        reason: manifestPresent ? '任务快照损坏，未执行撤销。' : '找不到该任务的快照。',
      );
    }
    final activeResolver = _activityResolver;
    if (activeResolver != null) {
      try {
        if (await activeResolver(taskId)) {
          return WorkSnapshotUndoResult(
            taskId: taskId,
            status: WorkSnapshotUndoStatus.unavailable,
            reason: '任务仍在执行，必须等任务结束后才能撤销。',
          );
        }
      } on Object {
        return WorkSnapshotUndoResult(
          taskId: taskId,
          status: WorkSnapshotUndoStatus.unavailable,
          reason: '无法确认任务是否仍在执行，未执行撤销。',
        );
      }
    }
    final locks = _lockRequestsForManifest(manifest);
    final manager = resourceLockManager;
    if (manager != null) {
      try {
        return await manager.withLocks(
          'undo:$taskId',
          locks,
          () => _undoInternal(taskId, authorization: authorization),
        );
      } on Object catch (error) {
        return WorkSnapshotUndoResult(
          taskId: taskId,
          status: WorkSnapshotUndoStatus.unavailable,
          reason: '撤销资源锁不可用：${sanitizeWorkTaskError(error)}',
        );
      }
    }
    return _undoInternal(taskId, authorization: authorization);
  }

  Future<WorkSnapshotUndoResult> _undoInternal(
    String taskId, {
    WorkspacePathPolicy? authorization,
  }) {
    return _serializeStorage(
      () => _undoInternalUnlocked(taskId, authorization: authorization),
    );
  }

  Future<WorkSnapshotUndoResult> _undoInternalUnlocked(
    String taskId, {
    WorkspacePathPolicy? authorization,
  }) async {
    final manifest = await readManifest(taskId);
    if (manifest == null) {
      return WorkSnapshotUndoResult(
        taskId: taskId,
        status: WorkSnapshotUndoStatus.notFound,
        reason: '找不到该任务的快照。',
      );
    }
    final policy = authorization ?? pathPolicy;
    if (policy == null) {
      return WorkSnapshotUndoResult(
        taskId: taskId,
        status: WorkSnapshotUndoStatus.unavailable,
        reason: '撤销前无法重新校验工作目录授权。',
      );
    }
    try {
      await _verifyUndoAuthorization(manifest, policy);
    } on WorkspacePathException {
      return WorkSnapshotUndoResult(
        taskId: taskId,
        status: WorkSnapshotUndoStatus.unavailable,
        reason: '撤销前工作目录授权已失效，未覆盖当前内容。',
      );
    }
    final restored = <String>[];
    final deleted = <String>[];
    final conflicts = <WorkSnapshotConflict>[];
    final actions = List<WorkSnapshotAction>.from(manifest.actions);
    for (var index = actions.length - 1; index >= 0; index--) {
      final action = actions[index];
      if (!action.completed || action.undone) continue;
      try {
        final outcome = await _undoAction(taskId, action, policy);
        if (outcome == _UndoOutcome.restored) {
          restored.add(action.originalPath);
          actions[index] = action.copyWith(undone: true);
        } else if (outcome == _UndoOutcome.deleted) {
          deleted.add(action.originalPath);
          actions[index] = action.copyWith(undone: true);
        }
      } on _SnapshotConflict catch (error) {
        conflicts.add(
          WorkSnapshotConflict(
            sequence: action.sequence,
            path: error.path,
            reason: error.reason,
          ),
        );
      } on Object catch (error) {
        conflicts.add(
          WorkSnapshotConflict(
            sequence: action.sequence,
            path: action.originalPath,
            reason: '撤销失败：${sanitizeWorkTaskError(error)}',
          ),
        );
      }
    }
    final allUndone =
        actions.every((action) => !action.completed || action.undone);
    final status = conflicts.isEmpty
        ? (allUndone
            ? WorkSnapshotUndoStatus.success
            : WorkSnapshotUndoStatus.failed)
        : WorkSnapshotUndoStatus.conflict;
    final updatedStatus = conflicts.isEmpty && allUndone
        ? WorkSnapshotTaskStatus.undone
        : WorkSnapshotTaskStatus.partiallyUndone;
    await _writeManifest(
      snapshotDirectoryFor(taskId),
      manifest.copyWith(
        updatedAt: clock(),
        taskStatus: updatedStatus,
        actions: actions,
      ),
    );
    await _recordUndoEvents(
      taskId: taskId,
      restored: restored,
      deleted: deleted,
      conflicts: conflicts,
    );
    return WorkSnapshotUndoResult(
      taskId: taskId,
      status: status,
      reason: conflicts.isEmpty ? '任务改动已撤销。' : '部分改动存在外部冲突，外部内容已保留。',
      restoredPaths: restored,
      deletedPaths: deleted,
      conflicts: conflicts,
    );
  }

  List<WorkResourceLockRequest> _lockRequestsForManifest(
    WorkSnapshotManifest manifest,
  ) {
    final paths = <String>{};
    for (final action in manifest.actions) {
      if (!action.completed || action.undone) continue;
      paths.add(action.originalPath);
      if (action.targetPath != null) paths.add(action.targetPath!);
    }
    return paths.map(WorkResourceLockRequest.write).toList(growable: false);
  }

  Future<WorkSnapshotUndoResult> undoTask(
    String taskId, {
    WorkspacePathPolicy? authorization,
  }) =>
      undo(taskId, authorization: authorization);

  Future<WorkSnapshotCleanupResult> cleanupSnapshots({
    int? retentionDays,
    int? snapshotLimitBytes,
    WorkSnapshotActivityResolver? isTaskActive,
  }) =>
      cleanup(
        retentionDays: retentionDays,
        snapshotLimitBytes: snapshotLimitBytes,
        isTaskActive: isTaskActive,
      );

  Future<WorkSnapshotCleanupResult> cleanup({
    int? retentionDays,
    int? snapshotLimitBytes,
    WorkSnapshotActivityResolver? isTaskActive,
  }) {
    return _serializeStorage(
      () => _cleanupUnlocked(
        retentionDays: retentionDays,
        snapshotLimitBytes: snapshotLimitBytes,
        isTaskActive: isTaskActive,
      ),
    );
  }

  Future<WorkSnapshotCleanupResult> _cleanupUnlocked({
    int? retentionDays,
    int? snapshotLimitBytes,
    WorkSnapshotActivityResolver? isTaskActive,
  }) async {
    final retention = retentionDays ?? this.retentionDays;
    final limit = snapshotLimitBytes ?? this.snapshotLimitBytes;
    if (retention <= 0 || limit <= 0) {
      throw ArgumentError('清理阈值必须为正数');
    }
    if (!await _ensureSnapshotsDirectory(create: false)) {
      return const WorkSnapshotCleanupResult();
    }
    final corruptedTaskIds = <String>[];
    final records = await _loadRecords(
      isTaskActive,
      corruptedTaskIds: corruptedTaskIds,
    )
      ..sort(_compareSnapshotRecords);
    final cutoff = clock().subtract(Duration(days: retention));
    final expired = <String>[];
    final survivors = <_SnapshotTaskRecord>[];
    for (final record in records) {
      // Retention is measured from the first durable snapshot, not from a
      // later status/undo update that could otherwise keep old bytes alive.
      if (_isTerminal(record.manifest) &&
          record.manifest.createdAt.isBefore(cutoff)) {
        await _deleteRecord(record);
        expired.add(record.taskId);
      } else {
        survivors.add(record);
      }
    }
    final terminal = survivors
        .where((record) => _isTerminal(record.manifest))
        .toList(growable: false)
      ..sort(_compareSnapshotRecords);
    var total = survivors.fold<int>(0, (sum, item) => sum + item.size);
    final evicted = <String>[];
    for (final record in terminal) {
      if (total <= limit) break;
      await _deleteRecord(record);
      total -= record.size;
      evicted.add(record.taskId);
    }
    return WorkSnapshotCleanupResult(
      expiredTaskIds: expired,
      sizeEvictedTaskIds: evicted,
      corruptedTaskIds: List.unmodifiable(corruptedTaskIds),
      remainingBytes: total,
    );
  }

  Future<List<_SnapshotTaskRecord>> _loadRecords(
    WorkSnapshotActivityResolver? activeResolver, {
    List<String>? corruptedTaskIds,
  }) async {
    final records = <_SnapshotTaskRecord>[];
    await for (final entity in snapshotsDirectory.list(followLinks: false)) {
      if (entity is! Directory ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.directory) {
        continue;
      }
      final normalizedEntityPath = entity.path.replaceAll('\\', '/');
      final taskId = normalizedEntityPath.substring(
        normalizedEntityPath.lastIndexOf('/') + 1,
      );
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(taskId)) continue;
      final manifest = await readManifest(taskId);
      if (manifest == null) {
        // A missing manifest means an incomplete/pre-commit directory and is
        // safe to ignore. A present-but-invalid manifest is different: keep
        // it on disk and report it so callers cannot silently lose undo
        // visibility after a restart or partial write.
        if (await FileSystemEntity.type(
              manifestFileFor(taskId).path,
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          corruptedTaskIds?.add(taskId);
        }
        continue;
      }
      final resolver = activeResolver ?? _activityResolver;
      final active =
          resolver == null ? !_isTerminal(manifest) : await resolver(taskId);
      if (active) continue;
      records.add(
        _SnapshotTaskRecord(
          taskId: taskId,
          manifest: manifest,
          directory: entity,
          // Resolve the same deterministic path exposed to callers so fake
          // size clocks and the deletion target cannot disagree on symlinks.
          size: await _sizeResolver(snapshotDirectoryFor(taskId)),
        ),
      );
    }
    return records;
  }

  Future<_UndoOutcome> _undoAction(
    String taskId,
    WorkSnapshotAction action,
    WorkspacePathPolicy policy,
  ) async {
    switch (action.actionType) {
      case WorkChangeActionType.create:
        await _verifyCurrent(policy, action.originalPath, action.postSha256,
            mustExist: true);
        await File(action.originalPath).delete();
        return _UndoOutcome.deleted;
      case WorkChangeActionType.modify:
      case WorkChangeActionType.patch:
      case WorkChangeActionType.delete:
        await _verifyCurrent(
          policy,
          action.originalPath,
          action.postSha256,
          mustExist: action.actionType != WorkChangeActionType.delete,
        );
        final backupPath = action.backupRelativePath;
        if (backupPath == null || action.sha256 == null) {
          throw _SnapshotConflict(action.originalPath, '缺少可恢复的备份。');
        }
        final bytes = await _readBackup(taskId, backupPath);
        final backupHash = sha256.convert(bytes).toString();
        if (backupHash != action.sha256) {
          throw _SnapshotConflict(action.originalPath, '快照备份哈希校验失败，未覆盖当前内容。');
        }
        await _restoreBytes(
          action.originalPath,
          bytes,
          isWindows: policy.isWindows,
        );
        final restoredHash = await _hashFile(File(action.originalPath));
        if (restoredHash != action.sha256) {
          throw _SnapshotConflict(action.originalPath, '恢复后哈希校验失败。');
        }
        if (action.mtime != null) {
          try {
            await File(action.originalPath).setLastModified(action.mtime!);
          } on Object {
            // A platform may not preserve nanosecond mtime precision; the
            // restored bytes and SHA-256 remain the authoritative recovery.
          }
        }
        return _UndoOutcome.restored;
      case WorkChangeActionType.rename:
        final destination = action.targetPath;
        if (destination == null ||
            action.postSha256 == null ||
            action.sha256 == null) {
          throw _SnapshotConflict(action.originalPath, '重命名快照缺少目标或哈希。');
        }
        await _verifyCurrent(policy, action.originalPath, null,
            mustExist: false);
        await _verifyCurrent(policy, destination, action.postSha256,
            mustExist: true);
        await File(destination).rename(action.originalPath);
        final restoredHash = await _hashFile(File(action.originalPath));
        if (restoredHash != action.sha256) {
          throw _SnapshotConflict(action.originalPath, '重命名逆转后哈希校验失败。');
        }
        return _UndoOutcome.restored;
      case WorkChangeActionType.command:
        throw _SnapshotConflict(action.originalPath, '命令动作没有文件快照。');
    }
  }

  Future<void> _verifyCurrent(
    WorkspacePathPolicy policy,
    String path,
    String? expectedHash, {
    required bool mustExist,
  }) async {
    final resolved = await policy.resolve(path, allowMissing: !mustExist);
    if (workPathKey(resolved.path) != workPathKey(path) ||
        resolved.wasSymbolicLink) {
      throw _SnapshotConflict(path, '授权路径发生变化，未覆盖当前内容。');
    }
    if (!mustExist) {
      if (!resolved.exists) return;
      if (!resolved.isFile) throw _SnapshotConflict(path, '当前目标不是普通文件。');
    } else if (!resolved.exists || !resolved.isFile) {
      throw _SnapshotConflict(path, '当前目标不存在或不是普通文件。');
    }
    if (expectedHash == null) throw _SnapshotConflict(path, '快照缺少当前哈希。');
    final actual = await _hashFile(File(resolved.path));
    if (actual != expectedHash) {
      throw _SnapshotConflict(path, '文件已被外部修改，未覆盖新内容。');
    }
  }

  Future<void> _verifyUndoAuthorization(
    WorkSnapshotManifest manifest,
    WorkspacePathPolicy policy,
  ) async {
    final paths = <String>{};
    for (final action in manifest.actions) {
      if (!action.completed || action.undone) continue;
      for (final path in <String?>[
        action.originalPath,
        if (action.actionType == WorkChangeActionType.rename) action.targetPath,
      ]) {
        if (path == null) continue;
        late final String key;
        try {
          key = workPathKey(path);
        } on Object {
          throw WorkspacePathException(
            WorkspacePathErrorKind.invalidPath,
            '撤销路径格式无效。',
            path: path,
          );
        }
        if (!paths.add(key)) continue;
        final resolved = await policy.resolve(path, allowMissing: true);
        if (workPathKey(resolved.path) != workPathKey(path) ||
            resolved.wasSymbolicLink) {
          throw WorkspacePathException(
            WorkspacePathErrorKind.symlinkEscape,
            '撤销路径授权状态发生变化。',
            path: path,
          );
        }
      }
    }
  }

  Future<List<int>> _readBackup(String taskId, String relative) async {
    if (!await _ensureSnapshotsDirectory(create: false)) {
      throw StateError('快照备份目录不是受信任目录');
    }
    final taskDirectory = snapshotDirectoryFor(taskId);
    if (await FileSystemEntity.type(
          taskDirectory.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      throw StateError('任务快照目录不是受信任目录');
    }
    final normalized = relative.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalized) ||
        segments.any((segment) =>
            segment.isEmpty || segment == '.' || segment == '..')) {
      throw StateError('快照备份路径无效');
    }
    final file = File('${snapshotDirectoryFor(taskId).path}/$normalized');
    if (!await file.exists()) throw StateError('快照备份文件不存在');
    final parentType = await FileSystemEntity.type(
      file.parent.path,
      followLinks: false,
    );
    final fileType = await FileSystemEntity.type(
      file.path,
      followLinks: false,
    );
    if (parentType != FileSystemEntityType.directory ||
        fileType != FileSystemEntityType.file) {
      throw StateError('快照备份文件不是受信任的普通文件');
    }
    return file.readAsBytes();
  }

  Future<bool> _isRegularFile(File file) async =>
      await FileSystemEntity.type(file.path, followLinks: false) ==
      FileSystemEntityType.file;

  Future<void> _restoreBytes(
    String path,
    List<int> bytes, {
    required bool isWindows,
  }) async {
    final target = File(path);
    final temp = _temporarySibling(target, 'undo');
    try {
      await _writeFlushed(temp, bytes);
      if (!isWindows) {
        await temp.rename(target.path);
        return;
      }
      final replaced = _temporarySibling(target, 'undo-original');
      var originalMoved = false;
      try {
        await _assertTemporaryPathAvailable(replaced);
        if (await target.exists()) {
          await target.rename(replaced.path);
          originalMoved = true;
        }
        await temp.rename(target.path);
        if (originalMoved) {
          try {
            await replaced.delete();
          } on Object {
            // The restored target is valid; a later cleanup can remove the
            // old temporary file if Windows still holds it briefly.
          }
        }
      } catch (_) {
        if (originalMoved &&
            !await target.exists() &&
            await replaced.exists()) {
          try {
            await replaced.rename(target.path);
          } on Object {
            // The manifest and backup remain available for a later retry.
          }
        }
        rethrow;
      }
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<_CapturedState> _capture(
    WorkChangePlan plan,
    List<String> paths,
  ) async {
    if (plan.actionType == WorkChangeActionType.create) {
      return const _CapturedState();
    }
    // ponytail: V1 snapshots cover ordinary files only; bounded tree archives
    // can be added when directory-level undo is explicitly required.
    final file = File(paths.first);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw StateError('只有普通文件支持可恢复快照');
    }
    final stat = await file.stat();
    if (stat.size > snapshotLimitBytes) {
      throw StateError('快照文件超过单文件大小上限');
    }
    final bytes = await _readSnapshotBytes(file, snapshotLimitBytes);
    return _CapturedState(
      existed: true,
      mtime: stat.modified,
      size: stat.size,
      sha256: sha256.convert(bytes).toString(),
      bytes: bytes,
    );
  }

  Future<List<int>> _readSnapshotBytes(File file, int limit) async {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    try {
      await for (final chunk in file.openRead()) {
        total += chunk.length;
        if (total > limit) throw StateError('快照文件超过单文件大小上限');
        builder.add(chunk);
      }
    } on FileSystemException {
      throw StateError('无法读取快照源文件');
    }
    return builder.takeBytes();
  }

  Future<String> _hashFile(File file) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    try {
      await for (final chunk in file.openRead()) {
        input.add(chunk);
      }
      input.close();
      final digest = sink.value;
      if (digest == null) throw StateError('文件哈希为空');
      return digest.toString();
    } on Object {
      throw StateError('无法读取文件哈希');
    }
  }

  Future<_CapturedState> _postCondition(
    WorkChangePlan plan,
    List<String> paths,
  ) async {
    if (plan.actionType == WorkChangeActionType.delete) {
      return const _CapturedState();
    }
    final path =
        plan.actionType == WorkChangeActionType.rename && paths.length > 1
            ? paths[1]
            : paths.first;
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.file) return const _CapturedState();
    final file = File(path);
    final stat = await file.stat();
    final digest = await _hashFile(file);
    return _CapturedState(
      existed: true,
      mtime: stat.modified,
      size: stat.size,
      sha256: digest,
    );
  }

  Future<void> _writeManifest(
    Directory directory,
    WorkSnapshotManifest manifest,
  ) async {
    await _ensureSnapshotsDirectory(create: true);
    final directoryType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (directoryType == FileSystemEntityType.link ||
        (directoryType != FileSystemEntityType.notFound &&
            directoryType != FileSystemEntityType.directory)) {
      throw StateError('任务快照目录不是普通目录');
    }
    if (directoryType == FileSystemEntityType.notFound) {
      await directory.create(recursive: false);
    }
    final temp = _temporarySibling(
      File('${directory.path}/$_manifestName'),
      'manifest',
    );
    try {
      await _writeFlushed(temp, utf8.encode(manifest.toJsonString()));
      final target = File('${directory.path}/$_manifestName');
      final isWindows = pathPolicy?.isWindows ?? Platform.isWindows;
      final targetType = await FileSystemEntity.type(
        target.path,
        followLinks: false,
      );
      if (targetType != FileSystemEntityType.notFound &&
          targetType != FileSystemEntityType.file) {
        throw StateError('任务快照 manifest 不是普通文件');
      }
      if (isWindows && targetType == FileSystemEntityType.file) {
        await _replaceManifestOnWindows(temp, target, directory);
        return;
      }
      await temp.rename(target.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> _replaceManifestOnWindows(
    File temp,
    File target,
    Directory directory,
  ) async {
    final replaced = _temporarySibling(
      File('${directory.path}/$_manifestName'),
      'manifest-previous',
    );
    var originalMoved = false;
    try {
      await _assertTemporaryPathAvailable(replaced);
      await target.rename(replaced.path);
      originalMoved = true;
      await temp.rename(target.path);
      try {
        await replaced.delete();
      } on Object {
        // The new manifest is authoritative; a later cleanup can remove the
        // old temporary copy if Windows still holds it briefly.
      }
    } catch (_) {
      if (originalMoved && !await target.exists() && await replaced.exists()) {
        try {
          await replaced.rename(target.path);
        } on Object {
          // Keep the durable backup and report the manifest failure.
        }
      }
      rethrow;
    }
  }

  Future<void> _writeFlushed(File file, List<int> bytes) async {
    // Every caller writes a newly-created temporary or backup file. Exclusive
    // creation prevents a pre-existing symlink from redirecting snapshot
    // bytes outside the app-managed snapshot directory.
    await file.create(exclusive: true);
    final handle = await file.open(mode: FileMode.write);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  File _temporarySibling(File target, String purpose) {
    final sequence = _temporaryFileSequence++;
    return File(
      '${target.path}.codex-$purpose-${clock().microsecondsSinceEpoch}-$sequence.tmp',
    );
  }

  Future<void> _assertTemporaryPathAvailable(File file) async {
    final type = await FileSystemEntity.type(
      file.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound) {
      throw StateError('快照临时文件路径已被占用');
    }
  }

  /// Validates the app-managed parent chain before snapshot reads/writes.
  /// Final-component no-follow checks are not enough when an intermediate
  /// `work_mode_agent` directory is replaced with a symlink.
  Future<bool> _ensureSnapshotsDirectory({required bool create}) async {
    if (!await _ensureManagedParents(create: create)) return false;
    final type = await FileSystemEntity.type(
      snapshotsDirectory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      if (!create) return false;
      throw StateError('工作模式快照目录不是受信任目录');
    }
    if (type == FileSystemEntityType.notFound) {
      if (!create) return false;
      await snapshotsDirectory.create(recursive: false);
    } else if (type != FileSystemEntityType.directory) {
      throw StateError('工作模式快照目录不是普通目录');
    }
    return true;
  }

  Future<bool> _ensureManagedParents({required bool create}) async {
    final appSupportType = await FileSystemEntity.type(
      appSupportDirectory.path,
      followLinks: false,
    );
    if (appSupportType == FileSystemEntityType.link) {
      throw StateError('工作模式快照的应用数据根不是受信任目录');
    }
    if (appSupportType == FileSystemEntityType.notFound) {
      if (!create) return false;
      await appSupportDirectory.create(recursive: true);
    } else if (appSupportType != FileSystemEntityType.directory) {
      throw StateError('工作模式快照的应用数据根不是普通目录');
    }

    final container = Directory('${appSupportDirectory.path}/work_mode_agent');
    final containerType = await FileSystemEntity.type(
      container.path,
      followLinks: false,
    );
    if (containerType == FileSystemEntityType.link) {
      throw StateError('工作模式快照目录不是受信任目录');
    }
    if (containerType == FileSystemEntityType.notFound) {
      if (!create) return false;
      await container.create(recursive: false);
    } else if (containerType != FileSystemEntityType.directory) {
      throw StateError('工作模式快照目录不是普通目录');
    }
    return true;
  }

  Future<T> _serializeStorage<T>(Future<T> Function() operation) {
    final previous = _storageQueue;
    late final Future<T> scheduled;
    scheduled = previous.catchError((Object _) {}).then((_) => operation());
    _storageQueue = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return scheduled;
  }

  List<WorkSnapshotUndoItem> _previewItems(WorkSnapshotManifest manifest) {
    return manifest.actions
        .where((action) => action.completed && !action.undone)
        .toList(growable: false)
        .reversed
        .map(
          (action) => WorkSnapshotUndoItem(
            sequence: action.sequence,
            operation:
                action.actionType == WorkChangeActionType.create ? '删除' : '恢复',
            path: action.originalPath,
            targetPath: action.targetPath,
          ),
        )
        .toList(growable: false);
  }

  bool _isTerminal(WorkSnapshotManifest manifest) {
    return manifest.taskStatus != WorkSnapshotTaskStatus.active;
  }

  Future<void> _deleteRecord(_SnapshotTaskRecord record) async {
    await _deleteTreeNoFollow(record.directory);
  }

  Future<int> _deleteTreeNoFollow(FileSystemEntity entity) async {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return 0;
    if (type != FileSystemEntityType.directory) {
      await entity.delete();
      return 1;
    }
    var removed = 0;
    await for (final child in Directory(entity.path).list(followLinks: false)) {
      removed += await _deleteTreeNoFollow(child);
    }
    await entity.delete();
    return removed + 1;
  }

  Future<void> _recordUndoEvents({
    required String taskId,
    required List<String> restored,
    required List<String> deleted,
    required List<WorkSnapshotConflict> conflicts,
  }) async {
    final store = eventStore;
    if (store == null) return;
    await _appendUndoEvent(
      store,
      taskId: taskId,
      kind: WorkTaskEventKind.undoCompleted,
      title: conflicts.isEmpty ? '任务改动已撤销' : '任务改动撤销存在冲突',
      detail:
          '恢复 ${restored.length} 项，删除 ${deleted.length} 项，冲突 ${conflicts.length} 项。',
      safeMetadata: {
        'restoredCount': restored.length,
        'deletedCount': deleted.length,
        'conflictCount': conflicts.length,
      },
    );
    for (final path in restored) {
      await _appendUndoEvent(
        store,
        taskId: taskId,
        kind: WorkTaskEventKind.stepCompleted,
        title: '已恢复文件',
        detail: _auditSnapshotPath(path),
        safeMetadata: {'action': 'restore', 'path': _auditSnapshotPath(path)},
      );
    }
    for (final path in deleted) {
      await _appendUndoEvent(
        store,
        taskId: taskId,
        kind: WorkTaskEventKind.stepCompleted,
        title: '已删除新文件',
        detail: _auditSnapshotPath(path),
        safeMetadata: {'action': 'delete', 'path': _auditSnapshotPath(path)},
      );
    }
    for (final conflict in conflicts) {
      await _appendUndoEvent(
        store,
        taskId: taskId,
        kind: WorkTaskEventKind.failed,
        title: '撤销冲突',
        detail: conflict.reason,
        safeMetadata: {
          'sequence': conflict.sequence,
          'path': _auditSnapshotPath(conflict.path),
        },
      );
    }
  }

  Future<void> _appendUndoEvent(
    WorkTaskEventStore store, {
    required String taskId,
    required WorkTaskEventKind kind,
    required String title,
    String detail = '',
    Map<String, Object?>? safeMetadata,
  }) async {
    try {
      await store.append(
        taskId: taskId,
        kind: kind,
        title: title,
        detail: detail,
        safeMetadata: safeMetadata,
      );
    } on Object {
      // Undo outcome remains authoritative when diagnostic persistence fails.
    }
  }

  String _auditSnapshotPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final isWindows = RegExp(r'^[A-Za-z]:/').hasMatch(normalized) ||
        normalized.startsWith('//');
    return WorkFolderGrantService.displayNameFor(
      normalized,
      isWindows: isWindows,
    );
  }

  static Future<int> _directorySize(Directory directory) async {
    final directoryType = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (directoryType == FileSystemEntityType.notFound) return 0;
    if (directoryType != FileSystemEntityType.directory) {
      throw StateError('快照目录不是受信任目录');
    }
    var total = 0;
    await for (final entity
        in directory.list(followLinks: false, recursive: true)) {
      final entityType = await FileSystemEntity.type(
        entity.path,
        followLinks: false,
      );
      if (entityType == FileSystemEntityType.link) {
        throw StateError('快照目录包含符号链接');
      }
      if (entityType == FileSystemEntityType.file) {
        try {
          total += await File(entity.path).length();
        } on Object {
          // Under-counting an unreadable file could let a new snapshot exceed
          // the configured quota. Fail closed so callers can retry or surface
          // an actionable error instead of silently weakening retention.
          throw StateError('无法统计快照文件占用');
        }
      }
    }
    return total;
  }

  void _validateTaskId(String taskId) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(taskId)) {
      throw ArgumentError.value(taskId, 'taskId', '任务标识不合法');
    }
  }

  int _compareSnapshotRecords(
    _SnapshotTaskRecord left,
    _SnapshotTaskRecord right,
  ) {
    final byCreatedAt =
        left.manifest.createdAt.compareTo(right.manifest.createdAt);
    return byCreatedAt == 0 ? left.taskId.compareTo(right.taskId) : byCreatedAt;
  }
}

class _CapturedState {
  final bool existed;
  final DateTime? mtime;
  final int? size;
  final String? sha256;
  final List<int>? bytes;

  const _CapturedState({
    this.existed = false,
    this.mtime,
    this.size,
    this.sha256,
    this.bytes,
  });
}

enum _UndoOutcome { restored, deleted }

class _SnapshotConflict implements Exception {
  final String path;
  final String reason;

  const _SnapshotConflict(this.path, this.reason);
}
