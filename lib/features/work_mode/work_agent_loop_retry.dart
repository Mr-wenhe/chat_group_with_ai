part of 'work_agent_loop.dart';

/// 输出被上限截断时给模型的唯一出路：把这次写入拆小。
///
/// 只要求"输出合法 JSON"没有用——被截断的正是"一次写完整份文件"这个动作，
/// 原样重试必然再撞上限。截断修复与协议重试共用同一句话，避免两处措辞漂移。
///
/// 措辞里刻意不提"追加"：`workspace.patch` 是整文件覆盖写、没有追加，让模型
/// "再往目标文件写一段"会把前一段冲掉，而它还以为拼好了。
const String _truncatedOutputChunkingAdvice =
    '这一次的输出太大：把内容拆成多次动作——每个分段各写一个**独立的分段文件**'
    '（workspace.patch，每次 content 控制在 3000 字以内），'
    '全部写完后再用一次 command.run 合并成目标文件（Markdown 转 DOCX 可把各分段'
    '一起交给 pandoc），然后读回并交付；'
    '不要反复往目标文件写，也不要把整份内容放进一次动作。';

/// 输出预算的判定余量（取 1/N）。供应商的计数不会与请求预算精确对齐，所以
/// "用满"必须按"基本用满"判定。实测（2026-09-30，SensoNova 6.8 flash-lite）：
/// 请求上限 20480，模型输出 20331 token 后被切断，正文 JSON 没有收尾，供应商
/// 既没给 `finish_reason=length`，计数也停在预算以下 149。
const int _outputBudgetMarginDivisor = 20;

extension _WorkAgentLoopRetry on WorkAgentLoop {
  Future<WorkToolResult> _callToolWithRetries(
    _LoopState state,
    AgentToolCall call, {
    required WorkToolActionStarter actionStarter,
  }) async {
    WorkToolResult? last;
    for (var attempt = 0; attempt <= maxToolRetries; attempt++) {
      if (state.cancellation.isCancelled) {
        return const WorkToolResult.paused(message: '工具执行已停止。');
      }
      if (_budgetExceeded(state)) {
        return const WorkToolResult.paused(
          message: '已达到执行软上限，请手点继续。',
          failureCode: 'softLimit',
        );
      }
      last = await registry.execute(
        call,
        context: WorkToolExecutionContext(
          task: state.task,
          cancellation: state.cancellation,
          clock: clock,
          state: {
            ..._buildContext(state),
            // Approval gates may allow a retry of the exact operation that
            // already passed once, while a fresh model operation must ask
            // again for high-risk or irreversible changes.
            'toolRetryAttempt': attempt,
          },
          actionStarter: actionStarter,
        ),
      );
      if (!last.retryable || last.committed || attempt == maxToolRetries) {
        return last;
      }
      state.toolRetryCount++;
      await _emit(
        state,
        WorkTaskEventKind.toolOutput,
        '工具暂时失败，准备重试。',
        detail: '第 ${attempt + 1} 次重试',
        safeMetadata: {
          'tool': call.name.wireName,
          'retry': attempt + 1,
        },
      );
      await _delayFor(state, attempt);
    }
    return last ?? const WorkToolResult.failed(message: '工具执行失败。');
  }

