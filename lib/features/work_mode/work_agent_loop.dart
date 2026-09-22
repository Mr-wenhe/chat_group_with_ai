import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/agent_decision_parser.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_context_builder.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_handoff_state.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/work_task_clarification.dart';
import 'package:chat_group/features/work_mode/work_task_budget_wait.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:crypto/crypto.dart';

part 'work_agent_loop_retry.dart';
part 'work_agent_loop_checkpoint.dart';
part 'work_agent_loop_safety.dart';
part 'work_agent_loop_actions.dart';

/// A model call receives a public checkpoint, never a private reasoning trace.
typedef WorkAgentModel = FutureOr<Map<String, dynamic>> Function(
  WorkAgentModelRequest request,
);

typedef WorkAgentEventSink = FutureOr<void> Function(WorkTaskEvent event);
typedef WorkAgentCheckpointSink = FutureOr<void> Function(AgentTask task);
typedef WorkAgentSleep = Future<void> Function(Duration delay);
typedef WorkAgentCompletionGuard = FutureOr<String?> Function(
  AgentTask task,
  AgentFinishCompletion completion,
);
typedef WorkAgentArtifactCompletion = FutureOr<AgentFinishCompletion?> Function(
  AgentTask task,
  AgentToolCall call,
  WorkToolResult result,
);
typedef WorkAgentPreflightTool = FutureOr<AgentToolCall?> Function(
  AgentTask task,
);

class WorkAgentModelRequest {
  final AgentTask task;
  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic> context;
  final bool isRepair;
  final String? malformedResponse;
  final int retryNumber;

  WorkAgentModelRequest({
    required this.task,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> context,
    this.isRepair = false,
    this.malformedResponse,
    this.retryNumber = 0,
  })  : messages = List<Map<String, dynamic>>.unmodifiable(
          messages.map((message) => Map<String, dynamic>.unmodifiable(message)),
        ),
        context = Map<String, dynamic>.unmodifiable(
          Map<String, dynamic>.from(context),
        );

  WorkAgentModelRequest copyWith({
    List<Map<String, dynamic>>? messages,
    Map<String, dynamic>? context,
    bool? isRepair,
    String? malformedResponse,
    int? retryNumber,
  }) {
    return WorkAgentModelRequest(
      task: task,
      messages: messages ?? this.messages,
      context: context ?? this.context,
      isRepair: isRepair ?? this.isRepair,
      malformedResponse: malformedResponse ?? this.malformedResponse,
      retryNumber: retryNumber ?? this.retryNumber,
    );
  }
}

enum WorkAgentLoopStatus {
  completed,
  paused,
  waitingForApproval,
  failed,
  cancelled,
}

class WorkAgentLoopResult {
  final WorkAgentLoopStatus status;
  final String message;
  final int actionCount;
  final int retryCount;
  final int modelRetryCount;
  final int toolRetryCount;
  final int protocolRepairAttempts;

  /// Full in-memory request retained by the production adapter while a user
  /// approval dialog is open. It is never serialized in the task checkpoint.
  final ToolRequest? pendingToolRequest;
  final List<WorkTaskEvent> events;
  final WorkFailure? failure;

  const WorkAgentLoopResult({
    required this.status,
    required this.message,
    required this.actionCount,
    this.retryCount = 0,
    this.modelRetryCount = 0,
    this.toolRetryCount = 0,
    this.protocolRepairAttempts = 0,
    this.pendingToolRequest,
    this.events = const [],
    this.failure,
  });

  bool get isCompleted => status == WorkAgentLoopStatus.completed;
}

