part of 'chat_room_page.dart';

extension _ChatRoomAgenticRecoverySupport on _ChatRoomPageState {
  /// 查找本会话中"可在工作模式下恢复"的 agentic 任务，取最近一条询问用户。
  ///
  /// 仅工作模式生效；用户选择继续则续跑，否则标记为放弃并清理。
  Future<void> _offerAgentTaskRecovery() async {
    if (!_workModeEnabled) return;
    final tasks = _db.agentTaskBox.values
        .where((task) =>
            task.groupId == widget.groupId && task.canResumeInWorkMode)
        .toList()
      // 按最后更新时间倒序，优先恢复最近中断的那个任务。
      ..sort((a, b) =>
          (b.updatedAt ?? b.createdAt).compareTo(a.updatedAt ?? a.createdAt));
    if (tasks.isEmpty || !_canTouchUi) return;
    final task = tasks.first;
    final continueTask = await showDialog<bool>(
      context: context,
      // 强制用户明确选择"继续/放弃"，避免任务悬挂在不确定状态。
      barrierDismissible: false,
      builder: (dialogContext) => AgentTaskRecoveryDialog(
        task: task,
        onAbandon: () => Navigator.pop(dialogContext, false),
        onContinue: () => Navigator.pop(dialogContext, true),
      ),
    );
    if (continueTask == true) {
      await _resumeAgentTask(task);
    } else {
      await _cancelAgentTask(task, reason: '用户放弃恢复任务。');
    }
  }

  /// 恢复一个中断的 agentic 任务。
  ///
  /// 两种恢复路径：
  /// 1. 任务卡在"等待工具审批"→ 重建审批项并再次弹给用户确认；
  /// 2. 否则从已完成的操作列表继续跑 agentic 循环。
  Future<void> _resumeAgentTask(AgentTask task) async {
    if (!_workModeEnabled || !task.workModeTask) return;
    final character = _db.aiCharacterBox.get(task.characterId);
    if (character == null) return;
    final config = _resolveApiConfig(character);
    if (config == null) return;
    final provider = ApiProvider.values.firstWhere(
      (value) => value.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );
    final workspace = await WorkModeWorkspaceService(db: _db).loadOrCreate(
      conversationId: widget.groupId,
      isDirectChat: _isDirectChat,
    );
    // 每个 await 之后都要复检：期间用户可能已退出页面或关闭工作模式。
    if (!_canTouchUi || !_workModeEnabled) return;
    final registration = await LocalAgentBridgeLauncher().registerWorkspace(
      conversationId: widget.groupId,
      workspacePath: workspace.workDirPath,
    );
    if (!_canTouchUi || !_workModeEnabled) {
      await LocalAgentBridgeLauncher().unregisterWorkspace(
        conversationId: widget.groupId,
        registration: registration,
      );
      return;
    }
    final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
    if (pending != null) {
      // 路径 1：中断点正好停在待审批的工具调用上。
      final approval = PendingAgentToolApproval(
        character: character,
        config: config,
        provider: provider,
        userRequest: task.userRequest,
        request: pending,
        priorExecutedRequests: _restoredExecutedRequests(task),
        task: task,
      );
      await _presentPendingAgentApproval(approval);
      return;
    }
    // 路径 2：直接续跑 agentic 循环。
    if (_conversationController.beginWork() == null) {
      // Another run owns this conversation. Do not leave this resume attempt's
      // route behind (and let the lease protect a newer registration).
      await LocalAgentBridgeLauncher().unregisterWorkspace(
        conversationId: widget.groupId,
        registration: registration,
      );
      return;
    }
    if (_canTouchUi) _setUiState(() {});
    final workModeRun = _workModeSession.beginRun();
    final cancelToken = workModeRun.token;
    try {
      await _generateAgenticReply(
        character: character,
        config: config,
        provider: provider,
        userMessage: task.userRequest,
        context: _recentMessagesForContext(),
        resumeTask: task,
        workMode: true,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );
    } finally {
      _workModeSession.finishRun(workModeRun);
      await _finishWorkActivityAndDispatchNext();
    }
  }

