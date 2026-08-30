part of 'workspace_mutation_service.dart';

extension _WorkspaceMutationResolution on WorkspaceMutationService {
  Future<_ResolvedMutation> _resolveInitial(
    WorkChangePlan plan,
    WorkspaceMutationRequest request,
  ) async {
    switch (plan.actionType) {
      case WorkChangeActionType.create:
        final target = await pathPolicy.resolveNewTarget(request.path);
        if (target.exists) {
          throw _MutationAbort(
            WorkspaceMutationResult(
              status: WorkspaceMutationStatus.conflict,
              reason: '创建目标已存在，未覆盖现有文件。',
              path: target.path,
            ),
          );
        }
        return _ResolvedMutation(target: target);
      case WorkChangeActionType.modify:
      case WorkChangeActionType.patch:
        final target = await pathPolicy.resolveExisting(request.path);
        _requireFile(target);
        return _ResolvedMutation(target: target);
      case WorkChangeActionType.rename:
        final source = await pathPolicy.resolveExisting(request.path);
        _requireFile(source);
        final destination = await pathPolicy.resolveNewTarget(
          request.destinationPath!,
        );
        if (destination.exists) {
          throw _MutationAbort(
            WorkspaceMutationResult(
              status: WorkspaceMutationStatus.conflict,
              reason: '重命名目标已存在，已重新分类为冲突。',
              path: source.path,
              destinationPath: destination.path,
            ),
          );
        }
        return _ResolvedMutation(target: source, destination: destination);
      case WorkChangeActionType.delete:
        final target = await pathPolicy.resolveExisting(request.path);
        if (!target.isFile) {
          throw const _MutationAbort(
            WorkspaceMutationResult(
              status: WorkspaceMutationStatus.pathRejected,
              reason: 'Stage 02 只支持可撤销的普通文件删除，目录删除暂未开放。',
            ),
          );
        }
        return _ResolvedMutation(target: target);
      case WorkChangeActionType.command:
        throw const _MutationAbort(
          WorkspaceMutationResult(
            status: WorkspaceMutationStatus.invalidRequest,
            reason: '文件变更入口不执行命令动作。',
          ),
        );
    }
  }

