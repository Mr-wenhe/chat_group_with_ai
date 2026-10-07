import 'dart:async';
import 'dart:convert';
import 'work_collaboration_state.dart';
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
import 'work_discussion_investigation.dart';
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
  workItemCompleted,
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
  bool get isWorkItemCompleted =>
      status == WorkAgentLoopStatus.workItemCompleted;
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

/// 一次截断抢救的运行态：抢救写进哪个分段、原本要写哪个目标、救回多少字。
///
/// 它必须落进 `task.executionStateJson` 的运行态字段，不能只留在循环局部变量里：
/// 抢救的**第一次几乎必然要审批**（分段是新路径，要补充审批），而"暂停 → 用户批准
/// → 恢复运行"之间 `execute` 会重新进入，局部变量连同续写指令一起消失。那时模型
/// 只看到 `committedWrites` 里多了个 `report.rescue-<hash>.md`，没有任何"从这里接着
/// 写"的说明，于是重吐全文、再撞上限、再抢救、再弹审批——这条路是被设计出来的
/// 常态路径，不是边角。
///
/// 不存回显用的正文结尾：那是模型原文，没必要为了省一次重读而落盘；恢复后的指令
/// 因此省略结尾回显（见 [_WorkAgentLoopRetry._continuationHint]）。
class _TruncationSalvageState {
  final String truncatedTargetPath;
  final String partPath;
  final int salvagedCharacters;

  const _TruncationSalvageState({
    required this.truncatedTargetPath,
    required this.partPath,
    required this.salvagedCharacters,
  });
}

/// 「原地重建分段文件」护栏的常量，见
/// [_WorkAgentLoopActions._observeStagedRewrite]。
///
/// 阈值只数**真实重复**，不数新建文件个数：2026-09-30 那次私聊三国杀任务的特点是
/// 同一份正文被反复重建（13 个分段的文件名毫无同族关系，只有正文一致），而这正是
/// 普通多文件生成不会有的形状。曾经按"连续新建文件数达到 3"拦截过，结果是
/// "创建六个独立文件"这类正常请求在第三个文件后就被要求直接 finish 并最终暂停。
const int _stagedRewriteRepeatedThreshold = 2;

/// 已记录的分段正文指纹上限。只用来判"这一版是不是又在重建同一份东西"，
/// 保留最近几条就够，不必随步骤数增长。
const int _stagedRewriteFingerprintLimit = 4;

/// 「原地重建分段文件」的判定态（见 [_WorkAgentLoopActions._observeStagedRewrite]）。
///
/// 落检查点，因为护栏必须活着穿过暂停：2026-09-30 那次私聊三国杀任务被软上限
/// 暂停过三次，每次用户点「继续」都是一轮新的空转。计数只在内存里的话，一个
/// 60 分钟的暂停就能把它清零。
class _StagedRewriteState {
  /// 连续**新建**文件的次数（只有新建计数，见 [_observeStagedRewrite]）。
  /// 续写或成功的命令把它清零。
  ///
  /// 命中条件是 [_stagedRewriteRepeatedThreshold] 与"这次的正文与最近几段相同"：
  /// 光有新文件、正文各不相同不算重建，只算在做多份互不相同的交付物。
  final int count;

  /// 已经给过一次纠正指令。第二次命中必须暂停——纠正指令明说了"不要再新建"，
  /// 再犯就不是没听懂，而是做不动。
  final bool corrected;

  /// 最近一次新建文件的相对路径，用来把纠正指令钉在一个具体文件上。
  final String lastPath;

  /// 已记录的一次性写入正文指纹（sha256，**不落正文**）。
  ///
  /// 存指纹而不是正文：检查点是明文持久数据，一条写配置文件的命令不该因为护栏
  /// 把密钥抄进 `agent_tasks.hive`。指纹取**整份原始**正文：只比开头会把共用
  /// 版权头/HTML 模板头的独立文件误判成同一份东西，折叠空白则会把两份显示结果
  /// 不同的正文（`<pre>` 里的空格数）判成同一份。
  ///
  /// 落盘键叫 `writeDigests`，刻意避开 `_isPrivateField` 的正文黑名单（含
  /// `content` 子串的键会在检查点里被整体丢掉，护栏就活不过一次暂停）。
  final List<String> writeDigests;

  const _StagedRewriteState({
    this.count = 0,
    this.corrected = false,
    this.lastPath = '',
    this.writeDigests = const <String>[],
  });

  bool get isEmpty =>
      count == 0 && !corrected && lastPath.isEmpty && writeDigests.isEmpty;
}

