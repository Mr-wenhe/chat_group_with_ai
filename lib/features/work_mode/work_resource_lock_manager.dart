import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'work_folder_grant_service.dart';

/// The smallest lock scope understood by the work-mode scheduler.
enum WorkResourceLockMode {
  read,
  write,
  treeWrite,
}

/// One planned resource access. Paths are normalized when a plan is acquired,
/// not when the request object is constructed, so callers can reuse a plan
/// with a platform-specific manager.
class WorkResourceLockRequest {
  final String path;
  final WorkResourceLockMode mode;

  const WorkResourceLockRequest({required this.path, required this.mode});

  const WorkResourceLockRequest.read(String path)
      : this(path: path, mode: WorkResourceLockMode.read);

  const WorkResourceLockRequest.write(String path)
      : this(path: path, mode: WorkResourceLockMode.write);

  const WorkResourceLockRequest.treeWrite(String path)
      : this(path: path, mode: WorkResourceLockMode.treeWrite);
}

/// Alias for integrations that call a planned access a resource lock.
typedef WorkResourceLock = WorkResourceLockRequest;

class WorkResourceLockCancelled implements Exception {
  final String ownerId;

  const WorkResourceLockCancelled(this.ownerId);

  @override
  String toString() => '工作资源锁等待已取消：$ownerId';
}

/// A granted, all-or-nothing set of resource locks.
class WorkResourceLockLease {
  final String ownerId;
  final List<WorkResourceLockRequest> requests;
  final Future<void> Function() _releaseCallback;
  bool _released = false;

  WorkResourceLockLease._({
    required this.ownerId,
    required List<WorkResourceLockRequest> requests,
    required Future<void> Function() release,
  })  : requests = List<WorkResourceLockRequest>.unmodifiable(requests),
        _releaseCallback = release;

  bool get isReleased => _released;

  Future<void> release() {
    if (_released) return Future<void>.value();
    _released = true;
    return _releaseCallback();
  }
}

class _HeldResourceLock {
  final int leaseId;
  final String ownerId;
  final WorkResourceLockRequest request;

  const _HeldResourceLock({
    required this.leaseId,
    required this.ownerId,
    required this.request,
  });
}

class _ResourceLockWaiter {
  final String ownerId;
  final List<WorkResourceLockRequest> requests;
  final Completer<WorkResourceLockLease> completer =
      Completer<WorkResourceLockLease>();
  bool cancelled = false;
  bool granted = false;

  _ResourceLockWaiter({required this.ownerId, required this.requests});
}

/// App-scoped in-memory resource lock coordinator.
///
/// Locks are intentionally not persisted: a new manager represents a new app
/// process, so it cannot inherit a lock whose owner may no longer exist.
class WorkResourceLockManager {
  final bool isWindows;
  final List<_HeldResourceLock> _held = <_HeldResourceLock>[];
  final Queue<_ResourceLockWaiter> _waiters = Queue<_ResourceLockWaiter>();
  int _nextLeaseId = 0;

  WorkResourceLockManager({bool? isWindows})
      : isWindows = isWindows ?? Platform.isWindows;

  int get activeLockCount => _held.length;

  int get activeLeaseCount => _held.map((lock) => lock.leaseId).toSet().length;

  List<String> get waitingOwnerIds => List<String>.unmodifiable(
        _waiters.map((waiter) => waiter.ownerId),
      );

  /// Normalizes, deduplicates and stably sorts a complete plan.
  ///
  /// If one owner requests multiple modes for one path, the strongest mode is
  /// retained. This keeps a plan atomic without making an owner deadlock on
  /// its own read followed by write request.
  List<WorkResourceLockRequest> normalizeLockSet(
    Iterable<WorkResourceLockRequest> requests,
  ) {
    final byPath = <String, WorkResourceLockRequest>{};
    for (final request in requests) {
      final path = _normalizePath(request.path);
      final normalized = WorkResourceLockRequest(
        path: path,
        mode: request.mode,
      );
      final pathKey = _comparisonKey(path);
      final previous = byPath[pathKey];
      if (previous == null ||
          _modeRank(normalized.mode) > _modeRank(previous.mode)) {
        byPath[pathKey] = normalized;
      }
    }
    final result = byPath.values.toList(growable: false)
      ..sort(_compareRequests);
    return List<WorkResourceLockRequest>.unmodifiable(result);
  }