  /// 把任务里以 JSON 字符串保存的"已执行操作"还原成 [ToolRequest] 列表。
  ///
  /// 解析失败的条目会被 [Iterable.whereType] 静默丢弃——历史数据格式变化时
  /// 不应阻断整个任务恢复。
  List<ToolRequest> _restoredExecutedRequests(AgentTask task) {
    return task.completedOperations
        .map(ToolRequest.fromJsonString)
        .whereType<ToolRequest>()
        .toList();
  }

  /// 启动空闲自动聊天调度器（首次延迟带随机抖动）。
  void _startAutoChat() {
    if (!ChatActivityPolicy.canStartAutoChat(
      workModeEnabled: _workModeEnabled,
      autoChatEnabled: _isAutoChatEnabled,
      hasCharacters: _characters.isNotEmpty,
      hasApiConfig: _hasAnyApiConfig,
    )) {
      return;
    }
    if (!_canTouchUi) return;
    _setUiState(() => _autoChatStatus = AutoChatStatus.waiting);
    _autoChatScheduler.start(
      initialDelay: Duration(
        seconds: _autoChatBaseIntervalSeconds +
            _autoChatRandom.nextInt(
              _ChatRoomPageState._autoChatIntervalJitterSeconds,
            ),
      ),
    );
  }

  /// 自动聊天的基础间隔（秒）。
  ///
  /// 私聊固定 45 秒（更克制）；群聊取群配置的 replyIntervalSeconds，
  /// 并夹到 5~60 秒防止用户配出极端值把接口打爆或几乎不说话。
  int get _autoChatBaseIntervalSeconds {
    if (_isDirectChat) return 45;
    final configured = _group?.replyIntervalSeconds ??
        _ChatRoomPageState._autoChatMinIntervalSeconds;
    return configured.clamp(5, 60);
  }

  /// 停止自动聊天并把轮次计数归零，状态置为 [AutoChatStatus.paused]。
  void _stopAutoChat() {
    _autoChatScheduler.stop();
    _autoChatRoundCount = 0;
    if (_canTouchUi) _setUiState(() => _autoChatStatus = AutoChatStatus.paused);
  }

