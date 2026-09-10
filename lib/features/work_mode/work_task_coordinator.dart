import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:hive/hive.dart';

import 'work_task_event.dart';
import 'work_task_event_store.dart';
import 'work_task_error_sanitizer.dart';
import 'work_folder_grant_service.dart';
import 'work_resource_lock_manager.dart';
import 'work_snapshot_manifest.dart';
import 'work_approval_decision.dart';
import 'work_change_plan.dart';
import 'work_command_runner.dart';
import 'work_context_builder.dart';
import 'work_follow_up_policy.dart';
import 'work_handoff_state.dart';
import 'work_failure.dart';
import 'work_mode_directory_service.dart';
import 'work_tool_registry.dart';

typedef WorkTaskSnapshotStatusUpdater = Future<void> Function(
    String taskId, WorkSnapshotTaskStatus status);

/// A cancellation handle belongs to exactly one active work task.
class WorkTaskCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Runs one task after the coordinator has reserved its global slot.
abstract interface class WorkTaskRunner {
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation);
}

/// Optional capability used at the durable task boundary. The panel may list
/// a candidate, but the coordinator must re-check the selected character
/// before changing the task's execution identity.
abstract interface class WorkTaskVisionModelValidator {
  bool supportsVisionModel(String characterId);

  /// Applies the same capability check while preserving the conversation
  /// boundary. Runners that do not need task-scoped membership can inherit the
  /// character-only default.
  bool supportsVisionModelForTask(AgentTask task, String characterId) =>
      supportsVisionModel(characterId);
}

/// Optional capability for runners that persist checkpoints themselves.
///
/// The coordinator remains the owner of the task stream, while a production
/// runner can publish each durable checkpoint immediately instead of waiting
/// for the whole run to finish. Test runners do not need this capability.
abstract interface class WorkTaskProgressReporter {
  void setTaskUpdateSink(void Function(AgentTask task) sink);
}

/// Optional capability for runners that need the coordinator to persist every
/// loop checkpoint. The UI update sink above remains intentionally synchronous;
/// checkpoint persistence may await Hive/file I/O.
abstract interface class WorkTaskCheckpointReporter {
  void setTaskCheckpointSink(Future<void> Function(AgentTask task) sink);
}

/// Computes the complete resource plan before a task starts executing.
typedef WorkTaskResourceLockPlan = Iterable<WorkResourceLockRequest> Function(
    AgentTask task);

/// Optional runner capability for a production loop that owns its plan.
abstract interface class WorkTaskResourceLockPlanner {
  Iterable<WorkResourceLockRequest> planResourceLocks(AgentTask task);
}

/// Optional capability used by the execution panel when a command depends on
/// a missing, known tool. The handler owns the process boundary; the
/// coordinator only persists the user's explicit install decision.
abstract interface class WorkTaskInstallHandler {
  Future<WorkCommandResult> installMissingTool(
    AgentTask task,
    WorkTaskCancellation cancellation,
  );
}

/// Optional runner capability used after an explicit folder reauthorization.
/// The coordinator owns the consent boundary; the runner owns its workspace
/// persistence and therefore must clear the stale conversation path before a
/// retry can resolve the newly granted root.
abstract interface class WorkTaskWorkspaceRebinder {
  Future<void> rebindWorkspace(AgentTask task, String grantedPath);
}

class _RunningTask {
  final AgentTask task;
  final WorkTaskCancellation cancellation;

  const _RunningTask({required this.task, required this.cancellation});
}

class _WaitingResourceTask {
  final AgentTask task;
  final WorkTaskCancellation cancellation;
  WorkResourceLockLease? lease;

  _WaitingResourceTask({required this.task, required this.cancellation});
}

/// Owns work-task scheduling independently from every chat-room widget.
///
/// State updates are serialized before starting a runner, so two concurrent
/// submissions cannot consume the same slot or run the same conversation.
class WorkTaskCoordinator {
  static const int maximumConcurrentTasks = 2;

  /// A user stop is terminal by design, but a task that has not committed a
  /// mutation can safely be restarted from zero.  This narrow predicate keeps
  /// the recovery affordance from replaying a task after a real file change.
  static bool canRestartAfterUserStop(AgentTask task) {
    if (task.status != AgentTaskStatus.cancelled ||
        task.lastError.trim() != '用户已停止任务。' ||
        task.lastArtifactPaths.isNotEmpty) {
      return false;
    }
    if (task.completedOperations.isEmpty) return true;
    try {
      final decoded = jsonDecode(task.executionStateJson);
      if (decoded is! Map) return false;
      final committed = decoded['committedActionKeys'];
      return committed is List && committed.isEmpty;
    } on Object {
      return false;
    }
  }

  final Box<AgentTask> _taskBox;
  final WorkTaskEventStore _eventStore;
  final WorkTaskRunner _runner;
  final WorkFolderGrantService? _folderGrantService;
  final WorkFolderPicker? _folderPicker;
  WorkFolderGrantConsent? _folderGrantConsent;
  final bool _requireFolderGrant;
  final WorkTaskSnapshotStatusUpdater? _snapshotStatusUpdater;
  final WorkResourceLockManager _resourceLockManager;
  final WorkTaskResourceLockPlan? _resourceLockPlan;
  final WorkContextBuilder _contextBuilder;
  final WorkFollowUpPolicy _followUpPolicy;
  final DateTime Function() _clock;
  final StreamController<AgentTask> _taskUpdates =
      StreamController<AgentTask>.broadcast(sync: true);
  final Map<String, _RunningTask> _running = <String, _RunningTask>{};
  final Map<String, Queue<String>> _conversationQueues =
      <String, Queue<String>>{};
  final Queue<String> _readyConversations = Queue<String>();
  final Set<String> _readyConversationIds = <String>{};
  final Map<String, Future<void>> _activeRuns = <String, Future<void>>{};
  final Map<String, List<WorkResourceLockRequest>> _taskLockPlans =
      <String, List<WorkResourceLockRequest>>{};
  final Map<String, _WaitingResourceTask> _waitingForResources =
      <String, _WaitingResourceTask>{};
  final Map<String, WorkTaskCancellation> _folderWaiters =
      <String, WorkTaskCancellation>{};
  final Set<String> _conversationReservations = <String>{};
  final Set<String> _handoffsAwaitingLease = <String>{};
  final Set<String> _startingTaskIds = <String>{};
  final Queue<Completer<void>> _slotWaiters = Queue<Completer<void>>();
  Future<WorkFolderRequestResult>? _folderRequest;

  Future<void> _operations = Future<void>.value();
  Future<void>? _disposeFuture;
  bool _disposed = false;
  bool _dataClearInProgress = false;

  WorkTaskCoordinator({
    required Box<AgentTask> taskBox,
    required WorkTaskEventStore eventStore,
    required WorkTaskRunner runner,
    WorkFolderGrantService? folderGrantService,
    WorkFolderPicker? folderPicker,
    WorkFolderGrantConsent? folderGrantConsent,
    bool requireFolderGrant = false,
    WorkTaskSnapshotStatusUpdater? snapshotStatusUpdater,
    WorkResourceLockManager? resourceLockManager,
    WorkTaskResourceLockPlan? resourceLockPlan,
    WorkContextBuilder? contextBuilder,
    WorkFollowUpPolicy? followUpPolicy,
    DateTime Function()? clock,
  })  : _taskBox = taskBox,
        _eventStore = eventStore,
        _runner = runner,
        _folderGrantService = folderGrantService,
        _folderPicker = folderPicker,
        _folderGrantConsent = folderGrantConsent,
        _requireFolderGrant = requireFolderGrant,
        _snapshotStatusUpdater = snapshotStatusUpdater,
        _resourceLockManager = resourceLockManager ?? WorkResourceLockManager(),
        _resourceLockPlan = resourceLockPlan,
        _contextBuilder = contextBuilder ?? const WorkContextBuilder(),
        _followUpPolicy = followUpPolicy ?? const WorkFollowUpPolicy(),
        _clock = clock ?? DateTime.now {
    if (runner case final WorkTaskProgressReporter reporter) {
      reporter.setTaskUpdateSink(_publish);
    }
    if (runner case final WorkTaskCheckpointReporter reporter) {
      reporter.setTaskCheckpointSink(_checkpointFromRunner);
    }
  }

  int get runningTaskCount => _running.length;

  /// Quiesces every work task before the app-wide data lifecycle service
  /// removes event logs and snapshots. Active runners are cancelled
  /// cooperatively, while their finalizers are drained outside [_serialize]
  /// to avoid the runner's own completion checkpoint deadlocking the queue.
  Future<void> stopAllForDataClear() async {
    var activeRuns = <Future<void>>[];
    await _serialize(() async {
      if (_disposed) return;
      _dataClearInProgress = true;
      _eventStore.suspendAppendsForDataClear();
      activeRuns = List<Future<void>>.from(_activeRuns.values);
      for (final task in _allWorkTasks()) {
        if (task.isTerminal) continue;
        _removeQueuedTask(task);
        _running[task.id]?.cancellation.cancel();
        _folderWaiters.remove(task.id)?.cancel();
        final waiting = _waitingForResources.remove(task.id);
        waiting?.cancellation.cancel();
        final lease = waiting?.lease;
        if (lease != null) unawaited(lease.release());
        _conversationReservations.remove(task.groupId);
        _handoffsAwaitingLease.remove(task.id);
        _taskLockPlans.remove(task.id);
        task
          ..status = AgentTaskStatus.cancelled
          ..resumeRequired = false
          ..pendingToolRequestJson = ''
          ..queuedUserRequests = <String>[]
          ..lastError = sanitizeWorkTaskError('App 数据清除前已停止工作任务。')
          ..updatedAt = _clock();
        await _save(task);
        await _markSnapshotStatus(task);
        unawaited(
          _record(task, WorkTaskEventKind.failed, 'App 数据清除前已停止任务'),
        );
      }
      _readyConversations.clear();
      _readyConversationIds.clear();
      _conversationQueues.clear();
      _notifySlotAvailable();
    });
    if (activeRuns.isNotEmpty) {
      await Future.wait<void>(activeRuns, eagerError: false);
    }
    // Wait for runner finalizers and any cancellation callbacks queued behind
    // the first serialized operation before the event/snapshot trees are
    // deleted. The no-op also makes this method a durable barrier for callers.
    await _serialize(() async {});
  }

  /// Reopens scheduling after a clear attempt has finished. The coordinator
  /// instance remains app-scoped; clearing data must not dispose it.
  Future<void> resumeAfterDataClear() {
    return _serialize(() async {
      if (_disposed) return;
      _dataClearInProgress = false;
      _eventStore.resumeAppendsAfterDataClear();
      await _schedule();
    });
  }

  /// Lets the app-level overlay provide the one-time cloud-disclosure dialog
  /// without coupling the scheduler to a particular [BuildContext].
  void setFolderGrantConsent(WorkFolderGrantConsent? consent) {
    _folderGrantConsent = consent;
  }

