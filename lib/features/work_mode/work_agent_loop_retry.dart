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
      await _delayFor(state, attempt);
    }
    return last ?? const {};
  }

  Future<String?> _repairModel(
    _LoopState state,
    WorkAgentModelRequest original,
    String raw,
  ) async {
    final repairContext = <String, dynamic>{
      ...original.context,
      'repairInstruction': '只返回一个合法 AgentDecision JSON object；'
          'command.run 的 arguments 必须是 JSON 字符串数组，'
          '即使只有一个参数也必须写成 ["test"]，不得返回字符串。',
    };
    final response = await model(
      original.copyWith(
        context: repairContext,
        messages: _buildMessages(state.task, repairContext),
        isRepair: true,
        malformedResponse: raw,
      ),
    );
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
    final started = task.startedAt ??= clock();
    return (includeActionLimit &&
            task.actionCount >= _effectiveActionLimit(task)) ||
        clock().difference(started) >= _effectiveTimeLimit(task);
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
        WorkFailure.fromError(
          StateError(message),
          scope: 'loop',
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