  Future<Map<String, dynamic>> _callModelWithRetries(
    _LoopState state,
    WorkAgentModelRequest request,
  ) async {
    Map<String, dynamic>? last;
    for (var attempt = 0; attempt <= maxModelRetries; attempt++) {
      if (state.cancellation.isCancelled) return const {};
      if (attempt > 0 && _budgetExceeded(state)) {
        return const {
          'success': false,
          'failureCode': 'softLimit',
          'message': '已达到执行软上限，请手点继续。',
        };
      }
      try {
        last = await model(request.copyWith(retryNumber: attempt));
      } on Object catch (error) {
        final failure = WorkFailure.fromError(error, scope: 'model');
        last = {
          'success': false,
          // Feed the already-sanitized reason back through the normal model
          // boundary. Keeping the stable category here is important for
          // exceptions such as a Dio 401/403 where the adapter did not provide
          // a separate statusCode field; those must pause for reauthorization
          // instead of becoming an opaque internal failure.
          'message': failure.reason,
          'failureCode': failure.type.name,
          // WorkFailure extends the old retry helper to include all 5xx
          // responses and keeps the classification identical at the final
          // checkpoint.
          'retryable': failure.retryable,
        };
      }
      final response = last;
      final transient = _modelFailed(response) &&
          !_modelNeedsUserAction(response) &&
          WorkFailure.fromModelResponse(response).retryable;
      if (!transient || attempt == maxModelRetries) {
        return response;
      }
      state.modelRetryCount++;
      await _emit(
        state,
        WorkTaskEventKind.toolOutput,
        '模型请求暂时失败，准备重试。',
        detail: '第 ${attempt + 1} 次重试',
        safeMetadata: {'retry': attempt + 1, 'scope': 'model'},
      );
      await _delayFor(
        state,
        attempt,
        retryAfter: _retryAfter(response),
      );
    }
    return last ?? const {};
  }

  Duration? _retryAfter(Map<String, dynamic>? response) {
    final milliseconds = response?['retryAfterMs'];
    if (milliseconds is! num || milliseconds < 0) return null;
    final bounded = milliseconds
        .toInt()
        .clamp(0, const Duration(minutes: 2).inMilliseconds)
        .toInt();
    return Duration(milliseconds: bounded);
  }

  /// 供应商在输出上限处截断时的失败原因。
  ///
  /// 正文缺少结尾，动作 JSON 必然解析失败；带上已输出的 token 数是为了让
  /// 「模型把预算烧在了重复内容上」这类故障一眼可见。
  String _truncatedOutputDetail(Map<String, dynamic> response) {
    final completion = response['completionTokens'];
    return completion is int && completion > 0
        ? '模型输出达到上限被截断（已输出 $completion token），未产出完整动作 JSON。'
        : '模型输出达到上限被截断，未产出完整动作 JSON。';
  }

  /// 供应商是否把输出预算用尽（正文因此不完整、动作 JSON 必然解析失败）。
  ///
  /// `truncated` 只有 OpenAI 兼容解析器会给出（`finish_reason == length`）；
  /// 协议通道（Anthropic / Responses / Gemini）只回 usage，所以再比一次
  /// "已输出 token 是否基本用满本次请求的 max_tokens"。余量是必需的：计数不会
  /// 与预算精确对齐（见 [_outputBudgetMarginDivisor]），按"必须用满"判定会把
  /// 真实截断判成格式错误，任务就在"原样重发同一个巨无霸动作"里空转到超时。
  /// 代价只是极少数恰好用满预算的正常响应会多走一次修复，而解析成功时这个
  /// 判定根本不生效。
  bool _responseHitsOutputLimit(Map<String, dynamic> response) {
    if (response['truncated'] == true) return true;
    final completion = response['completionTokens'];
    final requested = response['requestedMaxTokens'];
    if (completion is! int || requested is! int || requested <= 0) return false;
    return completion >= requested - requested ~/ _outputBudgetMarginDivisor;
  }

  /// 解析失败的原因与本次输出的规模/预算，随协议重试事件一起落盘。
  ///
  /// 只记解析器自己的固定文案与计数，**绝不记正文**：原始响应按设计不落盘，
  /// 而这条事件是用户唯一看得到的失败线索——缺了它，"为什么格式无效"只能靠
  /// 事后反推（2026-09-30 的截断漏判就是这么查出来的）。
  Map<String, Object?> _protocolFailureDiagnostics(
    Map<String, dynamic> response,
    String reason,
  ) {
    final characters = _responseCharacterCount(response);
    final completion = response['completionTokens'];
    final requested = response['requestedMaxTokens'];
    return <String, Object?>{
      'reason': reason,
      if (characters != null) 'responseCharacters': characters,
      if (completion is int) 'completionTokens': completion,
      if (requested is int) 'requestedMaxTokens': requested,
    };
  }

  /// 本次响应正文的字符数。生产流式路径只放 `message`，供应商形状与测试放在
  /// `content`；取值顺序与 [AgentDecisionParser.parseResponse] 保持一致。
  int? _responseCharacterCount(Map<String, dynamic> response) {
    final content = response['content'];
    if (content is String) return content.length;
    final message = response['message'];
    return message is String ? message.length : null;
  }

