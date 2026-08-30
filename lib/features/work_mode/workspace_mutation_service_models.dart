part of 'workspace_mutation_service.dart';

/// The result of one mutation attempt. A failed result never implies that a
/// partial target was left behind.
enum WorkspaceMutationStatus {
  success,
  notApproved,
  pathRejected,
  conflict,
  snapshotUnavailable,
  cancelled,
  invalidRequest,
  failed,
}

class WorkspaceMutationResult {
  final WorkspaceMutationStatus status;
  final String reason;
  final String? path;
  final String? destinationPath;
  final int bytesWritten;

  /// True only when the target change was committed before a later
  /// bookkeeping step failed. Snapshot abort handlers use this bit to keep a
  /// recoverable, auditable action instead of hiding it as an uncompleted
  /// reservation.
  final bool mutationCommitted;

  const WorkspaceMutationResult({
    required this.status,
    required this.reason,
    this.path,
    this.destinationPath,
    this.bytesWritten = 0,
    this.mutationCommitted = false,
  });

  bool get succeeded => status == WorkspaceMutationStatus.success;
  bool get isConflict => status == WorkspaceMutationStatus.conflict;
  bool get isCancelled => status == WorkspaceMutationStatus.cancelled;
  bool get isRejected =>
      status == WorkspaceMutationStatus.notApproved ||
      status == WorkspaceMutationStatus.pathRejected;

  WorkspaceMutationResult copyWith({
    WorkspaceMutationStatus? status,
    String? reason,
    String? path,
    String? destinationPath,
    int? bytesWritten,
    bool? mutationCommitted,
  }) {
    return WorkspaceMutationResult(
      status: status ?? this.status,
      reason: reason ?? this.reason,
      path: path ?? this.path,
      destinationPath: destinationPath ?? this.destinationPath,
      bytesWritten: bytesWritten ?? this.bytesWritten,
      mutationCommitted: mutationCommitted ?? this.mutationCommitted,
    );
  }
}

/// Input for one file mutation. The action itself comes from [WorkChangePlan]
/// so callers cannot submit an approved plan for a different operation.
class WorkspaceMutationRequest {
  final String path;
  final String? contents;
  final List<int>? bytes;
  final String? expectedSha256;
  final String? expectedFragment;
  final String? replacement;
  final String? destinationPath;

  /// This flag is set only by a separate user decision to accept no undo.
  /// It is deliberately independent from the ordinary-write preference.
  // Legacy compatibility field. Production callers must provide the typed
  // task-bound approvalDecision instead.
  final bool allowWithoutUndo;
  final WorkChangeApprovalDecision? approvalDecision;

  const WorkspaceMutationRequest({
    required this.path,
    this.contents,
    this.bytes,
    this.expectedSha256,
    this.expectedFragment,
    this.replacement,
    this.destinationPath,
    this.approvalDecision,
    this.allowWithoutUndo = false,
  });

  const WorkspaceMutationRequest.text({
    required this.path,
    required this.contents,
  })  : bytes = null,
        expectedSha256 = null,
        expectedFragment = null,
        replacement = null,
        destinationPath = null,
        approvalDecision = null,
        allowWithoutUndo = false;

  const WorkspaceMutationRequest.binary({
    required this.path,
    required this.bytes,
  })  : contents = null,
        expectedSha256 = null,
        expectedFragment = null,
        replacement = null,
        destinationPath = null,
        approvalDecision = null,
        allowWithoutUndo = false;

  const WorkspaceMutationRequest.patch({
    required this.path,
    required this.expectedSha256,
    required this.expectedFragment,
    required this.replacement,
  })  : contents = null,
        bytes = null,
        destinationPath = null,
        approvalDecision = null,
        allowWithoutUndo = false;

  factory WorkspaceMutationRequest.rename({
    required String sourcePath,
    required String destinationPath,
  }) {
    return WorkspaceMutationRequest(
      path: sourcePath,
      destinationPath: destinationPath,
    );
  }