  /// 执行一轮空闲自动聊天。
  ///
  /// 多重让位条件（任一命中则本轮跳过或进入冷却）：
  /// - 策略层不允许（工作模式 / 开关关闭 / 无角色 / 无 API 配置）；
  /// - 已有回复在跑、正在流式输出、或用户正在输入（不打断用户）；
  /// - 私聊里 AI 已连说 3 条而用户没回（避免单方面刷屏）；
  /// - 本 burst 轮数达上限 → 停止并冷却 [_autoChatBurstPause]。
  Future<void> _tryAutoChatRound() async {
    if (!_pageActive) return;
    if (!ChatActivityPolicy.canStartAutoChat(
      workModeEnabled: _workModeEnabled,
      autoChatEnabled: _isAutoChatEnabled,
      hasCharacters: _characters.isNotEmpty,
      hasApiConfig: _hasAnyApiConfig,
    )) {
      if (_canTouchUi) {
        _setUiState(() => _autoChatStatus = AutoChatStatus.paused);
      }
      return;
    }
    if (!_canTouchUi) return;
    if (_isAiReplying ||
        _isStreaming ||
        _textController.text.trim().isNotEmpty) {
      if (_canTouchUi) {
        _setUiState(() => _autoChatStatus = AutoChatStatus.paused);
      }
      return;
    }
    if (_isDirectChat && _directAiMessagesSinceLastUser() >= 3) {
      if (_canTouchUi) {
        _setUiState(() => _autoChatStatus = AutoChatStatus.paused);
      }
      return;
    }
    if (_autoChatRoundCount >= _ChatRoomPageState._maxAutoChatRounds) {
      _stopAutoChat();
      _autoChatScheduler.coolDown(_ChatRoomPageState._autoChatBurstPause);
      return;
    }

    // 由拟人化编排器根据记忆、关系、话题契合度挑选本轮发言者及其发言意图。
    final autoIntents = HumanizedChatOrchestrator.selectReplyIntents(
      characters: _characters,
      recentMessages: _messages.toList(),
      recentMessagesForCharacter: (character) => _visibleContextForCharacter(
        character.id,
        _recentMessagesForContext(),
      ),
      groupId: widget.groupId,
      groupTheme: _group?.theme ?? '日常聊天',
      userMessage: null,
      mentionedIds: const [],
      memories: _characterMemories,
      relationships: _relationshipStates,
      isEligible: _isEligibleToReply,
      random: _autoChatRandom,
      isAutoChat: true,
    );
    // 排除正在跑 agentic 任务的角色，防止同一角色重入产生重复消息/文件。
    var speakers = _charactersForIntents(autoIntents)
        .where((c) => !_agenticRunningCharacterIds.contains(c.id))
        .toList();
    final lastAiSenderId = _lastAiSenderId;
    // 有多个候选时避免让上一条的发言者连说两轮；只剩一个候选就不再过滤。
    final speakersToUse = speakers.length <= 1
        ? speakers
        : speakers.where((c) => c.id != lastAiSenderId).toList();
    _pendingReplyIntents
      ..clear()
      ..addEntries(
          autoIntents.map((intent) => MapEntry(intent.speakerId, intent)));

    if (speakersToUse.isEmpty) {
      if (_canTouchUi) {
        _setUiState(() {
          _autoChatStatus = AutoChatStatus.unavailable;
          _lastReplyBlockReason = _eligibleCharacters.isEmpty
              ? _firstBlockReason(_characters)
              : null;
        });
      }
      return;
    }

    // beginAutoGuard 返回 null 表示已有回合占用，本轮直接放弃。其完成
    // 不依赖 UI 活跃状态，避免页面切出后把会话永久留在 generating。
    final autoRunGuard = _conversationController.beginAutoGuard();
    if (autoRunGuard == null) return;

    try {
      _setUiState(() {
        _autoChatRoundCount++;
        _autoChatStatus = AutoChatStatus.generating;
      });
      for (final speaker in speakersToUse) {
        // 循环内逐次复检开关：用户可能中途关闭自动聊天或切到工作模式。
        if (!_isAutoChatEnabled || _workModeEnabled) break;
        if (!_isEligibleToReply(speaker)) continue;
        final replyContent = await _generateAiReply(
          speaker,
          _messages.toList(),
          null,
          isAutoChat: true,
          intent: _pendingReplyIntents[speaker.id],
        );
        if (_workModeEnabled) break;
        if (_conversationController.state.phase == ConversationPhase.stopping) {
          break;
        }
        // 按内容长度模拟"打字时间"，让多人接话有真实节奏。
        await _delay(replyContent);
      }

      // 自动聊天每 3 轮才更新一次记忆，避免每轮都额外调用一次 LLM。
      if (!_workModeEnabled) {
        _autoChatMemoryTick++;
        if (_autoChatMemoryTick >= 3) {
          _autoChatMemoryTick = 0;
          await _maybeUpdateMemory();
        }
      }
    } finally {
      autoRunGuard.finish();
      if (_canTouchUi) {
        _setUiState(() {
          _autoChatStatus = _isAutoChatEnabled && !_workModeEnabled
              ? AutoChatStatus.waiting
              : AutoChatStatus.paused;
        });
      }
    }

    // 处理排队中的用户消息：当前回合结束后自动触发下一轮 AI 回复。
    await _drainQueuedUserMessage();
  }

  /// 计算这批消息对应的"已读截止时间"。
  DateTime _readThrough(List<Message> messages) {
    return ChatRoomLoader.readThrough(
      messages.map((message) => message.timestamp),
    );
  }

  /// 把当前会话标记为已读并清除"@我"横幅。
  ///
  /// 传 [throughMessage] 时只按该条消息的时间戳推进已读位置，
  /// 否则按当前已加载消息的最大时间戳。
}
