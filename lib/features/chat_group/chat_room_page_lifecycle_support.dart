part of 'chat_room_page.dart';

extension _ChatRoomPageLifecycleSupport on _ChatRoomPageState {
  void _handleDependenciesChanged() {
    // 依赖变化（例如路由复用同一 State）时重新登记在场状态。
    ConversationPresenceService.instance.enter(widget.groupId);
    _reloadSearchRuntimeIfChanged();
    _handleRouteVisibilityChanged();
  }

  /// 路由可见性变化：重新判定本页是否被**另一个全屏页面**盖住。
  ///
  /// 用 [TickerMode] 而不是 `ModalRoute.isCurrent`：Flutter 的 Overlay 只对被
  /// 不透明路由盖住的条目关闭 ticker，因此底部弹层、对话框这类非全屏浮层不会
  /// 把群判成不可见——用户还在看群，正在生成的回复不该被打断；切到别的群或
  /// 别的全屏页面才会关闭 ticker，此时旧群必须立刻停止。
  ///
  /// 依赖关系在 `didChangeDependencies` 里建立，所以可见性翻转会再回到这里。
  void _handleRouteVisibilityChanged() {
    _routeVisible = TickerMode.of(context);
    _refreshRoomActivity();
  }

  /// 重新评估"用户是否真的在看这个群"，并对称地起停本群的自动工作。
  ///
  /// 路由可见性、App 前台状态和 widget 生命周期必须分别判断：widget 仍然
  /// mounted 不代表用户正在看这个群，而 push 新路由也不一定触发 [deactivate]。
  /// 三者在 [_roomWorkAllowed] 处合流，只有全部成立才允许继续自动工作。
  void _refreshRoomActivity() {
    final allowed = _pageActive && _routeVisible && _appForeground;
    if (allowed == _roomWorkAllowed) return;
    _roomWorkAllowed = allowed;
    if (allowed) {
      _resumeRoomAutoWork();
    } else {
      _pauseRoomAutoWork();
    }
  }

  /// 停止本群的一切自动行为。
  ///
  /// 停调度器是"不再起新回合"，停流是"已有请求尽力取消"——本地一定不采纳
  /// 迟到的结果（见 [_generateAiReply] 的复检）。
  void _pauseRoomAutoWork() {
    _autoChatStartTimer?.cancel();
    _autoChatStartTimer = null;
    _autoChatScheduler.stop();
    _cancelActiveSpeakerPick();
    if (_isStreaming) _stopStreaming();
  }

  /// 恢复本群的自动行为。
  ///
  /// 恢复时不补跑暂停期间错过的回合：调度器只被启动一次（`start` 会替换旧
  /// 计时器），因此不会积累一批计时器。
  void _resumeRoomAutoWork() {
    _flushPendingMessageChanges();
    _reloadSearchRuntimeIfChanged();
    if (!_isLoading && !_autoChatPausedByWorkMode) {
      _startAutoChat();
    }
    if (!_isLoading) unawaited(_drainQueuedUserMessage());
  }

  void _initializeSearchRuntime() {
    _searchRuntime = ChatRoomSearchRuntimeController(
      conversationId: widget.groupId,
      governanceStore: _governanceStore,
      aiGateway: _aiGateway,
      credentialResolver: _credentialResolver,
      allCharacters: _searchRuntimeCharacters,
      resolveApiConfig: _resolveApiConfig,
    );
    _searchRuntime.initialize();
  }

  /// Reads the latest character bindings when a room is reactivated.
  ///
  /// Settings and member editors preserve their object identity while the
  /// room is inactive, so returning the list captured during the first load
  /// would keep an old `apiConfigId` in the planner/native route. Historical
  /// characters remain in the set for deleted-message rendering, while active
  /// group members are added from the current group record.
  Iterable<AICharacter> _searchRuntimeCharacters() {
    final characters = <String, AICharacter>{
      for (final character in _allGroupCharacters)
        character.id: _db.aiCharacterBox.get(character.id) ?? character,
    };
    final group = _db.chatGroupBox.get(widget.groupId);
    for (final characterId in group?.aiCharacterIds ?? const <String>[]) {
      final character = _db.aiCharacterBox.get(characterId);
      if (character != null) characters[character.id] = character;
    }
    return characters.values;
  }