  const WorkspaceMutationRequest.delete({required this.path})
      : contents = null,
        bytes = null,
        expectedSha256 = null,
        expectedFragment = null,
        replacement = null,
        destinationPath = null,
        approvalDecision = null,
        allowWithoutUndo = false;

  bool get hasPayload => contents != null || bytes != null;

  WorkspaceMutationRequest copyWith({
    String? path,
    String? contents,
    List<int>? bytes,
    String? expectedSha256,
    String? expectedFragment,
    String? replacement,
    String? destinationPath,
    WorkChangeApprovalDecision? approvalDecision,
    bool? allowWithoutUndo,
  }) {
    return WorkspaceMutationRequest(
      path: path ?? this.path,
      contents: contents ?? this.contents,
      bytes: bytes ?? this.bytes,
      expectedSha256: expectedSha256 ?? this.expectedSha256,
      expectedFragment: expectedFragment ?? this.expectedFragment,
      replacement: replacement ?? this.replacement,
      destinationPath: destinationPath ?? this.destinationPath,
      approvalDecision: approvalDecision ?? this.approvalDecision,
      allowWithoutUndo: allowWithoutUndo ?? this.allowWithoutUndo,
    );
  }

  List<int> get encodedContents {
    if (contents != null) return utf8.encode(contents!);
    return List<int>.unmodifiable(bytes ?? const <int>[]);
  }
}

/// Technical-design naming retained for callers that use "operation".
typedef WorkspaceMutationOperation = WorkspaceMutationRequest;

/// Reservation hook for Task 11's snapshot implementation. Task 10 only
/// checks and forwards the reservation; it never stores snapshot contents.
class WorkspaceSnapshotReservation {
  final bool available;
  final String? reservationId;

  const WorkspaceSnapshotReservation({
    required this.available,
    this.reservationId,
  });
}

abstract interface class WorkspaceMutationSnapshotPort {
  Future<WorkspaceSnapshotReservation> reserve({
    required WorkChangePlan plan,
    required List<String> paths,
  });
}

/// Lightweight quota/pre-image check used while preparing an approval prompt.
/// Implementations must not mutate the target workspace.
abstract interface class WorkspaceMutationSnapshotAvailabilityPort {
  Future<bool> canReserve({
    required WorkChangePlan plan,
    required List<String> paths,
  });
}

/// Optional second half of the reservation protocol. Task 10 callers that
/// only provide a reservation port remain source-compatible; Task 11's
/// concrete snapshot service also records the post-mutation condition here.
abstract interface class WorkspaceMutationSnapshotCompletionPort {
  Future<void> complete({
    required WorkspaceSnapshotReservation reservation,
    required WorkChangePlan plan,
    required List<String> paths,
    required WorkspaceMutationResult result,
  });
}

/// Completes the other side of a reservation when a mutation fails after the
/// pre-image was reserved. Implementations must keep the manifest recoverable
/// and release their in-memory reservation; leaving it pending would make a
/// later mutation reuse an ambiguous sequence.
abstract interface class WorkspaceMutationSnapshotAbortPort {
  Future<void> abort({
    required WorkspaceSnapshotReservation reservation,
    required WorkChangePlan plan,
    required List<String> paths,
    required WorkspaceMutationResult result,
  });
}

typedef WorkspaceSnapshotPort = WorkspaceMutationSnapshotPort;

/// Test and diagnostic checkpoints. A production caller may use these to
/// inject a failure or cancel after the temporary file has been flushed.
enum WorkspaceMutationPhase {
  beforeInitialResolve,
  afterInitialResolve,
  beforeSnapshot,
  afterSnapshot,
  beforeTempWrite,
  afterTempFlush,
  beforeReplace,
  afterReplace,
}

typedef WorkspaceMutationFailureInjector = void Function(
    WorkspaceMutationPhase phase);

class _ResolvedMutation {
  final WorkspaceResolvedPath target;
  final WorkspaceResolvedPath? destination;

  const _ResolvedMutation({required this.target, this.destination});
}

class _MutationAbort implements Exception {
  final WorkspaceMutationResult result;

  const _MutationAbort(this.result);
}