/// [_WorkAgentLoopActions._stepStagedRewrite] 的结果。
///
/// [next] 只在没有暂停时使用：第二次命中要暂停，暂停不写状态（记录留给用户
/// 处置后的下一次运行），所以那一支的 [next] 是可忽略的。
class _StagedRewriteStep {
  final _StagedRewriteState next;
  final bool hit;
  final bool repeatedContent;
  final int count;

  const _StagedRewriteStep({
    required this.next,
    required this.hit,
    required this.repeatedContent,
    required this.count,
  });
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
  // Sized to ride out an ordinary link hiccup or a short provider brownout on
  // its own: the ladder below spans about twelve seconds of waiting across five
  // attempts. Anything longer is the coordinator's auto-resume layer's job, so
  // this budget does not need to grow with the outage length.
  static const int defaultMaxModelRetries = 4;
  // A protocol drift is recoverable without user input. Allow three fresh
  // decisions after the one bounded repair attempt before surfacing a task
  // failure, while retaining the global retry cap below.
  static const int defaultMaxProtocolRetries = 3;
  // 一次成功的截断抢救能换来几次「接着写」的续写决策。
  //
  // 与协议重试额度**分开**：抢救花的是那份额度，两条线合用一个计数器时会出现
  // "抢救跑完却立刻判失败"的顺序（`execute` 里判额度的位置见
  // `WorkAgentLoop` 的截断分支）。分开之后它也要有界——续写指令要求的是每次
  // ≤3000 字的 `append`，本就不会再撞上限，两次足以覆盖"抢救后又截断一次"，
  // 而真正的失控由动作数上限兜住（抢救写入计入动作数，是设计刻意如此）。
  static const int _salvageContinuationBudget = 2;
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

  /// Full tool results are available only at this real execution boundary;
  /// public checkpoints still use the existing redacted projection.
  final FutureOr<void> Function(AgentTask, AgentToolCall, WorkToolResult)?
      onToolResult;
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
    this.onToolResult,
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

