import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/agent_decision_parser.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_confirmation.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_guard.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_context_builder.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_handoff_state.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_model_deadline.dart';
import 'package:chat_group/features/work_mode/work_prompt_context_compactor.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/work_task_clarification.dart';
import 'package:chat_group/features/work_mode/work_task_budget_wait.dart';
import 'package:chat_group/features/work_mode/work_task_execution_policy.dart';
import 'package:chat_group/features/work_mode/work_truncation_salvage.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:crypto/crypto.dart';

part 'work_agent_loop_retry.dart';
part 'work_agent_loop_checkpoint.dart';
part 'work_agent_loop_safety.dart';
part 'work_agent_loop_actions.dart';

/// 续写提示里回显的"已落盘内容结尾"长度。
///
/// 它只用来让模型无缝接上下一句，所以取一小段即可。把整份已抢救内容回灌进
/// prompt 会让窗口先被这次失败烧掉一遍——而那正是要补救的问题。
const int _salvageTailCharacters = 200;

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
typedef WorkAgentArtifactConfirmation = FutureOr<List<String>> Function(
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

/// 抢救结果：无论成功与否，`hint` 都是下一次决策要带的续写指令。
///
/// [stop] 非空表示抢救这次工具请求本身就把任务带离了循环（典型是等待审批），
/// 调用方必须原样返回它——抢救走的是模型自己写文件时的那条管线，不能绕过它的
/// 暂停语义。
class _TruncationSalvageOutcome {
  final WorkAgentLoopResult? stop;
  final String hint;
  final String? rescuedPath;
  final int rescuedCharacters;

  const _TruncationSalvageOutcome({
    this.stop,
    required this.hint,
    this.rescuedPath,
    this.rescuedCharacters = 0,
  });
}

/// 抢救没能落盘（提取不出内容、被拒、写入失败）时的结果：退回通用的分块话术，
/// 让模型至少还能从头分块写。
const _TruncationSalvageOutcome _truncationSalvageFallback =
    _TruncationSalvageOutcome(hint: _truncatedOutputChunkingAdvice);

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
  // Sized to ride out an ordinary link hiccup or a short provider brownout on
  // its own: the ladder below spans about twelve seconds of waiting across five
  // attempts. Anything longer is the coordinator's auto-resume layer's job, so
  // this budget does not need to grow with the outage length.
  static const int defaultMaxModelRetries = 4;
  // A protocol drift is recoverable without user input. Allow three fresh
  // decisions after the one bounded repair attempt before surfacing a task
  // failure, while retaining the global retry cap below.
  static const int defaultMaxProtocolRetries = 3;
  // How many times a command the input validator rejected may be replanned
  // before that rejection is surfaced. Deliberately separate from the protocol
  // retry budget: a rejected command carries its own failure text and remedy, so
  // a change to protocol-drift handling must not widen it.
  static const int defaultMaxInvalidCommandRepairs = 2;
  static const int defaultMaxToolRetries = 1;
  // How many times one task may hand a failed tool call back to the model for a
  // repair before pausing for the user. The failure-history detectors only
  // recognise repeated fingerprints and outcomes, so a model that keeps
  // proposing new, equally broken calls needs this separate bound. It is set
  // well above real convergence (a write/compile/fix loop usually converges in
  // one to three rounds) so a task that is still making progress is never
  // paused for being slow; the 100-action budget remains the outer limit.
  static const int defaultMaxToolRepairs = 8;
  // How many times a rejected finish may be handed back to the model before the
  // task fails. Unlike the tool budget this one is deliberately small: a
  // completion guard failure means the model claimed done work that is not
  // there, so a couple of corrections are worth trying, and beyond that the
  // claim is the problem. The count restarts whenever a tool call succeeds, so
  // this bounds one progress segment rather than the whole run; the 100-action
  // budget is what bounds the run.
  static const int defaultMaxCompletionRepairs = 2;
  static const int maxRetryCountCap = 5;

  /// Fraction by which a model/tool backoff delay is randomly stretched or
  /// shaved (0.2 = ±20%), so two concurrent tasks do not retry in lockstep.
  /// Injected as a 0..1 sample; a server-provided Retry-After is never jittered.
  static const double retryJitterRatio = 0.2;
  // Must have one entry per configured retry: a shorter ladder silently repeats
  // its last delay and turns the extra retries into back-to-back attempts.
  static const List<Duration> defaultRetryDelays = [
    Duration(milliseconds: 250),
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 8),
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

  /// Names the readable files the run wrote, so a rejected completion can ask
  /// the user instead of failing when the guard cannot recognise the
  /// deliverable. Empty means there is nothing to offer, which keeps the plain
  /// failure for a run that really did write nothing.
  final WorkAgentArtifactConfirmation? artifactConfirmation;
  final WorkContextBuilder contextBuilder;
  final WorkContextCompressionModel? contextCompressionModel;
  final String Function()? systemPromptBuilder;

  /// 提示词上下文的压缩预算（token）。null 表示不压缩。
  ///
  /// 由宿主按模型能力算出来（`ContextWindowManager.workPromptCompactionBudget`），
  /// 循环本身不认识模型窗口——它只负责在装配提示词时把预算交给
  /// [WorkPromptContextCompactor]。
  final int? promptCompactionBudgetTokens;
  final int maxActions;
  final Duration softTimeLimit;
  final int maxModelRetries;
  final int maxProtocolRetries;
  final int maxToolRetries;
  final int maxToolRepairs;
  final int maxCompletionRepairs;

  /// Returns a 0..1 sample used to jitter a backoff delay. Injectable so tests
  /// can pin the delay; production uses [Random.nextDouble].
  final double Function() retryJitter;
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
    this.artifactConfirmation,
    WorkContextBuilder? contextBuilder,
    this.contextCompressionModel,
    this.systemPromptBuilder,
    this.promptCompactionBudgetTokens,
    int? maxActions,
    Duration? softTimeLimit,
    int? maxModelRetries,
    int? maxProtocolRetries,
    int? maxToolRetries,
    int? maxToolRepairs,
    int? maxCompletionRepairs,
    double Function()? retryJitter,
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
        ),
        maxToolRepairs = _boundRetryCount(
          maxToolRepairs ?? defaultMaxToolRepairs,
        ),
        maxCompletionRepairs = _boundRetryCount(
          maxCompletionRepairs ?? defaultMaxCompletionRepairs,
        ),
        retryJitter = retryJitter ?? Random().nextDouble;

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
      if (!WorkTaskExecutionPolicy.isValidatedV2GroupTask(task) ||
          WorkProgressGuard.snapshot(task)['stalled'] != true) {
        WorkFailure.clearFromTask(task);
        state.failure = null;
        task.lastError = '';
      }
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
      // 这一次决策要带的续写指令（截断之后才非空）。它要跨迭代保留：截断说明
      // "一次写完"这个策略不可行，下一次决策必须换成分块/续写指令，否则只是原样
      // 再撞一次上限。抢救成功时它是"接着哪个分段文件写"的具体指令，失败时退回
      // 通用的分块话术。`salvaged` 与它同寿命，只用来给事件标题选措辞。
      var continuationHint = '';
      var salvaged = false;
      while (true) {
        final boundary = await _checkBoundary(state);
        if (boundary != null) return boundary;

        final modelDecisionBoundary = await _startModelDecision(state);
        if (modelDecisionBoundary != null) return modelDecisionBoundary;
        final context = _buildContext(state);
        final request = WorkAgentModelRequest(
          task: task,
          messages: _buildMessages(
            task,
            context,
            continuationHint: continuationHint,
          ),
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
          final stalled = await _observeV2Progress(
            state,
            WorkProgressObservation(
              kind: WorkProgressObservationKind.failure,
              fingerprint: sha256
                  .convert(utf8.encode(
                    '${response['failureCode'] ?? 'model'}|${response['statusCode'] ?? ''}',
                  ))
                  .toString(),
              summary: '模型请求失败（${response['failureCode'] ?? 'model'}）。',
              missing: '需要可用的模型响应或新的服务条件。',
            ),
          );
          if (stalled != null) return stalled;
          final failure = WorkFailure.fromModelResponse(
            response,
            completedContent: _completedContent(state),
          );
          return _modelNeedsUserAction(response)
              ? _pauseForUserAction(state, message, failure: failure)
              : _fail(state, message, failure: failure);
        }

        final truncated = _responseHitsOutputLimit(response);
        final parsed = await parser.parseResponse(
          response,
          repair: (malformed) => _repairModel(
            state,
            request,
            malformed,
            wasTruncated: truncated,
          ),
        );
        if (parsed.repairAttempted) state.protocolRepairAttempts++;
        if (!parsed.isSuccess) {
          // 截断才是这次不可解析的原因，它比解析器的具体校验信息更值得上报：
          // 用户据此才知道该收窄要求或换模型，而不是以为模型不会写 JSON。
          if (truncated) {
            final outcome = await _salvageTruncatedOutput(state, response);
            if (outcome.stop != null) return outcome.stop!;
            continuationHint = outcome.hint;
            salvaged = outcome.rescuedPath != null;
          } else {
            continuationHint = '';
            salvaged = false;
          }
          final repairRequestFailed = parsed.repairRequestFailed;
          final detail = truncated
              ? _truncatedOutputDetail(response)
              : (parsed.detail ?? '模型返回的 AgentDecision 无法解析。');
          if (protocolRetryCount < maxProtocolRetries) {
            protocolRetryCount++;
            await _emit(
              state,
              WorkTaskEventKind.toolOutput,
              _protocolRetryTitle(
                truncated: truncated,
                repairRequestFailed: repairRequestFailed,
                salvaged: salvaged,
              ),
              detail: '第 $protocolRetryCount 次协议重试',
              safeMetadata: {
                'scope': 'modelProtocol',
                'retry': protocolRetryCount,
                if (truncated) 'truncated': true,
                if (repairRequestFailed) 'repairRequestFailed': true,
                ..._protocolFailureDiagnostics(
                  response,
                  detail,
                  repairResponseSnippet: state.repairResponseSnippet,
                ),
              },
            );
            continue;
          }
          return await _fail(
            state,
            detail,
            failure: WorkFailure.fromSignalsForProtocol(
              detail,
              completedContent: _completedContent(state),
            ),
          );
        }
        protocolRetryCount = 0;
        continuationHint = '';
        salvaged = false;
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

        // _emit yields to the event store. A supplement may land in that
        // window after the model returned but before its tool action starts.
        final changedBeforeAction = await _checkBoundary(
          state,
          includeActionLimit: false,
        );
        if (changedBeforeAction != null) return changedBeforeAction;

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

  /// 抢救写入合成的工具请求：一次 `workspace.patch` **追加写**。
  ///
  /// `append: true` 不只是"文件不存在就创建"：它正是**"这次写还不是交付物的最终
  /// 形态"这个契约标记**（`_artifactToolChanged`，`default_work_task_runner_delivery.dart`）。
  /// 缺了它，与目标同目录、同扩展名、mtime 新鲜的暂存分段会立刻满足交付物契约，
  /// 任务带着被截断的前缀 `completed`、交付一个残缺文件，而这条续写指令永远等不
  /// 到下一轮。
  ///
  /// 不带 `overwrite`：派生路径按内容哈希命名，首次必然不存在；同内容重复抢救的
  /// 参数逐字相同，会被 `committedActionKeys` 在进 handler 之前去重。
  AgentToolCall _salvageRequest(String rescuedPath, String content) =>
      AgentToolCall(
        name: AgentToolName.workspacePatch,
        arguments: {
          'path': rescuedPath,
          'content': content,
          'append': true,
        },
      );

  /// 把一次被截断的写入抢救成分段文件，并给出下一次决策的续写指令。
  ///
  /// 抢救走 [_handleDecision]，于是审批、快照、事件、检查点与去重全部沿用模型
  /// 自己写文件时的那条管线——它是**真实的工具请求**，不是直写文件。
  ///
  /// 它同时是一次止损：提取不出内容、写入被拒或没落盘时，返回的 `hint` 仍是
  /// 通用的分块话术，任务照常重试，绝不因为抢救没成功而失败。落盘走
  /// [_salvageRequest]（一次追加写），它不是交付物。
  Future<_TruncationSalvageOutcome> _salvageTruncatedOutput(
    _LoopState state,
    Map<String, dynamic> response,
  ) async {
    final salvage = WorkTruncationSalvage.extract(_responseBody(response) ?? '');
    if (salvage == null) return _truncationSalvageFallback;
    final rescuedPath = WorkTruncationSalvage.rescuePath(
      salvage.targetPath,
      salvage.content,
    );
    const notice = '已抢救被截断的输出，先写入分段文件再继续。';
    final stop = await _handleDecision(
      state,
      AgentToolDecision(
        publicUpdate: notice,
        tool: _salvageRequest(rescuedPath, salvage.content),
      ),
      notice,
    );
    if (stop == null) {
      return _reportSalvageOutcome(state, salvage, rescuedPath);
    }
    if (stop.status != WorkAgentLoopStatus.failed) {
      // 需要审批（或到达软上限）时，这次抢救和模型的工具请求一样把任务带离循环，
      // 按既有语义原样返回，不绕过它的暂停。
      return _TruncationSalvageOutcome(
        stop: stop,
        hint: _truncationSalvageFallback.hint,
      );
    }
    // 抢救写入自己失败（`pathRejected`，或工具根本不在注册表里）。抢救只是止损，
    // 不能成为新的失败源：拨回 `_fail` 写下的终态，退回话术路径继续，而不是让一次
    // 补救动作判死任务。注意此时**不能**用 `recentResults.last` 判断落盘结果：
    // 这个分支可能在结果被记录之前就返回（`registry.validate` 失败），那读到的会
    // 是更早的一次成功写入，于是发出一条点名不存在文件的续写指令。
    await _clearSalvageFailure(state);
    return _reportSalvageOutcome(
      state,
      salvage,
      rescuedPath,
      failedReason: _publicText(stop.message),
    );
  }

  /// 公布一次抢救的结果，并给出下一次决策要带的续写指令。
  ///
  /// [failedReason] 非空表示写入工具自身失败（结果未必进过 `recentResults`），
  /// 此时一律按未落盘处理。
  Future<_TruncationSalvageOutcome> _reportSalvageOutcome(
    _LoopState state,
    WorkTruncationSalvage salvage,
    String rescuedPath, {
    String failedReason = '',
  }) async {
    final characters = salvage.content.length;
    final committed = failedReason.isEmpty &&
        state.recentResults.isNotEmpty &&
        state.recentResults.last['committed'] == true;
    final resultReason = state.recentResults.isEmpty
        ? ''
        : _publicText(state.recentResults.last['message']?.toString() ?? '');
    await _emit(
      state,
      WorkTaskEventKind.toolOutput,
      committed
          ? '已抢救被截断的输出：$characters 字写入分段文件。'
          : '抢救被截断的输出未落盘，将按精简指令重试。',
      detail: committed
          ? rescuedPath
          : _salvageFailureDetail(
              failedReason: failedReason,
              resultReason: resultReason,
            ),
      safeMetadata: {
        'scope': 'truncationSalvage',
        'salvaged': committed,
        'salvagedCharacters': characters,
        'partPath': rescuedPath,
        'truncatedTargetPath': salvage.targetPath,
      },
    );
    if (!committed) return _truncationSalvageFallback;
    return _TruncationSalvageOutcome(
      hint: _continuationHint(
        targetPath: salvage.targetPath,
        rescuedPath: rescuedPath,
        rescuedCharacters: characters,
        rescuedTail: _boundedTail(salvage.content),
      ),
      rescuedPath: rescuedPath,
      rescuedCharacters: characters,
    );
  }

  /// 抢救没落盘时的公开原因。
  ///
  /// 写入工具自身失败时，`_handleDecision` 已经先落了一条「任务未完成。」——那是
  /// 这次止损动作留下的，不是任务的结局（[`_clearSalvageFailure`] 已把状态拨回）。
  /// 撤销不了那条事件，就在这条里把口径点明，免得用户把红色失败读成本任务的结局。
  String _salvageFailureDetail({
    required String failedReason,
    required String resultReason,
  }) {
    final reason = failedReason.isNotEmpty ? failedReason : resultReason;
    final base = reason.isEmpty ? '分段文件未能写入。' : reason;
    if (failedReason.isEmpty) return base;
    return '$base 抢救写入只是止损：上一条「任务未完成。」来自这次抢救本身，'
        '可以忽略，任务会按精简指令继续。';
  }

  /// 撤掉一次失败抢救留在任务上的终态。
  ///
  /// 抢救必须经 [_handleDecision] 才能拿到审批、快照与去重，而那条管线的失败
  /// 分支会把任务判成 `failed` 并持久化失败——那不是一次止损动作该有的结局。
  /// 这里把失败标记、状态与错误文案逐项拨回可继续的样子，让循环退回话术路径。
  Future<void> _clearSalvageFailure(_LoopState state) async {
    final task = state.task;
    state.failure = null;
    WorkFailure.clearFromTask(task);
    task
      ..status = AgentTaskStatus.runningTool
      ..resumeRequired = false
      ..lastError = ''
      ..pendingToolRequestJson = '';
    await _checkpoint(state);
  }

  /// 抢救内容的结尾片段，用来让模型无缝接上：只取有界的一段，绝不把整份
  /// 已生成内容回灌进 prompt。
  String _boundedTail(String content) => content.length <= _salvageTailCharacters
      ? content
      : content.substring(content.length - _salvageTailCharacters);
}