  /// 截断之后的协议重试要给模型换策略，而不是原样重试同一个巨无霸动作。
  ///
  /// 指令只加在这一次的提示里（渲染进公开任务检查点），不写回任务上下文：
  /// 它是这次重试的指令，不是任务的持久状态，重试成功后即失效。**注意它必须经
  /// `messages` 出站**——运行器只发 `request.messages`，`request.context` 不参与，
  /// 将来若改成从 context 重建消息，这里要一起改，否则指令会静默丢掉。
  Map<String, dynamic> _withTruncatedOutputHint(Map<String, dynamic> context) =>
      <String, dynamic>{
        ...context,
        'truncatedOutputHint': _truncatedOutputChunkingAdvice,
      };

  Future<String?> _repairModel(
    _LoopState state,
    WorkAgentModelRequest original,
    String raw, {
    bool wasTruncated = false,
  }) async {
    const decisionRules = '只返回一个合法 AgentDecision JSON object；'
        'action 只能放在顶层，禁止把 action、reason 或 public_update 放进 tool.arguments；'
        'tool.arguments 只能包含对应工具 schema 声明的字段；'
        'command.run 的 arguments 必须是 JSON 字符串数组，'
        '即使只有一个参数也必须写成 ["test"]，不得返回字符串。';
    final repairContext = <String, dynamic>{
      ...original.context,
      'repairInstruction': wasTruncated
          // 输出被上限截断时原文对修复没有价值：重复的内容不是 JSON 语法问题，
          // 回灌只会把 prompt 撑成三倍，并给模型再喂一遍重复的引子。
          ? '上一次响应因为达到输出上限被截断，不是 JSON 语法问题；'
              '不要输出正文、解释或 Markdown 代码块。'
              '$_truncatedOutputChunkingAdvice$decisionRules'
          : decisionRules,
    };
    var repair = original.copyWith(
      context: repairContext,
      messages: _buildMessages(state.task, repairContext),
      isRepair: true,
    );
    if (!wasTruncated) {
      // copyWith 用 `??` 合并，传 null 不会清空，所以只在非截断时回灌原文。
      repair = repair.copyWith(malformedResponse: raw);
    }
    final response = await model(repair);
    if (_modelFailed(response)) return null;
    return _responseContent(response);
  }

  /// Counts the model's next decision as a budgeted agent step before the
  /// request leaves the app.  A model turn can be slow or fail, but it still
  /// consumed scheduler work and must not let a task exceed the 100-step cap
  /// merely because no tool was started yet.
  Future<WorkAgentLoopResult?> _startModelDecision(_LoopState state) async {
    final boundary = await _checkBoundary(state);
    if (boundary != null) return boundary;
    final task = state.task;
    task
      ..actionCount += 1
      ..currentStep = task.completedOperations.length + 1
      ..status = AgentTaskStatus.planning;
    await _checkpoint(state);
    return null;
  }

  Future<WorkAgentLoopResult> _pauseForCheckpointReview(
    _LoopState state,
  ) async {
    const message = '任务检查点版本不受支持，已暂停，请确认后重新继续。';
    final failure = WorkFailure.fromSignalsForUserAction(
      message,
      completedContent: _completedContent(state),
    );
    state.failure = failure;
    state.task
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..lastError = message
      ..pendingToolRequestJson = '';
    await _emit(
      state,
      WorkTaskEventKind.paused,
      '等待确认任务检查点',
      detail: message,
      safeMetadata: {'reason': 'unsupportedCheckpointSchema'},
    );
    // _checkpoint applies the current allow-list and retains typed discussion
    // and known resource blockers before adding the review marker. It is the
    // only safe way to rewrite an unknown checkpoint without replaying it.
    await _checkpoint(state);
    return _result(state, WorkAgentLoopStatus.paused, message);
  }

