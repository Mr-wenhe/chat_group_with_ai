part of 'chat_room_page.dart';

extension _ChatRoomAgenticInputSupport on _ChatRoomPageState {
  Future<void> _markCurrentConversationRead({Message? throughMessage}) async {
    await _repository.markRead(
      throughMessage == null
          ? _readThrough(_messages)
          : _readThrough([throughMessage]),
    );
    _clearActiveUserMentionBanner();
  }

  /// 发送用户消息的主入口。
  ///
  /// 顺序：收起 @ 弹窗 → 解析 @ 列表 → 构造并落库消息 → 私聊标记来源/已读
  /// → 清理引用与附件 → 派发 AI 回复或全局工作任务。
  Future<void> _sendMessage() async {
    _hideMentionOverlay();
    final text = _textController.text.trim();
    final hasAttachments = _pendingAttachments.isNotEmpty;
    // 放宽发送条件：文案非空 或 有附件均可发送。
    if (text.isEmpty && !hasAttachments) return;

    _textController.clear();
    final mentionedIds = _parseMentions(text);
    for (final id in mentionedIds) {
      if (!_pendingMentionedIds.contains(id)) {
        _pendingMentionedIds.add(id);
      }
    }

    // 构造带媒体附件的用户消息（媒体为不可变快照，避免后续清空影响已落库消息）。
    final userMessage = Message(
      groupId: widget.groupId,
      senderId: 'user',
      senderType: 'user',
      content: text,
      replyToMessageId: _quotedMessage?.id,
      media: hasAttachments
          ? List<MediaAttachment>.from(_pendingAttachments)
          : null,
    );
    await _appendMessage(userMessage);
    if (_isDirectChat) {
      // 记录该私聊由用户主动发起，影响后续主动联系的冷却判断。
      await _db.saveDirectChatSource(widget.groupId, DirectChatSource.direct);
      await _repository.markRead(_readThrough(_messages));
    }
    _cancelQuote();

    // 发送后清空待发送附件。
    if (hasAttachments && mounted) {
      _setUiState(() => _pendingAttachments.clear());
    }

    // 用户开口即重置 burst 计数，让自动聊天重新获得完整额度。
    _autoChatRoundCount = 0;

    // Ordinary chat still needs an active speaker, but work-mode requests must
    // be durably recorded even when the group currently has no usable member;
    // the discussion gate can then @ the owner and resume after a qualified
    // role is added.
    if (_characters.isEmpty && !_workModeEnabled) {
      if (mounted) {
        AppToast.show(context, _isDirectChat ? '该角色当前不可回复' : '该群聊没有活跃的角色',
            icon: Icons.info_outline_rounded);
      }
      return;
    }

    // 工作任务由全局协调器串行化。即使普通聊天页仍在处理旧回合，新的
    // 工作指令也必须立即进入持久任务队列，不能被页面队列或取消逻辑吞掉。
    if (_workModeEnabled) {
      await _runWorkModeTask(
        text: text,
        mentionedIds: mentionedIds,
        hasAttachments: hasAttachments,
        attachmentMessageId: hasAttachments ? userMessage.id : null,
      );
      return;
    }

    if (WorkModePolicy.looksLikeWorkRequest(text)) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'system',
        content: WorkModePolicy.workModeHint,
      ));
    }

    if (_isAiReplying) {
      // AI 正在回复中，排队等待当前回合结束后再处理。
      _conversationController.enqueue(PendingUserMessage(
        text,
        mentionedIds,
        message: userMessage,
      ));
      return;
    }

    await _dispatchUserRequest(
      text: text,
      mentionedIds: mentionedIds,
      userMessage: userMessage,
    );
  }

  /// 根据当前模式把用户请求派发给"工作模式任务"或"普通聊天回合"。
  Future<void> _dispatchUserRequest({
    required String text,
    required List<String> mentionedIds,
    Message? userMessage,
  }) async {
    if (_workModeEnabled) {
      await _runWorkModeTask(
        text: text,
        mentionedIds: mentionedIds,
        hasAttachments: userMessage?.media?.isNotEmpty == true,
        attachmentMessageId:
            userMessage?.media?.isNotEmpty == true ? userMessage?.id : null,
      );
      return;
    }
    final sentiment = UserMessageSentimentAnalyzer.analyze(text);
    await _runAiRound(
      userMessage: text,
      mentionedIds: mentionedIds,
      currentUserMessage: userMessage,
      userSentiment: sentiment,
    );
  }

  /// Drains one queued user message once the previous run has released the
  /// controller. Queued input is retained while a page is inactive and is
  /// resumed by the lifecycle activation hook.
  Future<void> _drainQueuedUserMessage() async {
    if (!_canTouchUi || _isAiReplying) return;
    final next = _conversationController.takeNext();
    if (next == null) return;
    await _dispatchQueuedUserMessage(next);
  }

  Future<void> _dispatchQueuedUserMessage(PendingUserMessage next) async {
    if (!_canTouchUi) {
      _conversationController.requeueFirst(next);
      return;
    }
    try {
      await _dispatchUserRequest(
        text: next.text,
        mentionedIds: next.mentionedIds,
        userMessage: next.message,
      );
    } on Object {
      // A page can be disposed or a transient dispatch failure can happen
      // after the message was taken. Return it to the queue so the next active
      // lifecycle can retry instead of losing user input.
      _conversationController.requeueFirst(next);
      rethrow;
    }
  }

  /// 页面只负责把用户已落库的消息提交给全局协调器；它不创建取消令牌、
  /// 工作区跨进程层或旧的聊天代理循环。后续追问复用同一任务的持久上下文。
  Future<void> _runWorkModeTask({
    required String text,
    required List<String> mentionedIds,
    bool hasAttachments = false,
    String? attachmentMessageId,
  }) async {
    final coordinator = ref.read(workTaskCoordinatorProvider);
    final activeTask = _latestWorkTaskForConversation();
    if (activeTask != null) {
      final followUpRequest = text.trim().isEmpty && hasAttachments
          ? WorkModePolicy.attachmentOnlyRequest
          : text;
      final decision = coordinator.followUpDecisionForTask(
        activeTask.id,
        followUpRequest,
      );
      // A completed checkpoint does not own a brand-new deliverable. Let the
      // normal router run so explicit @角色, qualification, permissions and
      // the fresh discussion task are rebuilt from the new request. All other
      // inputs remain on the durable FIFO/follow-up path.
      final startsNewTask = coordinator.shouldRouteNewTaskForFollowUp(
        activeTask.id,
        followUpRequest,
      );
      if (!startsNewTask) {
        await coordinator.enqueueFollowUp(
          activeTask.id,
          followUpRequest,
          attachmentMessageId: hasAttachments ? attachmentMessageId : null,
        );
        final discussion = coordinator.discussionStateForTask(activeTask.id);
        final discussionPending =
            discussion.state != null && !discussion.state!.isExecutionReady;
        await _appendMessage(Message(
          groupId: widget.groupId,
          senderId: 'system',
          senderType: 'system',
          content: decision.isClarification
              ? '@$_ownerMentionName 工作模式需要你明确修订目标：${decision.clarificationQuestion ?? '请明确要修改的文件路径。'}'
              : discussionPending
                  ? '已收到补充要求，已纳入当前群讨论；将按最新请求版本重新确认方案。'
                  : '已收到补充要求，当前执行完成后将按 FIFO 顺序处理。',
          isMention: decision.isClarification,
        ));
        return;
      }
    }

    // Route against the complete group membership so an explicit @ can
    // produce a useful unavailable/ambiguous diagnostic instead of silently
    // falling back to the first active character. The router also creates the
    // durable product → development → testing stage plan used by the
    // coordinator for serial role handoff.
    // The loader keeps deleted/history-only senders in `_allGroupCharacters`
    // so old bubbles can still render their persona.  That display snapshot is
    // not current group membership, however, and must never become an
    // executor or a discussion participant.  Route against the current group
    // ids while retaining inactive current members for precise diagnostics.
    final currentMemberIds = _group?.aiCharacterIds.toSet() ??
        _characters.map((character) => character.id).toSet();
    final groupCharacters =
        (_allGroupCharacters.isEmpty ? _characters : _allGroupCharacters)
            .where((character) => currentMemberIds.contains(character.id))
            .toList(growable: false);
    // Automatic routing must not ask a model to choose a role that cannot
    // actually run. Explicit @ and DM routes retain the full list so their
    // unavailable-role diagnostics remain precise.
    // Use the display snapshot only to detect that the user explicitly named
    // someone.  The router still receives current membership, so a deleted or
    // historical name is reported as an unknown role instead of silently
    // turning an explicit request into automatic election.
    final hasExplicitMention = analyzeMentionedCharacterIds(
      text,
      _allGroupCharacters.isEmpty ? groupCharacters : _allGroupCharacters,
    ).hasExplicitMention;
    final routableCharacters = hasExplicitMention || _isDirectChat
        ? groupCharacters
        : await _charactersWithUsableCredentials(groupCharacters);
    final routeSelector = WorkRoleModelSelectorService(
      characters: routableCharacters,
      credentials: _credentialResolver,
      resolveApiConfig: _resolveApiConfig,
      complete: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required messages,
        required timeout,
      }) =>
          _aiGateway.sendChatMessageWithResponseLimit(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: config.protocol,
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        messages: messages,
        maxTokens: 256,
        receiveTimeout: timeout,
        maxRetries: 0,
        purpose: AiRequestPurpose.agent,
        conversationId: widget.groupId,
        characterId: 'work-role-router',
        requiresTools: false,
        userInitiated: true,
        maxResponseBytes: WorkRoleModelSelectorService.maxResponseBytes,
      ),
    );
    final route =
        await WorkRoleRouter(modelSelector: routeSelector.select).route(
      request: text,
      hasAttachments: hasAttachments,
      characters: routableCharacters,
      conversationId: widget.groupId,
      requestRevision: 1,
      isDirectChat: _isDirectChat,
      directCharacterId: _directCharacterId,
      skills: _db.characterSkillBox.values,
    );
    // Keep task routing and stage/permission lookup constrained to current
    // group membership.  Historical senders remain available to render old
    // bubbles, but can never become an executor or a tool-bearing stage.
    final charactersById = <String, AICharacter>{
      for (final character in groupCharacters) character.id: character,
    };
    if (!route.isSuccess) {
      final pendingTask = _buildDiscussionTask(
        text: text,
        hasAttachments: hasAttachments,
        attachmentMessageId: attachmentMessageId,
        route: route,
        charactersById: charactersById,
      );
      if (pendingTask != null) {
        final requiresOwnerClarification = route.needsMentionClarification ||
            (route.characterId == null &&
                route.deliverableContract?.explicitExecutorId
                        ?.trim()
                        .isNotEmpty ==
                    true);
        await _appendMessage(Message(
          groupId: widget.groupId,
          senderId: 'system',
          senderType: 'system',
          content: '${requiresOwnerClarification ? '@$_ownerMentionName ' : ''}'
              '工作模式角色路由未完成，任务已进入群讨论等待：${route.reason}',
          isMention: requiresOwnerClarification,
        ));
        await coordinator.submit(pendingTask);
        return;
      }
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'system',
        content: '工作模式角色路由未完成：${route.reason}',
      ));
      return;
    }
    final executor = charactersById[route.characterId];
    if (executor == null) {
      await _queueDiscussionTask(
        coordinator: coordinator,
        text: text,
        hasAttachments: hasAttachments,
        attachmentMessageId: attachmentMessageId,
        route: route,
        charactersById: charactersById,
        additionalBlockers: const ['executorUnavailable'],
        additionalQuestion: '找不到指定的执行角色，请先把该角色加入当前群组后再继续。',
        reason: '找不到选中的执行角色。',
      );
      return;
    }
    if (_workModeEnabled && !executor.agenticEnabled) {
      await _queueDiscussionTask(
        coordinator: coordinator,
        text: text,
        hasAttachments: hasAttachments,
        attachmentMessageId: attachmentMessageId,
        route: route,
        charactersById: charactersById,
        additionalBlockers: const ['executorUnavailable'],
        additionalQuestion: '指定的执行角色尚未启用工作能力，请在角色设置中开启后再继续。',
        reason: '${executor.name}未启用工作能力。',
      );
      return;
    }
    final stageRoleIds = route.stages.isEmpty
        ? <String>[executor.id]
        : route.stages.map((stage) => stage.roleId).toSet().toList();
    if (_isDirectChat) {
      // Private chats retain the existing explicit handoff semantics.  There
      // is no group discussion task to hold a later receiver's credential
      // blocker, so fail visibly before the fixed conversation starts.
      final stageCharacters = stageRoleIds
          .map((characterId) => charactersById[characterId])
          .whereType<AICharacter>()
          .toList(growable: false);
      final usableStageIds = (await _charactersWithUsableCredentials(
        stageCharacters,
      ))
          .map((character) => character.id)
          .toSet();
      final unavailableRoles = stageCharacters
          .where((character) => !usableStageIds.contains(character.id))
          .map((character) => character.name)
          .toList(growable: false);
      if (unavailableRoles.isNotEmpty) {
        await _appendMessage(Message(
          groupId: widget.groupId,
          senderId: 'system',
          senderType: 'system',
          content: '工作模式角色路由未完成：${unavailableRoles.join('、')}尚未配置可用模型凭据。',
        ));
        return;
      }
    }
    // A group discussion elects one final owner.  Its route may still carry
    // legacy product/development/testing stages, but those later roles are
    // discussion participants rather than an implicit handoff chain.  Only
    // the concrete owner must pass the secure-credential preflight here; the
    // discussion runner records unavailable consulted members without making
    // an otherwise valid task disappear into a one-off chat notice.
    final usableExecutor =
        await _charactersWithUsableCredentials(<AICharacter>[executor]);
    if (usableExecutor.isEmpty) {
      await _queueDiscussionTask(
        coordinator: coordinator,
        text: text,
        hasAttachments: hasAttachments,
        attachmentMessageId: attachmentMessageId,
        route: route,
        charactersById: charactersById,
        additionalBlockers: const ['executorUnavailable'],
        additionalQuestion: '指定的执行角色当前没有可用模型凭据，请配置或更换该角色后再继续。',
        reason: '${executor.name}尚未配置可用模型凭据。',
      );
      return;
    }
    // 策略层判断这条输入是否值得触发一次工作任务（例如纯闲聊则跳过）。
    if (!WorkModePolicy.shouldRun(
      enabled: _workModeEnabled,
      character: executor,
      userRequest: text,
      hasAttachments: hasAttachments,
    )) {
      return;
    }
    final requestedPermissions = <ToolPermission>{};
    for (final characterId in stageRoleIds) {
      requestedPermissions.addAll(
        charactersById[characterId]?.toolPermissions ?? const [],
      );
    }
    if (requestedPermissions.isEmpty) {
      requestedPermissions.addAll(executor.toolPermissions);
    }
    final taskRequest = text.trim().isEmpty && hasAttachments
        ? WorkModePolicy.attachmentOnlyRequest
        : text;
    // Tool permissions are enforced again by the production runner after the
    // public discussion gate.  Do not reject the group input here: every
    // group task must first leave a durable discussion record so the user can
    // repair the role, add a qualified member, or choose a different executor
    // without losing the original request.  A missing capability therefore
    // becomes a visible, recoverable execution failure instead of a one-off
    // system message that bypasses R01/R04.
    final task = AgentTask(
      groupId: widget.groupId,
      characterId: executor.id,
      // Keep the chat message's original empty text, but give the durable
      // task a stable goal so checkpoints, skills and the execution panel do
      // not lose an attachment-only request.
      userRequest: taskRequest,
      requestedPermissions: requestedPermissions.toList(growable: false),
      assignedCharacterIds: stageRoleIds,
      plan: '角色路由：${route.reason}',
      workModeTask: true,
    );
    final discussionParticipants = <String>{
      ...stageRoleIds,
      ...route.discussionCharacterIds,
      ...route.consultedCharacterIds,
    };
    if (attachmentMessageId != null && attachmentMessageId.trim().isNotEmpty) {
      task.executionStateJson = jsonEncode({
        'attachmentMessageId': attachmentMessageId.trim(),
      });
    }
    if (!_isDirectChat) {
      final discussionState = WorkDiscussionState.initial(
        conversationId: widget.groupId,
        requestRevision: route.deliverableContract?.requestRevision ?? 1,
        coordinatorId: route.discussionCharacterIds.isEmpty
            ? null
            : route.discussionCharacterIds.first,
        executorId: executor.id,
        candidateCharacterIds: stageRoleIds,
        participantCharacterIds: discussionParticipants,
        deliverableContract: route.deliverableContract?.toJson(),
      );
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        discussionState,
      );
    }
    final handoff = route.handoffState;
    if (handoff != null) WorkHandoffState.persistToTask(task, handoff);
    await _appendMessage(Message(
      groupId: widget.groupId,
      senderId: 'system',
      senderType: 'system',
      content: '工作模式角色路由：${route.reason}',
    ));
    await coordinator.submit(task);
  }

  /// Creates the durable waiting record for a route that still needs group
  /// discussion or an executor. It deliberately leaves characterId empty;
  /// a coordinator/candidate is never promoted to a tool executor here.
  AgentTask? _buildDiscussionTask({
    required String text,
    required bool hasAttachments,
    required String? attachmentMessageId,
    required WorkRoleRouteResult route,
    required Map<String, AICharacter> charactersById,
    Iterable<String> additionalBlockers = const [],
    String? additionalQuestion,
  }) {
    if (_isDirectChat) return null;
    final taskRequest = text.trim().isEmpty && hasAttachments
        ? WorkModePolicy.attachmentOnlyRequest
        : text;
    // Some handoff/transport failures happen before the router has a
    // contract. Keep a durable pending record for those group tasks too; the
    // fallback describes no executor and never grants a role or tool access.
    final contract = route.deliverableContract ??
        WorkDeliverableContract(
          deliverableType: 'generic',
          format: 'unspecified',
          location: 'unspecified',
          contentScope: taskRequest,
          revisionTarget: '',
          requestRevision: 1,
        );
    final candidates = route.candidateCharacterIds.toSet();
    if (route.characterId != null) candidates.add(route.characterId!);
    final participants = <String>{
      ...route.discussionCharacterIds,
      ...route.consultedCharacterIds,
      ...candidates,
    };
    final explicitExecutorUnavailable = route.characterId == null &&
        contract.explicitExecutorId?.trim().isNotEmpty == true;
    // Even when S1 could not activate a user-named role (for example because
    // its credential or occupation is invalid), retain that exact identity in
    // the discussion checkpoint. A later retry must re-check the same owner;
    // an empty executor would let the runner elect a different role silently.
    final checkpointExecutorId = route.characterId ??
        (explicitExecutorUnavailable
            ? contract.explicitExecutorId!.trim()
            : null);
    if (checkpointExecutorId != null && checkpointExecutorId.isNotEmpty) {
      candidates.add(checkpointExecutorId);
    }
    // Candidate selection is the intended S3 entry point: the group must be
    // allowed to discuss and elect a qualified executor. Keep routePending
    // only for a genuine routing failure (unknown/ambiguous mention, an
    // unavailable explicit owner, or another route that needs user action),
    // otherwise it would be an immortal blocker that even a valid election
    // could never clear.
    final routeNeedsUserAction = !route.needsExecutorSelection;
    final blockers = <String>[
      if (routeNeedsUserAction) 'routePending',
      if (explicitExecutorUnavailable) 'executorUnavailable',
      ...additionalBlockers,
    ];
    if (route.needsMentionClarification) blockers.add('mentionClarification');
    final question = additionalQuestion?.trim() ?? '';
    final state = WorkDiscussionState.initial(
      conversationId: widget.groupId,
      requestRevision:
          contract.requestRevision < 1 ? 1 : contract.requestRevision,
      coordinatorId: route.discussionCharacterIds.isEmpty
          ? null
          : route.discussionCharacterIds.first,
      executorId: checkpointExecutorId,
      candidateCharacterIds: candidates,
      participantCharacterIds: participants,
      deliverableContract: contract.toJson(),
      openQuestions: route.needsMentionClarification ||
              explicitExecutorUnavailable ||
              question.isNotEmpty
          ? <String>[question.isEmpty ? route.reason : question]
          : const <String>[],
      blockers: blockers,
    );
    final task = AgentTask(
      groupId: widget.groupId,
      characterId: route.characterId ?? '',
      userRequest: taskRequest,
      assignedCharacterIds: candidates.toList(growable: false),
      plan: '角色路由候选：${route.reason}',
      workModeTask: true,
    );
    var execution = <String, dynamic>{};
    final attachment = attachmentMessageId?.trim();
    if (attachment != null && attachment.isNotEmpty) {
      execution['attachmentMessageId'] = attachment;
    }
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      jsonEncode(execution),
      state,
    );
    final handoff = route.handoffState;
    if (handoff != null) WorkHandoffState.persistToTask(task, handoff);
    // Keep this lookup in the helper's contract so callers cannot accidentally
    // manufacture a candidate that is absent from the current group map.
    if (route.characterId != null &&
        !charactersById.containsKey(route.characterId)) {
      task.characterId = '';
    }
    return task;
  }

  /// Persists a recoverable group task when routing found a concrete owner but
  /// a user-action boundary (missing role, disabled work mode, or credentials)
  /// prevents discussion/execution from starting. The chat message and task
  /// checkpoint share the same reason and always address the current owner.
  Future<void> _queueDiscussionTask({
    required WorkTaskCoordinator coordinator,
    required String text,
    required bool hasAttachments,
    required String? attachmentMessageId,
    required WorkRoleRouteResult route,
    required Map<String, AICharacter> charactersById,
    Iterable<String> additionalBlockers = const [],
    String? additionalQuestion,
    String? reason,
  }) async {
    final contract = route.deliverableContract;
    final extraBlockers = List<String>.from(additionalBlockers);
    final publicReason =
        reason?.trim().isNotEmpty == true ? reason!.trim() : route.reason;
    final pendingTask = _buildDiscussionTask(
      text: text,
      hasAttachments: hasAttachments,
      attachmentMessageId: attachmentMessageId,
      route: route,
      charactersById: charactersById,
      additionalBlockers: extraBlockers,
      additionalQuestion: additionalQuestion,
    );
    if (pendingTask == null) {
      // Private chats deliberately do not create a virtual group discussion.
      // Still keep the existing fixed-role conversation informed when a
      // preflight boundary rejects the request; silently returning here would
      // make missing credentials or disabled work mode look like a lost input.
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'system',
        content: '工作模式角色路由未完成：$publicReason',
      ));
      return;
    }
    final requiresOwnerMention = route.needsMentionClarification ||
        extraBlockers.isNotEmpty ||
        (route.characterId == null &&
            contract?.explicitExecutorId?.trim().isNotEmpty == true);
    await _appendMessage(Message(
      groupId: widget.groupId,
      senderId: 'system',
      senderType: 'system',
      content: '${requiresOwnerMention ? '@$_ownerMentionName ' : ''}'
          '工作模式角色路由未完成，任务已进入群讨论等待：$publicReason',
      isMention: requiresOwnerMention,
    ));
    await coordinator.submit(pendingTask);
  }

  Future<List<AICharacter>> _charactersWithUsableCredentials(
    Iterable<AICharacter> characters,
  ) async {
    final members = List<AICharacter>.from(characters);
    final checks = await Future.wait(
      members.map(_hasUsableCredential),
    );
    return [
      for (var index = 0; index < checks.length; index++)
        if (checks[index]) members[index],
    ];
  }

  Future<bool> _hasUsableCredential(AICharacter character) async {
    final config = _resolveApiConfig(character);
    if (config == null) return false;
    try {
      final key = await _credentialResolver
          .resolve(config)
          .timeout(WorkRoleModelSelectorService.defaultTimeout);
      return key != null && key.trim().isNotEmpty;
    } on Object {
      // A broken credential entry is unavailable for automatic routing;
      // the explicit route/preflight still reports the affected role.
      return false;
    }
  }

  AgentTask? _latestWorkTaskForConversation() {
    return ref
        .read(workTaskCoordinatorProvider)
        .taskForConversation(widget.groupId);
  }

  /// 执行一轮普通群聊 / 私聊的 AI 回复。
  ///
  /// [userMessage] 本轮触发的用户文本（自动聊天时为 null）；
  /// [mentionedIds] 用户 @ 到的角色；[isAutoChat] 区分空闲自动聊天；
  /// [currentUserMessage] 用户消息实体（含附件），供多模态上下文使用。
  ///
  /// 非自动轮受 [_ChatRoomPageState._maxAutoRounds] 约束，防止角色互相接话形成无限循环。
}
