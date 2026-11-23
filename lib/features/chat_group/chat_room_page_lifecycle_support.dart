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
  /// 三者在 [_roomWorkAllowed] 处合流；自动聊天与已发出的回合只要求
  /// [_roomSessionVisible]（遮挡/失焦继续），这个合流值仅用于用户输入派发。
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

  /// 停止本群的**自动调度与在飞请求**（用户真的离开了这个会话）。
  ///
  /// 判据是 [_roomSessionVisible]，不是 [_autoChatAllowed]：后者把"真后台"和
  /// "正在多选"也算成不允许，用它当早返回条件会把 `hidden`（窗口遮挡）那一拍
  /// 的调用直接吞掉；随后 `paused` 到来时闸门值没有变化、不会再触发，真后台的
  /// 取消就永远轮不到（Android 的 `inactive → hidden → paused` 必然命中）。
  /// 真后台由 [_handleAppLifecycleState] 单独收口到 [_haltRoomWork]。
  ///
  /// 窗口被遮挡/失焦**不算离开**：用户明确要求此时继续自动聊天（2026-11-17
  /// 拍板），所以这里直接返回，不停调度器、不取消在飞的请求。
  void _pauseRoomAutoWork() {
    if (_roomSessionVisible) return;
    _haltRoomWork('room-left');
  }

  /// 停掉本群一切在飞工作：调度器、启动延迟、看门狗、选人请求、回复请求。
  ///
  /// [reason] 只进诊断：它会被 dio 带进 `DioException` 文案，最终落到
  /// `ai_request_diagnostics_v1` 的 `failureDetail`，事后靠它区分这次中断是
  /// 「离开会话」还是「App 进后台」。
  void _haltRoomWork(String reason) {
    // 页面对象已经销毁时由 `_disposePage` 收过口，再来一次会碰到已 dispose 的
    // ConversationController。
    if (_disposed) return;
    _autoChatStartTimer?.cancel();
    _autoChatStartTimer = null;
    _autoChatWatchdog?.cancel();
    _autoChatWatchdog = null;
    _autoChatScheduler.stop();
    _cancelActiveSpeakerPick();
    // 真正离开会话 / 进后台：整轮作废并断开请求，迟到结果不落地。
    _roomRoundGeneration++;
    if (_isStreaming) {
      _stopStreaming(preservePendingReply: true, cancelReason: reason);
    } else {
      // 没有活跃的流也照样要断开：本轮可能正卡在压缩或失败重试里。
      _cancelActiveReplyRequest(reason);
    }
  }

  /// 恢复本群的自动行为。
  ///
  /// 恢复时不补跑暂停期间错过的回合：调度器只被启动一次（`start` 会替换旧
  /// 计时器），因此不会积累一批计时器。
  void _resumeRoomAutoWork() {
    _flushPendingMessageChanges();
    _reloadSearchRuntimeIfChanged();
    _startAutoChatWatchdog();
    if (!_isLoading && !_autoChatPausedByWorkMode) {
      // 窗口失焦/遮挡也会触发可见性翻转，但那时调度器还在跑；重复 start 会把
      // 45 秒间隔不断往后推，切一次窗口就永远等不到下一次自动聊天。
      if (!_autoChatScheduler.isActive) _startAutoChat();
    }
    if (!_isLoading) unawaited(_drainQueuedUserMessage());
  }

  /// 房间允许自动聊天时，每 15 秒确认一次调度器还活着。
  ///
  /// 「停止生成」、生命周期暂停、burst 冷却都曾把调度器停掉而没人重启；这里不
  /// 依赖某条路径的收尾，兜底把它拉回来（[AutoChatScheduler.isActive] 保证不会
  /// 反复重排把计时器一直往后推）。
  void _startAutoChatWatchdog() {
    if (_autoChatWatchdog?.isActive ?? false) return;
    _autoChatWatchdog = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _ensureAutoChatScheduled(),
    );
  }

  /// 角色回合结束后确认空闲自动聊天仍被调度。
  ///
  /// 与看门狗同一判据，用到不了下一拍时立刻补上。判据全部收在
  /// [_autoChatAllowed] 里（会话在 + 非真后台 + 非多选），这里只补一条工作模式
  /// 暂停；多加一份本地判断迟早会与 `_enterMessageSelection` 的临时 `stop` 打架，
  /// 让看门狗在多选期间把自动发言重新拉起来。
  void _ensureAutoChatScheduled() {
    if (!_autoChatAllowed || _autoChatPausedByWorkMode) return;
    if (_autoChatScheduler.isActive) return;
    _startAutoChat();
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
    // 页面离开是本轮必须作废的事件，直接收口，不等闸门：页面可能早已被别的
    // 全屏页面盖住（合流值已经是 false），只走闸门会漏掉这次取消。收口里包含
    // 停调度器、取消选人请求与回复请求（取消令牌会让 dio abort socket），
    // 运行守卫仍会在底层 Future 返回时完成 controller 的收尾。
    _haltRoomWork('page-deactivated');
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
    // 页面对象消失后仍有在飞的回复请求（流式或失败重试）时，必须真的断开，
    // 否则它会一直挂到进程结束，而结果已经没有任何人接收。
    _cancelActiveReplyRequest('page-disposed');
    ConversationPresenceService.instance.leave(widget.groupId);
    WidgetsBinding.instance.removeObserver(this);
    if (_pendingAttachments.isNotEmpty) {
      unawaited(_cleanupMediaPaths(_pendingAttachments));
    }
    _pendingAttachments.clear();
    _documentProcessingToken?.cancel();
    _conversationController.dispose();
    _autoChatScheduler.dispose();
    _autoChatWatchdog?.cancel();
    _autoChatWatchdog = null;
    _autoChatStartTimer?.cancel();
    _autoChatStartTimer = null;
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
    // 是否这一次回调才刚进入真后台。判断"是否刚进入"而不是直接看 `_appPaused`：
    // paused 之后系统还会补发回调，重复收口会把代际号反复推进。
    var enteredTrueBackground = false;
    // 只把真正的后台状态当作"看不见"：`inactive` 在 iOS 上也会因为来电、
    // 系统弹窗或下拉通知中心触发，此时 App 仍在屏幕上，不该打断正在生成的回复。
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _appForeground = false;
        enteredTrueBackground = !_appPaused;
        _appPaused = true;
        break;
      case AppLifecycleState.hidden:
        // 桌面端的"窗口被完全遮挡/最小化"走这里：不算真后台，自动聊天继续。
        _appForeground = false;
        _appPaused = false;
        break;
      case AppLifecycleState.resumed:
        _appForeground = true;
        _appPaused = false;
        break;
      case AppLifecycleState.inactive:
        break;
    }
    _refreshRoomActivity();
    // 真后台必须立刻停（CLAUDE.md 红线：没有通知设计就不能在后台继续生成）。
    // 不能指望上面的闸门：`hidden` 已经先把 `_roomWorkAllowed` 压成 false，
    // `paused` 再来时闸门判定"没有变化"直接返回，取消与停调度都不会执行。
    if (enteredTrueBackground) _haltRoomWork('app-background');
    // 回到前台：重新登记在场并把当前会话标记为已读。
    if (state == AppLifecycleState.resumed) {
      ConversationPresenceService.instance.enter(widget.groupId);
      unawaited(_markCurrentConversationRead());
      _reloadSearchRuntimeIfChanged();
    }
  }
}
