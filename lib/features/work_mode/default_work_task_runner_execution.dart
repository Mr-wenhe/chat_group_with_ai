part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerExecution on DefaultWorkTaskRunner {
  void _implSetTaskUpdateSink(void Function(AgentTask task) sink) {
    _taskUpdateSink = sink;
  }

  void _implSetTaskCheckpointSink(Future<void> Function(AgentTask task) sink) {
    _taskCheckpointSink = sink;
  }

  Future<void> _implRebindWorkspace(AgentTask task, String grantedPath) async {
    if (grantedPath.trim().isEmpty) return;
    await workspaceService.rebindConversationWorkspace(
      conversationId: task.groupId,
      isDirectChat: task.groupId.startsWith('dm:'),
      grantedPath: grantedPath,
    );
  }

  Future<void> _implReportFailure(AgentTask task, WorkFailure failure) async {
    if (_artifactDeliveryNoticePublished(task)) return;
    final character = database.aiCharacterBox.get(task.characterId);
    if (character == null) return;
    await _appendPublicMessage(
      task,
      character,
      await _failureReply(task, failure),
      enforceArtifactContract: false,
    );
  }

  bool _implSupportsVisionModel(String characterId) {
    try {
      final character = database.aiCharacterBox.get(characterId.trim());
      if (character == null ||
          !character.isActive ||
          !character.agenticEnabled) {
        return false;
      }
      final config = _resolveApiConfig(character);
      if (config == null || (!config.hasCredential && !config.hasApiKey)) {
        return false;
      }
      return gateway
          .capability(_providerFor(config), config.modelName)
          .supportsVision;
    } on Object {
      return false;
    }
  }

  bool _implSupportsVisionModelForTask(AgentTask task, String characterId) {
    final normalized = characterId.trim();
    if (normalized.isEmpty || !supportsVisionModel(normalized)) return false;
    try {
      if (task.groupId.startsWith('dm:')) {
        // A private conversation is permanently bound to its character; a
        // vision handoff must never turn a DM into a cross-character channel.
        return task.groupId.substring(3) == normalized;
      }
      final group = database.chatGroupBox.get(task.groupId);
      return group != null && group.aiCharacterIds.contains(normalized);
    } on Object {
      return false;
    }
  }

  Future<String?> _implValidateDiscussionExecutor(
    AgentTask task,
    WorkDiscussionState state,
  ) async {
    final identityError = _discussionExecutorIdentityError(task, state);
    if (identityError != null) return identityError;
    // 身份、可用性、群归属与职业资格已由上面那次判据逐条核过并各自报出成因，
    // 这里只补它不管的模型配置与凭据——把同一批判据抄第二遍，两边的文案迟早
    // 分叉（这里曾经整段重复 `_discussionExecutorIdentityError`）。
    final character =
        database.aiCharacterBox.get(state.executorId?.trim() ?? '');
    if (character == null) return '群讨论选定的执行角色已删除。';
    final config = _resolveApiConfig(character);
    if (config == null) {
      return '群讨论选定的执行角色没有可用的模型配置，请重新选择模型。';
    }
    try {
      final apiKey = await credentials.resolve(config);
      if (apiKey == null || apiKey.trim().isEmpty) {
        return '群讨论选定的执行角色模型凭据不可用。';
      }
    } on Object {
      return '群讨论选定的执行角色模型凭据不可用。';
    }
    return null;
  }

  String? _discussionExecutorIdentityError(
    AgentTask task,
    WorkDiscussionState state,
  ) {
    final executorId = state.executorId?.trim() ?? '';
    if (executorId.isEmpty) return '群讨论尚未选定最终执行角色。';
    if (task.characterId.trim().isNotEmpty && task.characterId != executorId) {
      return '任务记录的执行角色与群讨论最终执行人不一致。';
    }
    if (task.assignedCharacterIds.isNotEmpty &&
        !task.assignedCharacterIds.contains(executorId)) {
      return '群讨论最终执行人不在任务的合格角色范围内。';
    }
    final contract = state.deliverableContract;
    final contractRevision = contract?['requestRevision'];
    if (contractRevision is! num ||
        contractRevision.toInt() != state.requestRevision) {
      return '讨论状态与最新请求版本不一致。';
    }
    final explicitExecutor = contract?['explicitExecutorId'];
    if (explicitExecutor is String &&
        explicitExecutor.trim().isNotEmpty &&
        explicitExecutor.trim() != executorId) {
      return '讨论状态与产物合同中的最终执行人不一致。';
    }
    final character = database.aiCharacterBox.get(executorId);
    if (character == null) return '群讨论选定的执行角色已删除。';
    // 未启用与未开 Agentic 必须各自报出：合成一句「当前不可用」时，用户看不出
    // 该在角色设置里重新启用它、打开 Agentic，还是换人。
    final unavailable = WorkRoleRouter.availabilityFailure(character);
    if (unavailable != null) {
      return '群讨论选定的执行角色$unavailable。';
    }
    if (task.groupId.startsWith('dm:')) {
      if (task.groupId.substring(3) != executorId) {
        return '私聊任务不能改派给其他角色。';
      }
    } else {
      final group = database.chatGroupBox.get(task.groupId);
      if (group == null || !group.aiCharacterIds.contains(executorId)) {
        return '群讨论选定的执行角色不属于当前群组。';
      }
    }
    if (!WorkRoleRouter.isQualifiedForRequest(
      request: WorkDiscussionState.currentRequestScope(task),
      character: character,
      skills: database.characterSkillBox.values,
    )) {
      return '群讨论选定的执行角色不具备当前任务所需职业资格，已阻止执行。';
    }
    return null;
  }

  Future<void> _implRun(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    // Do not let a stale runner invocation mutate a terminal task while it
    // validates the optional discussion marker. The coordinator normally
    // filters these tasks, but the runner is also a public recovery boundary.
    if (cancellation.isCancelled || task.isTerminal) return;
    if (task.status == AgentTaskStatus.queued &&
        _artifactDeliveryRetryOnly(task) &&
        WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) {
      await _retryArtifactDelivery(task, cancellation);
      return;
    }
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final v2 = discussion.state?.collaboration;
    if (v2 != null && await _runProductionTransportStage(task)) return;
    if (v2 == null &&
        WorkDiscussionState.requiresDiscussionForConversation(task.groupId) &&
        discussion.present) {
      final state = discussion.state;
      if (state == null ||
          state.conversationId != task.groupId ||
          !state.isExecutionReady) {
        if (cancellation.isCancelled || task.isTerminal) return;
        task
          ..status = AgentTaskStatus.paused
          ..resumeRequired = false
          ..lastError = '群讨论尚未完成，已阻止执行。'
          ..updatedAt = clock();
        await _persistCheckpoint(task);
        return;
      }
      if (task.characterId.trim().isEmpty && state.executorId != null) {
        task.characterId = state.executorId!;
      }
      final identityError = _artifactDeliveryRetryOnly(task)
          ? _discussionExecutorIdentityError(task, state)
          : await validateDiscussionExecutor(task, state);
      // Credential/group validation is asynchronous. A stop can arrive while
      // it is pending; never let its result mutate or launch a terminal task.
      if (cancellation.isCancelled || task.isTerminal) return;
      if (identityError != null) {
        task
          ..status = AgentTaskStatus.paused
          ..resumeRequired = false
          ..lastError = identityError
          ..updatedAt = clock();
        await _persistCheckpoint(task);
        return;
      }
    }
    if (task.status == AgentTaskStatus.queued &&
        _artifactDeliveryRetryOnly(task)) {
      await _retryArtifactDelivery(task, cancellation);
      return;
    }
    final character = database.aiCharacterBox.get(task.characterId);
    if (character == null || !character.isActive || !character.agenticEnabled) {
      throw StateError('执行角色不可用');
    }
    final workItem = _decodeMap(task.executionStateJson)['workItemExecution'];
    final isAutonomousUsage = workItem is Map &&
        workItem['stage'] == 'usage' &&
        v2?.isAutonomous == true;
    final visualId = isAutonomousUsage
        ? null
        : _decodeMap(task.executionStateJson)['visionModelCharacterId'];
    var modelCharacter = character;
    if (visualId is String && visualId.isNotEmpty) {
      if (!supportsVisionModelForTask(task, visualId)) {
        throw StateError('所选视觉模型已不可用，请重新选择。');
      }
      modelCharacter = database.aiCharacterBox.get(visualId)!;
    }
    final config = _resolveApiConfig(modelCharacter);
    if (config == null) throw StateError('角色尚未配置可用的模型');
    final apiKey = await credentials.resolve(config);
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw StateError('角色模型凭据不可用');
    }
    final files = workspaceFileService;
    final mutations = mutationService;
    if (files == null || mutations == null) {
      // A missing Stage 02 capability is a visible configuration failure. It
      // must never silently fall back to a cross-process service or another
      // runtime.
      throw StateError('工作模式文件服务未就绪，请稍后重试。');
    }
    if (cancellation.isCancelled || task.isTerminal) return;

    // An in-process approval continuation normally keeps the full request in
    // memory. The durable checkpoint is intentionally redacted, so it is only
    // promoted back into this map by installMissingTool after a trusted
    // installer succeeds and the structured command still matches the saved
    // checkpoint. All other post-restart checkpoints are re-planned by the
    // model because they may omit content or command arguments.
    final hasPendingCheckpoint = task.pendingToolRequestJson.trim().isNotEmpty;
    final persistedPending = hasPendingCheckpoint
        ? ToolRequest.fromJsonString(task.pendingToolRequestJson)
        : null;
    final inMemoryPending =
        hasPendingCheckpoint ? _pendingRequests[task.id] : null;
    final requiresWritableWorkspace = _pendingRequiresWritableWorkspace(
      task,
      inMemoryPending ?? persistedPending,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: task.groupId,
      isDirectChat: task.groupId.startsWith('dm:'),
      requireWritable: requiresWritableWorkspace,
      preferredRootPath: directoryService.requestedWorkspacePath(
        WorkDiscussionState.currentRequestScope(task),
      ),
    );
    if (requiresWritableWorkspace && _hasWritableWorkspaceMarker(task)) {
      _consumeWritableWorkspaceMarker(task);
      await _persistCheckpoint(task);
    }
    final provider = _providerFor(config);
    final history = await _conversationHistory(task);
    final requestText = await _requestWithAttachmentContext(task);
    // Commands without an explicit workingDirectory must follow the same
    // authorized root as workspace.patch/read. Using the app's private
    // processing directory here made a request for “桌面” silently write to
    // ~/.chat_group instead.
    final defaultCommandWorkingDirectory = workspace.workDirPath;
    final decision = _approvalDecision(task.executionStateJson);
    final scope = _approvalScope(task.executionStateJson);
    final cancellationToken = CancelToken();
    final cancelForwarder = cancellation.whenCancelled.then<void>(
      (_) => cancellationToken.cancel('用户已停止任务'),
    );

    try {
      final skills = _skillsFor(
        character,
        WorkDiscussionState.currentRequestScope(task),
        taskId: task.id,
      );
      final capability = gateway.capability(provider, config.modelName);
      final attachments = WorkTaskAttachmentContext.attachments(
        task,
        database.messageBox.values,
        characterId: character.id,
      );
      if (attachments.any((attachment) => attachment.type == 'image') &&
          !capability.supportsVision) {
        const reason = '当前角色模型不支持图片输入，请选择已配置的视觉模型后再继续；应用不会自动切换。';
        task
          ..status = AgentTaskStatus.paused
          ..resumeRequired = false
          ..lastError = reason
          ..executionStateJson = jsonEncode(
            _decodeMap(task.executionStateJson)
              ..['visionModelRequired'] = true
              ..['visionModelProvider'] = config.provider
              ..['visionModel'] = config.modelName,
          )
          ..updatedAt = clock();
        WorkFailure.persistOnTask(
            task,
            WorkFailure.fromToolResult(
              const WorkToolResult.paused(
                message: reason,
                failureCode: 'visionModelRequired',
              ),
              completedContent: task.lastArtifactPaths,
            ));
        await _persistCheckpoint(task);
        await _record(task, WorkTaskEventKind.paused, reason);
        return;
      }
      final attachmentContent = await WorkTaskAttachmentContext.prepare(
        task: task,
        attachments: attachments,
        supportsVision: capability.supportsVision,
      );
      if (cancellation.isCancelled || task.isTerminal) return;
      final review = v2 == null ? null : await _prepareProductionReview(task);
      final usage = v2 == null ? null : await _prepareProductionUsage(task);
      final registry = _registryFor(
        task: task,
        character: character,
        workspaceRoot: workspace.workDirPath,
        files: files,
        mutations: mutations,
        cancellationToken: cancellationToken,
        approvalDecision: decision,
        approvalScope: scope,
        modelCapability: capability,
        candidate: usage?.candidate,
      );
      final usageRegistry = usage == null
          ? registry
          : _usageRegistry(registry, usage, task, character);
      final effectiveRegistry = review == null
          ? usageRegistry
          : _reviewRegistry(task, usageRegistry, review);
      final systemPrompt = AgentPromptBuilder.buildAgentDecisionPrompt(
        rolePlaySystemPrompt: character.rolePlaySystemPrompt,
        skills: skills,
        userRequest: requestText,
        workModeContext: _workModeContext(
          task,
          character,
          effectiveRegistry,
          workspaceRoot: workspace.workDirPath,
          candidate: usage?.candidate,
        ),
      );
      final loop = WorkAgentLoop(
        model: (request) => _completeModelTurn(
          request,
          task: task,
          provider: provider,
          config: config,
          apiKey: apiKey,
          requestText: requestText,
          attachmentContent: attachmentContent,
          actorCharacterId: character.id,
          cancellationToken: cancellationToken,
          cancellation: cancellation,
          capabilityMaxOutput: capability.maxOutput,
          capabilityContextWindow: capability.contextWindow,
          usage: usage,
        ),
        registry: effectiveRegistry,
        onToolResult: (task, call, result) async {
          if (cancellation.isCancelled) return;
          if (usage != null && result.usageObservation != null) {
            await _recordUsageObservation(
                task, usage, result.usageObservation!);
          }
          if (review != null) {
            await _recordProductionReviewReceipt(task, review, call, result);
          }
        },
        parser: AgentDecisionParser(
          defaultCommandWorkingDirectory: defaultCommandWorkingDirectory,
          allowBrowserContext: usage != null &&
              _canUseBrowserContext(
                task,
                character,
                usage.state.usageAssignments
                    .singleWhere((item) => item['memberId'] == usage.actorId),
                usage.candidate,
              ),
        ),
        eventStore: eventStore,
        clock: clock,
        onCheckpoint: _persistCheckpoint,
        completionGuard: review != null
            ? (task, completion) =>
                _validateProductionReview(task, review, completion)
            : usage != null
                ? (task, completion) =>
                    _validateProductionUsage(task, usage, completion)
                : (_decodeMap(task.executionStateJson)['workItemExecution']
                            as Map?)?['stage'] ==
                        'material'
                    ? (task, completion) =>
                        _validateProductionMaterials(task, completion)
                    : _validateCompletion,
        artifactCompletion: _autoCompleteAfterArtifact,
        artifactConfirmation: _offerableDeliverables,
        preflightTool: review == null && usage == null
            ? (task) => _preflightSkillTool(task, character)
            : null,
        contextCompressionModel: (snapshot) => _compressWorkContext(
          snapshot,
          task: task,
          provider: provider,
          config: config,
          apiKey: apiKey,
          cancellation: cancellation,
        ),
        // 提示词一旦超过模型有效窗口的 80%（窗口不足 20 万时按 20 万算）就先做
        // 结构化收缩，而不是等装不下时再被硬裁剪。实际发送仍然受输入预算约束。
        promptCompactionBudgetTokens:
            ContextWindowManager.workPromptCompactionBudget(
          contextWindow: capability.contextWindow,
          inputBudget: workModeRequestInputBudget(
            capabilityMaxOutput: capability.maxOutput,
            capabilityContextWindow: capability.contextWindow,
          ),
        ),
        systemPrompt: systemPrompt,
        // Skill creation/download is a normal in-task mutation. Rebuild the
        // prompt before every model turn so the next turn can use the newly
        // persisted skill without injecting the entire skill library up front.
        systemPromptBuilder: () => AgentPromptBuilder.buildAgentDecisionPrompt(
          rolePlaySystemPrompt: character.rolePlaySystemPrompt,
          skills: _skillsFor(character, requestText, taskId: task.id),
          userRequest: requestText,
          workModeContext: _workModeContext(
            task,
            character,
            effectiveRegistry,
            workspaceRoot: workspace.workDirPath,
            candidate: usage?.candidate,
          ),
        ),
        maxActions: task.actionLimit,
        softTimeLimit: task.softTimeLimit,
      );
      final result = await loop.execute(
        task,
        cancellation: cancellation,
        conversationHistory: history,
        approvedPendingTool: inMemoryPending,
      );
      if (cancellation.isCancelled) return;
      if (result.pendingToolRequest != null) {
        _pendingRequests[task.id] = result.pendingToolRequest!;
      }
      if (result.status == WorkAgentLoopStatus.completed ||
          result.isWorkItemCompleted) {
        _pendingRequests.remove(task.id);
        task.executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        );
        if (v2 != null) {
          try {
            await _recordLocalDraftSkillsAfterSuccess(task, character);
          } on Object {
            // Local drafts remain unverified if their validation receipt cannot be saved.
          }
          if (review != null) {
            await _finishProductionReview(task, review, character);
          } else if (usage != null) {
            await _finishProductionUsage(task, usage, character, cancellation);
          } else {
            await _completeProductionItem(task, character);
          }
          return;
        }
        final delivery = await _appendPublicMessage(
          task,
          character,
          task.resultSummary,
        );
        if (!delivery.succeeded) {
          _applyArtifactDeliveryFailure(task, delivery);
        } else {
          await database.recordCharacterReplyUsage(character.id);
          try {
            await _recordLocalDraftSkillsAfterSuccess(task, character);
          } on Object {
            // Local drafts remain unverified if their validation receipt cannot be saved.
          }
          try {
            await _skillResourcePackStore.recordSuccessfulUse(
              database: database,
              taskId: task.id,
              conversationId: task.groupId,
              characterId: character.id,
            );
          } on Object {
            // A task remains complete if the optional skill receipt cannot
            // be persisted; the affected package remains unverified.
          }
          _clearArtifactDeliveryNotice(task);
          await _tryOpenHtmlArtifact(task);
        }
        await _persistCheckpoint(task);
      } else if (result.status != WorkAgentLoopStatus.waitingForApproval) {
        _pendingRequests.remove(task.id);
        if (review != null &&
            // Transport failure resumes this review; it changes no acceptance requirement.
            task.workFailure?.type != WorkFailureType.retryableNetwork &&
            !cancellation.isCancelled &&
            task.status != AgentTaskStatus.cancelled &&
            !_candidateState(task).hasPendingDecision) {
          await _productionDecision(
              task,
              'acceptance',
              _candidateState(task).acceptances.first['id'] as String,
              '实际验证未取得有效结论：${task.lastError}。请补充能力、人工验收、明确豁免或暂缓；未记为通过。');
        }
      }
    } finally {
      // Do not await a cancellation future that only completes on stop; this
      // forwarder exists solely to cancel the existing gateway's Dio request.
      unawaited(cancelForwarder);
      cancellationToken.cancel();
      if (cancellation.isCancelled) _pendingRequests.remove(task.id);
    }
  }
}
