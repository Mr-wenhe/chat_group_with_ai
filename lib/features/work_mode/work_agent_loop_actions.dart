part of 'work_agent_loop.dart';

extension _WorkAgentLoopActions on WorkAgentLoop {
  Future<WorkAgentLoopResult?> _handleDecision(
    _LoopState state,
    AgentDecision decision,
    String publicUpdate,
  ) async {
    final task = state.task;
    switch (decision) {
      case AgentPlanDecision(:final completion):
        final safeSteps = completion.steps
            .map(_publicText)
            .where((step) => step.isNotEmpty)
            .toList(growable: false);
        task
          ..plan = safeSteps.join(' → ')
          ..status = AgentTaskStatus.planning
          ..lastError = ''
          ..pendingToolRequestJson = '';
        state.failure = null;
        WorkFailure.clearFromTask(task);
        state.publicUpdates.add(publicUpdate);
        await _checkpoint(state);
        return null;
      case AgentClarifyDecision(:final completion):
        final failure = WorkFailure.fromSignalsForUserAction(
          completion.question,
          completedContent: _completedContent(state),
        );
        state.failure = failure;
        task
          ..status = AgentTaskStatus.paused
          ..resumeRequired = true
          ..lastError = _publicText(completion.question)
          ..pendingToolRequestJson = '';
        state.publicUpdates.add(publicUpdate);
        await _emit(
          state,
          WorkTaskEventKind.paused,
          publicUpdate,
          detail: _publicText(completion.question),
          safeMetadata: {'reason': 'clarification'},
        );
        await _checkpoint(state);
        return _result(state, WorkAgentLoopStatus.paused, task.lastError);
      case AgentHandoffDecision(:final completion):
        final routedHandoff = WorkHandoffState.fromTask(task);
        if (routedHandoff != null && routedHandoff.needsHandoff) {
          final target = _publicText(completion.target).trim();
          final expected = routedHandoff.receivingRoleId;
          if (target != expected) {
            return _fail(
              state,
              '角色接力目标与已规划的下一角色不一致，未自动改派。',
            );
          }
          // Mark the current stage terminal. The coordinator owns the actual
          // role switch and will advance the durable handoff only after this
          // runner releases its lease, so two roles cannot overlap.
          task
            ..resultSummary = _publicText(completion.summary)
            ..status = AgentTaskStatus.completed
            ..resumeRequired = false
            ..lastError = ''
            ..pendingToolRequestJson = '';
          state.failure = null;
          WorkFailure.clearFromTask(task);
          state.publicUpdates.add(publicUpdate);
          await _emit(
            state,
            WorkTaskEventKind.stepCompleted,
            publicUpdate,
            detail: _publicText(completion.summary),
            safeMetadata: {
              'reason': 'handoff',
              'target': expected,
            },
          );
          await _checkpoint(state);
          return _result(
            state,
            WorkAgentLoopStatus.completed,
            task.resultSummary,
          );
        }
        task
          ..status = AgentTaskStatus.paused
          ..resumeRequired = true
          ..lastError = '等待角色 ${_publicText(completion.target)} 接手。'
          ..pendingToolRequestJson = '';
        state.failure = WorkFailure.fromSignalsForUserAction(
          task.lastError,
          completedContent: _completedContent(state),
        );
        state.publicUpdates.add(publicUpdate);
        state.handoff = {
          'target': _publicText(completion.target),
          'summary': _publicText(completion.summary),
        };
        await _emit(
          state,
          WorkTaskEventKind.paused,
          publicUpdate,
          detail: _publicText(completion.summary),
          safeMetadata: {'reason': 'handoff'},
        );
        await _checkpoint(state);
        return _result(state, WorkAgentLoopStatus.paused, task.lastError);
      case AgentFinishDecision(:final completion):
        final completionFailure = await completionGuard?.call(task, completion);
        if (completionFailure != null && completionFailure.trim().isNotEmpty) {
          return _fail(
            state,
            completionFailure,
            failure: WorkFailure.fromError(
              StateError(completionFailure),
              scope: 'completion',
              completedContent: _completedContent(state),
            ),
          );
        }
        task
          ..resultSummary = _publicText(completion.summary)
          ..status = AgentTaskStatus.completed
          ..resumeRequired = false
          ..softLimitReached = false
          ..lastError = ''
          ..pendingToolRequestJson = '';
        state.failure = null;
        WorkFailure.clearFromTask(task);
        state.publicUpdates.add(publicUpdate);
        await _emit(
          state,
          WorkTaskEventKind.completed,
          publicUpdate,
          detail: task.resultSummary,
          safeMetadata: {'actionCount': task.actionCount},
        );
        await _checkpoint(state);
        return _result(
          state,
          WorkAgentLoopStatus.completed,
          task.resultSummary,
        );
      case AgentToolDecision(:final tool):
        return _handleTool(state, tool, publicUpdate);
    }
  }