  /// Returns the normalized key used by the compatibility table.
  String keyFor(WorkResourceLockRequest request) {
    final normalized = normalizeLockSet([request]);
    if (normalized.isEmpty) throw ArgumentError('资源锁路径不能为空');
    final item = normalized.single;
    return '${_comparisonKey(item.path)}|${item.mode.name}';
  }

  /// Returns a safe normalized path currently blocking [requests], if any.
  String? conflictPath(Iterable<WorkResourceLockRequest> requests) {
    final normalized = normalizeLockSet(requests);
    for (final requested in normalized) {
      for (final held in _held) {
        if (_conflicts(held.request, requested)) return held.request.path;
      }
    }
    return null;
  }

  /// Synchronously grants an uncontended plan. A null result means the plan
  /// must join the FIFO queue through [acquire].
  WorkResourceLockLease? tryAcquire(
    String ownerId,
    Iterable<WorkResourceLockRequest> requests,
  ) {
    final normalizedOwner = ownerId.trim();
    if (normalizedOwner.isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', '资源锁 owner 不能为空');
    }
    final normalized = normalizeLockSet(requests);
    final canReenter = _hasOverlappingHeldPath(normalizedOwner, normalized);
    if ((!canReenter && _waiters.isNotEmpty) ||
        !_canGrant(normalizedOwner, normalized)) {
      return null;
    }
    return _newLease(normalizedOwner, normalized);
  }

  /// Queues one complete lock plan and grants it atomically when it reaches
  /// the FIFO head and every requested resource is compatible.
  Future<WorkResourceLockLease> acquire(
    String ownerId,
    Iterable<WorkResourceLockRequest> requests, {
    Future<void>? cancellation,
    bool Function()? isCancelled,
  }) {
    final normalizedOwner = ownerId.trim();
    if (normalizedOwner.isEmpty) {
      return Future<WorkResourceLockLease>.error(
        ArgumentError.value(ownerId, 'ownerId', '资源锁 owner 不能为空'),
      );
    }
    final normalized = normalizeLockSet(requests);
    if (isCancelled?.call() ?? false) {
      return Future<WorkResourceLockLease>.error(
        WorkResourceLockCancelled(normalizedOwner),
      );
    }
    if (normalized.isEmpty) {
      return Future<WorkResourceLockLease>.value(_newLease(
        normalizedOwner,
        normalized,
      ));
    }

    // Stage 02 may wrap a mutation in a task-level tree lock and the
    // mutation service may acquire its exact file lock inside that scope.
    // Let an owner extend an overlapping lock set immediately; otherwise a
    // queued conflicting owner would wait on the outer lease while the outer
    // owner waits forever for this nested lease.
    if (_hasOverlappingHeldPath(normalizedOwner, normalized) &&
        _canGrant(normalizedOwner, normalized)) {
      return Future<WorkResourceLockLease>.value(
        _newLease(normalizedOwner, normalized),
      );
    }

    final waiter = _ResourceLockWaiter(
      ownerId: normalizedOwner,
      requests: normalized,
    );
    _waiters.addLast(waiter);
    if (cancellation != null) {
      unawaited(
        cancellation.then<void>(
          (_) => _cancelWaiter(waiter),
          onError: (Object _, StackTrace __) => _cancelWaiter(waiter),
        ),
      );
    }
    _pump();
    return waiter.completer.future;
  }

  Future<WorkResourceLockLease> acquireLocks({
    required String ownerId,
    required Iterable<WorkResourceLockRequest> requests,
    Future<void>? cancellation,
    bool Function()? isCancelled,
  }) =>
      acquire(
        ownerId,
        requests,
        cancellation: cancellation,
        isCancelled: isCancelled,
      );

  /// Runs [body] while holding a complete plan, releasing it on every exit.
  Future<T> withLocks<T>(
    String ownerId,
    Iterable<WorkResourceLockRequest> requests,
    Future<T> Function() body, {
    Future<void>? cancellation,
    bool Function()? isCancelled,
  }) async {
    final lease = await acquire(
      ownerId,
      requests,
      cancellation: cancellation,
      isCancelled: isCancelled,
    );
    try {
      return await body();
    } finally {
      await lease.release();
    }
  }

