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
        final planFingerprint = sha256
            .convert(utf8.encode(
              safeSteps.join('|').toLowerCase().replaceAll(RegExp(r'\s+'), ''),
            ))
            .toString();
        final stalled = await _observeV2Progress(
          state,
          WorkProgressObservation(
            kind: WorkProgressObservationKind.noProgress,
            fingerprint: planFingerprint,
            summary: '模型重复提出方案，尚无新的外部证据。',
            missing: '需要新的事实、问题处置或真实工作结果。',
          ),
        );
        if (stalled != null) return stalled;
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
        final question = _publicText(completion.question);
        final failure = WorkFailure.fromSignalsForUserAction(
          question,
          completedContent: _completedContent(state),
        );
        state.failure = failure;
        WorkTaskClarification.markPending(task, question);
        task
          ..status = AgentTaskStatus.paused
          ..resumeRequired = true
          ..lastError = question
          ..pendingToolRequestJson = '';
        state.publicUpdates.add(publicUpdate);
        await _emit(
          state,
          WorkTaskEventKind.paused,
          publicUpdate,
          detail: question,
          safeMetadata: {'reason': 'clarification'},
        );
        await _checkpoint(state);
        return _result(state, WorkAgentLoopStatus.paused, task.lastError);
      case AgentHandoffDecision(:final completion):
        if (WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) {
          return _handleDecision(
              state,
              AgentFinishDecision(
                  publicUpdate: publicUpdate,
                  completion:
                      AgentFinishCompletion(summary: completion.summary)),
              publicUpdate);
        }
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
          if (state.completionRepairCount >= maxCompletionRepairs) {
            final offered = await _offerDeliveryConfirmation(
              state,
              completionFailure,
            );
            if (offered != null) return offered;
            return _fail(
              state,
              completionFailure,
              failure: WorkFailure.fromLoopMessage(
                completionFailure,
                scope: 'completion',
                completedContent: _completedContent(state),
              ),
            );
          }
          state.completionRepairCount++;
          state.completionRepairInstruction = _publicText(completionFailure);
          task.lastError = state.completionRepairInstruction;
          await _emit(
            state,
            WorkTaskEventKind.toolOutput,
            '完成校验未通过，正在根据校验结果自动修复。',
            detail: state.completionRepairInstruction,
            safeMetadata: {
              'scope': 'completion',
              'automaticRepair': true,
              'repair': state.completionRepairCount,
            },
          );
          await _checkpoint(state);
          return null;
        }
        if (WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) {
          final root = _safeExistingMap(task.executionStateJson);
          root['v2WorkItemCompletion'] = completion.toJson();
          task.executionStateJson = jsonEncode(root);
          return _completeV2WorkItem(state, completion.summary, publicUpdate);
        }
        task
          ..resultSummary = _publicText(completion.summary)
          ..status = AgentTaskStatus.completed
          ..resumeRequired = false
          ..softLimitReached = false
          ..lastError = ''
          ..pendingToolRequestJson = '';
        state.failure = null;
        state.completionRepairInstruction = '';
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

  /// P6 supplies an explicit signal for P7 scheduling without publishing a
  /// false root completed event or advancing legacy handoff state.
  Future<WorkAgentLoopResult> _completeV2WorkItem(
      _LoopState state, String summary, String publicUpdate) async {
    final task = state.task;
    task
      ..resultSummary = _publicText(summary)
      ..status = AgentTaskStatus.paused
      ..resumeRequired = false
      ..lastError = ''
      ..pendingToolRequestJson = '';
    state.failure = null;
    WorkFailure.clearFromTask(task);
    await _emit(state, WorkTaskEventKind.stepCompleted, publicUpdate,
        detail: task.resultSummary,
        safeMetadata: {'reason': 'workItemCompleted'});
    await _checkpoint(state);
    return _result(
        state, WorkAgentLoopStatus.workItemCompleted, task.resultSummary);
  }

  /// Asks the user to confirm a delivery the completion guard could not place,
  /// and pauses the task on that question.
  ///
  /// Returns null when there is nothing to ask about — the run wrote no readable
  /// file, or the question was already put to the user once — so the caller
  /// falls through to the ordinary failure report. Asking at most once is what
  /// keeps this from becoming a loop: a user who resumes or answers with
  /// something else gets the failure report (and the retry that comes with it),
  /// not the same question again.
  Future<WorkAgentLoopResult?> _offerDeliveryConfirmation(
    _LoopState state,
    String completionFailure,
  ) async {
    final confirm = artifactConfirmation;
    if (confirm == null) return null;
    final task = state.task;
    if (artifactDeliveryConfirmationPaths(task.executionStateJson).isNotEmpty) {
      return null;
    }
    final offered = <String>[];
    for (final path in await confirm(task)) {
      final trimmed = path.trim();
      if (trimmed.isEmpty || offered.contains(trimmed)) continue;
      offered.add(trimmed);
    }
    if (offered.isEmpty) return null;

    final question = _artifactConfirmationQuestion(offered);
    // The question goes through the one clarification contract, so the panel's
    // reply box, the chat entry and "继续" all agree that this task is waiting
    // for an answer.
    WorkTaskClarification.markPending(task, question);
    task.executionStateJson = withArtifactDeliveryConfirmationPending(
      task.executionStateJson,
      offered,
    );
    state.failure = WorkFailure.fromSignalsForUserAction(
      question,
      completedContent: _completedContent(state),
    );
    task
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..lastError = question
      ..pendingToolRequestJson = '';
    state.publicUpdates.add(question);
    await _emit(
      state,
      WorkTaskEventKind.paused,
      question,
      detail: completionFailure,
      safeMetadata: {
        'reason': 'artifactConfirmation',
        'fileCount': offered.length,
      },
    );
    await _checkpoint(state);
    return _result(state, WorkAgentLoopStatus.paused, question);
  }

  /// Names the files in the question, so the user can tell a deliverable from an
  /// intermediate the same run happened to leave behind.
  String _artifactConfirmationQuestion(List<String> offered) {
    final names = offered
        .map(_fileNameOf)
        .map((name) => _publicText(name, maximum: 120))
        .where((name) => name.isNotEmpty)
        .take(6)
        .toList(growable: false);
    final suffix = offered.length > names.length ? ' 等' : '';
    return '这次运行写出了 ${names.join('、')}$suffix，'
        '但完成校验认不出它是否符合你的要求。把它们作为本次交付吗？';
  }

  String _fileNameOf(String path) => path.replaceAll('\\', '/').split('/').last;

  /// Hands a failed or malformed tool call back to the model as one bounded
  /// repair round, and pauses once the task has used up its repair budget or the
  /// exact failure keeps repeating.
  ///
  /// [repeats] is consulted only while budget remains, so a task that has
  /// already exhausted its repairs pauses without recording another failure
  /// fingerprint. Returns null when the loop should continue with a fresh model
  /// decision.
  Future<WorkAgentLoopResult?> _repairToolFailure(
    _LoopState state, {
    required String message,
    required String instruction,
    required String scope,
    bool Function()? repeats,
  }) async {
    if (state.toolRepairCount >= maxToolRepairs || (repeats?.call() ?? false)) {
      const loopMessage = '工具和错误反复出现，自动修复没有取得进展，已暂停。请检查权限、依赖或补充新的处理信息后继续。';
      return _pauseForUserAction(
        state,
        loopMessage,
        failure: WorkFailure.fromSignalsForUserAction(
          loopMessage,
          completedContent: _completedContent(state),
        ),
      );
    }
    state.toolRepairCount++;
    state.toolRepairInstruction = instruction;
    await _emit(
      state,
      WorkTaskEventKind.toolOutput,
      '工具调用失败，正在根据错误自动修复并继续。',
      detail: message,
      safeMetadata: {
        'scope': scope,
        'automaticRepair': true,
        'repair': state.toolRepairCount,
      },
    );
    await _checkpoint(state);
    return null;
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
      // Unreachable with the production registry, which always defines every
      // tool the parser's Stage 03 allow-list accepts; a registry that is
      // missing one of them is a wiring defect, not a model mistake to repair.
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
    final operationKey = _operationKey(call, task: task);
    if (definition.isMutation &&
        (state.committedActionKeys.contains(operationKey) ||
            WorkTaskExecutionPolicy.isValidatedV2GroupTask(task) &&
                (await eventStore?.hasCommittedAction(task.id, operationKey) ??
                    false))) {
      await _skipCommittedTool(state, call);
      return null;
    }
    if (state.cancellation.isCancelled) return _interrupt(state);

    // Count only when the handler is about to start. Approval and lock waits
    // therefore remain free, while retry attempts share this one increment.
    var actionStarted = false;
    WorkToolResult? softLimitResult;
    Future<WorkToolResult?> startAction() async {
      if (actionStarted) return null;
      if (WorkTaskExecutionPolicy.enforcesCumulativeLimits(task) &&
          (task.actionCount >= _effectiveActionLimit(task) ||
              _timeBudgetExceeded(task))) {
        softLimitResult = const WorkToolResult.paused(
          message: '已达到执行软上限，请手点继续。',
          failureCode: 'softLimit',
        );
        return softLimitResult;
      }
      if (definition.isMutation &&
          WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) {
        final root = _decodeMap(task.executionStateJson);
        root['mutationRecoveryVersion'] = 1;
        root['uncertainAction'] = {
          'operationKey': operationKey,
          'tool': call.name.wireName,
          'path':
              call.arguments['path'] is String ? call.arguments['path'] : '',
          if (call.name == AgentToolName.workspacePatch &&
              call.arguments['content'] is String &&
              call.arguments['append'] != true &&
              call.arguments['parts'] == null)
            'expectedSha256': sha256
                .convert(utf8.encode(call.arguments['content'] as String))
                .toString(),
        };
        task.executionStateJson = jsonEncode(root);
        // Flush intent after gates, before the handler. A crash before receipt
        // commit must not make an external call or append look safe to replay.
        await _checkpoint(state);
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
    // Keep the intent through receipt observers; they may persist independently.
    await onToolResult?.call(task, call, toolResult);
    if (!toolResult.succeeded &&
        actionStarted &&
        definition.isMutation &&
        toolResult.data['exitCode'] is int &&
        WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) {
      // A returned process exit is an executed attempt, even when QA failed.
      // Consume its identity; later work may proceed, this call may not replay.
      await eventStore?.recordCommittedAction(task.id, operationKey);
      state.committedActionKeys.add(operationKey);
      final root = _decodeMap(task.executionStateJson)
        ..remove('uncertainAction');
      task.executionStateJson = jsonEncode(root);
    }
    if (toolResult.isRejected ||
        !actionStarted ||
        toolResult.data['changed'] == false ||
        {
          'waitingForApproval',
          'toolMissing',
          'pathRejected',
          'blockedByDefault'
        }.contains(toolResult.data['runStatus'])) {
      final root = _decodeMap(task.executionStateJson)
        ..remove('uncertainAction');
      task.executionStateJson = jsonEncode(root);
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
      final stalled = await _observeV2Progress(
        state,
        _toolProgressObservation(call, toolResult),
      );
      if (stalled != null) return stalled;
      final message = _publicText(toolResult.message);
      final failure = WorkFailure.fromToolResult(
        toolResult,
        completedContent: _completedContent(state),
      );
      if (toolResult.failureCode == 'modelProtocol' &&
          toolResult.data['rejectionKind'] ==
              WorkCommandRejectionKind.invalidInput.name) {
        if (state.invalidCommandRepairCount >=
            WorkAgentLoop.defaultMaxInvalidCommandRepairs) {
          // The dedicated replan budget is authoritative for a rejected command.
          // Letting it fall through to the generic repair round would silently
          // hand it a second, larger budget and lose the command's own remedy.
          return _fail(
            state,
            message,
            failure: failure,
          );
        }
        state.invalidCommandRepairCount++;
        await _emit(
          state,
          WorkTaskEventKind.toolOutput,
          '命令未通过安全校验，正在自动重新规划。',
          detail: message,
          safeMetadata: {
            'scope': WorkCommandRejectionKind.invalidInput.name,
            'retry': state.invalidCommandRepairCount,
          },
        );
        await _checkpoint(state);
        return null;
      }
      if (_isRepairableToolFailure(toolResult)) {
        return _repairToolFailure(
          state,
          message: message,
          instruction: _toolRepairInstruction(call, toolResult),
          scope: toolResult.failureCode ?? call.name.wireName,
          repeats: () =>
              _isCommandFailureLoop(state, call, toolResult) ||
              _isRepeatedCommandOutcome(state, call, toolResult),
        );
      }
      return _fail(
        state,
        message,
        failure: failure,
      );
    }

    if (definition.isMutation && toolResult.data['changed'] == false) {
      final stalled = await _observeV2Progress(
        state,
        _toolProgressObservation(call, toolResult),
      );
      if (stalled != null) return stalled;
      return _handleUnchangedMutation(state, call, toolResult);
    }

    await _completeTool(
      state,
      call: call,
      operation: operation,
      operationKey: operationKey,
      isMutation: definition.isMutation,
      result: toolResult,
    );
    final stalled = await _observeV2Progress(
      state,
      _toolProgressObservation(call, toolResult),
    );
    if (stalled != null) return stalled;
    if (state.cancellation.isCancelled) return _interrupt(state);
    final autoCompletion = await artifactCompletion?.call(
      task,
      call,
      toolResult,
    );
    if (autoCompletion != null) {
      final update = WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)
          ? '文件已写入并验证，制作工作项完成，等待候选审查。'
          : '文件已写入并验证，任务自动完成。';
      return _handleDecision(
        state,
        AgentFinishDecision(
          publicUpdate: update,
          completion: autoCompletion,
        ),
        update,
      );
    }
    // 判交付物契约之前的分支都跑完了：到这里才谈得上"这次写入是不是原地重建"。
    return _observeStagedRewrite(state, call, toolResult);
  }

  /// 「原地重建分段文件」护栏：先给一次纠正，再命中就暂停。
  ///
  /// 现场（2026-09-30 私聊三国杀任务）：18:19 第一版合并成功之后，模型又**新建**了 13 个
  /// 分段文件（`sanguosha_v2.part1.html` … `sg9_p1.html`、`sg10_p1.html`），
  /// **一个都没续写过、一次 command.run 都没跑**，5 小时里 110 分钟纯粹在等上游首字节。
  /// 既有的 `_handleUnchangedMutation` 拦不住它——重复的只是"新建完就丢"这个形状。
  ///
  /// 判据刻意不看文件名：那 13 个名字互相之间没有任何稳定的同族关系
  /// （`sg_final.part1.html` 与 `sanguosha_v6.part1.html` 连前缀都不共享），
  /// 任何名称规则都会漏掉它。可靠的是**正文本身**：这次写入的整份正文与最近几次
  /// 新建过的某一份相同，就是**真实重复**。
  ///
  /// 指纹因此取整份正文而不是开头若干字符。共用版权头、`<!DOCTYPE html>…<title>`
  /// 这类模板头的独立文件，开头可以一模一样；按开头判会把正常的「创建六个独立
  /// 文件」在第二个文件就判成原地重建、纠正一次后直接暂停。代价是模型每次重写都
  /// 产出不同文字时不再命中——正文不同就是不同的文件，这条护栏此刻守的是
  /// "同一份正文换名字重建"这个形状。
  ///
  /// 计数之前必须先确认**这次写入新建了文件**：`content` 写入同时也是整份覆盖已有
  /// 文件的唯一手段（`stage02.write`），而反复重写同一个交付物是正常迭代。判据是
  /// 结果里的 `beforeSha256`——它只在写入前目标已存在（modify 计划）时出现，
  /// 新建（create 计划）时为 null。
  ///
  /// 刻意**不**按新建文件的个数拦截：一个接一个写出互不相同的新文件是正常的多文件
  /// 交付，用计数拦它会让「创建六个独立文件」在第三个之后被要求直接 finish。
  Future<WorkAgentLoopResult?> _observeStagedRewrite(
    _LoopState state,
    AgentToolCall call,
    WorkToolResult result,
  ) async {
    if (result.data['rejected'] == true) return null;
    final append = call.name == AgentToolName.workspacePatch &&
        call.arguments['append'] == true;
    // 抢救写入带 `append: true`，但它是**客户端合成**的续写，由模型被截断触发——
    // 它恰恰是"还在原地重建"的产物，不是模型改用分块了。把它当进展清零，护栏就会
    // 在自己要抓的场景里失效（每次抢救都把计数抹掉一次）。所以既不计数也不清零。
    // 判据取命名规则的所有者，不在这里另写一份正则（见 `WorkTruncationSalvage`）。
    if (append && WorkTruncationSalvage.isRescuePath(_stagedWritePath(call))) {
      return null;
    }
    // 续写与成功合并都是"在向前推进"，与重建是同一枚硬币的两面。
    final continuesExistingFile =
        call.name == AgentToolName.commandRun || append;
    if (continuesExistingFile) {
      if (state.stagedRewrite.isEmpty) return null;
      state.stagedRewrite = const _StagedRewriteState();
      state.stagedRewriteInstruction = '';
      _persistStagedRewrite(state.task, state.stagedRewrite);
      return null;
    }
    if (call.name != AgentToolName.workspacePatch) return null;
    final content = call.arguments['content'];
    if (content is! String || content.trim().isEmpty) return null;
    // 覆盖已有文件既不计数也不清零：清零会让"新建一份、改一次"的交替写法绕开判据，
    // 而计数就会把上一条注释里那种正常重写误判成原地重建。
    if (result.data['beforeSha256'] is String) return null;

    final previous = state.stagedRewrite;
    final step = _stepStagedRewrite(
      previous,
      _stagedWriteFingerprint(content),
      _stagedWritePath(call),
    );
    if (!step.hit) {
      state.stagedRewrite = step.next;
      _persistStagedRewrite(state.task, state.stagedRewrite);
      return null;
    }
    if (previous.corrected) return _pauseForStagedRewrite(state, step.count);
    state.stagedRewrite = step.next;
    _persistStagedRewrite(state.task, state.stagedRewrite);
    state.stagedRewriteInstruction = _stagedRewriteInstruction(
      state.stagedRewrite.lastPath,
    );
    await _emit(
      state,
      WorkTaskEventKind.toolOutput,
      '检测到反复重建分段文件，正在改为续写已有分段。',
      detail: state.stagedRewriteInstruction,
      safeMetadata: {
        'scope': 'stagedRewrite',
        'automaticRepair': true,
        'stagedWrites': step.count,
        'repeatedWrite': step.repeatedContent,
      },
    );
    await _checkpoint(state);
    return null;
  }

  /// 一次写入之后的判定：命中与否，以及要落盘的下一份判定态。
  ///
  /// 纯计算，不碰 state 与 IO——命中的两种后果（纠正、暂停）留在调用处，
  /// 因为其中一种要发事件、另一种要暂停，都不是这个函数该知道的事。
  _StagedRewriteStep _stepStagedRewrite(
    _StagedRewriteState previous,
    String fingerprint,
    String path,
  ) {
    final repeatedContent = previous.writeDigests.contains(fingerprint);
    final count = previous.count + 1;
    final hit = repeatedContent && count >= _stagedRewriteRepeatedThreshold;
    // 同一份正文只留一条：重建出来的新版会顶掉旧版，不然 4 个槽位会被
    // 同一份正文占满，真正的新一版反而没地方记。
    final contents = <String>[
      ...previous.writeDigests.where((value) => value != fingerprint),
      fingerprint,
    ];
    final bounded = contents.length <= _stagedRewriteFingerprintLimit
        ? contents
        : contents.sublist(contents.length - _stagedRewriteFingerprintLimit);
    return _StagedRewriteStep(
      hit: hit,
      repeatedContent: repeatedContent,
      count: count,
      // 第一次命中：计数归零但留住"已纠正"标记，于是下一次重复要重新累到阈值才会
      // 暂停，多文件任务还有一次自然收尾的机会——命中后直接 finish 不会被拦下来。
      next: hit && !previous.corrected
          ? _StagedRewriteState(
              corrected: true,
              lastPath: path,
              writeDigests: bounded,
            )
          : _StagedRewriteState(
              count: count,
              corrected: previous.corrected,
              lastPath: path,
              writeDigests: bounded,
            ),
    );
  }

  /// 纠正过一次之后仍然在原地重建：把任务交回用户，别再烧上游。
  Future<WorkAgentLoopResult?> _pauseForStagedRewrite(
    _LoopState state,
    int stagedWrites,
  ) async {
    final message = '已连续 $stagedWrites 次新建文件，其中反复写入完全相同的正文，'
        '且从未续写任何一个，自动改为续写的纠正没有取得进展，任务未完成。'
        '请确认是要在同一个文件上继续写，还是要生成多个互相独立的文件。';
    return _pauseForUserAction(
      state,
      message,
      failure: WorkFailure.fromSignalsForUserAction(
        message,
        completedContent: _completedContent(state),
      ),
      reason: 'stagedRewrite',
    );
  }

  /// 写入正文的指纹。存 sha256 而不是正文：检查点是明文持久数据，
  /// 一条写配置文件的命令不该因为护栏把密钥抄进 `agent_tasks.hive`。
  ///
  /// 取**整份**正文而不是开头若干字符：只比开头会把共用版权头或 HTML 模板头的
  /// 独立文件当成同一份东西，正常的"创建六个文件"就永远走不到 finish。也**不做
  /// 空白折叠**：`<pre>` 里一个空格与六个空格是两份显示结果不同的正文，折叠成同一
  /// 份会把"用 pre 演示一至六个空格"这类正常多文件交付在第四次写入后暂停。
  String _stagedWriteFingerprint(String content) =>
      sha256.convert(utf8.encode(content)).toString();

  String _stagedWritePath(AgentToolCall call) {
    final path = call.arguments['path'];
    return path is String ? path.trim() : '';
  }

  /// 纠正指令：两种情形都必须自洽，否则会误伤正常的多文件生成。
  ///
  /// 只禁止"再新建"，不禁"重写"：重写已有文件本来就不进入判定（见
  /// [_observeStagedRewrite]），把它写进禁令会逼模型在"必须整份重写"时去 append，
  /// 那会把第二份正文追加进同一个文件。合并路线与截断抢救共用同一句
  /// （`_truncatedOutputChunkingAdvice`）：纯文本拼接用 `parts`，不要为它开一次
  /// 需要用户批准的命令。
  String _stagedRewriteInstruction(String lastPath) {
    final anchor = lastPath.isEmpty ? '你最近新建的那个分段文件' : '`$lastPath`';
    return '本任务已反复新建正文完全相同的分段文件，且从未续写任何一个。'
        '如果你是在同一个交付物上重做：不要再新建分段文件，改为对已有的 '
        '$anchor 用 workspace.patch 并带 {"append":true} 续写，每次 content 不超过 3000 字，'
        '全部写完后用一次 workspace.patch 的 parts 把分段合并成交付物。'
        '如果你确实在生成多个互相独立的文件：下一次决策直接返回 finish 并列出它们，'
        '不要再新增文件。';
  }

  Future<WorkAgentLoopResult?> _handleUnchangedMutation(
    _LoopState state,
    AgentToolCall call,
    WorkToolResult result,
  ) async {
    final task = state.task;
    state.pendingToolRequest = null;
    task.pendingToolRequestJson = '';
    state.unchangedMutationCount++;
    _persistUnchangedMutationCount(task, state.unchangedMutationCount);
    const detail = '工具报告目标文件内容未发生变化，未执行写入。';
    if (state.unchangedMutationCount > 1) {
      const message = '连续验证发现目标文件内容没有实际变化，任务未完成。请补充明确的修改点后再继续。';
      return _pauseForUserAction(
        state,
        message,
        failure: WorkFailure.fromSignalsForUserAction(
          message,
          completedContent: _completedContent(state),
        ),
      );
    }
    await _emit(
      state,
      WorkTaskEventKind.toolOutput,
      '未检测到实际修改，正在自动重新规划。',
      detail: detail,
      safeMetadata: {
        'tool': call.name.wireName,
        'changed': false,
        'automaticRepair': true,
      },
    );
    await _checkpoint(state);
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

  /// A mutation approval authenticates one concrete operation only. Once that
  /// operation has completed, remove its per-operation capability before the
  /// next model turn so a different tool cannot inherit the decision.
  ///
  /// The approved path scope deliberately outlives the operation: it is the
  /// grant the user already made for this task, and WorkChangePolicy still
  /// forces a fresh prompt for deletes, commands, irreversible writes and
  /// sensitive paths. Dropping it here re-asked for every later write to the
  /// same approved paths and reported each one as the task's "first" write.
  void _clearCompletedMutationApproval(AgentTask task) {
    final checkpoint = _decodeMap(task.executionStateJson)
      ..remove('approvalDecision')
      ..remove('approvalPlan')
      ..remove('approvalCapability')
      ..remove('approvalOperationFingerprint')
      ..remove('approvalConsumed')
      ..remove('approvalPromptShown');
    task.executionStateJson = checkpoint.isEmpty ? '' : jsonEncode(checkpoint);
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
    // Keep the current-process model view in sync with the durable result.
    // Without this, _buildContext prefers modelResults and the model never
    // sees that its repeated mutation was already committed.
    state.modelResults.add(_modelResult(skipped, call));
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
    // A completed tool call is progress, so the repair budgets start over; the
    // failure fingerprint history is deliberately left alone because a
    // successful read does not prove an earlier defect is gone.
    state.toolRepairCount = 0;
    state.toolRepairInstruction = '';
    state.completionRepairCount = 0;
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
      clearCommandFailureHistory(state);
      _persistUnchangedMutationCount(task, 0);
      if (WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) {
        await eventStore?.recordCommittedAction(task.id, operationKey);
        final root = _decodeMap(task.executionStateJson)
          ..remove('uncertainAction');
        task.executionStateJson = jsonEncode(root);
      }
      state.committedActionKeys.add(operationKey);
      task.lastArtifactPaths = _updatedArtifactPaths(
        task,
        call,
        result: result,
      );
      // 同一批路径同时进两份记录：`lastArtifactPaths` 是整条任务血缘的候选集合
      // （产物契约、完成校验要用它），运行记录只服务失败报告的附件。
      _addRunArtifactPaths(task, _writtenArtifactPaths(call, result: result));
      _recordArtifactChange(task, call, result);
    }
    if (isMutation) _clearCompletedMutationApproval(task);
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