  Future<_ResolvedMutation> _revalidate(
    WorkChangePlan plan,
    WorkspaceMutationRequest request,
    _ResolvedMutation initial, {
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) async {
    try {
      switch (plan.actionType) {
        case WorkChangeActionType.create:
          final target = await pathPolicy.resolveNewTarget(request.path);
          if (target.exists) {
            throw const _MutationAbort(
              WorkspaceMutationResult(
                status: WorkspaceMutationStatus.conflict,
                reason: '最终校验发现创建目标已出现，未覆盖现有文件。',
              ),
            );
          }
          _requireSamePath(initial.target, target);
          return _ResolvedMutation(target: target);
        case WorkChangeActionType.modify:
        case WorkChangeActionType.patch:
          final target = await pathPolicy.resolveExisting(request.path);
          _requireFile(target);
          _requireSamePath(initial.target, target);
          return _ResolvedMutation(target: target);
        case WorkChangeActionType.rename:
          final source = await pathPolicy.resolveExisting(request.path);
          _requireFile(source);
          final destination = await pathPolicy.resolveNewTarget(
            request.destinationPath!,
          );
          _requireSamePath(initial.target, source);
          if (destination.exists) {
            throw const _MutationAbort(
              WorkspaceMutationResult(
                status: WorkspaceMutationStatus.conflict,
                reason: '最终校验发现重命名目标已存在，未覆盖目标。',
              ),
            );
          }
          _requireSamePath(initial.destination!, destination);
          return _ResolvedMutation(target: source, destination: destination);
        case WorkChangeActionType.delete:
          final target = await pathPolicy.resolveExisting(request.path);
          if (!target.isFile) {
            throw const _MutationAbort(
              WorkspaceMutationResult(
                status: WorkspaceMutationStatus.pathRejected,
                reason: '最终校验发现删除目标不是可撤销的普通文件。',
              ),
            );
          }
          _requireSamePath(initial.target, target);
          return _ResolvedMutation(target: target);
        case WorkChangeActionType.command:
          throw const _MutationAbort(
            WorkspaceMutationResult(
              status: WorkspaceMutationStatus.invalidRequest,
              reason: '文件变更入口不执行命令动作。',
            ),
          );
      }
    } on _MutationAbort {
      rethrow;
    } on WorkspacePathException {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.pathRejected,
          reason: '批准后路径状态发生变化，已拒绝文件变更。',
        ),
      );
    }
  }

  Future<WorkspaceSnapshotReservation?> _reserveSnapshotIfNeeded(
    WorkChangePlan plan,
    _ResolvedMutation paths, {
    required bool allowWithoutUndo,
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) async {
    _checkCancellation(cancellation, isCancelled);
    _inject(WorkspaceMutationPhase.beforeSnapshot);
    if (!plan.snapshotAvailable || !plan.reversible || snapshotPort == null) {
      if (allowWithoutUndo) return null;
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.snapshotUnavailable,
          reason: '变更没有可用的快照预留，已阻止覆盖、重命名或删除。',
        ),
      );
    }
    final pathsToReserve = <String>[
      paths.target.path,
      if (paths.destination != null) paths.destination!.path,
    ];
    try {
      final reservation = await snapshotPort!.reserve(
        plan: plan,
        paths: List<String>.unmodifiable(pathsToReserve),
      );
      if (!reservation.available) {
        if (allowWithoutUndo) return null;
        throw const _MutationAbort(
          WorkspaceMutationResult(
            status: WorkspaceMutationStatus.snapshotUnavailable,
            reason: '快照预留失败，已阻止文件变更。',
          ),
        );
      }
      return reservation;
    } on _MutationAbort {
      rethrow;
    } on Object {
      if (allowWithoutUndo) return null;
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.snapshotUnavailable,
          reason: '快照预留发生安全错误，已阻止文件变更。',
        ),
      );
    }
  }

  void _validateRequest(
    WorkChangePlan plan,
    WorkspaceMutationRequest request,
  ) {
    if (request.hasPayload &&
        request.encodedContents.length > maxMutationBytes) {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.invalidRequest,
          reason: '文件变更超过单次写入大小上限，未执行写入。',
        ),
      );
    }
    if (request.replacement != null &&
        utf8.encode(request.replacement!).length > maxMutationBytes) {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.invalidRequest,
          reason: '补丁替换内容超过单次写入大小上限，未执行写入。',
        ),
      );
    }
    final path = _normalizeRequestPath(request.path);
    if (!plan.exactPaths
        .any((item) => workPathKey(item) == workPathKey(path))) {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.notApproved,
          reason: '请求路径不在变更计划的精确路径集合内。',
        ),
      );
    }
    switch (plan.actionType) {
      case WorkChangeActionType.create:
      case WorkChangeActionType.modify:
        if (!request.hasPayload ||
            (request.contents != null && request.bytes != null) ||
            (plan.actionType == WorkChangeActionType.create &&
                request.expectedSha256 != null) ||
            (plan.actionType == WorkChangeActionType.modify &&
                request.expectedSha256 != null &&
                !_isValidSha256(request.expectedSha256)) ||
            request.expectedFragment != null ||
            request.replacement != null ||
            request.destinationPath != null) {
          throw const _MutationAbort(
            WorkspaceMutationResult(
              status: WorkspaceMutationStatus.invalidRequest,
              reason: '创建或覆盖请求必须提供唯一文件内容。',
            ),
          );
        }
        break;
      case WorkChangeActionType.patch:
        if (request.expectedSha256 == null ||
            !_isValidSha256(request.expectedSha256) ||
            request.expectedFragment == null ||
            request.expectedFragment!.isEmpty ||
            request.replacement == null ||
            request.hasPayload ||
            request.destinationPath != null) {
          throw const _MutationAbort(
            WorkspaceMutationResult(
              status: WorkspaceMutationStatus.invalidRequest,
              reason: '补丁请求必须包含原 SHA-256、明确片段和替换文本。',
            ),
          );
        }
        break;
      case WorkChangeActionType.rename:
        final destination = request.destinationPath;
        if (destination == null ||
            request.hasPayload ||
            request.expectedSha256 != null ||
            request.expectedFragment != null ||
            request.replacement != null) {
          throw const _MutationAbort(
            WorkspaceMutationResult(
              status: WorkspaceMutationStatus.invalidRequest,
              reason: '重命名请求必须只包含已批准的源路径和目标路径。',
            ),
          );
        }
        final normalizedDestination = _normalizeRequestPath(destination);
        if (!plan.exactPaths.any(
          (item) => workPathKey(item) == workPathKey(normalizedDestination),
        )) {
          throw const _MutationAbort(
            WorkspaceMutationResult(
              status: WorkspaceMutationStatus.notApproved,
              reason: '重命名目标不在变更计划的精确路径集合内。',
            ),
          );
        }
        break;
      case WorkChangeActionType.delete:
        if (request.hasPayload ||
            request.expectedSha256 != null ||
            request.expectedFragment != null ||
            request.replacement != null ||
            request.destinationPath != null) {
          throw const _MutationAbort(
            WorkspaceMutationResult(
              status: WorkspaceMutationStatus.invalidRequest,
              reason: '删除请求不能携带写入内容或第二路径。',
            ),
          );
        }
        break;
      case WorkChangeActionType.command:
        throw const _MutationAbort(
          WorkspaceMutationResult(
            status: WorkspaceMutationStatus.invalidRequest,
            reason: '文件变更入口不执行命令动作。',
          ),
        );
    }
  }

  String _normalizeRequestPath(String raw) {
    try {
      return normalizeWorkAbsolutePath(raw);
    } on ArgumentError {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.invalidRequest,
          reason: '请求必须使用精确绝对路径。',
        ),
      );
    }
  }

  bool _isValidSha256(String? value) =>
      value != null && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value.trim());

  void _requireFile(WorkspaceResolvedPath path) {
    if (!path.isFile) {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.pathRejected,
          reason: '原子文件入口只处理普通文件目标。',
        ),
      );
    }
  }

  void _requireReservation(
    WorkspaceSnapshotReservation? reservation,
    bool allowWithoutUndo,
  ) {
    if (reservation?.available != true && !allowWithoutUndo) {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.snapshotUnavailable,
          reason: '缺少有效快照预留，已阻止覆盖性变更。',
        ),
      );
    }
  }

  void _requireSamePath(
    WorkspaceResolvedPath expected,
    WorkspaceResolvedPath actual,
  ) {
    if (workPathKey(expected.path) != workPathKey(actual.path) ||
        expected.exists != actual.exists ||
        expected.type != actual.type ||
        expected.wasSymbolicLink != actual.wasSymbolicLink) {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.pathRejected,
          reason: '批准后路径状态发生变化，已拒绝文件变更。',
        ),
      );
    }
  }

  void _checkCancellation(
    WorkTaskCancellation? cancellation,
    bool Function()? isCancelled,
  ) {
    if (cancellation?.isCancelled == true || isCancelled?.call() == true) {
      throw const _MutationAbort(
        WorkspaceMutationResult(
          status: WorkspaceMutationStatus.cancelled,
          reason: '用户已取消文件变更，临时文件已清理。',
        ),
      );
    }
  }

  void _inject(WorkspaceMutationPhase phase) {
    failureInjector?.call(phase);
  }

  void _runPostReplaceHook() {
    try {
      _inject(WorkspaceMutationPhase.afterReplace);
    } on Object {
      // The rename/replace already committed atomically. Do not report a
      // successful mutation as failed merely because diagnostics failed.
    }
  }

  Future<WorkspaceMutationResult> _record(
    WorkChangePlan plan,
    WorkspaceMutationResult result,
  ) async {
    final store = eventStore;
    if (store != null) {
      final primaryPath = result.path ??
          (plan.exactPaths.isEmpty ? null : plan.exactPaths.first);
      final destinationPath = result.destinationPath ??
          (plan.exactPaths.length > 1 ? plan.exactPaths[1] : null);
      try {
        await store.append(
          taskId: plan.taskId,
          kind: result.succeeded
              ? WorkTaskEventKind.stepCompleted
              : WorkTaskEventKind.failed,
          title: result.succeeded ? '文件变更已完成' : '文件变更未执行',
          detail: result.reason,
          safeMetadata: {
            'action': plan.actionType.wireName,
            'status': result.status.name,
            // Include the planned path even for rejected/conflicted actions;
            // otherwise a failed mutation event cannot be correlated with the
            // exact target the user approved. Prefer the resolved final path
            // returned by the I/O layer when one exists.
            if (primaryPath != null) 'path': _auditPath(primaryPath, plan),
            if (destinationPath != null)
              'destinationPath': _auditPath(destinationPath, plan),
          },
        );
      } on Object {
        // Progress persistence must never turn a completed mutation into a
        // second write attempt or expose storage internals to the caller.
      }
    }
    return result;
  }

  String _auditPath(String path, WorkChangePlan plan) {
    try {
      final normalized = path.replaceAll('\\', '/');
      for (final root in plan.knownAffectedDirectories) {
        final rootPath = root.replaceAll('\\', '/');
        if (workPathKey(normalized) == workPathKey(rootPath)) return '.';
        if (isWorkPathWithin(normalized, rootPath)) {
          final prefix = rootPath.endsWith('/') ? rootPath : '$rootPath/';
          if (normalized.length >= prefix.length) {
            return normalized.substring(prefix.length);
          }
        }
      }
      // Never persist a user's home or workspace root into the public event
      // stream when a plan came from a legacy caller without an affected root.
      return WorkFolderGrantService.displayNameFor(
        normalized,
        isWindows: RegExp(r'^[A-Za-z]:/').hasMatch(normalized) ||
            normalized.startsWith('//'),
      );
    } on Object {
      // A malformed plan must still produce a safe failure event instead of
      // replacing the original mutation error with an audit-format exception.
      return '[路径已隐藏]';
    }
  }
}
