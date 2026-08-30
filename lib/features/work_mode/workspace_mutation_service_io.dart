part of 'workspace_mutation_service.dart';

extension _WorkspaceMutationIo on WorkspaceMutationService {
  Future<WorkspaceMutationResult> _create(
    WorkspaceMutationRequest request,
    WorkspaceResolvedPath target,
    WorkspaceSnapshotReservation? reservation, {
    required bool allowWithoutUndo,
    required Future<void> Function() verifyPath,
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) {
    _requireReservation(reservation, allowWithoutUndo);
    return _writeAtomically(
      target: target.path,
      bytes: request.encodedContents,
      targetExists: false,
      expectedSha256: null,
      verifyPath: verifyPath,
      cancellation: cancellation,
      isCancelled: isCancelled,
    );
  }

  Future<WorkspaceMutationResult> _modify(
    WorkspaceMutationRequest request,
    WorkspaceResolvedPath target,
    WorkspaceSnapshotReservation? reservation, {
    required bool allowWithoutUndo,
    required Future<void> Function() verifyPath,
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) async {
    _requireReservation(reservation, allowWithoutUndo);
    final bytes = request.encodedContents;
    final original = await _readFileBytes(target.path);
    // A caller may omit the precondition for backward compatibility, but the
    // service still snapshots the bytes observed at the mutation boundary and
    // rechecks that hash immediately before replacement. This closes the
    // modify TOCTOU window without making old callers silently unsafe.
    final expectedSha256 =
        request.expectedSha256 ?? sha256.convert(original).toString();
    _checkExpectedHashBytes(original, expectedSha256);
    return _writeAtomically(
      target: target.path,
      bytes: bytes,
      targetExists: true,
      expectedSha256: expectedSha256,
      verifyPath: verifyPath,
      cancellation: cancellation,
      isCancelled: isCancelled,
    );
  }

  Future<WorkspaceMutationResult> _patch(
    WorkspaceMutationRequest request,
    WorkspaceResolvedPath target,
    WorkspaceSnapshotReservation? reservation, {
    required bool allowWithoutUndo,
    required Future<void> Function() verifyPath,
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) async {
    _requireReservation(reservation, allowWithoutUndo);
    final originalBytes = await _readFileBytes(target.path);
    _checkExpectedHashBytes(originalBytes, request.expectedSha256);
    final originalText = _decodeUtf8(originalBytes);
    final fragment = request.expectedFragment!;
    final replacement = request.replacement!;
    final first = originalText.indexOf(fragment);
    final second = first < 0 ? -1 : originalText.indexOf(fragment, first + 1);
    if (first < 0 || second >= 0) {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.conflict,
          reason: '补丁片段不再唯一匹配，请 Agent 重新读取文件。',
        ),
      );
    }
    final patched = '${originalText.substring(0, first)}$replacement'
        '${originalText.substring(first + fragment.length)}';
    _checkCancellation(cancellation, isCancelled);
    return _writeAtomically(
      target: target.path,
      bytes: utf8.encode(patched),
      targetExists: true,
      expectedSha256: request.expectedSha256,
      verifyPath: verifyPath,
      cancellation: cancellation,
      isCancelled: isCancelled,
    );
  }

  Future<WorkspaceMutationResult> _rename(
    WorkspaceResolvedPath source,
    WorkspaceResolvedPath destination, {
    required WorkspaceSnapshotReservation? reservation,
    required bool allowWithoutUndo,
    required Future<void> Function() verifyPath,
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) async {
    _requireReservation(reservation, allowWithoutUndo);
    _checkCancellation(cancellation, isCancelled);
    try {
      _inject(WorkspaceMutationPhase.beforeReplace);
      _checkCancellation(cancellation, isCancelled);
      await verifyPath();
      await File(source.path).rename(destination.path);
      _runPostReplaceHook();
      return WorkspaceMutationResult(
        status: WorkspaceMutationStatus.success,
        reason: '文件已安全重命名。',
        path: source.path,
        destinationPath: destination.path,
      );
    } on FileSystemException {
      return const WorkspaceMutationResult(
        status: WorkspaceMutationStatus.failed,
        reason: '重命名失败，源文件未被主动删除。',
      );
    }
  }

  Future<WorkspaceMutationResult> _delete(
    WorkspaceResolvedPath target, {
    required WorkspaceSnapshotReservation? reservation,
    required bool allowWithoutUndo,
    required Future<void> Function() verifyPath,
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) async {
    _requireReservation(reservation, allowWithoutUndo);
    _checkCancellation(cancellation, isCancelled);
    try {
      _inject(WorkspaceMutationPhase.beforeReplace);
      _checkCancellation(cancellation, isCancelled);
      await verifyPath();
      if (target.isDirectory) {
        await Directory(target.path).delete();
      } else {
        await File(target.path).delete();
      }
      _runPostReplaceHook();
      return WorkspaceMutationResult(
        status: WorkspaceMutationStatus.success,
        reason: '精确路径已删除。',
        path: target.path,
      );
    } on FileSystemException {
      return const WorkspaceMutationResult(
        status: WorkspaceMutationStatus.failed,
        reason: '删除失败，未递归触及其他路径。',
      );
    }
  }

  Future<WorkspaceMutationResult> _writeAtomically({
    required String target,
    required List<int> bytes,
    required bool targetExists,
    required String? expectedSha256,
    required Future<void> Function() verifyPath,
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) async {
    _checkCancellation(cancellation, isCancelled);
    _inject(WorkspaceMutationPhase.beforeTempWrite);
    final temp = await _createTemporaryFile(target);
    try {
      final handle = await temp.open(mode: FileMode.write);
      try {
        await handle.writeFrom(bytes);
        await handle.flush();
        _inject(WorkspaceMutationPhase.afterTempFlush);
      } finally {
        await handle.close();
      }
      _checkCancellation(cancellation, isCancelled);
      _inject(WorkspaceMutationPhase.beforeReplace);
      _checkCancellation(cancellation, isCancelled);
      await verifyPath();
      await _checkExpectedHash(target, expectedSha256);
      await _replaceTemporary(
        temp: temp,
        target: target,
        targetExists: targetExists,
      );
      _runPostReplaceHook();
      return WorkspaceMutationResult(
        status: WorkspaceMutationStatus.success,
        reason: '文件已通过同目录临时文件原子替换。',
        path: target,
        bytesWritten: bytes.length,
      );
    } finally {
      try {
        if (await temp.exists()) {
          await temp.delete();
        }
      } on Object {
        // The original target remains authoritative if cleanup itself fails.
      }
    }
  }

  Future<File> _createTemporaryFile(String target) async {
    final parent = _parentDirectory(target);
    final basename = _basename(target);
    await Directory(parent).create(recursive: true);
    for (var attempt = 0; attempt < 20; attempt++) {
      final id = '${DateTime.now().microsecondsSinceEpoch}-'
          '${WorkspaceMutationService._temporaryFileCounter++}';
      final candidate = File('$parent/.$basename.codex-mutation-$id.tmp');
      try {
        // `exists()` followed by `create()` is itself a race: another
        // process can claim the generated name between those calls and
        // `create()` would truncate its file.  Exclusive creation makes the
        // temporary-file name reservation one filesystem operation.
        await candidate.create(exclusive: true);
        return candidate;
      } on FileSystemException {
        // A collision is harmless; retry with a fresh monotonic name. Other
        // filesystem failures are retried as well so the bounded loop can
        // provide one stable failure instead of leaking a partial temp file.
        continue;
      }
    }
    throw const FileSystemException('无法创建安全临时文件');
  }

  Future<void> _replaceTemporary({
    required File temp,
    required String target,
    required bool targetExists,
  }) async {
    if (!targetExists) {
      if (pathPolicy.isWindows) {
        // Windows does not expose a portable no-replace rename through
        // dart:io. Its rename fails when the destination is occupied; map
        // that race to a conflict rather than allowing a replacement.
        try {
          await temp.rename(target);
        } on FileSystemException {
          if (await File(target).exists()) {
            throw const _MutationAbort(
              WorkspaceMutationResult(
                status: WorkspaceMutationStatus.conflict,
                reason: '创建目标在替换时已出现，未覆盖现有文件。',
              ),
            );
          }
          rethrow;
        }
        return;
      }

      // dart:io has no portable no-replace rename primitive. Production
      // callers hold the task's path/tree lock across resolve, validation and
      // replacement; this final check also protects direct service callers
      // from the common create race without ever intentionally overwriting an
      // entry that appeared after the initial resolution.
      if (await File(target).exists()) {
        throw const _MutationAbort(
          WorkspaceMutationResult(
            status: WorkspaceMutationStatus.conflict,
            reason: '创建目标在替换时已出现，未覆盖现有文件。',
          ),
        );
      }
      await temp.rename(target);
      return;
    }
    if (!pathPolicy.isWindows) {
      await temp.rename(target);
      return;
    }

    // Windows cannot rely on rename-over-existing semantics. A same-directory
    // rollback name makes the replacement controlled and keeps the original
    // available if the second rename fails. The snapshot reservation is
    // already mandatory before this path is reached.
    final backup = File(
      '${_parentDirectory(target)}/.${_basename(target)}.codex-replace-backup-'
      '${DateTime.now().microsecondsSinceEpoch}-'
      '${WorkspaceMutationService._temporaryFileCounter++}.tmp',
    );
    var originalMoved = false;
    try {
      final backupType = await FileSystemEntity.type(
        backup.path,
        followLinks: false,
      );
      if (backupType != FileSystemEntityType.notFound) {
        throw const _MutationAbort(
          WorkspaceMutationResult(
            status: WorkspaceMutationStatus.conflict,
            reason: '替换临时路径已被占用，未覆盖原文件。',
          ),
        );
      }
      await File(target).rename(backup.path);
      originalMoved = true;
      await temp.rename(target);
      try {
        await backup.delete();
      } on Object {
        // The new target is valid; a later cleanup pass may remove the backup.
      }
    } catch (_) {
      if (originalMoved &&
          !await File(target).exists() &&
          await backup.exists()) {
        try {
          await backup.rename(target);
        } on Object {
          // The snapshot port remains the recovery boundary for this failure.
        }
      }
      rethrow;
    }
  }

  Future<List<int>> _readFileBytes(String path) async {
    try {
      return await File(path).readAsBytes();
    } on FileSystemException {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.conflict,
          reason: '读取当前文件失败，请 Agent 重新读取后再尝试。',
        ),
      );
    }
  }

  Future<void> _checkExpectedHash(String path, String? expectedSha256) async {
    if (expectedSha256 == null) return;
    try {
      _checkExpectedHashBytes(await File(path).readAsBytes(), expectedSha256);
    } on FileSystemException {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.conflict,
          reason: '原文件在替换前消失，请 Agent 重新读取后再尝试。',
        ),
      );
    }
  }

  void _checkExpectedHashBytes(List<int> bytes, String? expectedSha256) {
    final expected = expectedSha256?.trim().toLowerCase();
    if (expected == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(expected)) {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.invalidRequest,
          reason: '原文件 SHA-256 格式无效，未执行补丁。',
        ),
      );
    }
    final actual = sha256.convert(bytes).toString();
    if (actual != expected) {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.conflict,
          reason: '原文件 SHA-256 已变化，请 Agent 重新读取后再生成变更。',
        ),
      );
    }
  }

  String _decodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.invalidRequest,
          reason: '补丁目标不是有效 UTF-8 文本，未执行模糊转换。',
        ),
      );
    }
  }

  static String _parentDirectory(String path) {
    final slash = path.lastIndexOf('/');
    if (slash <= 0) return slash == 0 ? '/' : '.';
    return path.substring(0, slash);
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }
}