  /// Persists and schedules a new V1 work task. The task is queued before a
  /// runner can observe it, which makes state recoverable at every boundary.
  Future<AgentTask> submit(
    AgentTask task, {
    Iterable<WorkResourceLockRequest>? resourceLocks,
  }) {
    return _serialize(() async {
      _ensureOpen();
      if (!task.workModeTask) {
        throw ArgumentError.value(task, 'task', '协调器只接受工作模式任务');
      }
      if (_taskBox.containsKey(task.id)) {
        throw StateError('工作任务已存在：${task.id}');
      }
      if (resourceLocks != null) {
        final normalizedLocks = _resourceLockManager.normalizeLockSet(
          resourceLocks,
        );
        _taskLockPlans[task.id] = normalizedLocks;
        task.executionStateJson = _withResourceLockPlan(
          task.executionStateJson,
          normalizedLocks,
        );
      }
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..updatedAt = _clock();
      _refreshTaskContext(task);
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '任务已排队'));
      await _schedule();
      return task;
    });
  }

  /// Adds user input to the same durable task instead of replacing its run.
  Future<void> enqueueFollowUp(
    String taskId,
    String request, {
    String? attachmentMessageId,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final normalized = request.trim();
      if (normalized.isEmpty) return;
      final task = _requireWorkTask(taskId);
      if (task.status == AgentTaskStatus.cancelled) {
        throw StateError('已停止的任务不能继续追问，请创建新的工作任务。');
      }
      // A command/test/build proposal pauses with an explicit authorization
      // marker rather than a replayable tool checkpoint.  Treat the user's
      // concrete validation request as an authorization/re-plan for this
      // same durable task; placing it in the ordinary follow-up FIFO would
      // leave the marker in place and make both “继续” and the follow-up
      // loop forever.
      if (_requiresExplicitCommandRequest(task) &&
          (task.status == AgentTaskStatus.paused ||
              task.status == AgentTaskStatus.interrupted) &&
          isExplicitWorkValidationRequest(normalized)) {
        await _authorizeExplicitValidation(task, normalized);
        await _schedule();
        return;
      }
      final answeringClarification = task.status == AgentTaskStatus.paused &&
          _isFollowUpClarification(task) &&
          task.queuedUserRequests.isNotEmpty;
      final attachmentId = attachmentMessageId?.trim();
      final queuedAttachmentIds = _queuedAttachmentMessageIds(
        task.executionStateJson,
        expectedLength: task.queuedUserRequests.length,
      );
      task.queuedUserRequests = answeringClarification
          ? <String>[
              '${task.queuedUserRequests.first}\n用户明确目标：$normalized',
              ...task.queuedUserRequests.skip(1),
            ]
          : <String>[...task.queuedUserRequests, normalized];
      if (answeringClarification) {
        if (attachmentId != null && attachmentId.isNotEmpty) {
          queuedAttachmentIds[0] = attachmentId;
        }
      } else {
        queuedAttachmentIds.add(
          attachmentId == null || attachmentId.isEmpty ? '' : attachmentId,
        );
      }
      task.executionStateJson = _withQueuedAttachmentMessageIds(
        task.executionStateJson,
        queuedAttachmentIds,
      );
      _refreshTaskContext(
        task,
        nextStep: '当前任务完成后处理第 ${task.queuedUserRequests.length} 条追问。',
      );

      // A completed/failed/partially-completed task is a durable conversation
      // checkpoint. Promote its first follow-up immediately so the same task
      // id, artifacts, completed operations and context summary are reused.
      // Active tasks keep the queue and are promoted only after their current
      // run releases the slot.
      if (task.isTerminal || answeringClarification) {
        await _promoteQueuedFollowUp(
          task,
          resetRunBudget: true,
          allowPausedClarification: answeringClarification,
        );
        await _schedule();
        return;
      }
      await _save(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '已排队新的追问'));
    });
  }

  Future<void> _authorizeExplicitValidation(
    AgentTask task,
    String request,
  ) async {
    final original = task.userRequest.trim();
    final mergedRequest = original.isEmpty || original == request
        ? request
        : '$original\n用户明确要求：$request';
    final execution = _decodeExecutionMap(
      _withoutApprovalCheckpoint(task.executionStateJson),
    )..remove('explicitCommandRequestRequired');
    task
      ..userRequest = mergedRequest
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false
      ..pendingToolRequestJson = ''
      ..lastError = ''
      ..executionStateJson = execution.isEmpty ? '' : jsonEncode(execution)
      ..updatedAt = _clock();
    _conversationReservations.remove(task.groupId);
    await _save(task);
    _enqueueTask(task);
    unawaited(
      _record(
        task,
        WorkTaskEventKind.queued,
        '用户已明确授权测试、构建或分析，继续原任务',
        detail: request,
      ),
    );
  }

  /// Persists a tool-approval checkpoint without requiring a chat page to
  /// retain the pending request in memory.
  Future<void> pauseForApproval(
    String taskId, {
    required String pendingToolRequestJson,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.isTerminal) {
        throw StateError('终态任务不能再等待工具审批。');
      }
      task
        ..status = AgentTaskStatus.waitingForApproval
        // Keep only a display-safe checkpoint in Hive. The full request is
        // retained by the in-process runner while the approval dialog is open.
        ..pendingToolRequestJson =
            safeToolRequestCheckpointJson(pendingToolRequestJson)
        ..updatedAt = _clock();
      await _save(task);
      await _markSnapshotStatus(task);
      unawaited(
        _record(task, WorkTaskEventKind.approvalRequired, '等待用户批准操作'),
      );
    });
  }

  /// Records that the app-level approval prompt has been presented for this
  /// checkpoint. The marker prevents route rebuilds or app restarts from
  /// repeatedly interrupting the user while the task panel remains available.
  Future<bool> markApprovalPromptShown(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.waitingForApproval ||
          task.pendingToolRequestJson.trim().isEmpty) {
        return false;
      }
      final metadata = _decodeExecutionMap(task.executionStateJson);
      if (metadata['approvalPromptShown'] == true) return false;
      metadata['approvalPromptShown'] = true;
      task
        ..executionStateJson = jsonEncode(metadata)
        ..updatedAt = _clock();
      await _save(task);
      return true;
    });
  }

  /// Clears a prompt marker when the host failed before presenting the dialog.
  ///
  /// Presentation failures are recoverable (for example, a route can be
  /// rebuilt between the post-frame callback and [showDialog]). Keeping the
  /// marker in that case would suppress every later automatic retry and leave
  /// only the manual task panel as a workaround.
  Future<void> resetApprovalPromptShown(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.waitingForApproval ||
          task.pendingToolRequestJson.trim().isEmpty) {
        return;
      }
      final metadata = _decodeExecutionMap(task.executionStateJson);
      if (metadata.remove('approvalPromptShown') == null) return;
      task
        ..executionStateJson = metadata.isEmpty ? '' : jsonEncode(metadata)
        ..updatedAt = _clock();
      await _save(task);
    });
  }

  /// Approves the pending tool request and queues the same durable task.
  ///
  /// The decision is stored in the task checkpoint so a runner can consume it
  /// after the current process has released its slot, without relying on a
  /// chat-page object or an in-memory dialog callback.
  Future<void> approve(String taskId) => _resolveApproval(
        taskId,
        WorkChangeApprovalDecision.approved.wireName,
      );

  /// Rejects the pending tool request and queues the same durable task. The
  /// runner receives a structured rejection and may continue with safe work.
  Future<void> reject(String taskId) => _resolveApproval(
        taskId,
        WorkChangeApprovalDecision.rejected.wireName,
      );

  /// Approves a mutation after the user has explicitly accepted that this
  /// operation cannot be undone. This decision is durable and is never
  /// inferred from the ordinary-write setting.
  Future<void> approveWithoutUndo(String taskId) => _resolveApproval(
        taskId,
        WorkChangeApprovalDecision.approvedWithoutUndo.wireName,
      );

  /// Explicitly named aliases for UI integrations that prefer task wording.
  Future<void> approveTask(String taskId) => approve(taskId);

  Future<void> rejectTask(String taskId) => reject(taskId);

  Future<void> approveTaskWithoutUndo(String taskId) =>
      approveWithoutUndo(taskId);

  /// Runs a trusted package-manager suggestion only after the user chooses the
  /// install action in the execution panel. The original pending tool request
  /// remains intact so a successful install resumes the same loop turn.
  Future<void> installMissingTool(String taskId) async {
    if (_runner is! WorkTaskInstallHandler) {
      throw StateError('当前执行器不支持应用内安装工具。');
    }
    final handler = _runner as WorkTaskInstallHandler;
    final task = await _serialize(() async {
      _ensureOpen();
      final current = _requireWorkTask(taskId);
      if (current.status != AgentTaskStatus.paused ||
          current.pendingToolRequestJson.trim().isEmpty) {
        throw StateError('当前任务没有等待安装的缺失工具。');
      }
      return current;
    });
    final cancellation = WorkTaskCancellation();
    final result = await handler.installMissingTool(task, cancellation);
    await _serialize(() async {
      if (_disposed) return;
      final stored = _taskBox.get(taskId);
      if (stored == null || stored.isTerminal) return;
      if (result.succeeded) {
        final execution = _decodeExecutionMap(stored.executionStateJson)
          ..remove('toolMissing');
        stored
          ..status = AgentTaskStatus.queued
          ..resumeRequired = false
          ..lastError = ''
          ..executionStateJson = execution.isEmpty ? '' : jsonEncode(execution)
          ..updatedAt = _clock();
        _conversationReservations.remove(stored.groupId);
        await _save(stored);
        _enqueueTask(stored);
        unawaited(_record(
          stored,
          WorkTaskEventKind.queued,
          '缺失工具安装完成，继续原任务',
        ));
        await _schedule();
      } else {
        final failure = WorkFailure.fromToolResult(
          WorkToolResult(
            status: result.status == WorkCommandRunStatus.toolMissing
                ? WorkToolResultStatus.paused
                : WorkToolResultStatus.failed,
            message: result.message,
            failureCode: result.status == WorkCommandRunStatus.toolMissing
                ? 'toolMissing'
                : 'commandFailed',
          ),
          completedContent: _completedContentForTask(stored),
        );
        _applyFailure(
          stored,
          failure,
          status: AgentTaskStatus.paused,
          clearPendingTool: false,
        );
        await _save(stored);
        unawaited(_record(
          stored,
          WorkTaskEventKind.paused,
          '缺失工具安装未完成',
          detail: failure.technicalDetail,
        ));
      }
    });
  }

  /// Opens the app-level picker from the execution panel and requeues the
  /// waiting task when the selected directory covers its requested path.
  Future<void> requestFolderForTask(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final grantService = _folderGrantService;
      final picker = _folderPicker;
      if (grantService == null || picker == null) {
        throw StateError('当前没有可用的工作目录选择器。');
      }
      final task = _requireWorkTask(taskId);
      // The coordinator may already be awaiting the native picker started by
      // the initial run. Reuse that future instead of opening a second picker
      // when the panel renders its durable authorization action concurrently.
      final existingRequest = _folderRequest;
      if (existingRequest != null) {
        final sharedResult = await existingRequest;
        final requestedPath = _requestedFolderPath(task);
        final requiresWritable = _requiresWritableFolder(task);
        final grant = sharedResult.grant;
        final covered = sharedResult.granted &&
            (requestedPath == null || requestedPath.trim().isEmpty
                ? grant != null && (!requiresWritable || grant.writable)
                : requiresWritable
                    ? await grantService.isPathWritableResolved(requestedPath)
                    : await grantService
                        .isPathAuthorizedResolved(requestedPath));
        if (covered) {
          // The initial runner will persist/requeue its own task.  If this
          // panel request belongs to that same task, there is nothing else to
          // do; returning avoids a duplicate native picker.
          return;
        }
        // A different waiting task may have consumed the shared result.  The
        // picker is closed now, so continue below and request this task's
        // concrete capability instead of incorrectly marking it authorized.
      }
      WorkFolderRequestResult result;
      try {
        result = await grantService.requestFolder(
          picker: picker,
          requestedPath: _requestedFolderPath(task),
          forcePicker: true,
          requireWritable: _requiresWritableFolder(task),
          consent: _folderGrantConsent,
        );
      } on Object catch (error) {
        final failure = WorkFailure.fromError(
          error,
          scope: 'authorization',
          completedContent: _completedContentForTask(task),
        );
        _applyFailure(
          task,
          WorkFailure.fromToolFailure(
            code: 'authorizationLost',
            message: '工作目录授权请求失败，请重新选择目录。',
            completedContent: failure.completedContent,
          ),
          status: AgentTaskStatus.paused,
          clearPendingTool: false,
        );
        await _save(task);
        await _record(
          task,
          WorkTaskEventKind.paused,
          '等待工作目录授权',
          detail: failure.technicalDetail,
        );
        return;
      }
      if (!result.granted) {
        final failure = WorkFailure.fromToolFailure(
          code: 'authorizationLost',
          message: result.reason.isEmpty ? '未完成工作目录授权。' : result.reason,
          completedContent: _completedContentForTask(task),
        );
        _applyFailure(
          task,
          failure,
          status: AgentTaskStatus.paused,
          clearPendingTool: false,
        );
        await _save(task);
        await _record(
          task,
          WorkTaskEventKind.paused,
          '等待工作目录授权',
          detail: failure.technicalDetail,
        );
        return;
      }
      await _rebindWorkspaceAfterGrant(task, result.grant);
      _conversationReservations.remove(task.groupId);
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..lastError = ''
        ..executionStateJson = _withoutFolderRequest(task.executionStateJson)
        ..updatedAt = _clock();
      await _save(task);
      _enqueueTask(task);
      await _schedule();
    });
  }

  Future<void> _resolveApproval(String taskId, String decision) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.waitingForApproval ||
          task.pendingToolRequestJson.trim().isEmpty) {
        throw StateError('当前任务没有待处理的工具审批。');
      }
      final parsedDecision = WorkChangeApprovalDecision.fromWire(decision);
      if (parsedDecision == null) {
        throw ArgumentError.value(decision, 'decision', '审批决定无效');
      }
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..executionStateJson = _withApprovalDecision(
          task.executionStateJson,
          decision,
        )
        ..updatedAt = _clock();
      _conversationReservations.remove(task.groupId);
      _folderWaiters.remove(task.id)?.cancel();
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(
        task,
        WorkTaskEventKind.queued,
        parsedDecision.permitsExecution
            ? parsedDecision.permitsWithoutUndo
                ? '用户已批准无撤销执行，继续执行'
                : '用户已批准，继续执行'
            : '用户已拒绝，尝试安全替代路径',
      ));
      await _schedule();
    });
  }

  /// Stops only the requested task. Other conversations keep their slots.
  Future<void> stop(String taskId, {String reason = '用户已停止任务。'}) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.isTerminal) {
        throw StateError('终态任务不能停止。');
      }
      _removeQueuedTask(task);
      // Cancel before mutating the shared Hive object so a late progress
      // callback observes the cancellation and cannot resurrect running state.
      _running[taskId]?.cancellation.cancel();
      _folderWaiters.remove(taskId)?.cancel();
      final waiting = _waitingForResources.remove(taskId);
      waiting?.cancellation.cancel();
      final waitingLease = waiting?.lease;
      if (waitingLease != null) unawaited(waitingLease.release());
      _conversationReservations.remove(task.groupId);
      _makeConversationReady(task.groupId);
      _taskLockPlans.remove(taskId);
      task
        ..status = AgentTaskStatus.cancelled
        ..resumeRequired = false
        ..pendingToolRequestJson = ''
        ..queuedUserRequests = <String>[]
        ..lastError = sanitizeWorkTaskError(reason)
        ..updatedAt = _clock();
      await _save(task);
      await _markSnapshotStatus(task);
      unawaited(
        _record(task, WorkTaskEventKind.failed, '任务已停止', detail: reason),
      );
      await _schedule();
    });
  }

  /// Queues an interrupted or paused task only after an explicit user action.
  Future<void> resumeByUser(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (task.status != AgentTaskStatus.interrupted &&
          task.status != AgentTaskStatus.paused) {
        throw StateError('当前任务不需要手动继续。');
      }
      if (task.status == AgentTaskStatus.paused &&
          _isFollowUpClarification(task)) {
        // A clarification pause is waiting for the user's target answer, not
        // a generic task restart. Resuming it would run the old request while
        // leaving the ambiguous FIFO head untouched.
        throw StateError('请先明确要修改的文件路径，再继续任务。');
      }
      if (_requiresExplicitCommandRequest(task)) {
        throw StateError('请发送明确的测试、构建或分析请求后再继续任务。');
      }
      if (_requiresMissingToolAction(task)) {
        throw StateError(
          '当前任务依赖的工具尚未安装；请先处理安装提示，或改用已存在的工具后重新发起任务。',
        );
      }
      if (_requiresVisionModelSelection(task)) {
        throw StateError('请先选择支持图片的视觉模型后再继续任务。');
      }
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..lastError = ''
        // The durable request is redacted and may contain stale paths or
        // content. A manual restart always asks the model to re-plan against
        // current state; only the in-process approval continuation can replay
        // its full request.
        ..pendingToolRequestJson = ''
        // A pending request payload is intentionally not persisted in full.
        // A manual restart must re-plan against the current filesystem and
        // grant state; never reuse a stale path scope.
        ..executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        )
        ..updatedAt = _clock();
      _conversationReservations.remove(task.groupId);
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '用户已继续任务'));
      await _schedule();
    });
  }

  /// Retries a classified failure from the last durable checkpoint.
  ///
  /// The failure marker is intentionally kept while the task is queued so the
  /// panel can still explain why it stopped. [WorkAgentLoop] removes it only
  /// when a new attempt actually starts. Completed operation keys and artifact
  /// paths are never reset, so a committed mutation cannot be replayed.
  Future<void> retry(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (_running.containsKey(taskId) || _startingTaskIds.contains(taskId)) {
        throw StateError('任务正在执行，不能同时重试。');
      }
      final restartFromBeginning = canRestartAfterUserStop(task);
      if ((task.status == AgentTaskStatus.cancelled && !restartFromBeginning) ||
          task.status == AgentTaskStatus.completed) {
        throw StateError('已停止或已完成的任务不能重试。');
      }

      if (restartFromBeginning) {
        _removeQueuedTask(task);
        _waitingForResources.remove(taskId)?.cancellation.cancel();
        _folderWaiters.remove(taskId)?.cancel();
        _conversationReservations.remove(task.groupId);
        _taskLockPlans.remove(taskId);
        task
          ..status = AgentTaskStatus.queued
          ..resumeRequired = false
          ..plan = ''
          ..resultSummary = ''
          ..currentStep = 0
          ..completedOperations = <String>[]
          ..pendingToolRequestJson = ''
          ..queuedUserRequests = <String>[]
          ..contextSummary = ''
          ..lastError = ''
          ..startedAt = _clock()
          ..actionCount = 0
          ..softLimitReached = false
          ..executionStateJson = ''
          ..lastArtifactPaths = <String>[]
          ..eventLogIncomplete = false
          ..updatedAt = _clock();
        await _save(task);
        await _markSnapshotStatus(task);
        _enqueueTask(task);
        await _record(
          task,
          WorkTaskEventKind.queued,
          '已请求从头开始执行',
          detail: '上次停止前未提交文件变更，已清空运行检查点。',
        );
        await _schedule();
        return;
      }

      final failure = task.workFailure;
      if (failure == null) {
        throw StateError('当前任务没有可重试的结构化失败。');
      }
      if (!failure.retryable) {
        throw StateError(failure.suggestedAction);
      }
      _removeQueuedTask(task);
      _waitingForResources.remove(taskId)?.cancellation.cancel();
      _folderWaiters.remove(taskId)?.cancel();
      _conversationReservations.remove(task.groupId);
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..pendingToolRequestJson = ''
        ..updatedAt = _clock();
      _refreshTaskContext(
        task,
        nextStep: '已请求重试：${failure.suggestedAction}',
        extraErrors: [failure.reason],
      );
      await _save(task);
      _enqueueTask(task);
      await _record(
        task,
        WorkTaskEventKind.queued,
        '已请求重试，继续最近安全检查点',
        detail: failure.reason,
      );
      await _schedule();
    });
  }

  Future<void> retryTask(String taskId) => retry(taskId);

  /// Switches the current task to a user-selected visual character and
  /// resumes the same durable task. Production runners implement the optional
  /// validator so a caller cannot bypass the panel's capability list.
  Future<void> selectVisionModel(String taskId, String characterId) {
    return _serialize(() async {
      _ensureOpen();
      final normalized = characterId.trim();
      if (normalized.isEmpty) {
        throw ArgumentError.value(characterId, 'characterId');
      }
      final task = _requireWorkTask(taskId);
      if (!_requiresVisionModelSelection(task)) {
        throw StateError('当前任务不在等待视觉模型选择的状态。');
      }
      if (task.status != AgentTaskStatus.paused &&
          task.status != AgentTaskStatus.interrupted) {
        throw StateError('当前任务不在等待视觉模型选择的状态。');
      }
      if (_runner case final WorkTaskVisionModelValidator validator) {
        if (!validator.supportsVisionModelForTask(task, normalized)) {
          throw StateError('所选角色不是可用的视觉模型。');
        }
      } else {
        throw StateError('当前执行器无法验证视觉模型，已阻止继续。');
      }
      final execution = _decodeExecutionMap(task.executionStateJson)
        ..['visionModelRequired'] = false
        ..['visionModelCharacterId'] = normalized;
      task
        ..characterId = normalized
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..lastError = ''
        ..pendingToolRequestJson = ''
        ..executionStateJson = jsonEncode(execution)
        ..updatedAt = _clock();
      _conversationReservations.remove(task.groupId);
      await _save(task);
      _enqueueTask(task);
      unawaited(_record(task, WorkTaskEventKind.queued, '已选择视觉模型并继续任务'));
      await _schedule();
    });
  }

  /// Grants a fresh soft-limit budget only after the user chooses to continue.
  Future<void> continueAfterSoftLimit(String taskId) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      if (_running.containsKey(taskId)) {
        throw StateError('任务正在收尾，请稍后再点继续。');
      }
      if (!task.softLimitReached ||
          (task.status != AgentTaskStatus.paused &&
              task.status != AgentTaskStatus.interrupted)) {
        throw StateError('当前任务不在等待超限继续的状态。');
      }
      task
        ..status = AgentTaskStatus.queued
        ..actionCount = 0
        ..startedAt = _clock()
        ..softLimitReached = false
        ..resumeRequired = false
        ..lastError = ''
        ..executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        )
        ..updatedAt = _clock();
      await _save(task);
      _enqueueTask(task);
      unawaited(
        _record(task, WorkTaskEventKind.queued, '用户已继续超限任务'),
      );
      await _schedule();
    });
  }

  /// Reloads durable task state without invoking any runner automatically.
  Future<void> restore() {
    return _serialize(() async {
      _ensureOpen();
      for (final task in _allWorkTasks()) {
        // A process restart invalidates every in-memory runner and lock. Only
        // an explicit user continuation may re-plan and reacquire resources.
        if (!_running.containsKey(task.id) &&
            !_waitingForResources.containsKey(task.id) &&
            !task.isTerminal &&
            task.status != AgentTaskStatus.paused &&
            task.status != AgentTaskStatus.interrupted) {
          _applyFailure(
            task,
            WorkFailure.fromSignalsForUserAction(
              '应用已关闭，请由用户手动继续任务。',
              completedContent: _completedContentForTask(task),
            ),
            status: AgentTaskStatus.interrupted,
            clearPendingTool: false,
          );
          await _save(task);
        }
        if (task.status == AgentTaskStatus.paused &&
            _isFollowUpClarification(task)) {
          // An unanswered target question still owns this conversation. A
          // second task must not bypass it while the user is deciding which
          // artifact the queued revision may overwrite.
          _conversationReservations.add(task.groupId);
        }
        _publish(task);
      }
    });
  }

  Stream<AgentTask> watchTask(String taskId) async* {
    final initial = _taskBox.get(taskId);
    if (initial != null && initial.workModeTask) yield initial;
    yield* _taskUpdates.stream
        .where((task) => task.id == taskId)
        .map((task) => task);
  }

  Stream<List<AgentTask>> watchAllTasks() async* {
    yield _allWorkTasks();
    yield* _taskUpdates.stream.map((_) => _allWorkTasks());
  }

  /// The app scope can release listeners at shutdown; it deliberately does
  /// not stop active work merely because a chat room disappeared.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    for (final running in _running.values) {
      running.cancellation.cancel();
    }
    for (final waiting in _waitingForResources.values) {
      waiting.cancellation.cancel();
      final lease = waiting.lease;
      if (lease != null) unawaited(lease.release());
    }
    for (final cancellation in _folderWaiters.values) {
      cancellation.cancel();
    }
    _folderWaiters.clear();
    _waitingForResources.clear();
    _conversationReservations.clear();
    _handoffsAwaitingLease.clear();
    _taskLockPlans.clear();
    _notifySlotAvailable();
    _readyConversations.clear();
    _readyConversationIds.clear();
    _conversationQueues.clear();
    final drain = Future.wait<void>(_activeRuns.values, eagerError: false)
        .then<void>((_) async {
      if (!_taskUpdates.isClosed) await _taskUpdates.close();
    });
    _disposeFuture = drain;
    return drain;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final scheduled = _operations.then((_) => operation());
    _operations = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return scheduled;
  }

  Future<void> _schedule() async {
    if (_disposed || _dataClearInProgress) return;
    while (!_disposed &&
        !_dataClearInProgress &&
        _running.length + _startingTaskIds.length < maximumConcurrentTasks) {
      final task = _takeNextTask();
      if (task == null) return;
      // A native directory picker is user-driven and can remain open for an
      // arbitrary time. Do not hold the serialized submit operation while it
      // is open: another conversation must still be able to claim the second
      // global slot and start (or wait for its own grant) independently.
      if (_folderGrantService != null || _requireFolderGrant) {
        _launchStart(task);
      } else {
        await _start(task);
      }
    }
  }

  void _launchStart(AgentTask task) {
    _startingTaskIds.add(task.id);
    final start = _start(task);
    unawaited(
      start.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) async {
          await _handleStartFailure(task, error);
        },
      ).whenComplete(() {
        _startingTaskIds.remove(task.id);
        if (!_disposed && !_dataClearInProgress) unawaited(_schedule());
      }),
    );
  }

  Future<void> _handleStartFailure(AgentTask task, Object error) async {
    if (_disposed) return;
    try {
      await _serialize(() async {
        _folderWaiters.remove(task.id)?.cancel();
        _conversationReservations.remove(task.groupId);
        final stored = _taskBox.get(task.id);
        if (stored != null && !stored.isTerminal) {
          final failure = WorkFailure.fromError(
            error,
            scope: 'start',
            completedContent: _completedContentForTask(stored),
          );
          _applyFailure(stored, failure);
          await _save(stored);
          unawaited(
            _record(
              stored,
              WorkTaskEventKind.failed,
              '任务启动失败',
              detail: failure.technicalDetail,
            ),
          );
        }
        _makeConversationReady(task.groupId);
      });
    } on Object {
      // A startup persistence failure must not become an unhandled async
      // error. The durable task state remains authoritative when available.
    }
  }

  AgentTask? _takeNextTask() {
    while (_readyConversations.isNotEmpty) {
      final conversationId = _readyConversations.removeFirst();
      _readyConversationIds.remove(conversationId);
      if (_hasRunningConversation(conversationId)) continue;
      final queue = _conversationQueues[conversationId];
      if (queue == null) continue;
      while (queue.isNotEmpty) {
        final taskId = queue.removeFirst();
        final task = _taskBox.get(taskId);
        if (task == null ||
            !task.workModeTask ||
            task.status != AgentTaskStatus.queued) {
          continue;
        }
        if (queue.isEmpty) _conversationQueues.remove(conversationId);
        return task;
      }
      _conversationQueues.remove(conversationId);
    }
    return null;
  }

  Future<void> _start(AgentTask task) async {
    if (_disposed || _dataClearInProgress) return;
    final cancellation = WorkTaskCancellation();
    _conversationReservations.add(task.groupId);
    _folderWaiters[task.id] = cancellation;
    // The first task may be the one that opens the OS folder picker. Resolve
    // that grant before planning locks; otherwise the planner sees an empty
    // grant list, starts without a lease, and only obtains the directory after
    // the runner has already crossed the mutation boundary.
    if ((_folderGrantService != null || _requireFolderGrant) &&
        !await _ensureFolderGrant(task, cancellation)) {
      _folderWaiters.remove(task.id);
      // The picker was resolved before a runner/lease was started. A denied
      // or unavailable grant therefore has no waiter that should hold the
      // conversation reservation; release it so a later manual continuation
      // (or another queued task in the conversation) is not deadlocked.
      _conversationReservations.remove(task.groupId);
      cancellation.cancel();
      _makeConversationReady(task.groupId);
      return;
    }
    _folderWaiters.remove(task.id);
    if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
      cancellation.cancel();
      _conversationReservations.remove(task.groupId);
      _makeConversationReady(task.groupId);
      return;
    }
    late final List<WorkResourceLockRequest> locks;
    try {
      locks = _resourceLocksFor(task);
    } on Object catch (error) {
      await _failInvalidResourcePlan(task, error);
      return;
    }

    if (locks.isNotEmpty) {
      WorkResourceLockLease? lease;
      try {
        lease = _resourceLockManager.tryAcquire(task.id, locks);
      } on Object catch (error) {
        await _failInvalidResourcePlan(task, error);
        return;
      }
      if (lease == null) {
        await _waitForResource(task, cancellation, locks);
        return;
      }
      await _startRunning(task, cancellation, lease);
      return;
    }

    await _startRunning(task, cancellation, null);
  }

  Future<void> _failInvalidResourcePlan(AgentTask task, Object error) async {
    _conversationReservations.remove(task.groupId);
    _applyFailure(
      task,
      WorkFailure.fromError(
        error,
        scope: 'resource',
        completedContent: _completedContentForTask(task),
      ),
    );
    await _save(task);
    unawaited(_record(task, WorkTaskEventKind.failed, '资源锁计划无效'));
    _makeConversationReady(task.groupId);
    await _schedule();
  }

  Future<void> _startRunning(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkResourceLockLease? lease,
  ) async {
    if (_disposed || _dataClearInProgress) {
      cancellation.cancel();
      _conversationReservations.remove(task.groupId);
      if (lease != null) await lease.release();
      return;
    }
    _running[task.id] = _RunningTask(task: task, cancellation: cancellation);
    var runStarted = false;
    try {
      task
        ..status = AgentTaskStatus.planning
        ..startedAt ??= _clock()
        ..updatedAt = _clock();
      await _save(task);
      await _markSnapshotStatus(task);
      if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
        cancellation.cancel();
        return;
      }
      unawaited(_record(task, WorkTaskEventKind.planning, '任务开始执行'));
      final run = _runWithLease(task, cancellation, lease);
      _activeRuns[task.id] = run;
      runStarted = true;
      unawaited(
        run.then<void>(
          (_) => _removeActiveRun(task.id, run),
          onError: (Object _, StackTrace __) => _removeActiveRun(task.id, run),
        ),
      );
    } finally {
      if (!runStarted) {
        _running.remove(task.id);
        _conversationReservations.remove(task.groupId);
        cancellation.cancel();
        if (lease != null) await lease.release();
        _notifySlotAvailable();
      }
    }
  }

  List<WorkResourceLockRequest> _resourceLocksFor(AgentTask task) {
    final explicit = _taskLockPlans[task.id];
    if (explicit != null) return List<WorkResourceLockRequest>.from(explicit);
    final persisted = _persistedResourceLocks(task.executionStateJson);
    if (persisted != null) {
      _taskLockPlans[task.id] = persisted;
      return List<WorkResourceLockRequest>.from(persisted);
    }
    final callback = _resourceLockPlan;
    if (callback != null) {
      return _normalizeAndPersistResourceLocks(task, callback(task));
    }
    if (_runner case final WorkTaskResourceLockPlanner planner) {
      return _normalizeAndPersistResourceLocks(
        task,
        planner.planResourceLocks(task),
      );
    }
    return const <WorkResourceLockRequest>[];
  }

  List<WorkResourceLockRequest> _normalizeAndPersistResourceLocks(
    AgentTask task,
    Iterable<WorkResourceLockRequest> planned,
  ) {
    final normalized = _resourceLockManager.normalizeLockSet(planned);
    if (normalized.isEmpty) return const <WorkResourceLockRequest>[];
    _taskLockPlans[task.id] = normalized;
    // The runner may be created after a process restart, so the first plan
    // computed from the current grant must be persisted before execution can
    // cross the file boundary. _startRunning saves this same task object.
    task.executionStateJson = _withResourceLockPlan(
      task.executionStateJson,
      normalized,
    );
    return List<WorkResourceLockRequest>.from(normalized);
  }

  Future<void> _waitForResource(
    AgentTask task,
    WorkTaskCancellation cancellation,
    List<WorkResourceLockRequest> locks,
  ) async {
    final waiting = _WaitingResourceTask(
      task: task,
      cancellation: cancellation,
    );
    _waitingForResources[task.id] = waiting;
    task
      ..status = AgentTaskStatus.queued
      ..updatedAt = _clock();
    await _save(task);
    final conflict =
        _resourceLockManager.conflictPath(locks) ?? locks.first.path;
    final safePath = _safeLockPath(conflict);
    await _record(
      task,
      WorkTaskEventKind.queued,
      '等待另一个任务释放 $safePath',
      detail: '资源锁等待不会增加 Agent 动作数。',
    );
    unawaited(_awaitResourceLease(waiting, locks));
  }

  Future<void> _awaitResourceLease(
    _WaitingResourceTask waiting,
    List<WorkResourceLockRequest> locks,
  ) async {
    final task = waiting.task;
    try {
      final lease = await _resourceLockManager.acquire(
        task.id,
        locks,
        cancellation: waiting.cancellation.whenCancelled,
        isCancelled: () => waiting.cancellation.isCancelled,
      );
      if (!_isWaiting(waiting) ||
          _disposed ||
          _dataClearInProgress ||
          waiting.cancellation.isCancelled ||
          _taskBox.get(task.id)?.status != AgentTaskStatus.queued) {
        await lease.release();
        return;
      }
      waiting.lease = lease;
      while (!_disposed &&
          _running.length >= maximumConcurrentTasks &&
          !waiting.cancellation.isCancelled) {
        await Future.any<void>([
          _waitForSlot(),
          waiting.cancellation.whenCancelled,
        ]);
      }
      if (!_isWaiting(waiting) ||
          _disposed ||
          _dataClearInProgress ||
          waiting.cancellation.isCancelled ||
          _taskBox.get(task.id)?.status != AgentTaskStatus.queued) {
        await lease.release();
        return;
      }
      _waitingForResources.remove(task.id);
      _startingTaskIds.add(task.id);
      try {
        await _startRunning(task, waiting.cancellation, lease);
      } finally {
        _startingTaskIds.remove(task.id);
      }
    } on WorkResourceLockCancelled {
      _dropWaiting(waiting);
    } on Object catch (error) {
      await _failResourceWait(waiting, error);
    }
  }

  Future<void> _failResourceWait(
    _WaitingResourceTask waiting,
    Object error,
  ) async {
    await _serialize(() async {
      if (!_isWaiting(waiting) || _disposed || _dataClearInProgress) return;
      _dropWaiting(waiting);
      final stored = _taskBox.get(waiting.task.id);
      if (stored == null || stored.isTerminal) return;
      _applyFailure(
        stored,
        WorkFailure.fromError(
          error,
          scope: 'resource',
          completedContent: _completedContentForTask(stored),
        ),
      );
      await _save(stored);
      unawaited(
        _record(stored, WorkTaskEventKind.failed, '资源锁等待失败'),
      );
      _makeConversationReady(stored.groupId);
      await _schedule();
    });
  }

  bool _isWaiting(_WaitingResourceTask waiting) =>
      identical(_waitingForResources[waiting.task.id], waiting);

  void _dropWaiting(_WaitingResourceTask waiting) {
    if (!_isWaiting(waiting)) return;
    _waitingForResources.remove(waiting.task.id);
    _conversationReservations.remove(waiting.task.groupId);
    _makeConversationReady(waiting.task.groupId);
  }

  Future<void> _runWithLease(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkResourceLockLease? lease,
  ) async {
    try {
      await _run(task, cancellation);
    } finally {
      try {
        if (lease != null) await lease.release();
      } finally {
        await _releaseHandoffAfterLease(task);
      }
    }
  }

  Future<void> _releaseHandoffAfterLease(AgentTask task) async {
    if (!_handoffsAwaitingLease.contains(task.id)) return;
    if (_disposed || _dataClearInProgress) {
      _handoffsAwaitingLease.remove(task.id);
      _conversationReservations.remove(task.groupId);
      return;
    }
    await _serialize(() async {
      if (!_handoffsAwaitingLease.remove(task.id)) return;
      _conversationReservations.remove(task.groupId);
      if (_disposed || _dataClearInProgress) return;
      _makeConversationReady(task.groupId);
      await _schedule();
    });
  }

  Future<void> _run(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    Object? error;
    StackTrace? stackTrace;
    try {
      if ((_folderGrantService != null || _requireFolderGrant) &&
          !await _ensureFolderGrant(task, cancellation)) {
        await _serialize(() async {
          _running.remove(task.id);
          final stored = _taskBox.get(task.id);
          if (!_disposed &&
              !cancellation.isCancelled &&
              stored != null &&
              !stored.isTerminal) {
            _folderWaiters[task.id] = cancellation;
          } else {
            _folderWaiters.remove(task.id);
          }
          // A failed revalidation is a paused boundary, not an active run.
          // Release the conversation reservation so a later manual resume or
          // another queued task cannot be permanently starved by a stale
          // folder picker/authorization state.
          _conversationReservations.remove(task.groupId);
          _makeConversationReady(task.groupId);
          _notifySlotAvailable();
        });
        return;
      }
      await _runner.run(task, cancellation);
    } on Object catch (caught, trace) {
      error = caught;
      stackTrace = trace;
    }
    // Disposal is cooperative, but the runner may finish one microtask after
    // cancellation. Never touch Hive or the event store after shutdown starts.
    if (_disposed) return;
    await _serialize(() async {
      if (_disposed) return;
      final running = _running[task.id];
      if (running == null || !identical(running.cancellation, cancellation)) {
        return;
      }
      _running.remove(task.id);
      _notifySlotAvailable();
      final stored = _taskBox.get(task.id);
      if (stored == null) {
        _conversationReservations.remove(task.groupId);
        await _schedule();
        return;
      }

      if (error != null && !stored.isTerminal) {
        final failure = WorkFailure.fromError(
          error,
          scope: 'runner',
          completedContent: _completedContentForTask(stored),
        );
        _applyFailure(stored, failure);
        await _save(stored);
        unawaited(_record(
          stored,
          WorkTaskEventKind.failed,
          '任务执行失败',
          detail: failure.technicalDetail,
        ));
      } else if (!stored.isTerminal &&
          stored.status != AgentTaskStatus.queued &&
          stored.status != AgentTaskStatus.paused &&
          stored.status != AgentTaskStatus.interrupted &&
          stored.status != AgentTaskStatus.waitingForApproval) {
        stored
          ..status = AgentTaskStatus.completed
          ..updatedAt = _clock();
        await _save(stored);
        unawaited(
          _record(stored, WorkTaskEventKind.completed, '任务已完成'),
        );
      }

      // Fake and production runners may finish on different persistence
      // boundaries. Refresh the canonical Task 15 summary after the terminal
      // status is known so a result/error is still recoverable when a runner
      // did not publish its own checkpoint callback.
      final handedOff = _advanceCompletedHandoff(stored);
      _refreshTaskContext(
        stored,
        nextStep: handedOff
            ? '当前阶段已完成，下一角色将在释放资源后接手。'
            : stored.isTerminal
                ? '已完成，可继续追问。'
                : null,
      );
      await _save(stored);

      // A follow-up is promoted only after a successful stage. Failures and
      // pauses must leave the FIFO untouched so the recovery action can resume
      // the same checkpoint before any later request changes the task context.
      if (!handedOff && stored.status == AgentTaskStatus.completed) {
        await _promoteQueuedFollowUp(stored);
      }
      await _markSnapshotStatus(stored);

      final holdConversation = !handedOff &&
          !stored.isTerminal &&
          (stored.status == AgentTaskStatus.waitingForApproval ||
              stored.status == AgentTaskStatus.paused ||
              stored.status == AgentTaskStatus.interrupted);
      if (!holdConversation && !handedOff) {
        _conversationReservations.remove(task.groupId);
      }
      _folderWaiters.remove(task.id);

      if (stackTrace != null) {
        // The public event only contains the error message; stack traces stay
        // out of persisted task output and can be surfaced by a future logger.
      }
      if (handedOff) {
        // Keep the conversation reservation until _runWithLease releases the
        // previous role's resource lease. This remains serial even when a
        // stage has no explicit file lock plan (for example a skill-only
        // stage), so the next role cannot start in the same microtask.
        _handoffsAwaitingLease.add(task.id);
        _enqueueTask(stored);
        unawaited(_record(
          stored,
          WorkTaskEventKind.queued,
          '当前阶段完成，已排队下一角色接手',
          detail: stored.characterId,
        ));
      } else {
        _makeConversationReady(task.groupId);
      }
      await _schedule();
    });
  }

  /// Promotes a routed task to its next role after the current runner returns.
  /// Keeping this transition in the coordinator guarantees that one
  /// conversation never runs two assigned roles at the same time.
  bool _advanceCompletedHandoff(AgentTask task) {
    // A failed, cancelled or partially-completed stage must remain terminal;
    // only an actual successful stage completion may release the next role.
    if (!task.workModeTask || task.status != AgentTaskStatus.completed) {
      return false;
    }
    final state = WorkHandoffState.fromTask(task);
    if (state == null || state.isComplete) return false;
    try {
      if (!state.needsHandoff) {
        // Persist the terminal marker for the last stage as well. This keeps
        // a restarted task from looking as if it could still be handed off.
        WorkHandoffState.persistToTask(
          task,
          state.advance(
            previousRoleReleased: true,
            deliveredArtifacts: task.lastArtifactPaths,
            summary: task.resultSummary,
          ),
        );
        return false;
      }
      final waiting = state.advance(
        previousRoleReleased: true,
        deliveredArtifacts: task.lastArtifactPaths,
        summary: task.resultSummary,
      );
      final active = waiting.activateReceiver();
      task
        ..characterId = active.currentRoleId
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..pendingToolRequestJson = ''
        ..resultSummary = ''
        ..lastError = ''
        // The action/time budget belongs to the durable task, not to an
        // individual role.  A handoff must not reset it and thereby let a
        // product→developer→tester chain exceed the global 100/60-minute
        // safety boundary.
        ..softLimitReached = false;
      WorkHandoffState.persistToTask(task, active);
      return true;
    } on Object catch (error) {
      _applyFailure(
        task,
        WorkFailure.fromError(
          error,
          scope: 'handoff',
          completedContent: _completedContentForTask(task),
        ),
      );
      return false;
    }
  }

  Future<bool> _ensureFolderGrant(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    final grantService = _folderGrantService;
    if (grantService == null) {
      if (!_requireFolderGrant) return true;
      final failure = WorkFailure.fromToolFailure(
        code: 'authorizationLost',
        message: '工作目录授权服务不可用，请检查应用设置后重试。',
        completedContent: _completedContentForTask(task),
      );
      _applyFailure(
        task,
        failure,
        status: AgentTaskStatus.paused,
        clearPendingTool: false,
      );
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.paused,
        '工作目录授权不可用',
        detail: failure.technicalDetail,
      );
      return false;
    }
    try {
      await grantService.load();
    } on Object catch (error) {
      final failure = WorkFailure.fromError(
        error,
        scope: 'authorization',
        completedContent: _completedContentForTask(task),
      );
      _applyFailure(
        task,
        failure.type == WorkFailureType.internal
            ? WorkFailure.fromToolFailure(
                code: 'authorizationLost',
                message: '工作目录授权校验失败，请重新授权。',
                completedContent: _completedContentForTask(task),
              )
            : failure,
        status: AgentTaskStatus.paused,
        clearPendingTool: false,
      );
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.paused,
        '工作目录授权校验失败',
        detail:
            task.workFailure?.technicalDetail ?? sanitizeWorkTaskError(error),
      );
      return false;
    }
    if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
      return false;
    }
    final requestedPath = _requestedFolderPath(task);
    final requiresWritable = _requiresWritableFolder(task);
    if (requestedPath == null &&
        (requiresWritable
            ? grantService.hasConfirmedWritableGrant()
            : grantService.hasConfirmedAvailableGrant())) {
      if (requiresWritable) {
        // Keep the workspace capability requirement for the runner even when
        // an already-authorized writable root satisfies this task. A prior
        // read-only conversation workspace must still be replaced before a
        // write is attempted.
        task.executionStateJson = _withWritableRequirementMarker(
          task.executionStateJson,
        );
        await _save(task);
      }
      return true;
    }
    if (requestedPath != null &&
        (requiresWritable
            ? await grantService.isPathWritableResolved(requestedPath)
            : await grantService.isPathAuthorizedResolved(requestedPath))) {
      if (requiresWritable) {
        task.executionStateJson = _withWritableRequirementMarker(
          task.executionStateJson,
        );
      }
      task.executionStateJson = _withoutFolderRequest(task.executionStateJson);
      await _save(task);
      return true;
    }

    task
      ..status = AgentTaskStatus.waitingForApproval
      ..resumeRequired = false
      // Keep a durable UI marker even when the first request has no concrete
      // path yet. The execution panel must expose the folder picker instead
      // of rendering an approval/continue action that cannot succeed.
      ..executionStateJson = _withFolderGrantPending(
        task.executionStateJson,
        requestedPath,
        requiresWritable: requiresWritable,
      )
      ..updatedAt = _clock();
    await _save(task);
    await _record(
      task,
      WorkTaskEventKind.approvalRequired,
      '需要授权工作目录',
      detail: requestedPath == null
          ? '首次执行工作模式前，需要选择一个 App 级工作目录。'
          : '请求路径未被现有授权覆盖，需要选择其所在目录。',
    );
    if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
      return false;
    }

    final requestResult = await _requestFolder(
      grantService,
      task: task,
      requestedPath: requestedPath,
    );
    if (_disposed || _dataClearInProgress || cancellation.isCancelled) {
      return false;
    }
    if (requestResult.granted) {
      await _rebindWorkspaceAfterGrant(task, requestResult.grant);
      task
        ..status = AgentTaskStatus.planning
        ..resumeRequired = false
        ..lastError = ''
        ..executionStateJson = _withoutFolderRequest(task.executionStateJson)
        ..updatedAt = _clock();
      await _save(task);
      return true;
    }

    // The execution panel can finish a second, explicit picker request while
    // this initial request is unwinding from a cancellation.  In that case
    // the panel has already persisted a queued task and removed the durable
    // folder-pending marker.  Do not let this stale cancellation overwrite
    // the newly authorized state with a paused error; the panel-owned queue
    // will start the task with the confirmed grant.
    final currentState = _decodeExecutionMap(task.executionStateJson);
    if (task.status == AgentTaskStatus.queued &&
        currentState['folderGrantPending'] != true &&
        _requestedFolderPath(task) == null) {
      return false;
    }

    final reason =
        requestResult.reason.isEmpty ? '未完成工作目录授权。' : requestResult.reason;
    final failure = WorkFailure.fromToolFailure(
      code: 'authorizationLost',
      message: reason,
      completedContent: _completedContentForTask(task),
    );
    _applyFailure(
      task,
      failure,
      status: AgentTaskStatus.paused,
      clearPendingTool: false,
    );
    await _save(task);
    await _record(task, WorkTaskEventKind.paused, '等待工作目录授权', detail: reason);
    return false;
  }

  Future<void> _rebindWorkspaceAfterGrant(
    AgentTask task,
    WorkFolderGrant? grant,
  ) async {
    final path = grant?.path.trim() ?? '';
    final runner = _runner;
    if (path.isEmpty || runner is! WorkTaskWorkspaceRebinder) return;
    await (runner as WorkTaskWorkspaceRebinder).rebindWorkspace(task, path);
  }

  Future<WorkFolderRequestResult> _requestFolder(
    WorkFolderGrantService grantService, {
    required AgentTask task,
    String? requestedPath,
  }) async {
    final existing = _folderRequest;
    if (existing != null) {
      // A native picker is process-global, but its result is not necessarily
      // suitable for every waiting task.  One task may be asking for a
      // read-only root while another is waiting for a different writable
      // path.  Reuse the in-flight result only when it actually covers this
      // request; otherwise open a second picker after the first one closes.
      final sharedResult = await existing;
      if (!sharedResult.granted) return sharedResult;
      final requested = requestedPath?.trim();
      final requiresWritable = _requiresWritableFolder(task);
      final grant = sharedResult.grant;
      final covers = requested == null || requested.isEmpty
          ? grant != null && (!requiresWritable || grant.writable)
          : requiresWritable
              ? await grantService.isPathWritableResolved(requested)
              : await grantService.isPathAuthorizedResolved(requested);
      if (covers) return sharedResult;
      // The selected directory belongs to another task's request.  Falling
      // through is intentional: the picker future has completed, so this is
      // no longer a concurrent native dialog.
    }
    final request = _folderPicker == null
        ? Future<WorkFolderRequestResult>.value(
            const WorkFolderRequestResult(
              status: WorkFolderRequestStatus.unavailable,
              reason: '当前没有可用的目录选择器。',
            ),
          )
        : grantService.requestFolder(
            picker: _folderPicker,
            requestedPath: requestedPath,
            forcePicker: requestedPath != null,
            requireWritable: _requiresWritableFolder(task),
            consent: _folderGrantConsent,
          );
    _folderRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_folderRequest, request)) _folderRequest = null;
    }
  }

  void _enqueueTask(AgentTask task) {
    final queue = _conversationQueues.putIfAbsent(task.groupId, Queue.new);
    if (!queue.contains(task.id)) queue.addLast(task.id);
    if (!_hasRunningConversation(task.groupId)) {
      _makeConversationReady(task.groupId);
    }
  }

  void _removeQueuedTask(AgentTask task) {
    final queue = _conversationQueues[task.groupId];
    if (queue == null) return;
    queue.remove(task.id);
    if (queue.isEmpty) _conversationQueues.remove(task.groupId);
  }

  void _makeConversationReady(String conversationId) {
    final queue = _conversationQueues[conversationId];
    if (queue == null ||
        queue.isEmpty ||
        _hasRunningConversation(conversationId)) {
      return;
    }
    if (_readyConversationIds.add(conversationId)) {
      _readyConversations.addLast(conversationId);
    }
  }

  bool _hasRunningConversation(String conversationId) =>
      _conversationReservations.contains(conversationId) ||
      _running.values.any((running) => running.task.groupId == conversationId);

  Future<void> _waitForSlot() {
    if (_disposed || _running.length < maximumConcurrentTasks) {
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _slotWaiters.addLast(waiter);
    return waiter.future;
  }

  void _notifySlotAvailable() {
    if (!_disposed && _running.length >= maximumConcurrentTasks) return;
    while (_slotWaiters.isNotEmpty) {
      final waiter = _slotWaiters.removeFirst();
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  String _safeLockPath(String path) => WorkFolderGrantService.displayNameFor(
        path,
        isWindows: _resourceLockManager.isWindows,
      );

  AgentTask _requireWorkTask(String taskId) {
    final task = _taskBox.get(taskId);
    if (task == null || !task.workModeTask) {
      throw StateError('未找到工作模式任务：$taskId');
    }
    return task;
  }

  Future<void> _save(AgentTask task) async {
    await _taskBox.put(task.id, task);
    _publish(task);
  }

  void _applyFailure(
    AgentTask task,
    WorkFailure failure, {
    AgentTaskStatus status = AgentTaskStatus.failed,
    bool clearPendingTool = true,
  }) {
    task
      ..status = status
      ..resumeRequired = status == AgentTaskStatus.failed
          ? failure.retryable || task.completedOperations.isNotEmpty
          : true
      ..lastError = failure.reason
      ..updatedAt = _clock();
    if (clearPendingTool) task.pendingToolRequestJson = '';
    WorkFailure.persistOnTask(task, failure);
    _refreshTaskContext(
      task,
      nextStep: failure.suggestedAction,
      extraErrors: [failure.reason],
    );
  }

  List<String> _completedContentForTask(AgentTask task) {
    final values = <String>[
      ...task.completedOperations,
      if (task.resultSummary.trim().isNotEmpty) task.resultSummary,
      ...task.lastArtifactPaths.map((path) => '产物：$path'),
    ];
    final seen = <String>{};
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && seen.add(value))
        .take(32)
        .toList(growable: false);
  }

  Future<void> _checkpointFromRunner(AgentTask task) async {
    if (_disposed || _dataClearInProgress) return;
    await _serialize(() async {
      if (!_disposed && !_dataClearInProgress) await _save(task);
    });
  }

  void _refreshTaskContext(
    AgentTask task, {
    String? nextStep,
    Iterable<String> extraErrors = const [],
    bool clearRecentToolResults = false,
  }) {
    final raw = task.contextSummary.trim();
    if (raw.isNotEmpty && !_isTask15Context(raw, task.groupId)) {
      if (_hasForeignConversationContext(raw, task.groupId)) {
        // A checkpoint carrying another conversation id is never a legacy
        // summary. Drop it before publishing the task so a malformed import
        // cannot expose a different DM (or steer this task's revision).
        task.contextSummary = _contextBuilder
            .build(
              conversationId: task.groupId,
              target: task.userRequest,
              pendingFollowUps: task.queuedUserRequests,
              completedSummaries: task.resultSummary.trim().isEmpty
                  ? const []
                  : [task.resultSummary],
              artifactPaths: task.lastArtifactPaths,
              errors:
                  task.lastError.trim().isEmpty ? const [] : [task.lastError],
              nextStep: nextStep ?? '',
            )
            .toJsonString();
      }
      // Keep older Stage 02 summaries byte-for-byte compatible. The durable
      // AgentTask queue/artifact fields still carry the new state, and a
      // subsequent Task 15 checkpoint will migrate it through the builder.
      return;
    }
    final previous = raw.isEmpty
        ? WorkContextSnapshot(conversationId: task.groupId)
        : _contextBuilder.fromTask(task);
    final errors = _uniqueStrings(<String>[
      ...previous.errors,
      ...extraErrors,
      if (task.lastError.trim().isNotEmpty) task.lastError,
    ]);
    final completed = _uniqueStrings(<String>[
      ...previous.completedSummaries,
      if (task.resultSummary.trim().isNotEmpty) task.resultSummary,
    ]);
    final execution = _decodeExecutionMap(task.executionStateJson);
    final approvalScope = previous.approvalScope ??
        (execution['approvalScope'] is Map
            ? Map<String, dynamic>.from(execution['approvalScope'] as Map)
            : null);
    task.contextSummary = _contextBuilder
        .build(
          conversationId: task.groupId,
          target: previous.target.isEmpty ? task.userRequest : previous.target,
          pendingFollowUps: task.queuedUserRequests,
          completedSummaries: completed,
          // Tool results describe the previous execution run. Keep the
          // durable summary/artifacts for continuity, but do not let a
          // follow-up satisfy a new tool request with stale output.
          recentToolResults:
              clearRecentToolResults ? const [] : previous.recentToolResults,
          approvalScope: approvalScope,
          artifactPaths: <String>[
            ...previous.artifactPaths,
            ...task.lastArtifactPaths
          ],
          roleHandoff: previous.roleHandoff,
          errors: errors,
          nextStep: nextStep ?? previous.nextStep,
        )
        .toJsonString();
  }

  List<String> _uniqueStrings(Iterable<String> values) {
    final seen = <String>{};
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && seen.add(value))
        .toList(growable: false);
  }

  bool _isTask15Context(String raw, String conversationId) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map &&
          decoded['conversationId'] == conversationId &&
          decoded.containsKey('pendingFollowUps');
    } on Object {
      return false;
    }
  }

  bool _hasForeignConversationContext(String raw, String conversationId) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map &&
          decoded['conversationId'] is String &&
          decoded['conversationId'] != conversationId;
    } on Object {
      return false;
    }
  }

  bool _isFollowUpClarification(AgentTask task) {
    final execution = _decodeExecutionMap(task.executionStateJson);
    return execution['followUpKind'] == WorkFollowUpKind.clarification.name &&
        execution['clarificationQuestion'] is String;
  }

  bool _requiresExplicitCommandRequest(AgentTask task) {
    return _decodeExecutionMap(
            task.executionStateJson)['explicitCommandRequestRequired'] ==
        true;
  }

  bool _requiresMissingToolAction(AgentTask task) {
    return _decodeExecutionMap(task.executionStateJson)['toolMissing'] == true;
  }

  bool _requiresVisionModelSelection(AgentTask task) {
    return _decodeExecutionMap(
            task.executionStateJson)['visionModelRequired'] ==
        true;
  }

  Map<String, dynamic> _decodeExecutionMap(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on Object {
      return <String, dynamic>{};
    }
  }

  List<String> _queuedAttachmentMessageIds(
    String raw, {
    required int expectedLength,
  }) {
    final value = _decodeExecutionMap(raw)['queuedAttachmentMessageIds'];
    final ids = value is List
        ? value
            .map((item) => item is String ? item.trim() : '')
            .toList(growable: true)
        : <String>[];
    if (ids.length > expectedLength) {
      ids.removeRange(expectedLength, ids.length);
    }
    while (ids.length < expectedLength) {
      ids.add('');
    }
    return ids;
  }

  String _withQueuedAttachmentMessageIds(
    String raw,
    List<String> ids,
  ) {
    final metadata = _decodeExecutionMap(raw);
    final normalized = ids.map((id) => id.trim()).toList(growable: false);
    if (normalized.any((id) => id.isNotEmpty)) {
      metadata['queuedAttachmentMessageIds'] = normalized;
    } else {
      metadata.remove('queuedAttachmentMessageIds');
    }
    return metadata.isEmpty ? '' : jsonEncode(metadata);
  }

  void _persistAttachmentQueueMetadata(
    AgentTask task,
    List<String> queuedIds, {
    required String? currentAttachmentId,
  }) {
    final metadata = _decodeExecutionMap(task.executionStateJson)
      ..remove('attachmentMessageId')
      ..remove('queuedAttachmentMessageIds');
    final current = currentAttachmentId?.trim();
    if (current != null && current.isNotEmpty) {
      metadata['attachmentMessageId'] = current;
    }
    final normalized = queuedIds.map((id) => id.trim()).toList(growable: false);
    if (normalized.any((id) => id.isNotEmpty)) {
      metadata['queuedAttachmentMessageIds'] = normalized;
    }
    task.executionStateJson = metadata.isEmpty ? '' : jsonEncode(metadata);
  }

  String _withFollowUpDecision(
    String raw,
    WorkFollowUpDecision decision,
  ) {
    final metadata = _decodeExecutionMap(raw)
      ..['followUpKind'] = decision.kind.name
      ..['followUpReason'] = decision.reason;
    if (decision.artifactPath != null) {
      metadata['revisionTargetPath'] = decision.artifactPath;
    } else {
      metadata.remove('revisionTargetPath');
    }
    metadata['autoRenameIfExists'] = decision.autoRenameIfExists;
    if (decision.clarificationQuestion != null) {
      metadata['clarificationQuestion'] = decision.clarificationQuestion;
    } else {
      metadata.remove('clarificationQuestion');
    }
    return jsonEncode(metadata);
  }

  void _publish(AgentTask task) {
    if (!_disposed) _taskUpdates.add(task);
  }

  List<AgentTask> _allWorkTasks() {
    final tasks = _taskBox.values.where((task) => task.workModeTask).toList();
    tasks.sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return List<AgentTask>.unmodifiable(tasks);
  }

  Future<void> _record(
    AgentTask task,
    WorkTaskEventKind kind,
    String title, {
    String detail = '',
  }) async {
    // Data clear owns a hard lifecycle barrier. Late runner callbacks must not
    // recreate event files after the clear has removed the app-managed tree.
    if (_disposed || _dataClearInProgress) return;
    try {
      await _eventStore.append(
        taskId: task.id,
        kind: kind,
        title: title,
        detail: detail,
      );
    } on Object catch (error) {
      // Event persistence is diagnostic only; never replace a valid task
      // outcome with a logging exception. The durable flag tells the panel
      // that the timeline may have gaps.
      if (_disposed ||
          _dataClearInProgress ||
          _eventStore.appendsSuspendedForDataClear ||
          task.eventLogIncomplete) {
        return;
      }
      task.eventLogIncomplete = true;
      if (task.lastError.isEmpty) {
        task.lastError = '任务日志保存不完整：${sanitizeWorkTaskError(error)}';
      }
      try {
        await _taskBox.put(task.id, task);
        _publish(task);
      } on Object {
        // The database may already be closing. The task outcome must remain
        // authoritative even when there is no storage left for this flag.
      }
    }
  }

  Future<void> _markSnapshotStatus(AgentTask task) async {
    if (_dataClearInProgress) return;
    final updater = _snapshotStatusUpdater;
    if (updater == null) return;
    final status = switch (task.status) {
      AgentTaskStatus.completed => WorkSnapshotTaskStatus.completed,
      AgentTaskStatus.failed => WorkSnapshotTaskStatus.failed,
      AgentTaskStatus.cancelled => WorkSnapshotTaskStatus.cancelled,
      AgentTaskStatus.partiallyCompleted =>
        WorkSnapshotTaskStatus.partiallyCompleted,
      _ => WorkSnapshotTaskStatus.active,
    };
    try {
      await updater(task.id, status);
    } on Object {
      // Snapshot bookkeeping must not turn a valid task checkpoint into a
      // failed run. The next cleanup pass can retry this metadata update.
    }
  }

  Future<void> _promoteQueuedFollowUp(
    AgentTask task, {
    bool resetRunBudget = false,
    bool allowPausedClarification = false,
  }) async {
    final canPromotePausedClarification =
        allowPausedClarification && _isFollowUpClarification(task);
    if ((!task.isTerminal && !canPromotePausedClarification) ||
        task.status == AgentTaskStatus.cancelled ||
        task.queuedUserRequests.isEmpty ||
        _disposed) {
      return;
    }
    final nextRequest = task.queuedUserRequests.first.trim();
    final queuedAttachmentIds = _queuedAttachmentMessageIds(
      task.executionStateJson,
      expectedLength: task.queuedUserRequests.length,
    );
    final nextAttachmentId =
        queuedAttachmentIds.isEmpty ? null : queuedAttachmentIds.first.trim();
    if (nextRequest.isEmpty) {
      task.queuedUserRequests = task.queuedUserRequests.skip(1).toList();
      _persistAttachmentQueueMetadata(
        task,
        queuedAttachmentIds.skip(1).toList(),
        currentAttachmentId: null,
      );
      await _promoteQueuedFollowUp(task);
      return;
    }
    final decision = _followUpPolicy.resolve(
      request: nextRequest,
      // The model/result runner writes the structured field first. A
      // canonical Task 15 summary is a recovery fallback for tasks imported
      // between field writes; no chat-history or global-file lookup is used.
      lastArtifactPaths: _followUpArtifactPaths(task),
    );
    if (decision.isClarification) {
      // Keep the original request at the head of the durable FIFO. A later
      // user answer can therefore resolve it without losing any following
      // requests. No runner is started while the target is ambiguous.
      task
        ..status = AgentTaskStatus.paused
        ..resumeRequired = false
        ..lastError = decision.clarificationQuestion ?? '请明确要修改的文件路径。'
        ..executionStateJson = _withFollowUpDecision(
          task.executionStateJson,
          decision,
        )
        ..updatedAt = _clock();
      _conversationReservations.add(task.groupId);
      _refreshTaskContext(
        task,
        nextStep: task.lastError,
        extraErrors: [task.lastError],
      );
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.paused,
        '需要明确修订目标',
        detail: task.lastError,
      );
      return;
    }
    task.queuedUserRequests = task.queuedUserRequests.skip(1).toList();
    final remainingAttachmentIds = queuedAttachmentIds.skip(1).toList();
    // A follow-up is a new execution run under the same conversation/task
    // identity.  Do not reuse the previous run's in-memory lock plan: the
    // new request may target a different file, and a stale plan could either
    // block unrelated work or fail to serialize the new target.
    _taskLockPlans.remove(task.id);
    task
      ..userRequest = nextRequest
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false
      ..softLimitReached = false
      ..pendingToolRequestJson = ''
      ..executionStateJson = ''
      ..lastError = ''
      ..resultSummary = ''
      ..actionCount = resetRunBudget ? 0 : task.actionCount
      ..startedAt = resetRunBudget ? _clock() : task.startedAt
      ..updatedAt = _clock();
    _persistAttachmentQueueMetadata(
      task,
      remainingAttachmentIds,
      currentAttachmentId: nextAttachmentId,
    );
    task.executionStateJson = _withFollowUpDecision(
      task.executionStateJson,
      decision,
    );
    // A clarification pause intentionally held the conversation reservation;
    // the user's answer now makes the target runnable again.
    _conversationReservations.remove(task.groupId);
    _refreshTaskContext(
      task,
      nextStep: '开始处理已排队的追问。',
      clearRecentToolResults: true,
    );
    await _save(task);
    _enqueueTask(task);
    unawaited(
      _record(task, WorkTaskEventKind.queued, '开始处理已排队的追问'),
    );
  }

  List<String> _followUpArtifactPaths(AgentTask task) {
    if (task.lastArtifactPaths.isNotEmpty) {
      return List<String>.from(task.lastArtifactPaths);
    }
    final raw = task.contextSummary.trim();
    if (raw.isEmpty || !_isTask15Context(raw, task.groupId)) return const [];
    return _contextBuilder.fromTask(task).artifactPaths;
  }

  void _removeActiveRun(String taskId, Future<void> run) {
    if (identical(_activeRuns[taskId], run)) _activeRuns.remove(taskId);
  }

  String _withApprovalDecision(String raw, String decision) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..['approvalDecision'] = decision
          // A decision closes this exact prompt. If the resumed loop reaches
          // another mutation checkpoint, the host must be allowed to present
          // a fresh dialog for that new operation.
          ..remove('approvalPromptShown');
        final parsedDecision = WorkChangeApprovalDecision.fromWire(decision);
        if (parsedDecision?.permitsExecution == true) {
          // A new approval authorizes exactly the checkpoint that prompted it;
          // the runner consumes high-risk approvals on their first attempt.
          copy.remove('approvalConsumed');
        } else {
          copy
            ..remove('approvalCapability')
            ..remove('approvalOperationFingerprint')
            ..remove('approvalConsumed');
        }
        final rawPlan = copy['approvalPlan'];
        if (parsedDecision?.permitsExecution == true && rawPlan is Map) {
          try {
            final plan = WorkChangePlan.fromJson(
              Map<String, dynamic>.from(rawPlan),
            );
            copy['approvalScope'] = WorkApprovalScope.fromPlan(plan).toJson();
          } on Object {
            // The runner will fail closed when a tampered plan cannot produce
            // an exact scope; never synthesize a wildcard approval.
            copy.remove('approvalScope');
          }
        } else {
          // A rejection is not a capability grant. Remove the descriptive
          // scope before the runner continues with the safe skip path, so a
          // later tool cannot inherit the declined mutation's paths.
          copy.remove('approvalScope');
        }
        return jsonEncode(copy);
      }
    } on Object {
      // Replace malformed/non-object execution metadata with a minimal safe
      // checkpoint rather than persisting arbitrary model text.
    }
    return jsonEncode(<String, String>{'approvalDecision': decision});
  }

  String _withoutApprovalCheckpoint(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..remove('approvalDecision')
          ..remove('approvalScope')
          ..remove('approvalPlan')
          ..remove('approvalCapability')
          ..remove('approvalOperationFingerprint')
          ..remove('approvalConsumed');
        return copy.isEmpty ? '' : jsonEncode(copy);
      }
    } on Object {
      // A malformed checkpoint is not safe to reuse after a restart.
    }
    return '';
  }

  String? _requestedFolderPath(AgentTask task) {
    try {
      final decoded = jsonDecode(task.executionStateJson);
      if (decoded is! Map) return null;
      final direct = decoded['folderRequestPath'];
      if (direct is String && direct.trim().isNotEmpty) return direct.trim();
      final plan = decoded['approvalPlan'];
      if (plan is Map) {
        final paths = plan['exactPaths'];
        if (paths is List) {
          for (final path in paths) {
            if (path is String && path.trim().isNotEmpty) return path.trim();
          }
        }
      }
    } on Object {
      // Malformed execution metadata cannot safely identify a requested path.
    }
    return const WorkModeDirectoryService().requestedDesktopPath(
      task.userRequest,
    );
  }

  bool _requiresWritableFolder(AgentTask task) {
    final execution = _decodeExecutionMap(task.executionStateJson);
    // A concrete command can discover a local write only after the model
    // turn. The tool boundary records this marker before pausing so a resumed
    // task selects a writable workspace instead of retrying the old read root.
    if (execution['folderRequiresWritable'] == true) return true;
    final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
    if (pending == null) {
      // The first model turn may only inspect a read-only grant. Request a
      // writable capability up front only when the user's wording clearly
      // requires a mutation; an ambiguous request is revalidated when the
      // concrete tool call exposes its exact path.
      return _requestLikelyMutates(task.userRequest);
    }
    if (pending.tool == AgentToolName.commandRun) {
      // The checkpoint already contains the structured command fields. Make a
      // conservative preflight classification here so a resumed local
      // mutation asks for a writable grant before the runner resolves its
      // workspace. The runner still performs the authoritative policy check;
      // this only decides which capability the native picker should request.
      return _pendingCommandNeedsWritable(pending.args);
    }
    return pending.tool == AgentToolName.workspacePatch ||
        pending.tool == AgentToolName.workspaceRename ||
        pending.tool == AgentToolName.workspaceDelete;
  }

  bool _pendingCommandNeedsWritable(Map<String, dynamic> args) {
    final executable = (args['executable'] ?? '').toString().toLowerCase();
    final base = executable.replaceAll('\\', '/').split('/').last;
    final rawArguments = args['arguments'] ?? args['args'];
    final rawArgumentList = rawArguments is List
        ? rawArguments.map((item) => item.toString()).toList()
        : const <String>[];
    final arguments = rawArgumentList
        .map((item) => item.toLowerCase())
        .toList(growable: false);
    final rawImpact = args['declaredImpact'];
    final impactPaths =
        rawImpact is List ? rawImpact.whereType<String>() : const <String>[];
    if (impactPaths.any(_isAbsoluteWorkPath)) return true;
    // Shell redirection is rejected by the structured command policy as a
    // local mutation. Keep the folder preflight aligned with that policy so a
    // resumed `ls > report.txt` cannot start on a read-only workspace and only
    // discover the missing write capability after the process boundary.
    if (arguments.any(_isLocalRedirectArgument)) return true;
    if (const {
      'pwd',
      'ls',
      'dir',
      'rg',
      'ripgrep',
      'grep',
      'egrep',
      'fgrep',
      'cat',
      'head',
      'tail',
      'wc',
      'file',
      'stat',
      'which',
      'where',
      'whoami',
      'uname',
    }.contains(base)) {
      return false;
    }
    if (base == 'find' || base == 'fd') {
      return arguments.any(
        (argument) => {'-delete', '-exec', '-execdir', '-ok', '-okdir'}
            .contains(argument),
      );
    }
    if (base == 'git' && arguments.isNotEmpty) {
      return !const {
        'status',
        'diff',
        'log',
        'show',
        'branch',
        'rev-parse',
        'ls-files',
        'push',
      }.contains(arguments.first);
    }
    if (base == 'flutter' || base == 'dart') {
      final first = arguments.isEmpty ? '' : arguments.first;
      return first != 'analyze' && first != '--version' && first != '--help';
    }
    if (base == 'curl' || base == 'wget') {
      // A network write does not require a writable local folder unless the
      // impact list explicitly includes an absolute local path. Local output
      // flags do require the capability; upload/data flags only read local
      // inputs and therefore remain valid with a read-only grant.
      return rawArgumentList.any(
        (raw) {
          final argument = raw.toLowerCase();
          final curlShortOutput = base == 'curl' &&
              (raw == '-D' ||
                  raw.startsWith('-D') && raw.length > 2 ||
                  raw == '-c' ||
                  raw.startsWith('-c') && raw.length > 2);
          return curlShortOutput ||
              argument == '-o' ||
              argument == '--output' ||
              argument.startsWith('--output=') ||
              argument == '--output-dir' ||
              argument.startsWith('--output-dir=') ||
              argument == '--output-document' ||
              argument.startsWith('--output-document=') ||
              argument == '--dump-header' ||
              argument.startsWith('--dump-header=') ||
              argument == '--cookie-jar' ||
              argument.startsWith('--cookie-jar=') ||
              argument == '--trace' ||
              argument.startsWith('--trace=') ||
              argument == '--trace-ascii' ||
              argument.startsWith('--trace-ascii=') ||
              argument == '--stderr' ||
              argument.startsWith('--stderr=') ||
              argument == '--hsts' ||
              argument.startsWith('--hsts=') ||
              argument == '--etag-save' ||
              argument.startsWith('--etag-save=') ||
              argument.startsWith('-o') && argument.length > 2;
        },
      );
    }
    return true;
  }

  bool _isAbsoluteWorkPath(String value) {
    final path = value.trim();
    return path.startsWith('/') ||
        path.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
  }

  bool _isLocalRedirectArgument(String argument) {
    return argument == '>' ||
        argument == '>>' ||
        argument == '<' ||
        argument == '2>' ||
        argument.startsWith('>') ||
        argument.startsWith('<') ||
        argument.startsWith('2>');
  }

  bool _requestLikelyMutates(String request) {
    final lower = request.toLowerCase();
    // A task starts before the first structured tool call, so a read-only
    // command such as “运行 pwd” must not be blocked merely because the
    // request contains the generic verb “运行/执行”.  Keep this check
    // intentionally narrow: only well-known inspection commands qualify, and
    // any explicit write/test/build/install intent keeps the conservative
    // writable-folder requirement.
    if (_requestClearlyReadOnly(lower)) return false;
    return RegExp(
      r'(写|写入|修改|改写|创建|生成|删除|移除|重命名|替换|保存|覆盖|安装|提交|推送|'
      r'运行|执行|编译|构建|测试|开发|修复|实现|'
      r'\b(?:write|create|generate|modify|edit|delete|remove|rename|replace|save|overwrite|'
      r'install|commit|push|run|compile|build|test|develop|fix|implement)\b)',
      caseSensitive: false,
    ).hasMatch(lower);
  }

  bool _requestClearlyReadOnly(String lower) {
    // Merely mentioning an inspection command is not enough to classify the
    // whole request as read-only.  Shell separators, redirects and common
    // mutating subcommands make the intent compound/uncertain; request a
    // writable capability up front and let the structured command policy make
    // the final decision.
    if (RegExp(r'[|;]|&&|(?:>>?|<|2>)').hasMatch(lower) ||
        RegExp(
          r'(?<![a-z0-9_-])(?:rm|rmdir|del|erase|unlink|mv|move|copy|cp|touch|'
          r'mkdir|install|tee|chmod|chown|truncate|dd|sed|perl)(?![a-z0-9_-])',
          caseSensitive: false,
        ).hasMatch(lower) ||
        RegExp(
          r'(?<![a-z0-9_-])(?:find|fd)\b[^\n]*\s(?:-delete|-exec(?:dir)?|-ok(?:dir)?)\b',
          caseSensitive: false,
        ).hasMatch(lower) ||
        RegExp(
          r'(?<![a-z0-9_-])git\s+(?:commit|push|pull|merge|rebase|checkout|switch|tag|clean|reset)\b',
          caseSensitive: false,
        ).hasMatch(lower) ||
        RegExp(
          r'(?<![a-z0-9_-])(?:curl|wget)\b[^\n]*(?:--?data|--?upload-file|--?output|--?post|--?request[= ](?:post|put|patch|delete)|--?method[= ](?:post|put|patch|delete))',
          caseSensitive: false,
        ).hasMatch(lower)) {
      return false;
    }
    final hasInspectionCommand = RegExp(
      r'(?<![a-z0-9_-])(?:pwd|ls|dir|find|fd|rg|ripgrep|grep|egrep|fgrep|'
      r'cat|head|tail|wc|file|stat|which|where|whoami|uname)(?![a-z0-9_-])',
      caseSensitive: false,
    ).hasMatch(lower);
    if (!hasInspectionCommand) {
      final hasReadOnlyGit = RegExp(
        r'(?<![a-z0-9_-])git\s+(?:status|diff|log|show|branch|rev-parse|ls-files)'
        r'(?![a-z0-9_-])',
        caseSensitive: false,
      ).hasMatch(lower);
      final hasReadOnlySdk = RegExp(
        r'(?<![a-z0-9_-])(?:flutter|dart)\s+(?:analyze|--version|--help)'
        r'(?![a-z0-9_-])',
        caseSensitive: false,
      ).hasMatch(lower);
      if (!hasReadOnlyGit && !hasReadOnlySdk) return false;
    }
    return !RegExp(
      r'(写|写入|修改|改写|创建|生成|删除|移除|重命名|替换|保存|覆盖|安装|提交|推送|'
      r'编译|构建|测试|开发|修复|实现|发布|部署|'
      r'\b(?:write|create|generate|modify|edit|delete|remove|rename|replace|save|overwrite|'
      r'install|commit|push|compile|build|test|develop|fix|implement|deploy|publish)\b)',
      caseSensitive: false,
    ).hasMatch(lower);
  }

  String _withoutFolderRequest(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..remove('folderRequestPath')
          ..remove('folderGrantPending');
        return copy.isEmpty ? '' : jsonEncode(copy);
      }
    } on Object {
      return '';
    }
    return raw;
  }

  String _withFolderGrantPending(
    String raw,
    String? requestedPath, {
    required bool requiresWritable,
  }) {
    final metadata = _decodeExecutionMap(raw)..['folderGrantPending'] = true;
    if (requiresWritable) {
      metadata['folderRequiresWritable'] = true;
    } else {
      metadata.remove('folderRequiresWritable');
    }
    final path = requestedPath?.trim();
    if (path == null || path.isEmpty) {
      metadata.remove('folderRequestPath');
    } else {
      metadata['folderRequestPath'] = path;
    }
    return jsonEncode(metadata);
  }

  String _withWritableRequirementMarker(String raw) {
    final metadata = _decodeExecutionMap(raw)
      ..['folderRequiresWritable'] = true;
    return jsonEncode(metadata);
  }

  String _withResourceLockPlan(
    String raw,
    List<WorkResourceLockRequest> locks,
  ) {
    final resourceLocks = locks
        .map((lock) => <String, String>{
              'path': lock.path,
              'mode': lock.mode.name,
            })
        .toList(growable: false);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return jsonEncode({...decoded, 'resourceLocks': resourceLocks});
      }
    } on Object {
      // Replace malformed/non-object metadata with the durable lock plan.
    }
    return jsonEncode(<String, dynamic>{'resourceLocks': resourceLocks});
  }

  List<WorkResourceLockRequest>? _persistedResourceLocks(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final rawLocks = decoded['resourceLocks'];
      if (rawLocks is List) {
        final parsed = <WorkResourceLockRequest>[];
        for (final item in rawLocks) {
          if (item is! Map || item['path'] is! String) {
            throw const FormatException('资源锁计划格式无效');
          }
          final mode = switch (item['mode']) {
            'read' => WorkResourceLockMode.read,
            'write' => WorkResourceLockMode.write,
            'treeWrite' => WorkResourceLockMode.treeWrite,
            _ => throw const FormatException('资源锁模式无效'),
          };
          parsed.add(
            WorkResourceLockRequest(path: item['path'] as String, mode: mode),
          );
        }
        return _resourceLockManager.normalizeLockSet(parsed);
      }
      final legacyPaths = decoded['resourceLockPaths'];
      if (legacyPaths is List) {
        return _resourceLockManager.normalizeLockSet(
          legacyPaths.whereType<String>().map(WorkResourceLockRequest.write),
        );
      }
    } on Object {
      rethrow;
    }
    return null;
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('工作任务调度器已关闭。');
    if (_dataClearInProgress) {
      throw StateError('正在清除 App 数据，请稍后重试。');
    }
  }
}
