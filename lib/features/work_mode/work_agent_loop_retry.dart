part of 'work_agent_loop.dart';

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
              '不要输出正文、解释或 Markdown 代码块。$decisionRules'
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
