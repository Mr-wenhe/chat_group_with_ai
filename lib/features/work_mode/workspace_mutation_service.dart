import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_approval_decision.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:crypto/crypto.dart';

import 'workspace_path_policy.dart';

part 'workspace_mutation_service_models.dart';
part 'workspace_mutation_service_resolution.dart';
part 'workspace_mutation_service_io.dart';

/// The sole Task 10 entry point for approved file mutations.
///
/// ponytail: Keep the service small and synchronous at its boundary. It
/// delegates path authorization, approvals and future snapshots instead of
/// creating a second policy or persistence implementation.
class WorkspaceMutationService {
  static const int defaultMaxMutationBytes = 10 * 1024 * 1024;
  final WorkspacePathPolicy pathPolicy;
  final WorkspaceMutationSnapshotPort? snapshotPort;
  final WorkTaskEventStore? eventStore;
  final WorkspaceMutationFailureInjector? failureInjector;
  final int maxMutationBytes;
  final WorkResourceLockManager? resourceLockManager;

  static int _temporaryFileCounter = 0;
  // A single app may construct more than one service during provider
  // replacement or recovery. Keep a process-wide fallback queue so two such
  // instances cannot both pass the final create check for the same path.
  // The coordinator still uses finer-grained resource leases; this queue is
  // only the direct-service safety net.
  static Future<void> _globalMutationQueue = Future<void>.value();
  // Keep direct callers safe even when they bypass the coordinator's
  // workspace lock. The queue is intentionally scoped to one service
  // instance; production uses one app-scoped instance shared by all tasks.
  Future<void> _mutationQueue = Future<void>.value();

  WorkspaceMutationService({
    required this.pathPolicy,
    this.snapshotPort,
    this.eventStore,
    this.failureInjector,
    this.maxMutationBytes = defaultMaxMutationBytes,
    this.resourceLockManager,
  }) : assert(maxMutationBytes > 0);

  /// Executes exactly one operation described by [plan] and [request].
  /// Missing or incomplete approval is rejected before any file-system write.
  Future<WorkspaceMutationResult> execute({
    required WorkChangePlan plan,
    required WorkspaceMutationRequest request,
    WorkApprovalScope? approvalScope,
    WorkApprovalScope? approval,
    WorkChangeApprovalDecision? approvalDecision,
    bool allowWithoutUndo = false,
    WorkTaskCancellation? cancellation,
    bool Function()? isCancelled,
  }) async {
    return _serializeMutations(
      () => _serializeGlobal(
        () => _withResourceLock(
          plan,
          () => _executeUnlocked(
            plan: plan,
            request: request,
            approvalScope: approvalScope,
            approval: approval,
            approvalDecision: approvalDecision,
            allowWithoutUndo: allowWithoutUndo,
            cancellation: cancellation,
            isCancelled: isCancelled,
          ),
          cancellation: cancellation,
          isCancelled: isCancelled,
        ),
      ),
    );
  }