  Future<WorkAgentLoopResult?> _checkBoundary(
    _LoopState state, {
    bool includeActionLimit = true,
  }) async {
    if (state.cancellation.isCancelled) return _interrupt(state);
    final task = state.task;
    final limit = _effectiveActionLimit(task);
    task.startedAt ??= clock();
    if (_budgetExceeded(state, includeActionLimit: includeActionLimit)) {
      final message =
          task.actionCount >= limit ? '已达到本任务动作上限，请手点继续。' : '已达到本任务时间上限，请手点继续。';
      return _pauseForLimit(state, message);
    }
    return null;
  }

  bool _budgetExceeded(
    _LoopState state, {
    bool includeActionLimit = true,
  }) {
    final task = state.task;
    task.startedAt ??= clock();
    return (includeActionLimit &&
            task.actionCount >= _effectiveActionLimit(task)) ||
        _timeBudgetExceeded(task);
  }

  Future<WorkAgentLoopResult> _pauseForLimit(
    _LoopState state,
    String message,
  ) async {
    final task = state.task;
    final failure = WorkFailure.fromSignalsForUserAction(
      message,
      completedContent: _completedContent(state),
    );
    state.failure = failure;
    task
      ..status = AgentTaskStatus.paused
      ..softLimitReached = true
      ..resumeRequired = true
      ..lastError = message;
    WorkFailure.persistOnTask(task, failure);
    await _emit(
      state,
      WorkTaskEventKind.paused,
      '已暂停：达到执行软上限。',
      detail: message,
      safeMetadata: {
        'actionCount': task.actionCount,
        'actionLimit': _effectiveActionLimit(task),
        'softTimeLimitMinutes': _effectiveTimeLimit(task).inMinutes,
      },
    );
    await _checkpoint(state);
    return _result(state, WorkAgentLoopStatus.paused, message);
  }

  Future<WorkAgentLoopResult> _pauseForUserAction(
    _LoopState state,
    String message, {
    WorkFailure? failure,
  }) async {
    final task = state.task;
    final resolvedFailure = failure ??
        WorkFailure.fromSignalsForUserAction(
          message,
          completedContent: _completedContent(state),
        );
    state.failure = resolvedFailure;
    task
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..lastError = _publicText(message)
      ..pendingToolRequestJson = '';
    WorkFailure.persistOnTask(task, resolvedFailure);
    await _emit(
      state,
      WorkTaskEventKind.paused,
      '等待用户处理后继续。',
      detail: task.lastError,
      safeMetadata: {'reason': 'userActionRequired'},
    );
    await _checkpoint(state);
    return _result(state, WorkAgentLoopStatus.paused, task.lastError);
  }

  Future<WorkAgentLoopResult> _interrupt(_LoopState state) async {
    final task = state.task;
    final failure = WorkFailure.fromSignalsForUserAction(
      '任务已停止，可从最近检查点继续。',
      completedContent: _completedContent(state),
    );
    state.failure = failure;
    if (!task.isTerminal) {
      task
        ..status = AgentTaskStatus.interrupted
        ..resumeRequired = true
        ..lastError = '任务已停止，可从最近检查点继续。';
      WorkFailure.persistOnTask(task, failure);
      await _emit(
        state,
        WorkTaskEventKind.paused,
        '任务已停止。',
        detail: task.lastError,
      );
      await _checkpoint(state);
    }
    return _result(state, WorkAgentLoopStatus.cancelled, task.lastError);
  }

  Future<WorkAgentLoopResult> _fail(
    _LoopState state,
    String message, {
    WorkFailure? failure,
  }) async {
    final task = state.task;
    final resolvedFailure = failure ??
        WorkFailure.fromLoopMessage(
          message,
          completedContent: _completedContent(state),
        );
    state.failure = resolvedFailure;
    if (!task.isTerminal) {
      task
        ..status = AgentTaskStatus.failed
        ..resumeRequired =
            resolvedFailure.retryable || task.completedOperations.isNotEmpty
        ..lastError = _publicText(message)
        ..pendingToolRequestJson = '';
      WorkFailure.persistOnTask(task, resolvedFailure);
      await _emit(
        state,
        WorkTaskEventKind.failed,
        '任务未完成。',
        detail: task.lastError,
      );
      await _checkpoint(state);
    }
    return _result(state, WorkAgentLoopStatus.failed, task.lastError);
  }
}
