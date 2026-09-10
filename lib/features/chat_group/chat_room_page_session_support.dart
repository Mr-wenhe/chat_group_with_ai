part of 'chat_room_page.dart';

extension _ChatRoomPageSessionSupport on _ChatRoomPageState {
  /// 当前会话是否为私聊（`dm:` 前缀）。
  bool get _isDirectChat =>
      DirectChatSession.isDirectConversationId(widget.groupId);

  /// 私聊对应的角色 id；群聊场景返回 null。
  String? get _directCharacterId =>
      DirectChatSession.characterIdFrom(widget.groupId);

  /// 首屏加载：一次性取回群信息、成员、消息分页、记忆与关系态。
  ///
  /// 若带了 [ChatRoomPage.initialMessageId] 且该消息不在首屏分页内，
  /// 会改为加载"目标消息所在窗口"，再高亮定位过去。
  /// 加载失败（会话已被删除等）时弹提示并退出页面。
  Future<void> _loadData() async {
    try {
      // Capture membership before subscribing so a put that arrives during
      // the initial load is still distinguishable from an update of an older
      // message outside the visible page.
      final knownMessageIds =
          await _db.messageIdsForConversation(widget.groupId);
      if (!_canTouchUi) return;
      _knownConversationMessageIds
        ..clear()
        ..addAll(knownMessageIds);
      _startMessageSubscription();
      final loaded = await _loader.load(widget.groupId);
      var initialMessages = loaded.messages;
      var hasOlderMessages = loaded.hasOlderMessages;
      final targetId = widget.initialMessageId;
      // 目标消息不在默认分页中：改用"围绕目标消息"的分页窗口。
      if (targetId != null &&
          !initialMessages.any((message) => message.id == targetId)) {
        final page = await _repository.loadAround(targetId);
        initialMessages = page.messages;
        hasOlderMessages = page.hasOlder;
      }
      if (!_canTouchUi) return;

      setState(() {
        _group = loaded.displayGroup;
        _userProfile = loaded.userProfile;
        _characters = loaded.activeCharacters;
        _allGroupCharacters = loaded.allCharacters;
        _messages = initialMessages;
        _hasRestrictedHistory = loaded.hasRestrictedHistory;
        _hasOlderMessages = hasOlderMessages;
        _totalMessageCount = loaded.totalMessageCount;
        _groupMemory = loaded.groupMemory;
        _characterMemories = loaded.characterMemories;
        _relationshipStates = loaded.relationships;
        _workModeSession.setEnabled(
          WorkModeConfigService(db: _db).isWorkMode(widget.groupId),
        );
        _hasAnyApiConfig = loaded.hasAnyApiConfig;
        _isAutoChatEnabled = _governanceStore.budgetSettings.autoChatEnabled;
        _autoChatStatus = loaded.hasAnyApiConfig
            ? AutoChatStatus.waiting
            : AutoChatStatus.unavailable;
        // 私聊且对方没有可用 API 配置时，直接给出明确的阻塞原因提示。
        _lastReplyBlockReason = loaded.isDirectChat &&
                loaded.allCharacters.isNotEmpty &&
                !loaded.hasAnyApiConfig
            ? _blockReasonFor(loaded.allCharacters.first)
            : null;
        _isLoading = false;
      });
      _flushPendingMessageChanges();
      unawaited(_reconcileMessageMembership());

      // A global work-task overlay can mount in the same frame as the room.
      // Re-assert desktop input focus after that frame so opening a room from
      // the task panel does not leave keyboard input on the app root.
      if (_isDesktop) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_canTouchUi) _inputFocusNode.requestFocus();
        });
      }

      // The initial coordinator is created before group members are loaded.
      // Rebuild once member API configs are known; optional Planner/native
      // capabilities still remain gated by their explicit runtime switches.
      _searchRuntime.refreshAfterMembersLoaded();
      _restorePersistedSearchContexts(initialMessages);

      if (targetId == null) {
        // 常规进入：首帧布局完成后滚到底部。
        scrollToBottomAfterInitialLayout(_scrollController);
      } else {
        // 带定位目标：高亮并滚动到该消息。
        _highlightMessageTemporarily(targetId);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_canTouchUi) return;
          final target = _messages.where((message) => message.id == targetId);
          if (target.isNotEmpty) unawaited(_focusSearchResult(target.first));
        });
      }
      // 检查是否有上次异常中断的 agentic 任务需要恢复。
      _scheduleAgentTaskRecovery();
      if (ChatActivityPolicy.canStartAutoChat(
        workModeEnabled: _workModeEnabled,
        autoChatEnabled: _isAutoChatEnabled,
        hasCharacters: loaded.activeCharacters.isNotEmpty,
        hasApiConfig: loaded.hasAnyApiConfig,
      )) {
        // 私聊更克制：延迟更久再主动开口，避免一进来就被打扰。
        final delay = loaded.isDirectChat
            ? const Duration(seconds: 18)
            : _ChatRoomPageState._autoChatInitialDelay;
        _autoChatStartTimer = Timer(delay, () {
          _autoChatStartTimer = null;
          if (_canTouchUi && !_workModeEnabled) _startAutoChat();
        });
      }
    } on ChatRoomLoadException catch (error) {
      if (!mounted || _disposed) return;
      AppToast.show(context, error.message, icon: Icons.error_outline_rounded);
      Navigator.pop(context);
    } on Object catch (error) {
      // A source jump can race with a test teardown or database recovery. Once
      // the page is inactive, the load has no safe UI destination anymore.
      if (!mounted || _disposed || !_pageActive) return;
      AppToast.show(
        context,
        '会话加载失败：$error',
        icon: Icons.error_outline_rounded,
      );
      Navigator.pop(context);
    }
  }

  /// 滚动监听：接近顶部（<120px）且还有历史消息时，自动加载上一页。
  void _handleMessageScroll() {
    if (!_scrollController.hasClients ||
        _scrollController.position.pixels > 120 ||
        !_hasOlderMessages ||
        _isLoadingOlder) {
      return;
    }
    unawaited(_loadOlderMessages());
  }

  /// 向上加载更早的一页消息，并保持用户当前视觉位置不跳动。
  ///
  /// 做法：记录加载前的滚动偏移与内容总高，插入新消息后在下一帧
  /// 按"新增高度"补偿偏移，避免列表顶部插入导致内容瞬移。
  Future<void> _loadOlderMessages() async {
    if (_messages.isEmpty || _isLoadingOlder || !_hasOlderMessages) return;
    _isLoadingOlder = true;
    final oldPixels =
        _scrollController.hasClients ? _scrollController.position.pixels : 0.0;
    final oldExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;
    try {
      final page = await _repository.loadOlder(_messages.first.id);
      if (!_canTouchUi) return;
      final existingIds = _messages.map((message) => message.id).toSet();
      setState(() {
        // 用 Set.add 的返回值顺手去重，防止分页边界重复插入同一条消息。
        _messages = [
          ...page.messages.where((message) => existingIds.add(message.id)),
          ..._messages,
        ];
        _hasOlderMessages = page.hasOlder;
        _totalMessageCount = page.totalCount;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final addedExtent =
            _scrollController.position.maxScrollExtent - oldExtent;
        _scrollController.jumpTo(oldPixels + addedExtent);
      });
    } finally {
      _isLoadingOlder = false;
    }
  }

  /// 在首帧之后异步询问是否恢复中断的 agentic 任务。
  ///
  /// 放到 post-frame 是为了确保此时已有可用的 context 弹出对话框。
  void _scheduleAgentTaskRecovery() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_canTouchUi) unawaited(_offerAgentTaskRecovery());
    });
  }

  /// Starts the cross-component message bridge once the database is available.
  ///
  /// The work-mode runner is app-scoped and intentionally does not call back
  /// into a chat-room widget. Hive is the shared persistence boundary, so its
  /// box events are the durable source for live message updates.
  void _startMessageSubscription() {
    _messageSubscription ??= _db.messageBox.watch().listen(
          _handleMessageBoxEvent,
        );
  }

  void _handleMessageBoxEvent(BoxEvent event) {
    if (event.deleted) {
      final id = event.value is Message
          ? (event.value as Message).id
          : event.key?.toString();
      if (id == null || id.isEmpty) return;
      if (!_canTouchUi || _isLoading) {
        _pendingDeletedMessageIds.add(id);
        _pendingExternalMessages.remove(id);
        return;
      }
      _removeExternalMessage(id);
      return;
    }

    final message = event.value;
    if (message is! Message || message.groupId != widget.groupId) return;
    if (!_canTouchUi || _isLoading) {
      _pendingExternalMessages[message.id] = message;
      _pendingDeletedMessageIds.remove(message.id);
      return;
    }
    _mergeExternalMessage(message);
  }

  /// Applies all changes received while the room was loading or covered by
  /// another route. The latest value per message id wins.
  void _flushPendingMessageChanges() {
    if (!_canTouchUi || _isLoading) return;
    final deleted = List<String>.from(_pendingDeletedMessageIds);
    final messages = List<Message>.from(_pendingExternalMessages.values);
    _pendingDeletedMessageIds.clear();
    _pendingExternalMessages.clear();
    for (final id in deleted) {
      _removeExternalMessage(id);
    }
    for (final message in messages) {
      _mergeExternalMessage(message);
    }
  }

  Future<void> _reconcileMessageMembership() async {
    try {
      final ids = await _db.messageIdsForConversation(widget.groupId);
      if (!_canTouchUi) return;
      _knownConversationMessageIds
        ..clear()
        ..addAll(ids);
      _setUiState(() => _totalMessageCount = ids.length);
    } on Object {
      // The initial page and its event deltas remain usable if the optional
      // index refresh cannot complete during database recovery.
    }
  }

  void _mergeExternalMessage(Message message) {
    if (!_canTouchUi || message.groupId != widget.groupId) return;
    final isNewMessage = _knownConversationMessageIds.add(message.id);
    final existingIndex =
        _messages.indexWhere((existing) => existing.id == message.id);
    if (existingIndex >= 0) {
      _setUiState(() {
        _messages = List<Message>.from(_messages)..[existingIndex] = message;
      });
    } else if (isNewMessage) {
      _setUiState(() {
        _messages = [..._messages, message]
          ..sort((left, right) => left.timestamp.compareTo(right.timestamp));
        _totalMessageCount++;
      });
      _scrollToBottom();
    }
    if (message.senderType == 'ai') {
      // A globally persisted reply is already authoritative; only advance the
      // read marker here so a visible completion does not create an unread dot.
      unawaited(_markCurrentConversationRead(throughMessage: message));
    }
  }

  void _removeExternalMessage(String messageId) {
    final wasKnownMessage = _knownConversationMessageIds.remove(messageId);
    if (!wasKnownMessage) return;
    final existingIndex =
        _messages.indexWhere((message) => message.id == messageId);
    _setUiState(() {
      if (existingIndex >= 0) {
        _messages = List<Message>.from(_messages)..removeAt(existingIndex);
      }
      if (_totalMessageCount > 0) _totalMessageCount--;
    });
  }

  void _stopStreaming() {
    _cancelActiveSearch();
    if (!_isStreaming) {
      // There is no completion callback left to consume a discard latch. Clear
      // it here so a later, unrelated automatic reply cannot be dropped.
      _discardCurrentStream = false;
      return;
    }
    final runType = _conversationController.state.run?.type;
    // 先把最后一段增量刷进 UI，避免用户看到内容比实际生成的少。
    _flushStreamingUi();
    _conversationController.requestStop();
    unawaited(_streamingSession?.stop());
    // 若被停的是自动聊天回合，连调度器一起停，否则马上又会自动开口。
    if (runType == ConversationRunType.automatic) {
      _stopAutoChat();
    }
    if (_canTouchUi) {
      setState(() {
        _autoChatStatus = AutoChatStatus.paused;
      });
    }
  }

  void _flushStreamingUi({bool forceScroll = false}) {
    if (!_canTouchUi) return;
    final shouldScroll = forceScroll || _isNearBottom();
    setState(() {});
    if (shouldScroll) {
      // 流式跟随用 jumpTo（animated: false），避免每个 token 都触发一次动画。
      _scrollToBottom(animated: false);
    }
  }

  /// 当前是否滚动在底部附近（默认 160px 容差）。
  ///
  /// 尚未附着滚动视图时返回 true，视作"在底部"，让首帧内容正常跟随。
  bool _isNearBottom({double threshold = 160}) {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= threshold;
  }

  /// 滚动到列表底部。
  ///
  /// 放在 post-frame 回调里执行，确保新消息已完成布局、maxScrollExtent 已更新。
  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final target = _scrollController.position.maxScrollExtent;
        if (animated) {
          _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        } else {
          _scrollController.jumpTo(target);
        }
      }
    });
  }

  /// 为角色分配一个稳定的气泡/头像配色。
  ///
  /// 按角色 id 的字符码之和取模选色，保证同一角色每次进入都是同一个颜色。
  Color _senderColor(AICharacter sender) {
    const palette = [
      Color(0xFF576B95),
      Color(0xFF2F7D65),
      Color(0xFF9A5B31),
      Color(0xFF7A5C99),
      Color(0xFF3F6F8F),
      Color(0xFF8B5D6B),
      Color(0xFF5F7548),
    ];
    final hash = sender.id.codeUnits.fold<int>(0, (sum, unit) => sum + unit);
    return palette[hash % palette.length];
  }

  /// 自动发言状态条的展示文案。
  ///
  /// 工作模式与总开关的优先级高于具体运行状态——它们是"为什么不发言"的根因。
  String get _autoChatStatusText {
    if (_workModeEnabled) return '工作模式中，自动发言已暂停';
    if (!_isAutoChatEnabled) return '自动发言已关闭';
    switch (_autoChatStatus) {
      case AutoChatStatus.idle:
        return '自动发言空闲';
      case AutoChatStatus.waiting:
        return '自动发言等待中';
      case AutoChatStatus.generating:
        return '自动发言生成中';
      case AutoChatStatus.paused:
        return _textController.text.trim().isNotEmpty
            ? '你正在输入，自动发言暂停'
            : '自动发言已暂停';
      case AutoChatStatus.unavailable:
        return _replyBlockText(_lastReplyBlockReason);
      case AutoChatStatus.error:
        return '自动发言异常，已暂停';
    }
  }

  /// 切换空闲自动发言开关（仅本次会话内存态，不改全局治理设置）。
  void _toggleAutoChat(bool enabled) {
    if (!_canTouchUi) return;
    setState(() {
      _isAutoChatEnabled = enabled;
      _autoChatStatus =
          enabled ? AutoChatStatus.waiting : AutoChatStatus.paused;
    });
    if (enabled && !_workModeEnabled) {
      _startAutoChat();
    } else {
      _autoChatScheduler.stop();
    }
  }

  /// 切换工作模式（持久化到本会话配置）。
  ///
  /// 开启：中断进行中的自动发言流式输出并停掉调度器，再检查可恢复的任务。
  /// 关闭：只关闭本会话的 UI 开关；全局工作任务仍由执行面板控制。
  Future<void> _toggleWorkMode(bool enabled) async {
    await WorkModeConfigService(db: _db).setWorkMode(widget.groupId, enabled);
    _workModeSession.setEnabled(enabled);
    if (enabled) {
      // 正在自动发言的话先丢弃当前这条流式输出，避免它写进工作模式会话。
      if (shouldArmDiscardOnWorkModeToggle(
        schedulerRunning: _autoChatScheduler.isRunning,
        streamActive: _isStreaming,
      )) {
        _discardCurrentStream = true;
        _stopStreaming();
      } else {
        // The scheduler may be between bursts. Do not leave a stale latch from
        // an earlier run waiting for the next normal reply.
        _discardCurrentStream = false;
      }
      _stopAutoChat();
    }
    if (_canTouchUi) {
      setState(() {});
    }
    if (enabled) {
      _scheduleAgentTaskRecovery();
    } else if (_isAutoChatEnabled) {
      _startAutoChat();
    }
  }

  /// 构建 AppBar 下方的会话控件（自动发言 / 语音播报 / 工作模式开关）。
  ///
  /// 私聊只展示工作模式；流式语音播报属于群聊特性，默认关闭。语音服务未
  /// 配置时按钮置灰（Tooltip 引导去设置页绑定 Key）。
  Widget _buildConversationControls(ColorScheme cs) {
    final usable = _voiceBroadcastUsable;
    return CompactConversationControls(
      showAutoChat: !_isDirectChat,
      autoChatEnabled: _isAutoChatEnabled && _hasAnyApiConfig,
      workModeEnabled: _workModeEnabled,
      autoChatAvailable: _hasAnyApiConfig,
      autoChatTooltip: _autoChatStatusText,
      workModeTooltip: _workModeEnabled ? '工作模式已开启 · 敏感操作需确认' : '工作模式已关闭',
      onAutoChatChanged: _toggleAutoChat,
      onWorkModeChanged: _toggleWorkMode,
      showVoiceBroadcast: !_isDirectChat && !kIsWeb,
      voiceBroadcastEnabled: _voiceBroadcastEnabled,
      voiceBroadcastAvailable: usable,
      voiceBroadcastTooltip: _voiceBroadcastEnabled
          ? '流式语音播报已开启 · AI 回复将逐句朗读'
          : (usable
              ? '开启流式语音播报（AI 回复逐句朗读）'
              : '语音服务未配置，请到 设置 → API 配置 → 语音服务 绑定 Key'),
      onVoiceBroadcastChanged: (enabled) =>
          unawaited(_setVoiceBroadcastEnabled(enabled)),
    );
  }

  // —— 语音播放 ——
  /// TTS 总开关（存于 Hive app_settings，由设置页控制）。
  bool get _isTtsEnabled => _db.isTtsEnabled;

  /// TTS 状态回调：同步朗读状态，并把引擎错误以 Toast 形式提示用户。
  void _handleSpeechState(SpeechPlaybackState state) {
    if (!_canTouchUi) return;
    setState(() {
      _isSpeaking = state.isSpeaking;
      _speakingMessageId = state.messageId;
    });
    final error = state.error;
    if (error != null && error.isNotEmpty) {
      AppToast.show(
        context,
        error,
        icon: Icons.volume_off_rounded,
      );
    }
  }

  /// 朗读一条消息；若正在朗读别的内容会先停下（同一时刻只播一条）。
  Future<void> _ttsSpeak(Message message) async {
    if (_isSpeaking) {
      await _speech.stop();
    }
    final text = message.content;
    if (text.trim().isEmpty) return;
    await _speech.speak(messageId: message.id, text: text);
  }

  /// 停止朗读。
  Future<void> _ttsStop() => _speech.stop();

  /// 页面主体。
  ///
  /// 结构：AppBar（标题/搜索/导出/记忆/联网开关）+ 若干条件横幅
  /// （无 API Key、群公告、联网状态、@我 提醒）+ 会话开关 + 消息列表 + 输入区。
}
