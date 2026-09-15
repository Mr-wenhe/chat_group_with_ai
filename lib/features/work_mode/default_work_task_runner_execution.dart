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
    final executorId = state.executorId!.trim();
    final character = database.aiCharacterBox.get(executorId);
    if (character == null || !character.isActive || !character.agenticEnabled) {
      return '群讨论选定的执行角色当前不可用。';
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
      request: task.userRequest,
      character: character,
      skills: database.characterSkillBox.values,
    )) {
      return '群讨论选定的执行角色不具备当前任务所需职业资格，已阻止执行。';
    }
    final config = _resolveApiConfig(character);
    if (config == null) return '群讨论选定的执行角色尚未配置模型。';
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
    if (character == null || !character.isActive || !character.agenticEnabled) {
      return '群讨论选定的执行角色当前不可用。';
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
      request: task.userRequest,
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
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    if (WorkDiscussionState.requiresDiscussionForConversation(task.groupId) &&
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
    final visualId =
        _decodeMap(task.executionStateJson)['visionModelCharacterId'];
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
      preferredRootPath: directoryService.requestedDesktopPath(
        task.userRequest,
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
      final skills = _skillsFor(character, task.userRequest);
      final capability = gateway.capability(provider, config.modelName);
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
      );
      final systemPrompt = AgentPromptBuilder.buildAgentDecisionPrompt(
        rolePlaySystemPrompt: character.rolePlaySystemPrompt,
        skills: skills,
        userRequest: requestText,
        workModeContext: _workModeContext(
          task,
          character,
          registry,
          workspaceRoot: workspace.workDirPath,
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
          cancellationToken: cancellationToken,
          capabilityMaxOutput: capability.maxOutput,
          capabilityContextWindow: capability.contextWindow,
        ),
        registry: registry,
        parser: AgentDecisionParser(
          defaultCommandWorkingDirectory: defaultCommandWorkingDirectory,
        ),
        eventStore: eventStore,
        clock: clock,
        onCheckpoint: _persistCheckpoint,
        completionGuard: _validateCompletion,
        artifactCompletion: _autoCompleteAfterArtifact,
        preflightTool: (task) => _preflightSkillTool(task, character),
        contextCompressionModel: (snapshot) => _compressWorkContext(
          snapshot,
          task: task,
          provider: provider,
          config: config,
          apiKey: apiKey,
        ),
        systemPrompt: systemPrompt,
        // Skill creation/download is a normal in-task mutation. Rebuild the
        // prompt before every model turn so the next turn can use the newly
        // persisted skill without injecting the entire skill library up front.
        systemPromptBuilder: () => AgentPromptBuilder.buildAgentDecisionPrompt(
          rolePlaySystemPrompt: character.rolePlaySystemPrompt,
          skills: _skillsFor(character, requestText),
          userRequest: requestText,
          workModeContext: _workModeContext(
            task,
            character,
            registry,
            workspaceRoot: workspace.workDirPath,
          ),
        ),
        maxActions: task.actionLimit,
        softTimeLimit: task.softTimeLimit,
      );
      final result = await loop.execute(
        task,
        cancellation: cancellation,
        conversationHistory: history,
        // Only a full in-memory request may be replayed. A persisted request
        // is a display-safe checkpoint and may omit sensitive payloads; the
        // install recovery path can populate this map only for a complete,
        // sanitized command.run checkpoint after the installer succeeds.
        approvedPendingTool: inMemoryPending,
      );
      if (cancellation.isCancelled) return;
      if (result.pendingToolRequest != null) {
        _pendingRequests[task.id] = result.pendingToolRequest!;
      }
      if (result.status == WorkAgentLoopStatus.completed) {
        _pendingRequests.remove(task.id);
        task.executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        );
        final delivery = await _appendPublicMessage(
          task,
          character,
          task.resultSummary,
        );
        if (!delivery.succeeded) {
          final failure = WorkFailure.fromToolFailure(
            code: 'artifactDelivery',
            message: delivery.message,
            scope: 'delivery',
            completedContent: task.lastArtifactPaths,
            retryable: true,
          );
          task
            ..status = AgentTaskStatus.failed
            ..resumeRequired = true
            ..lastError = failure.reason
            ..updatedAt = clock();
          WorkFailure.persistOnTask(task, failure);
          _markArtifactDeliveryNoticePublished(
            task,
            messageId: delivery.messageId,
            retryOnly: delivery.retryWithExistingArtifact,
          );
        } else {
          await database.recordCharacterReplyUsage(character.id);
          _clearArtifactDeliveryNotice(task);
          await _tryOpenHtmlArtifact(task);
        }
        await _persistCheckpoint(task);
      } else if (result.status != WorkAgentLoopStatus.waitingForApproval) {
        _pendingRequests.remove(task.id);
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
