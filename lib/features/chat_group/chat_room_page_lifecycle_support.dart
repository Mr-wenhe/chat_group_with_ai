part of 'chat_room_page.dart';

extension _ChatRoomPageLifecycleSupport on _ChatRoomPageState {
  void _handleDependenciesChanged() {
    // 依赖变化（例如路由复用同一 State）时重新登记在场状态。
    ConversationPresenceService.instance.enter(widget.groupId);
    _reloadSearchRuntimeIfChanged();
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
    _autoChatStartTimer?.cancel();
    _autoChatStartTimer = null;
    _autoChatScheduler.stop();
  }

  void _activatePage() {
    _pageActive = true;
    ConversationPresenceService.instance.enter(widget.groupId);
    _reloadSearchRuntimeIfChanged();
    if (!_isLoading && !_workModeEnabled) {
      _startAutoChat();
    }
    if (!_isLoading) unawaited(_drainQueuedUserMessage());
  }

  void _disposePage() {
    _disposed = true;
    _cancelActiveSearch();
    ConversationPresenceService.instance.leave(widget.groupId);
    WidgetsBinding.instance.removeObserver(this);
    if (_pendingAttachments.isNotEmpty) {
      unawaited(_cleanupMediaPaths(_pendingAttachments));
    }
    _pendingAttachments.clear();
    _workModeSession.requestStop('页面已关闭');
    _documentProcessingToken?.cancel();
    _conversationController.dispose();
    _autoChatScheduler.dispose();
    unawaited(
      LocalAgentBridgeLauncher().unregisterWorkspace(
        conversationId: widget.groupId,
      ),
    );
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
    unawaited(_speech.dispose());
  }

  void _handleAppLifecycleState(AppLifecycleState state) {
    // 回到前台：重新登记在场并把当前会话标记为已读。
    if (state == AppLifecycleState.resumed) {
      ConversationPresenceService.instance.enter(widget.groupId);
      unawaited(_markCurrentConversationRead());
      _reloadSearchRuntimeIfChanged();
    }
  }
}