  void _reloadSearchRuntimeIfChanged() {
    _searchRuntime.reloadIfChanged(
        isBusy: _isAiReplying || _isRegenerating || _isStreaming);
  }

  void _deactivatePage() {
    _pageActive = false;
    _cancelActiveSearch();
    // Stop an active stream as early as possible. The run guard in the caller
    // still performs the controller completion if the underlying Future has
    // not returned yet.
    _stopStreaming();
    // 页面离开是"不能继续自动工作"的一种，交给统一闸门收口：它会停调度器、
    // 取消正在飞的选择请求，并清掉启动延迟计时器。
    _refreshRoomActivity();
    // 页面被路由遮挡时停止语音播报（不清空开关，恢复后继续播后续回复）。
    unawaited(_stopVoiceBroadcast());
    // 同样立刻停下麦克风与 ASR（已识别的文本保留在输入框）。
    unawaited(_disposeVoiceInput());
  }

  void _activatePage() {
    _pageActive = true;
    ConversationPresenceService.instance.enter(widget.groupId);
    _flushPendingMessageChanges();
    // 连接在 deactivate 时刻意不断开：页面被别的东西盖住（弹窗、切到别的页）
    // 不代表人离开了群。已经连上时这里是空操作，只兜底"上次激活时配置还没读出来"。
    unawaited(_startRealtimeIfNeeded());
    _refreshRoomActivity();
  }

  void _disposePage() {
    _disposed = true;
    // 页面对象消失后任何自动行为都必须停下；闸门可能不会再被调用，直接置位。
    _roomWorkAllowed = false;
    _cancelActiveSpeakerPick();
    unawaited(_messageSubscription?.cancel());
    _messageSubscription = null;
    _pendingExternalMessages.clear();
    _pendingDeletedMessageIds.clear();
    _knownConversationMessageIds.clear();
    _cancelActiveSearch();
    ConversationPresenceService.instance.leave(widget.groupId);
    WidgetsBinding.instance.removeObserver(this);
    if (_pendingAttachments.isNotEmpty) {
      unawaited(_cleanupMediaPaths(_pendingAttachments));
    }
    _pendingAttachments.clear();
    _documentProcessingToken?.cancel();
    _conversationController.dispose();
    _autoChatScheduler.dispose();
    final streamingSession = _streamingSession;
    _streamingSession = null;
    if (streamingSession != null) unawaited(streamingSession.dispose());
    _searchDebounceTimer?.cancel();
    _searchBannerDismissTimer?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    _searchController.dispose();
    _mentionHighlightTimer?.cancel();
    _searchRuntime.dispose();
    _hideMentionOverlay();
    _mentionSearchController.dispose();
    // 浮层先移除再释放控制器，避免滚动位置在弹窗消失后仍被引用。
    _mentionListController.dispose();
    unawaited(_stopRealtime());
    unawaited(_speech.dispose());
    unawaited(_disposeVoiceBroadcast());
    unawaited(_disposeVoiceInput());
  }

  void _handleAppLifecycleState(AppLifecycleState state) {
    // 只把真正的后台状态当作"看不见"：`inactive` 在 iOS 上也会因为来电、
    // 系统弹窗或下拉通知中心触发，此时 App 仍在屏幕上，不该打断正在生成的回复。
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _appForeground = false;
        break;
      case AppLifecycleState.resumed:
        _appForeground = true;
        break;
      case AppLifecycleState.inactive:
        break;
    }
    _refreshRoomActivity();
    // 回到前台：重新登记在场并把当前会话标记为已读。
    if (state == AppLifecycleState.resumed) {
      ConversationPresenceService.instance.enter(widget.groupId);
      unawaited(_markCurrentConversationRead());
      _reloadSearchRuntimeIfChanged();
    }
  }
}
