part of 'chat_room_page.dart';

extension _ChatRoomAgenticRecoverySupport on _ChatRoomPageState {
  /// 查找本会话中必须由用户明确继续的任务。
  ///
  /// 恢复由全局协调器执行：聊天页只展示选择，不重建 runtime、workspace 或
  /// bridge，因此离开当前页面不会改变任务所有权。
  Future<void> _offerAgentTaskRecovery() async {
    if (!_workModeEnabled) return;
    final tasks = _db.agentTaskBox.values
        .where(
            (task) => task.groupId == widget.groupId && task.requiresUserResume)
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
    final coordinator = ref.read(workTaskCoordinatorProvider);
    if (continueTask == true) {
      await coordinator.resumeByUser(task.id);
    } else {
      await coordinator.stop(task.id, reason: '用户放弃恢复任务。');
    }
  }

  /// 启动空闲自动聊天调度器（首次延迟带随机抖动）。
  ///
  /// 只有用户真的在看这个群时才启动：被别的页面盖住或 App 退到后台时
  /// [_roomWorkAllowed] 为假，此时连调度器都不该存在。
  void _startAutoChat() {
    if (!_roomWorkAllowed) return;
    if (!ChatActivityPolicy.canStartAutoChat(
      workModeEnabled: _workModeEnabled,
      hasActiveWorkTask: _hasActiveWorkTaskForAutoChat,
      autoChatEnabled: _isAutoChatEnabled,
      hasCharacters: _characters.isNotEmpty,
      hasApiConfig: _hasAnyApiConfig,
      isGuest: _isRealtimeGuest,
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
  /// - 用户已经看不见这个群（切走页面、App 进后台）；
  /// - 已有回复在跑、正在流式输出、或用户正在输入（不打断用户）；
  /// - 私聊里 AI 已连说 3 条而用户没回（避免单方面刷屏）；
  /// - 本 burst 轮数达上限 → 停止并冷却 [_autoChatBurstPause]。
  ///
  /// 一轮内的发言者**逐次**选出：上一位说完再决定下一位，因此候补是基于最新
  /// 对话算出来的，而不是开场时一次锁定。
  Future<void> _tryAutoChatRound() async {
    if (!_roomWorkAllowed) return;
    if (_hasActiveWorkTaskForAutoChat) {
      _stopAutoChat();
      return;
    }
    if (!ChatActivityPolicy.canStartAutoChat(
      workModeEnabled: _workModeEnabled,
      hasActiveWorkTask: _hasActiveWorkTaskForAutoChat,
      autoChatEnabled: _isAutoChatEnabled,
      hasCharacters: _characters.isNotEmpty,
      hasApiConfig: _hasAnyApiConfig,
      isGuest: _isRealtimeGuest,
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

    // 每一轮空闲自动聊天重新给选人器一次机会。
    _speakerPickerDisabledForTurn = false;

    // beginAutoGuard 返回 null 表示已有回合占用，本轮直接放弃。其完成
    // 不依赖 UI 活跃状态，避免页面切出后把会话永久留在 generating。
    final autoRunGuard = _conversationController.beginAutoGuard();
    if (autoRunGuard == null) return;

    // 与本群普通回合同一条代际口径：中途离开本群（哪怕立刻回来）让这一轮作废，
    // 循环据此收手，而不是接着往下一位发言者走。
    final roundGeneration = _roomRoundGeneration;
    // 空闲自动发言还有自己的代际号：用户关掉开关（或切到工作模式）同样让这一轮
    // 永久作废，重新打开开关只会启动携带新代际号的新回合。
    final autoChatGeneration = _autoChatRoundGeneration;
    try {
      _setUiState(() {
        _autoChatRoundCount++;
        _autoChatStatus = AutoChatStatus.generating;
      });
      final alreadySpoken = <String>[];
      var spokeAny = false;
      for (var step = 0;
          step < GroupSpeakerSelection.maxRepliesPerAutoRound;
          step++) {
        // 循环内逐次复检：用户可能中途关闭自动聊天、切到工作模式或离开本群。
        if (!_isAutoChatEnabled || _autoChatPausedByWorkMode) break;
        if (!_roomWorkAllowed) break;
        if (roundGeneration != _roomRoundGeneration) break;
        if (autoChatGeneration != _autoChatRoundGeneration) break;
        if (_conversationController.state.phase == ConversationPhase.stopping) {
          break;
        }
        final picked = await _selectNextGroupSpeaker(
          userMessage: null,
          mentionedIds: const [],
          isAutoChat: true,
          alreadySpoken: alreadySpoken,
          userSentiment: null,
          roundGeneration: roundGeneration,
          autoChatGeneration: autoChatGeneration,
        );
        if (picked == null) {
          if (!spokeAny && _canTouchUi) {
            _setUiState(() {
              _autoChatStatus = AutoChatStatus.unavailable;
              _lastReplyBlockReason = _eligibleCharacters.isEmpty
                  ? _firstBlockReason(_characters)
                  : null;
            });
          }
          break;
        }
        alreadySpoken.add(picked.character.id);
        final replyContent = await _generateAiReply(
          picked.character,
          _messages.toList(),
          null,
          isAutoChat: true,
          intent: picked.intent,
          roundGeneration: roundGeneration,
          autoChatGeneration: autoChatGeneration,
        );
        spokeAny = true;
        if (_autoChatPausedByWorkMode) break;
        if (_conversationController.state.phase == ConversationPhase.stopping) {
          break;
        }
        // 按内容长度模拟"打字时间"，让多人接话有真实节奏。
        await _delay(replyContent);
      }

      // 自动聊天每 3 轮才更新一次记忆，避免每轮都额外调用一次 LLM。
      if (!_autoChatPausedByWorkMode) {
        _autoChatMemoryTick++;
        if (_autoChatMemoryTick >= 3) {
          _autoChatMemoryTick = 0;
          await _maybeUpdateMemory(
            isAutoChat: true,
            roundGeneration: roundGeneration,
            autoChatGeneration: autoChatGeneration,
          );
        }
      }
    } finally {
      autoRunGuard.finish();
      if (_canTouchUi) {
        _setUiState(() {
          _autoChatStatus = _isAutoChatEnabled && !_autoChatPausedByWorkMode
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