/// Executes one durable work task using the Stage 03 decision protocol.
///
/// This is the sole production work-mode loop. Ordinary chat and legacy
/// agentic integrations keep their separate compatibility facade; they never
/// enter this task-scoped loop.
class WorkAgentLoop
    implements
        WorkTaskRunner,
        WorkTaskProgressReporter,
        WorkTaskCheckpointReporter {
  static const int defaultMaxActions = AgentTask.defaultActionLimit;
  static const Duration defaultSoftTimeLimit = AgentTask.defaultSoftTimeLimit;
  static const int defaultMaxModelRetries = 2;
  // A protocol drift is recoverable without user input. Allow two fresh
  // decisions after the one bounded repair attempt before surfacing a task
  // failure, while retaining the global retry cap below.
  static const int defaultMaxProtocolRetries = 2;
  static const int defaultMaxToolRetries = 1;
  static const int maxRetryCountCap = 5;
  static const List<Duration> defaultRetryDelays = [
    Duration(milliseconds: 250),
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];
  static const Set<String> _userActionFailureCodes = {
    'userActionRequired',
    'userJudgmentRequired',
    'clarificationRequired',
    'permissionDenied',
    'authorizationRequired',
    'authorizationLost',
    'loginRequired',
    'captchaRequired',
    'paymentRequired',
    'paywall',
    'toolMissing',
  };
  static const Set<int> _userAuthorizationStatusCodes = {401, 403};

  final WorkAgentModel model;
  final WorkToolRegistry registry;
  final AgentDecisionParser parser;
  final WorkTaskEventStore? eventStore;
  final DateTime Function() clock;
  final WorkAgentSleep sleep;
  final WorkAgentEventSink? onEvent;
  final WorkAgentCheckpointSink? onCheckpoint;
  final WorkAgentCompletionGuard? completionGuard;
  final WorkAgentArtifactCompletion? artifactCompletion;
  final WorkAgentPreflightTool? preflightTool;
  final WorkContextBuilder contextBuilder;
  final WorkContextCompressionModel? contextCompressionModel;
  final String Function()? systemPromptBuilder;
  final int maxActions;
  final Duration softTimeLimit;
  final int maxModelRetries;
  final int maxProtocolRetries;
  final int maxToolRetries;
  final String systemPrompt;
  void Function(AgentTask task)? _taskUpdateSink;
  WorkAgentCheckpointSink? _taskCheckpointSink;
  final Map<String, int> _localSequences = <String, int>{};

  WorkAgentLoop({
    required this.model,
    required this.registry,
    AgentDecisionParser? parser,
    this.eventStore,
    DateTime Function()? clock,
    WorkAgentSleep? sleep,
    this.onEvent,
    this.onCheckpoint,
    this.completionGuard,
    this.artifactCompletion,
    this.preflightTool,
    WorkContextBuilder? contextBuilder,
    this.contextCompressionModel,
    this.systemPromptBuilder,
    int? maxActions,
    Duration? softTimeLimit,
    int? maxModelRetries,
    int? maxProtocolRetries,
    int? maxToolRetries,
    this.systemPrompt = '',
  })  : parser = parser ?? const AgentDecisionParser(),
        contextBuilder = contextBuilder ?? const WorkContextBuilder(),
        clock = clock ?? DateTime.now,
        sleep = sleep ?? Future<void>.delayed,
        maxActions = maxActions ?? defaultMaxActions,
        softTimeLimit = softTimeLimit ?? defaultSoftTimeLimit,
        maxModelRetries = _boundRetryCount(
          maxModelRetries ?? defaultMaxModelRetries,
        ),
        maxProtocolRetries = _boundRetryCount(
          maxProtocolRetries ?? defaultMaxProtocolRetries,
        ),
        maxToolRetries = _boundRetryCount(
          maxToolRetries ?? defaultMaxToolRetries,
        );

  static int _boundRetryCount(int value) =>
      value.clamp(0, maxRetryCountCap).toInt();

  @override
  void setTaskUpdateSink(void Function(AgentTask task) sink) {
    _taskUpdateSink = sink;
  }

  @override
  void setTaskCheckpointSink(WorkAgentCheckpointSink sink) {
    _taskCheckpointSink = sink;
  }

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    await execute(task, cancellation: cancellation);
  }

  Future<WorkAgentLoopResult> execute(
    AgentTask task, {
    WorkTaskCancellation? cancellation,
    List<Map<String, dynamic>> conversationHistory = const [],
    ToolRequest? approvedPendingTool,
  }) async {
    final stop = cancellation ?? WorkTaskCancellation();
    final state = _LoopState(
      task: task,
      cancellation: stop,
      conversationHistory: conversationHistory,
      committedActionKeys: _loadCommittedActionKeys(task),
    );
    state.publicUpdates.addAll(_loadPublicUpdates(task));
    state.recentResults.addAll(_loadRecentResults(task));
    state.handoff = _loadHandoff(task);
    state.commandFailureKeys.addAll(_loadCommandFailureKeys(task));
    state.unchangedMutationCount = _loadUnchangedMutationCount(task);
    state.failure = task.workFailure;
    // Terminal tasks are immutable from the execution loop's perspective.
    // Check this before inspecting the discussion marker so a late direct
    // runner call cannot rewrite a completed/failed/cancelled task to paused
    // merely because its optional marker is malformed.
    if (task.isTerminal) {
      return _result(state, _statusForTask(task), task.resultSummary);
    }
    if (workExecutionCheckpointRequiresReview(task.executionStateJson)) {
      return _pauseForCheckpointReview(state);
    }
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    if (WorkDiscussionState.requiresDiscussionForConversation(task.groupId) &&
        discussion.present) {
      final gate = discussion.state;
      String? reason;
      if (gate == null || gate.conversationId != task.groupId) {
        reason = '讨论状态无效，已阻止执行。';
      } else if (!gate.isExecutionReady) {
        reason = '群讨论尚未完成，已阻止执行。';
      } else {
        final executor = gate.executorId?.trim() ?? '';
        if (executor.isEmpty) {
          reason = '群讨论尚未选定最终执行角色。';
        } else if (task.characterId.trim().isNotEmpty &&
            task.characterId != executor) {
          reason = '任务记录的执行角色与群讨论最终执行人不一致。';
        } else if (task.assignedCharacterIds.isNotEmpty &&
            !task.assignedCharacterIds.contains(executor)) {
          reason = '群讨论最终执行人不在任务的合格角色范围内。';
        } else {
          final contractRevision = gate.deliverableContract?['requestRevision'];
          final explicitExecutor =
              gate.deliverableContract?['explicitExecutorId'];
          if (contractRevision is! num ||
              contractRevision.toInt() != gate.requestRevision ||
              (explicitExecutor is String &&
                  explicitExecutor.trim().isNotEmpty &&
                  explicitExecutor.trim() != executor)) {
            reason = '讨论状态与最新请求版本或产物合同不一致。';
          }
          if (reason == null && task.characterId.trim().isEmpty) {
            task.characterId = executor;
          }
        }
      }
      if (reason != null) {
        task
          ..status = AgentTaskStatus.paused
          ..resumeRequired = false
          ..lastError = reason
          ..updatedAt = clock();
        return _result(state, WorkAgentLoopStatus.paused, reason);
      }
    }
    // The full request is intentionally kept in memory while the approval
    // dialog is open, but the durable checkpoint still authenticates which
    // operation may be replayed. Comparing the canonical redacted form
    // prevents a stale or mismatched caller from substituting another tool
    // payload merely because this task happens to have a pending checkpoint.
    final canResumeApprovedTool = approvedPendingTool != null &&
        task.pendingToolRequestJson.trim().isNotEmpty &&
        task.pendingToolRequestJson ==
            safeToolRequestCheckpoint(approvedPendingTool) &&
        (task.status == AgentTaskStatus.queued ||
            task.status == AgentTaskStatus.planning ||
            task.status == AgentTaskStatus.runningTool);
    if (task.status == AgentTaskStatus.completed ||
        task.status == AgentTaskStatus.cancelled ||
        task.status == AgentTaskStatus.failed ||
        ((task.status == AgentTaskStatus.paused ||
                task.status == AgentTaskStatus.interrupted ||
                task.status == AgentTaskStatus.waitingForApproval) &&
            task.resumeRequired &&
            !canResumeApprovedTool)) {
      return _result(state, _statusForTask(task), task.resultSummary);
    }
    // Retries keep the failure visible while queued. User continuations that
    // first re-enter group discussion clear it at the coordinator boundary;
    // this remains the fallback for runs that reach WorkAgentLoop directly.
    if (state.failure != null &&
        (task.status == AgentTaskStatus.queued ||
            task.status == AgentTaskStatus.planning ||
            task.status == AgentTaskStatus.runningTool)) {
      WorkFailure.clearFromTask(task);
      state.failure = null;
      task.lastError = '';
    }
    task.startedAt ??= clock();
    // An approval wait that ended before this run resumed must stop counting
    // against the wall-clock budget. It is folded in against this run's budget
    // origin, so a replanned task cannot inherit an older window's discount.
    _settleBudgetWait(task);

    try {
      var protocolRetryCount = 0;
      if (canResumeApprovedTool) {
        // The coordinator changes a waiting task back to queued after approval.
        // Replaying the exact in-memory request keeps the same model turn and
        // prevents a second planning response from duplicating a write. A
        // redacted request after process restart is intentionally not passed
        // here by default. Missing-tool recovery is the exception: it may
        // provide a complete structured command checkpoint only after a
        // trusted installer succeeds; the normal tool handler still
        // revalidates current policy, path and approval boundaries.
        final publicUpdate = _publicText(approvedPendingTool.reason);
        await _emit(
          state,
          WorkTaskEventKind.stepStarted,
          publicUpdate.isEmpty ? '继续执行已批准操作。' : publicUpdate,
          safeMetadata: {
            'action': AgentDecisionAction.tool.wireName,
            'resumedApproval': true,
            'actionCount': task.actionCount,
          },
        );
        final resumed = await _handleDecision(
          state,
          AgentToolDecision(
            publicUpdate: publicUpdate.isEmpty ? '继续执行已批准操作。' : publicUpdate,
            tool: AgentToolCall(
              name: approvedPendingTool.tool,
              arguments: approvedPendingTool.args,
            ),
          ),
          publicUpdate.isEmpty ? '继续执行已批准操作。' : publicUpdate,
        );
        if (resumed != null) return resumed;
      }
      final preflight = await preflightTool?.call(task);
      if (preflight != null) {
        const publicUpdate = '已找到匹配的专业技能，正在启用并按技能执行。';
        final preflightResult = await _handleDecision(
          state,
          AgentToolDecision(
            publicUpdate: publicUpdate,
            tool: preflight,
          ),
          publicUpdate,
        );
        if (preflightResult != null) return preflightResult;
      }
      while (true) {
        final boundary = await _checkBoundary(state);
        if (boundary != null) return boundary;

        final modelDecisionBoundary = await _startModelDecision(state);
        if (modelDecisionBoundary != null) return modelDecisionBoundary;
        final context = _buildContext(state);
        final request = WorkAgentModelRequest(
          task: task,
          messages: _buildMessages(task, context),
          context: context,
        );
        final response = await _callModelWithRetries(state, request);
        if (stop.isCancelled) return await _interrupt(state);
        // The decision that just returned is already the budgeted model step.
        // Keep its result available for parsing (a finish may complete exactly
        // at the limit), while still stopping a call that crossed the wall
        // clock deadline before it can start another action.
        final postModelBoundary = await _checkBoundary(
          state,
          includeActionLimit: false,
        );
        if (postModelBoundary != null) return postModelBoundary;
        if (response['success'] == false &&
            response['failureCode'] == 'softLimit') {
          return _pauseForLimit(
            state,
            _safeText(
              response['message']?.toString() ?? '已达到执行软上限，请手点继续。',
            ),
          );
        }
        if (_modelFailed(response)) {
          final message =
              _safeText(response['message']?.toString() ?? '模型请求失败。');
          final failure = WorkFailure.fromModelResponse(
            response,
            completedContent: _completedContent(state),
          );
          return _modelNeedsUserAction(response)
              ? _pauseForUserAction(state, message, failure: failure)
              : _fail(state, message, failure: failure);
        }

        final parsed = await parser.parseResponse(
          response,
          repair: (malformed) => _repairModel(state, request, malformed),
        );
        if (parsed.repairAttempted) state.protocolRepairAttempts++;
        if (!parsed.isSuccess) {
          if (protocolRetryCount < maxProtocolRetries) {
            protocolRetryCount++;
            await _emit(
              state,
              WorkTaskEventKind.toolOutput,
              '模型返回格式无效，正在自动重试。',
              detail: '第 $protocolRetryCount 次协议重试',
              safeMetadata: {
                'scope': 'modelProtocol',
                'retry': protocolRetryCount,
              },
            );
            continue;
          }
          return await _fail(
            state,
            parsed.detail ?? '模型返回的 AgentDecision 无法解析。',
            failure: WorkFailure.fromSignalsForProtocol(
              parsed.detail ?? '模型返回的 AgentDecision 无法解析。',
              completedContent: _completedContent(state),
            ),
          );
        }
        protocolRetryCount = 0;
        final decision = parsed.decision!;
        // `raw` is intentionally discarded here. Only public_update and
        // validated tool data can cross the event/checkpoint boundary.
        final publicUpdate = _publicText(decision.publicUpdate);
        await _emit(
          state,
          WorkTaskEventKind.stepStarted,
          publicUpdate,
          safeMetadata: {
            'action': decision.action.wireName,
            'actionCount': task.actionCount,
          },
        );
        if (stop.isCancelled) return await _interrupt(state);

        final next = await _handleDecision(state, decision, publicUpdate);
        if (next != null) return next;
      }
    } on Object catch (error) {
      if (stop.isCancelled) return await _interrupt(state);
      return _fail(
        state,
        _safeText(
            error.toString().trim().isEmpty ? '工作循环失败。' : error.toString()),
        failure: WorkFailure.fromError(
          error,
          scope: 'loop',
          completedContent: _completedContent(state),
        ),
      );
    }
  }
}