  Future<WorkAgentLoopResult?> _handleTool(
    _LoopState state,
    AgentToolCall call,
    String publicUpdate,
  ) async {
    final task = state.task;
    if (state.cancellation.isCancelled) return _interrupt(state);
    final boundary = await _checkBoundary(state);
    if (boundary != null) return boundary;
    final validation = registry.validate(call);
    if (!validation.isValid) {
      final message = validation.error ?? '工具校验失败。';
      return _fail(
        state,
        message,
        failure: WorkFailure.fromToolFailure(
          code: 'modelProtocol',
          message: message,
          completedContent: _completedContent(state),
        ),
      );
    }
    final definition = validation.definition!;
    final operation = ToolRequest(
      tool: call.name,
      reason: publicUpdate,
      args: call.arguments,
    );
    final operationKey = _operationKey(call);
    if (definition.isMutation &&
        state.committedActionKeys.contains(operationKey)) {
      await _skipCommittedTool(state, call);
      return null;
    }
    if (state.cancellation.isCancelled) return _interrupt(state);

    // Count only when the handler is about to start. Approval and lock waits
    // therefore remain free, while retry attempts share this one increment.
    var actionStarted = false;
    WorkToolResult? softLimitResult;
    WorkToolResult? startAction() {
      if (actionStarted) return null;
      final started = task.startedAt ?? clock();
      if (task.actionCount >= _effectiveActionLimit(task) ||
          clock().difference(started) >= _effectiveTimeLimit(task)) {
        softLimitResult = const WorkToolResult.paused(
          message: '已达到执行软上限，请手点继续。',
          failureCode: 'softLimit',
        );
        return softLimitResult;
      }
      actionStarted = true;
      task
        ..actionCount += 1
        ..currentStep = task.completedOperations.length + 1
        ..status = AgentTaskStatus.runningTool;
      return null;
    }

    final toolResult = await _callToolWithRetries(
      state,
      call,
      actionStarter: startAction,
    );
    if (toolResult.failureCode == 'softLimit') {
      return _pauseForLimit(state, toolResult.message);
    }
    if (softLimitResult != null && identical(toolResult, softLimitResult)) {
      return _pauseForLimit(state, softLimitResult!.message);
    }
    final safeResult = _safeResult(toolResult, call);
    state.recentResults.add(safeResult);
    // File bodies and command output may be needed by the next model turn,
    // but they never cross a durable checkpoint. Keep the bounded result only
    // in this in-memory loop state; _safeResult remains the persistence view.
    state.modelResults.add(_modelResult(toolResult, call));

    if (state.cancellation.isCancelled && !toolResult.succeeded) {
      return _interrupt(state);
    }

    // Approval, permission and path gates can return before a handler does
    // any work. Refund the speculative count for those outcomes, while a
    // paused process prompt remains a real started action. This check happens
    // before the user-action branch because pathRejected is a terminal
    // failure rather than a pause.
    if (actionStarted && _shouldRefundActionCount(toolResult)) {
      task.actionCount = task.actionCount > 0 ? task.actionCount - 1 : 0;
    }
    if (_toolNeedsUserAction(toolResult)) {
      if (toolResult.failureCode == 'toolMissing') {
        // The command approval only authorizes the attempted probe. A missing
        // executable did not run, so do not leave that approval reusable when
        // the user later continues or restarts the task; doing so would replay
        // the same command approval forever instead of showing the install or
        // manual-guidance boundary.
        _markMissingToolCheckpoint(task);
      }
      return _pauseForToolAction(state, operation, toolResult, call);
    }
    if (!toolResult.succeeded) {
      if (definition.isMutation && toolResult.committed) {
        // A mutation may reach the filesystem and then fail while completing
        // its snapshot/postcondition bookkeeping. Persist the operation key
        // before recording the failure so a retry cannot execute it twice.
        _recordCommittedMutationFailure(
          state,
          operation: operation,
          operationKey: operationKey,
          call: call,
          result: toolResult,
        );
      }
      final message = _publicText(toolResult.message);
      return _fail(
        state,
        message,
        failure: WorkFailure.fromToolResult(
          toolResult,
          completedContent: _completedContent(state),
        ),
      );
    }

    await _completeTool(
      state,
      call: call,
      operation: operation,
      operationKey: operationKey,
      isMutation: definition.isMutation,
      result: toolResult,
    );
    if (state.cancellation.isCancelled) return _interrupt(state);
    return null;
  }

