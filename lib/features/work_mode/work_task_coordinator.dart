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
import 'work_task_clarification.dart';
import 'work_task_budget_wait.dart';
import 'work_resource_lock_manager.dart';
import 'work_snapshot_manifest.dart';
import 'work_approval_decision.dart';
import 'work_change_plan.dart';
import 'work_command_runner.dart';
import 'work_context_builder.dart';
import 'work_discussion_state.dart';
import 'work_follow_up_policy.dart';
import 'work_handoff_state.dart';
import 'work_failure.dart';
import 'work_mode_directory_service.dart';
import 'work_role_router.dart';
import 'work_tool_registry.dart';
import 'work_task_user_action.dart';

part 'work_task_coordinator_submission.dart';
part 'work_task_coordinator_follow_up_input.dart';
part 'work_task_coordinator_permission_actions.dart';
part 'work_task_coordinator_recovery.dart';
part 'work_task_coordinator_auto_resume.dart';
part 'work_task_coordinator_discussion_lifecycle.dart';
part 'work_task_coordinator_scheduling.dart';
part 'work_task_coordinator_execution.dart';
part 'work_task_coordinator_workspace_queue.dart';
part 'work_task_coordinator_failure_checkpoint.dart';
part 'work_task_coordinator_follow_up_promotion.dart';
part 'work_task_coordinator_checkpoint_policy.dart';
part 'work_task_coordinator_contracts.dart';

/// Owns work-task scheduling independently from every chat-room widget.
///
/// State updates are serialized before starting a runner, so two concurrent
/// submissions cannot consume the same slot or run the same conversation.
class WorkTaskCoordinator {
  static const int maximumConcurrentTasks = 2;

  /// How long a retryable failure waits before it resumes itself, one entry per
  /// automatic attempt. Thirty seconds outlasts a brief provider brownout while
  /// staying visible in the panel; the longer second step covers a link that is
  /// still flapping. The ladder is also the cap: beyond it the task is the
  /// user's call, not the app's.
  static const List<Duration> defaultAutoResumeDelays = [
    Duration(seconds: 30),
    Duration(seconds: 90),
  ];
  /// Upper bound on one automatic-resume attempt.
  ///
  /// An app-initiated retry must not be able to sit on a slot for the whole
  /// model deadline (300s) just because the provider is unreachable, so the
  /// round is cancelled at this point and counted as a failed attempt, which
  /// puts the next step of [defaultAutoResumeDelays] in charge. User-initiated
  /// runs are deliberately not bounded this way.
  static const Duration defaultAutoResumeRoundTimeout = Duration(seconds: 120);

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
  final WorkTaskDiscussionRunner? _discussionRunner;
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

