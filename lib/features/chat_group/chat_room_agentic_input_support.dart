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
      );
      return;
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
  /// workspace bridge 或 AgentRuntime。后续追问复用同一任务的持久上下文。
  Future<void> _runWorkModeTask({
    required String text,
    required List<String> mentionedIds,
  }) async {
    final coordinator = ref.read(workTaskCoordinatorProvider);
    final activeTask = _latestWorkTaskForConversation();
    if (activeTask != null) {
      await coordinator.enqueueFollowUp(activeTask.id, text);
      return;
    }

    final executor = WorkModePolicy.selectExecutor(
      characters: _characters,
      mentionedIds: mentionedIds,
    );
    if (executor == null) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'ai',
        content: '工作模式需要至少一个已启用 Agentic 的活跃角色。',
      ));
      return;
    }
    // 策略层判断这条输入是否值得触发一次工作任务（例如纯闲聊则跳过）。
    if (!WorkModePolicy.shouldRun(
      enabled: _workModeEnabled,
      character: executor,
      userRequest: text,
    )) {
      return;
    }
    final task = AgentTask(
      groupId: widget.groupId,
      characterId: executor.id,
      userRequest: text,
      requestedPermissions: executor.toolPermissions,
      assignedCharacterIds: <String>[executor.id],
      workModeTask: true,
    );
    await coordinator.submit(task);
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
