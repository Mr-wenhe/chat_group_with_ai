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

    if (_characters.isEmpty) {
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
        senderType: 'ai',
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
      await coordinator.enqueueFollowUp(
        activeTask.id,
        followUpRequest,
        attachmentMessageId: hasAttachments ? attachmentMessageId : null,
      );
      return;
    }

    // Route against the complete group membership so an explicit @ can
    // produce a useful unavailable/ambiguous diagnostic instead of silently
    // falling back to the first active character. The router also creates the
    // durable product → development → testing stage plan used by the
    // coordinator for serial role handoff.
    final groupCharacters =
        _allGroupCharacters.isEmpty ? _characters : _allGroupCharacters;
    // Automatic routing must not ask a model to choose a role that cannot
    // actually run. Explicit @ and DM routes retain the full list so their
    // unavailable-role diagnostics remain precise.
    final routableCharacters = mentionedIds.isNotEmpty || _isDirectChat
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
      isDirectChat: _isDirectChat,
      directCharacterId: _directCharacterId,
      skills: _db.characterSkillBox.values,
    );
    if (!route.isSuccess) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'ai',
        content: '工作模式角色路由未完成：${route.reason}',
      ));
      return;
    }
    final charactersById = <String, AICharacter>{
      for (final character in _allGroupCharacters) character.id: character,
      for (final character in _characters) character.id: character,
    };
    final executor = charactersById[route.characterId];
    if (executor == null) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'ai',
        content: '工作模式角色路由未完成：找不到选中的执行角色。',
      ));
      return;
    }
    if (_workModeEnabled && !executor.agenticEnabled) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'ai',
        content: '工作模式未启动：${executor.name}未启用工作能力，请在角色设置中开启“允许工作模式”，或选择其他工作角色。',
      ));
      return;
    }
    final stageRoleIds = route.stages.isEmpty
        ? <String>[executor.id]
        : route.stages.map((stage) => stage.roleId).toSet().toList();
    // Re-check the concrete secure credential for every planned stage, not
    // only ApiConfig.hasCredential. The latter is persisted metadata and can
    // be stale after rotation/revocation; starting a later stage with a stale
    // flag would make the task fail after the user already approved routing.
    final stageCharacters = stageRoleIds
        .map((characterId) => charactersById[characterId])
        .whereType<AICharacter>()
        .toList(growable: false);
    final usableStageCharacters =
        await _charactersWithUsableCredentials(stageCharacters);
    final usableStageIds = usableStageCharacters.map((item) => item.id).toSet();
    final unavailableRoles = stageCharacters
        .where((character) => !usableStageIds.contains(character.id))
        .map((character) => character.name)
        .toList(growable: false);
    if (unavailableRoles.isNotEmpty) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'ai',
        content: '工作模式角色路由未完成：${unavailableRoles.join('、')}尚未配置可用模型凭据，未启动任务。',
      ));
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
    final requiredByIntent = CharacterSkillResolver.resolveFor(
      executor,
      taskRequest,
    ).permissions.toSet();
    final asksForSkillManagement = RegExp(
      r'技能|skill|template|模板',
      caseSensitive: false,
    ).hasMatch(taskRequest);
    final asksForMutation = RegExp(
      r'写入|修改|创建|生成|保存|导出|实现|修复|更新|重构|删除|重命名|patch|write|create|generate|edit|save|export|implement|fix|update|refactor|delete|rename',
      caseSensitive: false,
    ).hasMatch(taskRequest);
    final asksForCommand = RegExp(
      r'运行|执行|测试|构建|编译|验证|命令|run|execute|test|build|compile|verify|command',
      caseSensitive: false,
    ).hasMatch(taskRequest);
    final asksForBrowser = RegExp(
      r'网页|浏览器|页面|browser|web page|website',
      caseSensitive: false,
    ).hasMatch(taskRequest);
    final missingPermissions = requiredByIntent
        .where((permission) => switch (permission) {
              ToolPermission.skillCreate ||
              ToolPermission.skillDownload =>
                asksForSkillManagement,
              ToolPermission.workspacePatch => asksForMutation,
              ToolPermission.commandRun => asksForCommand,
              ToolPermission.browserContext => asksForBrowser,
              _ => true,
            })
        .where((permission) => !requestedPermissions.contains(permission))
        .toSet();
    if (missingPermissions.isNotEmpty) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'ai',
        content:
            '工作模式未启动：角色「${executor.name}」缺少当前任务所需工具权限：${missingPermissions.map((item) => item.name).join('、')}。请在角色设置中授予权限或选择其他工作角色。',
      ));
      return;
    }
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
    if (attachmentMessageId != null && attachmentMessageId.trim().isNotEmpty) {
      task.executionStateJson = jsonEncode({
        'attachmentMessageId': attachmentMessageId.trim(),
      });
    }
    final handoff = route.handoffState;
    if (handoff != null) WorkHandoffState.persistToTask(task, handoff);
    await _appendMessage(Message(
      groupId: widget.groupId,
      senderId: 'system',
      senderType: 'ai',
      content: '工作模式角色路由：${route.reason}',
    ));
    await coordinator.submit(task);
  }

  Future<List<AICharacter>> _charactersWithUsableCredentials(
    Iterable<AICharacter> characters,
  ) async {
    final result = <AICharacter>[];
    for (final character in characters) {
      final config = _resolveApiConfig(character);
      if (config == null) continue;
      try {
        final key = await _credentialResolver
            .resolve(config)
            .timeout(WorkRoleModelSelectorService.defaultTimeout);
        if (key != null && key.trim().isNotEmpty) result.add(character);
      } on Object {
        // A broken credential entry is unavailable for automatic routing;
        // the explicit route/preflight still reports the affected role.
      }
    }
    return result;
  }

  AgentTask? _latestWorkTaskForConversation() {
    final tasks = _db.agentTaskBox.values
        .where((task) =>
            task.workModeTask &&
            task.groupId == widget.groupId &&
            task.status != AgentTaskStatus.cancelled)
        .toList()
      ..sort((left, right) => (right.updatedAt ?? right.createdAt).compareTo(
            left.updatedAt ?? left.createdAt,
          ));
    return tasks.isEmpty ? null : tasks.first;
  }

  /// 执行一轮普通群聊 / 私聊的 AI 回复。
  ///
  /// [userMessage] 本轮触发的用户文本（自动聊天时为 null）；
  /// [mentionedIds] 用户 @ 到的角色；[isAutoChat] 区分空闲自动聊天；
  /// [currentUserMessage] 用户消息实体（含附件），供多模态上下文使用。
  ///
  /// 非自动轮受 [_ChatRoomPageState._maxAutoRounds] 约束，防止角色互相接话形成无限循环。
}