  Future<WorkspaceMutationResult> _withResourceLock(
    WorkChangePlan plan,
    Future<WorkspaceMutationResult> Function() operation, {
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) {
    final manager = resourceLockManager;
    if (manager == null) return operation();
    // Lock both declared impact directories and exact paths. A malformed or
    // incomplete rename plan must not leave its destination outside the lock
    // set; the exact-path fallback keeps the boundary safe while preserving
    // the planner's broader directory scope.
    final paths = <String>{
      ...plan.knownAffectedDirectories,
      ...plan.exactPaths,
    };
    final requests =
        paths.map(WorkResourceLockRequest.treeWrite).toList(growable: false);
    return manager.withLocks(
      plan.taskId,
      requests,
      operation,
      cancellation: cancellation?.whenCancelled,
      isCancelled: isCancelled,
    );
  }

  Future<WorkspaceMutationResult> _executeUnlocked({
    required WorkChangePlan plan,
    required WorkspaceMutationRequest request,
    WorkApprovalScope? approvalScope,
    WorkApprovalScope? approval,
    WorkChangeApprovalDecision? approvalDecision,
    bool allowWithoutUndo = false,
    WorkTaskCancellation? cancellation,
    bool Function()? isCancelled,
  }) async {
    final scope = approvalScope ?? approval;
    if (scope == null || !scope.allows(plan)) {
      return _record(
        plan,
        const WorkspaceMutationResult(
          status: WorkspaceMutationStatus.notApproved,
          reason: '当前变更没有覆盖全部精确路径的有效批准。',
        ),
      );
    }

    final requestDecision = request.approvalDecision;
    if (approvalDecision != null &&
        requestDecision != null &&
        approvalDecision != requestDecision) {
      return _record(
        plan,
        const WorkspaceMutationResult(
          status: WorkspaceMutationStatus.notApproved,
          reason: '审批决定与请求中的任务决定不一致，未执行文件变更。',
        ),
      );
    }
    final effectiveDecision = approvalDecision ?? requestDecision;
    if (effectiveDecision == WorkChangeApprovalDecision.rejected) {
      return _record(
        plan,
        const WorkspaceMutationResult(
          status: WorkspaceMutationStatus.notApproved,
          reason: '用户未批准当前文件变更。',
        ),
      );
    }
    // Keep the old boolean parameters source-compatible, but never treat them
    // as authorization. A raw flag has no task-bound user decision and would
    // let any direct caller bypass the snapshot safety boundary. The only
    // accepted no-undo grant is the durable structured decision carried by the
    // task checkpoint and request.
    if ((allowWithoutUndo || request.allowWithoutUndo) &&
        effectiveDecision != WorkChangeApprovalDecision.approvedWithoutUndo) {
      return _record(
        plan,
        const WorkspaceMutationResult(
          status: WorkspaceMutationStatus.notApproved,
          reason: '无撤销执行必须来自本任务的明确结构化批准，未执行文件变更。',
        ),
      );
    }
    final effectiveAllowWithoutUndo =
        effectiveDecision?.permitsWithoutUndo == true;
    final effectiveRequest =
        request.approvalDecision == null && approvalDecision != null
            ? request.copyWith(approvalDecision: approvalDecision)
            : request;

    WorkspaceSnapshotReservation? reservation;
    List<String> reservedPaths = const <String>[];
    try {
      _validateRequest(plan, request);
      _checkCancellation(cancellation, isCancelled);
      _inject(WorkspaceMutationPhase.beforeInitialResolve);
      final initial = await _resolveInitial(plan, request);
      _inject(WorkspaceMutationPhase.afterInitialResolve);
      _checkCancellation(cancellation, isCancelled);

      // Reject a stale content precondition before reserving a snapshot. This
      // keeps a pure conflict from creating any snapshot work or side effect.
      if ((plan.actionType == WorkChangeActionType.modify ||
              plan.actionType == WorkChangeActionType.patch) &&
          request.expectedSha256 != null) {
        final currentBytes = await _readFileBytes(initial.target.path);
        _checkExpectedHashBytes(currentBytes, request.expectedSha256);
      }

      // Validate once before any snapshot reservation and once again after
      // it. A reservation is not allowed to bless a path that changed.
      final beforeSnapshot = await _revalidate(
        plan,
        request,
        initial,
        cancellation: cancellation,
        isCancelled: isCancelled,
      );
      var requestForExecution = effectiveRequest;
      if (plan.actionType == WorkChangeActionType.modify &&
          effectiveRequest.expectedSha256 == null) {
        final observed = await _readFileBytes(beforeSnapshot.target.path);
        requestForExecution = effectiveRequest.copyWith(
          expectedSha256: sha256.convert(observed).toString(),
        );
      }
      reservedPaths = <String>[
        beforeSnapshot.target.path,
        if (beforeSnapshot.destination != null)
          beforeSnapshot.destination!.path,
      ];
      reservation = await _reserveSnapshotIfNeeded(
        plan,
        beforeSnapshot,
        allowWithoutUndo: effectiveAllowWithoutUndo,
        cancellation: cancellation,
        isCancelled: isCancelled,
      );
      _inject(WorkspaceMutationPhase.afterSnapshot);
      _checkCancellation(cancellation, isCancelled);
      final current = await _revalidate(
        plan,
        requestForExecution,
        beforeSnapshot,
        cancellation: cancellation,
        isCancelled: isCancelled,
      );
      _checkCancellation(cancellation, isCancelled);

      final result = await _perform(
        plan,
        requestForExecution,
        current,
        reservation,
        allowWithoutUndo: effectiveAllowWithoutUndo,
        cancellation: cancellation,
        isCancelled: isCancelled,
      );
      if (!result.succeeded && reservation != null) {
        await _abortReservation(
          reservation,
          plan: plan,
          paths: reservedPaths,
          result: result,
        );
      }
      var finalResult = result;
      if (result.succeeded && reservation != null) {
        final completion = snapshotPort;
        if (completion
            case final WorkspaceMutationSnapshotCompletionPort writer) {
          try {
            await writer.complete(
              reservation: reservation,
              plan: plan,
              paths: [
                current.target.path,
                if (current.destination != null) current.destination!.path,
              ],
              result: result,
            );
          } on Object {
            final failed = result.copyWith(
              status: WorkspaceMutationStatus.failed,
              reason: '文件已写入，但撤销记录未完成；请重试前先检查目标文件。',
              mutationCommitted: true,
            );
            await _abortReservation(
              reservation,
              plan: plan,
              paths: reservedPaths,
              result: failed,
            );
            finalResult = failed;
          }
        }
      }
      return _record(plan, finalResult);
    } on _MutationAbort catch (error) {
      await _abortReservation(
        reservation,
        plan: plan,
        paths: reservedPaths,
        result: error.result,
      );
      return _record(plan, error.result);
    } on WorkspacePathException {
      const result = WorkspaceMutationResult(
        status: WorkspaceMutationStatus.pathRejected,
        reason: '最终路径校验失败，已拒绝文件变更。',
      );
      await _abortReservation(
        reservation,
        plan: plan,
        paths: reservedPaths,
        result: result,
      );
      return _record(plan, result);
    } on FileSystemException {
      const result = WorkspaceMutationResult(
        status: WorkspaceMutationStatus.failed,
        reason: '文件系统操作失败，原文件未被主动覆盖。',
      );
      await _abortReservation(
        reservation,
        plan: plan,
        paths: reservedPaths,
        result: result,
      );
      return _record(plan, result);
    } on Object {
      const result = WorkspaceMutationResult(
        status: WorkspaceMutationStatus.failed,
        reason: '文件变更失败，原文件未被主动覆盖。',
      );
      await _abortReservation(
        reservation,
        plan: plan,
        paths: reservedPaths,
        result: result,
      );
      return _record(plan, result);
    }
  }

  Future<T> _serializeMutations<T>(Future<T> Function() operation) {
    final previous = _mutationQueue;
    late final Future<T> scheduled;
    scheduled = previous.catchError((Object _) {}).then((_) => operation());
    _mutationQueue = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return scheduled;
  }

  Future<T> _serializeGlobal<T>(Future<T> Function() operation) {
    final previous = WorkspaceMutationService._globalMutationQueue;
    late final Future<T> scheduled;
    scheduled = previous.catchError((Object _) {}).then((_) => operation());
    WorkspaceMutationService._globalMutationQueue = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return scheduled;
  }

  /// Alias used by callers that describe this boundary as applying a plan.
  Future<WorkspaceMutationResult> apply({
    required WorkChangePlan plan,
    required WorkspaceMutationRequest request,
    WorkApprovalScope? approvalScope,
    WorkApprovalScope? approval,
    WorkChangeApprovalDecision? approvalDecision,
    bool allowWithoutUndo = false,
    WorkTaskCancellation? cancellation,
    bool Function()? isCancelled,
  }) {
    return execute(
      plan: plan,
      request: request,
      approvalScope: approvalScope,
      approval: approval,
      approvalDecision: approvalDecision,
      allowWithoutUndo: allowWithoutUndo,
      cancellation: cancellation,
      isCancelled: isCancelled,
    );
  }

  Future<void> _abortReservation(
    WorkspaceSnapshotReservation? reservation, {
    required WorkChangePlan plan,
    required List<String> paths,
    required WorkspaceMutationResult result,
  }) async {
    if (reservation == null) return;
    final port = snapshotPort;
    if (port case final WorkspaceMutationSnapshotAbortPort aborter) {
      try {
        await aborter.abort(
          reservation: reservation,
          plan: plan,
          paths: paths,
          result: result,
        );
      } on Object {
        // The mutation result remains authoritative; the durable snapshot
        // service retains its pre-image when abort bookkeeping itself fails.
      }
    }
  }

  Future<WorkspaceMutationResult> _perform(
    WorkChangePlan plan,
    WorkspaceMutationRequest request,
    _ResolvedMutation current,
    WorkspaceSnapshotReservation? reservation, {
    required bool allowWithoutUndo,
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) {
    Future<void> verifyPath() => _verifyPath(
          plan,
          request,
          current,
          cancellation: cancellation,
          isCancelled: isCancelled,
        );

    switch (plan.actionType) {
      case WorkChangeActionType.create:
        return _create(
          request,
          current.target,
          reservation,
          allowWithoutUndo: allowWithoutUndo,
          verifyPath: verifyPath,
          cancellation: cancellation,
          isCancelled: isCancelled,
        );
      case WorkChangeActionType.modify:
        return _modify(
          request,
          current.target,
          reservation,
          allowWithoutUndo: allowWithoutUndo,
          verifyPath: verifyPath,
          cancellation: cancellation,
          isCancelled: isCancelled,
        );
      case WorkChangeActionType.patch:
        return _patch(
          request,
          current.target,
          reservation,
          allowWithoutUndo: allowWithoutUndo,
          verifyPath: verifyPath,
          cancellation: cancellation,
          isCancelled: isCancelled,
        );
      case WorkChangeActionType.rename:
        return _rename(
          current.target,
          current.destination!,
          reservation: reservation,
          allowWithoutUndo: allowWithoutUndo,
          verifyPath: verifyPath,
          cancellation: cancellation,
          isCancelled: isCancelled,
        );
      case WorkChangeActionType.delete:
        return _delete(
          current.target,
          reservation: reservation,
          allowWithoutUndo: allowWithoutUndo,
          verifyPath: verifyPath,
          cancellation: cancellation,
          isCancelled: isCancelled,
        );
      case WorkChangeActionType.command:
        return Future<WorkspaceMutationResult>.value(
          const WorkspaceMutationResult(
            status: WorkspaceMutationStatus.invalidRequest,
            reason: '文件变更入口不执行命令动作。',
          ),
        );
    }
  }

  Future<void> _verifyPath(
    WorkChangePlan plan,
    WorkspaceMutationRequest request,
    _ResolvedMutation expected, {
    required WorkTaskCancellation? cancellation,
    required bool Function()? isCancelled,
  }) async {
    _checkCancellation(cancellation, isCancelled);
    await _revalidate(
      plan,
      request,
      expected,
      cancellation: cancellation,
      isCancelled: isCancelled,
    );
  }
}
