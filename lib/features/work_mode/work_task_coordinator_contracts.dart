part of 'work_task_coordinator.dart';

typedef WorkTaskSnapshotStatusUpdater = Future<void> Function(
    String taskId, WorkSnapshotTaskStatus status);
typedef WorkTaskActionNotifier = Future<void> Function(AgentTask task);

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

/// The coordinator-owned S3 discussion capability. The callback is the same
/// durable state transition used by the execution gate; a discussion runner
/// never writes task state directly or starts the tool runner itself.
typedef WorkTaskDiscussionStateSink = Future<AgentTask> Function(
  WorkDiscussionState state,
);

abstract interface class WorkTaskDiscussionRunner {
  Future<void> runDiscussion(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkTaskDiscussionStateSink updateState,
  );
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

/// Optional capability for runners that can mirror a terminal failure into
/// the conversation. The task panel remains the diagnostic surface, while a
/// durable chat message makes the outcome visible even after the panel closes.
abstract interface class WorkTaskFailureReporter {
  Future<void> reportFailure(AgentTask task, WorkFailure failure);
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

/// Optional runner capability for the final discussion gate. The coordinator
/// owns the durable phase/revision checks; the production runner owns the
/// character, group membership, model and credential availability check.
abstract interface class WorkTaskDiscussionExecutorValidator {
  Future<String?> validateDiscussionExecutor(
    AgentTask task,
    WorkDiscussionState state,
  );
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