  void _pump() {
    // ponytail: this is an O(waiters × held-locks) scan; a path index can be
    // added only if profiling shows large task queues need it.
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.first;
      if (waiter.cancelled) {
        _waiters.removeFirst();
        continue;
      }
      if (!_canGrant(waiter.ownerId, waiter.requests)) return;
      _waiters.removeFirst();
      waiter.granted = true;
      final lease = _newLease(waiter.ownerId, waiter.requests);
      waiter.completer.complete(lease);
    }
  }

  bool _canGrant(
    String ownerId,
    List<WorkResourceLockRequest> requests,
  ) {
    for (final requested in requests) {
      for (final held in _held) {
        if (held.ownerId == ownerId) continue;
        if (_conflicts(held.request, requested)) return false;
      }
    }
    return true;
  }

  bool _hasOverlappingHeldPath(
    String ownerId,
    List<WorkResourceLockRequest> requests,
  ) {
    for (final held in _held) {
      if (held.ownerId != ownerId) continue;
      for (final requested in requests) {
        final heldPath = _comparisonKey(held.request.path);
        final requestedPath = _comparisonKey(requested.path);
        if (heldPath == requestedPath) return true;
        if (held.request.mode == WorkResourceLockMode.treeWrite ||
            requested.mode == WorkResourceLockMode.treeWrite) {
          if (_isWithinOrEqual(heldPath, requestedPath) ||
              _isWithinOrEqual(requestedPath, heldPath)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  WorkResourceLockLease _newLease(
    String ownerId,
    List<WorkResourceLockRequest> requests,
  ) {
    final leaseId = ++_nextLeaseId;
    _held.addAll(
      requests.map(
        (request) => _HeldResourceLock(
          leaseId: leaseId,
          ownerId: ownerId,
          request: request,
        ),
      ),
    );
    return WorkResourceLockLease._(
      ownerId: ownerId,
      requests: requests,
      release: () async {
        _held.removeWhere((lock) => lock.leaseId == leaseId);
        _pump();
      },
    );
  }

  void _cancelWaiter(_ResourceLockWaiter waiter) {
    if (waiter.granted || waiter.cancelled) return;
    waiter.cancelled = true;
    _waiters.remove(waiter);
    if (!waiter.completer.isCompleted) {
      waiter.completer.completeError(WorkResourceLockCancelled(waiter.ownerId));
    }
    _pump();
  }

  bool _conflicts(
    WorkResourceLockRequest held,
    WorkResourceLockRequest requested,
  ) {
    final heldPath = _comparisonKey(held.path);
    final requestedPath = _comparisonKey(requested.path);
    if (held.mode == WorkResourceLockMode.read &&
        requested.mode == WorkResourceLockMode.read &&
        heldPath == requestedPath) {
      return false;
    }
    if (held.mode != WorkResourceLockMode.treeWrite &&
        requested.mode != WorkResourceLockMode.treeWrite) {
      return heldPath == requestedPath;
    }
    return _isWithinOrEqual(heldPath, requestedPath) ||
        _isWithinOrEqual(requestedPath, heldPath);
  }

  String _normalizePath(String rawPath) {
    try {
      final value = rawPath.trim();
      final absolute = value.startsWith('/') ||
          RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
          value.startsWith(r'\\');
      if (!absolute) throw const FormatException();
      return WorkFolderGrantService.normalizePath(
        value,
        isWindows: isWindows,
      );
    } on Object {
      throw ArgumentError.value(rawPath, 'path', '资源锁路径无效');
    }
  }

  String _comparisonKey(String path) => isWindows ? path.toLowerCase() : path;

  bool _isWithinOrEqual(String candidate, String root) {
    if (candidate == root) return true;
    if (root == '/' || (isWindows && RegExp(r'^[a-z]:/$').hasMatch(root))) {
      return candidate.startsWith(root);
    }
    return candidate.startsWith('$root/');
  }

  int _compareRequests(
    WorkResourceLockRequest left,
    WorkResourceLockRequest right,
  ) {
    final pathOrder =
        _comparisonKey(left.path).compareTo(_comparisonKey(right.path));
    if (pathOrder != 0) return pathOrder;
    return _modeRank(left.mode).compareTo(_modeRank(right.mode));
  }

  int _modeRank(WorkResourceLockMode mode) => switch (mode) {
        WorkResourceLockMode.read => 0,
        WorkResourceLockMode.write => 1,
        WorkResourceLockMode.treeWrite => 2,
      };
}