  void _markMissingToolCheckpoint(AgentTask task) {
    final checkpoint = _decodeMap(task.executionStateJson)
      ..remove('approvalDecision')
      ..remove('approvalPlan')
      ..remove('approvalScope')
      ..remove('approvalCapability')
      ..remove('approvalOperationFingerprint')
      ..remove('approvalConsumed')
      ..['toolMissing'] = true;
    task.executionStateJson = jsonEncode(checkpoint);
  }

  void _recordCommittedMutationFailure(
    _LoopState state, {
    required ToolRequest operation,
    required String operationKey,
    required AgentToolCall call,
    required WorkToolResult result,
  }) {
    final task = state.task;
    if (state.committedActionKeys.add(operationKey)) {
      task.completedOperations = <String>[
        ...task.completedOperations,
        safeToolRequestCheckpoint(operation),
      ];
    }
    task.lastArtifactPaths = _updatedArtifactPaths(
      task,
      call,
      result: result,
    );
  }

  bool _shouldRefundActionCount(WorkToolResult result) {
    if (result.status == WorkToolResultStatus.permissionDenied ||
        result.status == WorkToolResultStatus.pathRejected) {
      return true;
    }
    return result.status == WorkToolResultStatus.waitingForApproval &&
        (result.data['requiresApproval'] == true ||
            result.data['sensitive'] == true);
  }

  Future<void> _skipCommittedTool(
    _LoopState state,
    AgentToolCall call,
  ) async {
    final task = state.task;
    const skipped = WorkToolResult.alreadyCommitted();
    state.recentResults.add(_safeResult(skipped, call));
    await _emit(
      state,
      WorkTaskEventKind.toolOutput,
      '已跳过已提交的重复变更。',
      detail: skipped.message,
      safeMetadata: {'tool': call.name.wireName, 'duplicate': true},
    );
    await _emit(
      state,
      WorkTaskEventKind.stepCompleted,
      '重复变更已确认，无需再次执行。',
      safeMetadata: {
        'tool': call.name.wireName,
        'duplicate': true,
        'actionCount': task.actionCount,
      },
    );
    await _checkpoint(state);
  }