  /// The delay ladder for automatic resumes of a retryable failure.
  final List<Duration> autoResumeDelays;
  final Duration autoResumeRoundTimeout;
  final WorkTaskActionNotifier? _userActionNotifier;
  final bool? _installerIsWindows;
  final bool? _installerIsMacOS;
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
  final Map<String, WorkTaskCancellation> _discussionCancellations =
      <String, WorkTaskCancellation>{};
  final Map<String, Future<void>> _discussionRuns = <String, Future<void>>{};
  final Set<String> _discussionStartingIds = <String>{};
  final Map<String, Future<void>> _installRuns = <String, Future<void>>{};
  final Map<String, Set<WorkTaskCancellation>> _installCancellations =
      <String, Set<WorkTaskCancellation>>{};
  final Map<String, Future<void>> _approvalRuns = <String, Future<void>>{};
  final Map<String, Future<void>> _folderActionRuns = <String, Future<void>>{};
  final Set<String> _conversationReservations = <String>{};
  final Set<String> _handoffsAwaitingLease = <String>{};
  final Set<String> _autoResumeTaskIds = <String>{};
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
    WorkTaskDiscussionRunner? discussionRunner,
    WorkFolderGrantService? folderGrantService,
    WorkFolderPicker? folderPicker,
    WorkFolderGrantConsent? folderGrantConsent,
    bool requireFolderGrant = false,
    WorkTaskSnapshotStatusUpdater? snapshotStatusUpdater,
    WorkResourceLockManager? resourceLockManager,
    WorkTaskResourceLockPlan? resourceLockPlan,
    WorkContextBuilder? contextBuilder,
    WorkFollowUpPolicy? followUpPolicy,
    WorkTaskActionNotifier? userActionNotifier,
    bool? installerIsWindows,
    bool? installerIsMacOS,
    DateTime Function()? clock,
    List<Duration>? autoResumeDelays,
    Duration? autoResumeRoundTimeout,
  })  : _taskBox = taskBox,
        _eventStore = eventStore,
        _runner = runner,
        _discussionRunner = discussionRunner,
        _folderGrantService = folderGrantService,
        _folderPicker = folderPicker,
        _folderGrantConsent = folderGrantConsent,
        _requireFolderGrant = requireFolderGrant,
        _snapshotStatusUpdater = snapshotStatusUpdater,
        _resourceLockManager = resourceLockManager ?? WorkResourceLockManager(),
        _resourceLockPlan = resourceLockPlan,
        _contextBuilder = contextBuilder ?? const WorkContextBuilder(),
        _followUpPolicy = followUpPolicy ?? const WorkFollowUpPolicy(),
        _userActionNotifier = userActionNotifier,
        _installerIsWindows = installerIsWindows,
        _installerIsMacOS = installerIsMacOS,
        _clock = clock ?? DateTime.now,
        autoResumeDelays = List<Duration>.unmodifiable(
          autoResumeDelays ?? defaultAutoResumeDelays,
        ),
        autoResumeRoundTimeout =
            autoResumeRoundTimeout ?? defaultAutoResumeRoundTimeout {
    if (runner case final WorkTaskProgressReporter reporter) {
      reporter.setTaskUpdateSink(_publishFromRunner);
    }
    if (runner case final WorkTaskCheckpointReporter reporter) {
      reporter.setTaskCheckpointSink(_checkpointFromRunner);
    }
  }

  int get runningTaskCount => _implRunningTaskCount;

  bool _hasInstallableMissingTool(AgentTask task) =>
      WorkFailure.hasInstallableMissingTool(
        task,
        isWindows: _installerIsWindows,
        isMacOS: _installerIsMacOS,
      );

  int _installActionVersion(AgentTask task) => WorkTaskUserAction.versionFor(
        task,
        'toolMissing',
        isWindows: _installerIsWindows,
        isMacOS: _installerIsMacOS,
      );

  /// Quiesces every work task before the app-wide data lifecycle service
  /// removes event logs and snapshots. Active runners are cancelled
  /// cooperatively, while their finalizers are drained outside [_serialize]
  /// to avoid the runner's own completion checkpoint deadlocking the queue.
  Future<void> stopAllForDataClear() => _implStopAllForDataClear();

  /// Reopens scheduling after a clear attempt has finished. The coordinator
  /// instance remains app-scoped; clearing data must not dispose it.
  Future<void> resumeAfterDataClear() => _implResumeAfterDataClear();

  /// Lets the app-level overlay provide the one-time cloud-disclosure dialog
  /// without coupling the scheduler to a particular [BuildContext].
  void setFolderGrantConsent(WorkFolderGrantConsent? consent) =>
      _implSetFolderGrantConsent(consent);

  /// Persists and schedules a new V1 work task. The task is queued before a
  /// runner can observe it, which makes state recoverable at every boundary.
  Future<AgentTask> submit(
    AgentTask task, {
    Iterable<WorkResourceLockRequest>? resourceLocks,
  }) =>
      _implSubmit(task, resourceLocks: resourceLocks);

  /// Atomically records a discussion transition. S3 can call this method after
  /// the group has actually discussed and elected an executor; S2 keeps the
  /// transition durable and refuses stale revisions without starting a runner.
  Future<AgentTask> updateDiscussionState(
    String taskId,
    WorkDiscussionState next,
  ) =>
      _implUpdateDiscussionState(taskId, next);

  /// Read-only helper used by panels/tests to avoid parsing the untrusted JSON
  /// extension in more than one place.
  WorkDiscussionDecodeResult discussionStateForTask(String taskId) =>
      _implDiscussionStateForTask(taskId);

  /// Returns the exact durable task addressed by a chat action. Callers must
  /// never replace this lookup with a "latest task" sort because an older
  /// paused checkpoint may still own the conversation.
  AgentTask? taskById(String taskId) => _implTaskById(taskId);

  /// Validates a message action against the current checkpoint. A completed,
  /// cancelled or revised task therefore makes the old button inert before
  /// any panel or coordinator operation is attempted.
  bool isUserActionCurrent({
    required String taskId,
    required String blockerId,
    required int version,
  }) =>
      _implIsUserActionCurrent(
          taskId: taskId, blockerId: blockerId, version: version);

  /// Reopens the same discussion checkpoint after the user returns from the
  /// existing group-member management page. The role requirement is cleared
  /// only temporarily; the discussion runner must revalidate the actual
  /// membership, occupation and credentials before it can elect an executor.
  Future<void> refreshDiscussionAfterMemberChange(
    String taskId, {
    required String blockerId,
    required int version,
  }) =>
      _implRefreshDiscussionAfterMemberChange(taskId,
          blockerId: blockerId, version: version);

  /// Leaves a blocker paused and records that the user deliberately deferred
  /// it. This is an explicit, idempotent panel action rather than an implicit
  /// downgrade or a hidden retry.
  Future<void> deferUserAction(
    String taskId, {
    String? blockerId,
    int? version,
  }) =>
      _implDeferUserAction(taskId, blockerId: blockerId, version: version);

  /// Returns the durable task that currently owns a conversation.  The chat
  /// page must not decide ownership by sorting the newest Hive row: after a
  /// restart an older paused task can still own the conversation, while a
  /// completed task may have a newer timestamp from a diagnostic checkpoint.
  /// Prefer in-process ownership, then any non-terminal checkpoint, and only
  /// use a terminal task as the follow-up lineage fallback.
  AgentTask? taskForConversation(String conversationId) =>
      _implTaskForConversation(conversationId);

  /// A runner may publish a terminal-looking checkpoint just before its
  /// coordinator finalizer releases the slot.  Callers use this predicate to
  /// keep those last-microtask inputs in the execution FIFO.
  bool isTaskInFlight(String taskId) => _implIsTaskInFlight(taskId);

  /// Exposes the single follow-up classifier to the input router and the
  /// coordinator.  Keeping this decision at the durable boundary prevents a
  /// widget from accidentally routing a completed revision as a new task (or
  /// applying a different collision/path rule than FIFO promotion).
  WorkFollowUpDecision followUpDecisionForTask(
    String taskId,
    String request,
  ) =>
      _implFollowUpDecisionForTask(taskId, request);

  /// Tells the chat input whether a completed group checkpoint must be routed
  /// as a new task.  The boundary conditions live here with the follow-up
  /// classifier; widgets only use the result to choose the existing route
  /// entry point.
  bool shouldRouteNewTaskForFollowUp(String taskId, String request) =>
      _implShouldRouteNewTaskForFollowUp(taskId, request);

  /// Adds user input to the same durable task instead of replacing its run.
  Future<void> enqueueFollowUp(
    String taskId,
    String request, {
    String? attachmentMessageId,
  }) =>
      _implEnqueueFollowUp(taskId, request,
          attachmentMessageId: attachmentMessageId);

  /// Persists a tool-approval checkpoint without requiring a chat page to
  /// retain the pending request in memory.
  Future<void> pauseForApproval(
    String taskId, {
    required String pendingToolRequestJson,
  }) =>
      _implPauseForApproval(taskId,
          pendingToolRequestJson: pendingToolRequestJson);

  /// Records that the app-level approval prompt has been presented for this
  /// checkpoint. The marker prevents route rebuilds or app restarts from
  /// repeatedly interrupting the user while the task panel remains available.
  Future<bool> markApprovalPromptShown(String taskId) =>
      _implMarkApprovalPromptShown(taskId);

  /// Clears a prompt marker when the host failed before presenting the dialog.
  ///
  /// Presentation failures are recoverable (for example, a route can be
  /// rebuilt between the post-frame callback and [showDialog]). Keeping the
  /// marker in that case would suppress every later automatic retry and leave
  /// only the manual task panel as a workaround.
  Future<void> resetApprovalPromptShown(String taskId) =>
      _implResetApprovalPromptShown(taskId);

  /// Approves the pending tool request and queues the same durable task.
  ///
  /// The decision is stored in the task checkpoint so a runner can consume it
  /// after the current process has released its slot, without relying on a
  /// chat-page object or an in-memory dialog callback.
  Future<void> approve(String taskId, {int? expectedActionVersion}) =>
      _implApprove(taskId, expectedActionVersion: expectedActionVersion);

  /// Rejects the pending tool request and queues the same durable task. The
  /// runner receives a structured rejection and may continue with safe work.
  Future<void> reject(String taskId, {int? expectedActionVersion}) =>
      _implReject(taskId, expectedActionVersion: expectedActionVersion);

  /// Approves a mutation after the user has explicitly accepted that this
  /// operation cannot be undone. This decision is durable and is never
  /// inferred from the ordinary-write setting.
  Future<void> approveWithoutUndo(String taskId,
          {int? expectedActionVersion}) =>
      _implApproveWithoutUndo(taskId,
          expectedActionVersion: expectedActionVersion);

  /// Explicitly named aliases for UI integrations that prefer task wording.
  Future<void> approveTask(String taskId, {int? expectedActionVersion}) =>
      _implApproveTask(taskId, expectedActionVersion: expectedActionVersion);

  Future<void> rejectTask(String taskId, {int? expectedActionVersion}) =>
      _implRejectTask(taskId, expectedActionVersion: expectedActionVersion);

  Future<void> approveTaskWithoutUndo(
    String taskId, {
    int? expectedActionVersion,
  }) =>
      _implApproveTaskWithoutUndo(taskId,
          expectedActionVersion: expectedActionVersion);

  /// Runs a trusted package-manager suggestion only after the user chooses the
  /// install action in the execution panel. The original pending tool request
  /// remains intact so a successful install resumes the same loop turn.
  Future<void> installMissingTool(
    String taskId, {
    int? expectedActionVersion,
  }) =>
      _implInstallMissingTool(taskId,
          expectedActionVersion: expectedActionVersion);

  /// Opens the app-level picker from the execution panel and requeues the
  /// waiting task when the selected directory covers its requested path.
  Future<void> requestFolderForTask(
    String taskId, {
    int? expectedActionVersion,
  }) =>
      _implRequestFolderForTask(taskId,
          expectedActionVersion: expectedActionVersion);

  /// Rebuilds a plan after a missing approval scope, or delegates to the
  /// directory picker for a genuine workspace authorization failure.
  Future<void> reauthorizeTask(String taskId) => _implReauthorizeTask(taskId);

  /// Stops only the requested task. Other conversations keep their slots.
  Future<void> stop(String taskId, {String reason = '用户已停止任务。'}) =>
      _implStop(taskId, reason: reason);

  /// Queues an interrupted or paused task only after an explicit user action.
  Future<void> resumeByUser(String taskId) => _implResumeByUser(taskId);

  /// Retries a classified failure from the last durable checkpoint.
  ///
  /// The failure marker is intentionally kept while the task is queued so the
  /// panel can still explain why it stopped. [WorkAgentLoop] removes it only
  /// when a new attempt actually starts. Completed operation keys and artifact
  /// paths are never reset, so a committed mutation cannot be replayed.
  Future<void> retry(String taskId) => _implRetry(taskId);

  Future<void> retryTask(String taskId) => _implRetryTask(taskId);

  /// Switches the current task to a user-selected visual character and
  /// resumes the same durable task. Production runners implement the optional
  /// validator so a caller cannot bypass the panel's capability list.
  Future<void> selectVisionModel(String taskId, String characterId) =>
      _implSelectVisionModel(taskId, characterId);

  /// Grants a fresh soft-limit budget only after the user chooses to continue.
  Future<void> continueAfterSoftLimit(String taskId) =>
      _implContinueAfterSoftLimit(taskId);

  /// Reloads durable task state without invoking any runner automatically.
  Future<void> restore() => _implRestore();

  Stream<AgentTask> watchTask(String taskId) => _implWatchTask(taskId);

  Stream<List<AgentTask>> watchAllTasks() => _implWatchAllTasks();

  /// The app scope can release listeners at shutdown; it deliberately does
  /// not stop active work merely because a chat room disappeared.
  Future<void> dispose() => _implDispose();
}