  /// One investigation action through the same registry, retry, event and
  /// progress boundaries. It completes an action, never the parent task.
  Future<WorkInvestigationResult> investigate(
    AgentTask task,
    AgentToolCall call,
    WorkInvestigationBinding binding,
    WorkTaskCancellation cancellation,
  ) async {
    if (!binding.matches(task) ||
        cancellation.isCancelled ||
        !WorkToolRegistry.investigationToolNames.contains(call.name)) {
      return const WorkInvestigationResult(
          result: WorkToolResult.permissionDenied(
              message: '调查归属失效或工具不属于受控只读能力，未执行。'));
    }
    final state = _LoopState(
        task: task,
        cancellation: cancellation,
        conversationHistory: const [],
        committedActionKeys: _loadCommittedActionKeys(task));
    var started = false;
    final result = await _callToolWithRetries(state, call, actionStarter: () {
      if (!binding.matches(task) || cancellation.isCancelled) {
        return const WorkToolResult.paused(message: '需求或成员版本已变化，调查停止。');
      }
      if (!started) {
        task.actionCount++;
        started = true;
      }
      return null;
    });
    if (cancellation.isCancelled || !binding.matches(task)) {
      return WorkInvestigationResult(
          result: WorkToolResult.paused(
              message: '调查结果属于旧版需求，未推进当前问题。', data: result.data));
    }
    final observation = _toolProgressObservation(call, result);
    final guard = WorkProgressGuard.observe(
        _decodeMap(task.executionStateJson), observation,
        now: clock());
    task.executionStateJson = jsonEncode(guard.executionState);
    await _emit(state, WorkTaskEventKind.toolOutput,
        result.message.isEmpty ? '调查动作已返回。' : result.message,
        detail:
            '调查凭据 investigation:${task.id}:${task.actionCount}；成员 ${binding.memberId}；问题 ${binding.issueId}；需求版本 ${binding.requestRevision}；工具 ${call.name.wireName}；来源 ${call.arguments['path'] ?? ''}；结果摘要 SHA256 ${sha256.convert(utf8.encode(jsonEncode(result.data)))}',
        safeMetadata: {
          'evidenceRef': 'investigation:${task.id}:${task.actionCount}',
          'phase': 'investigation',
          'memberId': binding.memberId,
          'issueId': binding.issueId,
          'requestRevision': binding.requestRevision,
          'teamRevision': binding.teamRevision,
          'tool': call.name.wireName
        });
    return WorkInvestigationResult(
        result: result,
        evidenceRef: 'investigation:${task.id}:${task.actionCount}',
        stalled: guard.stalled);
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
    state.stagedRewrite = _loadStagedRewrite(task);
    // 纠正指令由判定态派生而不是单独落盘：暂停会打断这次 execute，
    // 恢复时按同样的规则重建即可，两边不会说不一样的话。
    if (state.stagedRewrite.corrected) {
      state.stagedRewriteInstruction =
          _stagedRewriteInstruction(state.stagedRewrite.lastPath);
    }
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
    if (_decodeMap(task.executionStateJson).containsKey('uncertainAction')) {
      return _pauseForUserAction(state, '上次操作结果不确定，请先核对真实后置条件，未重放副作用。');
    }
    // 一次新运行从"本次运行写出的路径"清零开始（失败报告的附件只认这一段）。
    //
    // 两处顺序都是判据的一部分，不要挪：①在终态早退之后——终态任务上的一次迟到
    // 调用不该擦掉上一次运行的记录；②在检查点审查之后——写这条状态要解码再重新
    // 编码 `executionStateJson`，而 `_decodeMap` 会把畸形检查点悄悄读成 `{}`：
    // 排在审查之前，就等于抢在审查看见它之前把畸形抹平了，任务会带着损坏的检查点
    // 直接开跑。
    _resetRunArtifactPaths(task);
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    if (WorkDiscussionState.requiresDiscussionForConversation(task.groupId) &&
        discussion.present) {
      final gate = discussion.state;
      String? reason;
      if (gate == null || gate.conversationId != task.groupId) {
        reason = '讨论状态无效，已阻止执行。';
      } else if (gate.collaboration != null) {
        final binding =
            _decodeMap(task.executionStateJson)['workItemExecution'];
        final collaboration = gate.collaboration!;
        if (!gate.isExecutionReady ||
            binding is! Map ||
            binding['requestRevision'] != collaboration.requestRevision ||
            binding['teamRevision'] != collaboration.teamRevision ||
            binding['verificationRevision'] !=
                collaboration.verificationRevision ||
            binding['actorId'] != task.characterId ||
            !collaboration.activeMembers.contains(task.characterId)) {
          reason = '当前成员工作项或版本未通过执行门槛。';
        }
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
      // 这一次决策要带的续写指令（截断之后才非空）。它要跨迭代保留：截断说明
      // "一次写完"这个策略不可行，下一次决策必须换成分块/续写指令，否则只是原样
      // 再撞一次上限。抢救成功时它是"接着哪个分段文件写"的具体指令，失败时退回
      // 通用的分块话术。`salvaged` 与它同寿命，只用来给事件标题选措辞。
      var continuationHint = '';
      var salvaged = false;
      // 抢救自己那份额度。抢救花的是协议重试的额度，两条线合用一个计数器时会
      // 出现"抢救跑完却立刻判失败"的顺序——见 `_salvageContinuationBudget`。
      var salvageContinuations = 0;
      // 上一次运行留下的抢救运行态。审批暂停会把这次 execute 打断，所以它不在
      // 局部变量里，而在检查点的运行态字段里（[_TruncationSalvageState]）。
      final salvage = _loadTruncationSalvage(task);
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
      // 恢复"从这里续写"的指令：只有当那次抢救写入**确实已经落盘**时才重建。
      // 记录写得比写入早（否则审批暂停会把指令一起丢掉），所以"记录在"不等于
      // "内容在"——用户拒绝审批、写入失败时记录仍在，此时重建指令会告诉模型
      // "前缀已经在分段文件里"，它就只写余下部分，合并出来的交付物缺了前半截，
      // 比不救更糟。已提交的落地痕迹（`committedActionKeys` 里的操作键带明文
      // 路径）是这里唯一的判据，重放刚提交的那次写入同样落进来。
      if (salvage != null && _salvageLanded(state, salvage)) {
        continuationHint = _restoredContinuationHint(salvage);
        salvaged = true;
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
          final withinProtocolBudget = protocolRetryCount < maxProtocolRetries;
          if (withinProtocolBudget) protocolRetryCount++;
          // 抢救成功了就必须有一次续写机会，哪怕协议重试的额度刚好用尽。抢救的
          // 全部意义就是把"一次写不完"转成"接着写"，而它恰恰花的是协议重试的额度：
          // 额度先耗尽的顺序下，抢救会落盘一次分段、计一次动作数、多一个附件候选，
          // 然后同一秒判失败——收益一分不兑现（2026-10-01 00:07 现场：38742 字
          // 落盘，紧跟着 `failed 任务未完成。模型输出达到上限被截断`）。
          final withinSalvageBudget = salvaged &&
              !withinProtocolBudget &&
              salvageContinuations < _salvageContinuationBudget;
          if (withinSalvageBudget) salvageContinuations++;
          if (withinProtocolBudget || withinSalvageBudget) {
            await _emit(
              state,
              WorkTaskEventKind.toolOutput,
              _protocolRetryTitle(
                truncated: truncated,
                repairRequestFailed: repairRequestFailed,
                salvaged: salvaged,
              ),
              detail: withinProtocolBudget
                  ? '第 $protocolRetryCount 次协议重试'
                  : '抢救后续写（协议重试额度已用尽）',
              safeMetadata: {
                'scope': 'modelProtocol',
                'retry': protocolRetryCount,
                if (!withinProtocolBudget) 'salvageContinuation': true,
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
        // 这一次决策成功了：续写指令已经送达并被采纳，运行态随之作废。留着它会让
        // 后续任何一次恢复都重新念一遍"从那个分段文件接着写"。
        _clearTruncationSalvage(task);
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
  /// 抢救写入带 `overwrite: false`。"派生路径按内容哈希命名，首次必然不存在"
  /// 只在**任务内**成立：哈希只由内容决定，所以同一目录、同一目标名、字节级相同的
  /// 前缀若在更早的任务里写过同名文件，`append` 会把这段**再接一遍**——静默的内容
  /// 翻倍比少救一次危险得多，于是改成 `overwrite: false`（`_overwriteRefusal` 对每种
  /// 形态同义）：撞名时这次抢救失败、退回话术路径，任务照常继续。任务内的重复抢救
  /// 仍由 `committedActionKeys` 在进 handler 之前去重，不受影响。
  AgentToolCall _salvageRequest(String rescuedPath, String content) =>
      AgentToolCall(
        name: AgentToolName.workspacePatch,
        arguments: {
          'path': rescuedPath,
          'content': content,
          'append': true,
          'overwrite': false,
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
    final salvage =
        WorkTruncationSalvage.extract(_responseBody(response) ?? '');
    if (salvage == null) return _truncationSalvageFallback;
    final rescuedPath = WorkTruncationSalvage.rescuePath(
      salvage.targetPath,
      salvage.content,
    );
    final characters = salvage.content.length;
    // 运行态先落盘、再发起写入：写入会弹审批、把任务带离循环，而"从这里续写"的
    // 指令必须活过那次暂停（[_TruncationSalvageState]）。
    _persistTruncationSalvage(
      state.task,
      _TruncationSalvageState(
        truncatedTargetPath: salvage.targetPath,
        partPath: rescuedPath,
        salvagedCharacters: characters,
      ),
    );
    // 抢救的来源必须**在弹审批之前**就写进事件流。只把它放进 `ToolRequest.reason`
    // 不够——那条字段不进事件，于是任务暂停在审批上时，用户看到的弹窗与"模型主动
    // 创建了一个陌生 hash 名文件"完全同形（设计 §4.3：审批与事件的文案都要标明
    // 来源是截断抢救）。
    await _emit(
      state,
      WorkTaskEventKind.toolOutput,
      '模型输出被上限截断，正在抢救已生成的 $characters 字：先落入分段文件再续写余下部分。',
      detail: rescuedPath,
      safeMetadata: {
        'scope': 'truncationSalvage',
        'truncated': true,
        'partPath': rescuedPath,
        'truncatedTargetPath': salvage.targetPath,
        'salvagedCharacters': characters,
      },
    );
    final notice = '截断抢救（不是新的交付物）：把已生成的 $characters 字先写入分段文件，随后续写余下部分。';
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
      committed ? '已抢救被截断的输出：$characters 字写入分段文件。' : '抢救被截断的输出未落盘，将按精简指令重试。',
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
    if (!committed) {
      // 没落盘就把运行态撤掉：留着它等于让下一次恢复（或下一个任务）被告知"前缀
      // 已经在那个分段文件里"（见 [execute] 里的落地判据）。
      _clearTruncationSalvage(state.task);
      return _truncationSalvageFallback;
    }
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

  /// 恢复运行时的续写指令。
  ///
  /// 与抢救当场那条只差结尾回显：运行态里没有（也不该有）模型原文，恢复后的模型
  /// 手里已有那份分段文件的路径，重读一遍比把上千字原文落进检查点便宜得多。
  String _restoredContinuationHint(_TruncationSalvageState salvage) =>
      _continuationHint(
        targetPath: salvage.truncatedTargetPath,
        rescuedPath: salvage.partPath,
        rescuedCharacters: salvage.salvagedCharacters,
      );

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
  ///
  /// 按 `runes` 切，不按 UTF-16 码元：`substring(length - 200)` 可能正好劈开一个
  /// 代理对，产出的孤立代理在 `utf8.encode` 时静默变成 U+FFFD——而这段回显的用途
  /// 恰恰是让模型接上原文，凭空多出一个字符比少两个字更糟。
  String _boundedTail(String content) {
    final runes = content.runes.toList(growable: false);
    if (runes.length <= _salvageTailCharacters) return content;
    return String.fromCharCodes(
      runes.sublist(runes.length - _salvageTailCharacters),
    );
  }
}