  Future<WorkAgentLoopResult> _pauseForToolAction(
    _LoopState state,
    ToolRequest operation,
    WorkToolResult result,
    AgentToolCall call,
  ) async {
    final task = state.task;
    final waiting = result.status == WorkToolResultStatus.waitingForApproval;
    final failure = WorkFailure.fromToolResult(
      result,
      completedContent: _completedContent(state),
    );
    state.failure = failure;
    state.pendingToolRequest = operation;
    _persistFolderRequest(task, result);
    _persistVisionModelRequest(task, result);
    final requiresExplicitRequest =
        result.data['requiresExplicitRequest'] == true;
    task
      ..status =
          waiting ? AgentTaskStatus.waitingForApproval : AgentTaskStatus.paused
      ..resumeRequired = true
      ..lastError = _publicText(result.message)
      ..pendingToolRequestJson =
          requiresExplicitRequest ? '' : safeToolRequestCheckpoint(operation);
    WorkFailure.persistOnTask(task, failure);
    await _emit(
      state,
      waiting ? WorkTaskEventKind.approvalRequired : WorkTaskEventKind.paused,
      _publicText(result.message),
      safeMetadata: {'tool': call.name.wireName},
    );
    await _checkpoint(state);
    return _result(
      state,
      waiting
          ? WorkAgentLoopStatus.waitingForApproval
          : WorkAgentLoopStatus.paused,
      task.lastError,
    );
  }

  void _persistFolderRequest(AgentTask task, WorkToolResult result) {
    final requested =
        result.data['folderRequestPath'] ?? result.data['requestedPath'];
    final requiresGrant = result.data['requiresFolderGrant'] == true ||
        result.data['requiresWritable'] == true ||
        result.failureCode == 'authorizationRequired';
    if (!requiresGrant || requested is! String || requested.trim().isEmpty) {
      return;
    }
    final execution = _decodeMap(task.executionStateJson)
      ..['folderRequestPath'] = _publicText(requested, maximum: 4096);
    if (result.data['requiresWritable'] == true) {
      // Preserve the capability kind across a restart. A later resume must
      // select a writable workspace; an authorized read-only root is not a
      // valid substitute for a command/file mutation.
      execution['folderRequiresWritable'] = true;
    }
    task.executionStateJson = jsonEncode(execution);
  }

  void _persistVisionModelRequest(AgentTask task, WorkToolResult result) {
    if (result.data['requiresVisionModelSelection'] != true) return;
    final execution = _decodeMap(task.executionStateJson)
      ..['visionModelRequired'] = true;
    final provider = result.data['provider'];
    final model = result.data['model'];
    if (provider is String && provider.trim().isNotEmpty) {
      execution['visionModelProvider'] = _publicText(provider, maximum: 64);
    }
    if (model is String && model.trim().isNotEmpty) {
      execution['visionModel'] = _publicText(model, maximum: 128);
    }
    task.executionStateJson = jsonEncode(execution);
  }

  Future<void> _completeTool(
    _LoopState state, {
    required AgentToolCall call,
    required ToolRequest operation,
    required String operationKey,
    required bool isMutation,
    required WorkToolResult result,
  }) async {
    final task = state.task;
    state.pendingToolRequest = null;
    state.failure = null;
    WorkFailure.clearFromTask(task);
    // A user rejection is represented as a successful, safe no-op so the
    // model can choose an alternative. It must not be recorded as a committed
    // mutation or artifact, otherwise a later continuation would silently
    // skip the same change and report a file that was never written.
    final rejected = result.data['rejected'] == true;
    task
      ..pendingToolRequestJson = ''
      ..completedOperations = <String>[
        ...task.completedOperations,
        safeToolRequestCheckpoint(operation),
      ];
    if (isMutation && !rejected) {
      state.committedActionKeys.add(operationKey);
      task.lastArtifactPaths = _updatedArtifactPaths(
        task,
        call,
        result: result,
      );
    }
    await _emit(
      state,
      WorkTaskEventKind.toolOutput,
      _publicText(result.message),
      safeMetadata: {
        'tool': call.name.wireName,
        'actionCount': task.actionCount,
      },
    );
    await _emit(
      state,
      WorkTaskEventKind.stepCompleted,
      '步骤 ${task.completedOperations.length} 已完成。',
      safeMetadata: {
        'tool': call.name.wireName,
        'actionCount': task.actionCount,
      },
    );
    await _checkpoint(state);
  }
}
