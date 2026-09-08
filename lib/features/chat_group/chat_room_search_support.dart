part of 'chat_room_page.dart';

const _chatRoomSearchContextFormatter = SearchContextFormatter();

extension _ChatRoomSearchSupport on _ChatRoomPageState {
  bool get _webSearchUnsupported => kIsWeb;

  Future<T> _withSearchCancellation<T>(
    Future<T> Function(CancelToken cancelToken) operation,
  ) async {
    final cancelToken = CancelToken();
    _activeSearchCancelToken = cancelToken;
    try {
      return await operation(cancelToken);
    } finally {
      if (identical(_activeSearchCancelToken, cancelToken)) {
        _activeSearchCancelToken = null;
      }
      if (!cancelToken.isCancelled) cancelToken.cancel();
    }
  }

  void _cancelActiveSearch() {
    final cancelToken = _activeSearchCancelToken;
    _activeSearchCancelToken = null;
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel();
    }
  }

  Future<SearchTurnContext> _prepareSearchTurnContext({
    required String? userMessage,
    required Message? currentUserMessage,
    required bool isAutoChat,
  }) async {
    final query = userMessage?.trim() ?? '';
    final origin =
        isAutoChat ? SearchMessageOrigin.autoChat : SearchMessageOrigin.user;
    final sourceMessageId = currentUserMessage?.id.trim() ?? '';
    if (isAutoChat || query.isEmpty || sourceMessageId.isEmpty) {
      return SearchTurnContext.suppressed(
        conversationId: widget.groupId,
        sourceMessageId: sourceMessageId,
        turnId: sourceMessageId,
        query: query,
        origin: origin,
      );
    }
    final followUp = _latestSourceFollowUpContext(
      query: query,
      sourceMessageId: sourceMessageId,
    );
    if (followUp != null) return followUp;
    return _withSearchCancellation(
      (cancelToken) => _searchTurnController.prepareUserTurn(
        conversationId: widget.groupId,
        sourceMessageId: sourceMessageId,
        turnId: sourceMessageId,
        userMessage: query,
        requestConsent: _confirmWebSearch,
        onStatus: _handleWebSearchStatus,
        locale: _searchRuntimeSettings.locale,
        country: _searchRuntimeSettings.country,
        maxResults: _searchRuntimeSettings.maxResults,
        safeSearch: _searchRuntimeSettings.safeSearch,
        cancelToken: cancelToken,
      ),
    );
  }

  SearchTurnContext? _latestSourceFollowUpContext({
    required String query,
    required String sourceMessageId,
  }) {
    if (!const SearchIntentDetector().isSourceLinkRequest(query)) return null;
    final currentIndex = _messages.indexWhere(
      (message) => message.id == sourceMessageId,
    );
    if (currentIndex < 0) return null;
    for (var index = currentIndex - 1; index >= 0; index--) {
      final candidate = _messages[index];
      if (candidate.groupId != widget.groupId ||
          candidate.senderType == 'user') {
        continue;
      }
      final context = _searchTurnController.contextForReply(candidate.id) ??
          _persistedSearchContext(candidate);
      final snapshot = context?.snapshot;
      if (snapshot?.hasResults != true) continue;
      return _searchTurnController.reuseSourcesForFollowUp(
        conversationId: widget.groupId,
        sourceMessageId: sourceMessageId,
        turnId: sourceMessageId,
        query: query,
        snapshot: snapshot!,
      );
    }
    return null;
  }

  /// 当前生效的联网搜索策略：会话级覆盖优先于全局设置。
  WebSearchPolicy get _effectiveWebSearchPolicy =>
      _searchPolicyOverride ?? _governanceStore.globalSearchPolicy;

  /// 搜索策略对应的 AppBar 图标。
  IconData get _webSearchPolicyIcon => _webSearchUnsupported
      ? Icons.block_rounded
      : switch (_effectiveWebSearchPolicy) {
          WebSearchPolicy.off => Icons.public_off_rounded,
          WebSearchPolicy.ask => Icons.help_outline_rounded,
          WebSearchPolicy.auto => Icons.public_rounded,
        };

  /// `ask` 策略下逐次征求用户同意；明确展示查询内容与接收方，便于知情决定。
  Future<bool> _confirmWebSearch(String query) async {
    if (!_canTouchUi || _webSearchUnsupported) return false;
    final disclosedProvider = _webSearchState.provider.trim().isEmpty
        ? _activeSearchProviderLabel
        : _webSearchState.provider.trim();
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('允许本次联网搜索？'),
            content: Text('查询将发送给 $disclosedProvider：\n\n$query'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('不搜索'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('仅本次允许'),
              ),
            ],
          ),
        ) ??
        false;
  }

  /// 配置本会话的联网搜索策略（可选择跟随全局，即清除覆盖值）。
  Future<void> _configureWebSearchPolicy() async {
    if (_webSearchUnsupported) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('当前平台不支持联网搜索'),
          content:
              const Text('Web 端未启用联网搜索，请使用 Android、iOS、macOS 或 Windows 版本。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    final selection = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('本会话联网搜索'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'global'),
            child: Text('跟随全局（${_governanceStore.globalSearchPolicy.label}）'),
          ),
          for (final policy in WebSearchPolicy.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, policy.name),
              child: Text(policy.label),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
            child: Text(
              '当前搜索源：$_activeSearchProviderLabel。自动聊天和主动消息默认不会触发第三方搜索。',
            ),
          ),
        ],
      ),
    );
    if (selection == null) return;
    final policy = selection == 'global'
        ? null
        : WebSearchPolicy.values.firstWhere(
            (value) => value.name == selection,
          );
    await _governanceStore.saveConversationSearchPolicy(
      widget.groupId,
      policy,
    );
    if (_canTouchUi) _setUiState(() => _searchPolicyOverride = policy);
  }

  String get _activeSearchProviderLabel {
    if (_webSearchUnsupported) return '当前平台不支持联网搜索';
    final routes = _searchCoordinator.providerRoutes;
    return routes.isEmpty
        ? 'DuckDuckGo Instant Answer'
        : routes.first.providerName;
  }

  /// 联网搜索状态对应的用户可读提示文案。
  String get _webSearchStatusText => switch (_webSearchState.status) {
        SearchRunStatus.idle => '',
        SearchRunStatus.disabled => '联网搜索已关闭，本次未发送第三方请求',
        SearchRunStatus.suggested => '建议联网搜索',
        SearchRunStatus.awaitingConsent => '等待确认是否联网搜索',
        SearchRunStatus.planning => '正在整理搜索关键词…',
        SearchRunStatus.denied => '本次联网搜索未获同意',
        SearchRunStatus.searching =>
          '正在通过 ${_webSearchState.provider.isEmpty ? '搜索服务' : _webSearchState.provider} 搜索：${_webSearchState.query}',
        SearchRunStatus.retrying =>
          '搜索服务暂时不可用，正在重试 ${_webSearchState.retryNumber}/2…',
        SearchRunStatus.evaluating => '正在整理搜索结果…',
        SearchRunStatus.completed => _completedWebSearchStatus,
        SearchRunStatus.noResults => '联网搜索完成，但资料不足',
        SearchRunStatus.failed =>
          '联网搜索失败 · ${_webSearchState.snapshot?.failure?.type.name ?? 'unknown'}，点击查看诊断',
        SearchRunStatus.cancelled => '联网搜索已取消',
      };

  String get _completedWebSearchStatus {
    final snapshot = _webSearchState.snapshot;
    final cacheLabel = snapshot?.fromCache == true ? '使用缓存 · ' : '';
    final degradedLabel = snapshot?.degraded == true ? '已降级 · ' : '';
    return '联网搜索完成 · $cacheLabel$degradedLabel'
        '${snapshot?.results.length ?? 0} 个来源';
  }

  void _handleWebSearchStatus(SearchRunState state) {
    if (!_canTouchUi) return;
    _searchBannerDismissTimer?.cancel();
    _setUiState(() => _webSearchState = state);
    if (!state.status.isTerminal || state.status == SearchRunStatus.failed) {
      return;
    }
    _searchBannerDismissTimer = Timer(const Duration(seconds: 3), () {
      if (_canTouchUi) {
        _setUiState(
          () => _webSearchState = const SearchRunState(SearchRunStatus.idle),
        );
      }
    });
  }

  void _showWebSearchSources() {
    final snapshot = _webSearchState.snapshot;
    if (snapshot == null) return;
    _showSourcesDialog(snapshot);
  }

  void _showSourcesForReply(Message message) {
    final snapshot =
        _searchTurnController.contextForReply(message.id)?.snapshot ??
            _snapshotFromMessage(message);
    if (snapshot == null) return;
    _showSourcesDialog(snapshot);
  }

  web_search.WebSearchSnapshot? _snapshotFromMessage(Message message) {
    final raw = message.webSearchSnapshot;
    return raw == null ? null : web_search.WebSearchSnapshot.fromMap(raw);
  }

  SearchTurnContext? _persistedSearchContext(Message message) {
    final snapshot = _snapshotFromMessage(message);
    if (snapshot == null) return null;
    final sourceId =
        snapshot.rootRequestId.isEmpty ? message.id : snapshot.rootRequestId;
    return SearchTurnContext(
      conversationId: message.groupId,
      sourceMessageId: sourceId,
      turnId: sourceId,
      query: snapshot.executedQueries.isEmpty
          ? ''
          : snapshot.executedQueries.first,
      origin: SearchMessageOrigin.user,
      snapshot: snapshot,
    );
  }

  void _restorePersistedSearchContexts(Iterable<Message> messages) {
    for (final message in messages) {
      final context = _persistedSearchContext(message);
      if (context != null) _searchTurnController.bindReply(message.id, context);
    }
  }

  void _showSourcesDialog(web_search.WebSearchSnapshot snapshot) {
    SourcesDialog.show(
      context,
      snapshot,
      onOpenSource: (uri) => unawaited(_openSearchSource(uri)),
    );
  }

  Future<void> _openSearchSource(Uri uri) async {
    final safeUri = web_search.tryValidateSearchUrl(uri);
    if (safeUri == null) {
      _showSearchSourceOpenError('来源链接无效');
      return;
    }
    try {
      final launched = await launchUrl(
        safeUri,
        mode: LaunchMode.externalApplication,
      );
      if (launched || !_canTouchUi) return;
      _showSearchSourceOpenError('打开来源失败');
    } on Object catch (_) {
      _showSearchSourceOpenError('打开来源失败');
    }
  }

  void _showSearchSourceOpenError(String message) {
    if (!_canTouchUi) return;
    AppToast.show(
      context,
      message,
      icon: Icons.error_outline_rounded,
    );
  }

  /// 把搜索规则与 JSON evidence 数据作为隔离的消息注入请求。
  List<Map<String, dynamic>> _withWebSearchContext(
      List<Map<String, dynamic>> messages,
      web_search.WebSearchSnapshot? snapshot,
      {bool allowSourceLinks = false}) {
    if (snapshot == null) return messages;
    final next = List<Map<String, dynamic>>.from(messages);
    final insertAt = next.indexWhere((message) => message['role'] != 'system');
    final contextMessages = _chatRoomSearchContextFormatter.formatMessages(
      snapshot,
      allowSourceLinks: allowSourceLinks,
    );
    final target = insertAt < 0 ? next.length : insertAt;
    next.insertAll(target, contextMessages);
    return next;
  }

  /// 进入消息搜索模式（AppBar 切换为搜索框）。
  void _enterSearch() {
    _setUiState(() => _isSearching = true);
    _searchResults = [];
    _searchFocusIndex = null;
  }

  /// 退出搜索模式并清理关键词、结果与定位状态。
  void _exitSearch() {
    _searchDebounceTimer?.cancel();
    _setUiState(() {
      _isSearching = false;
      _searchController.clear();
      _searchResults = [];
      _searchFocusIndex = null;
    });
  }

  /// 搜索输入的防抖入口：停止输入 250ms 后才真正查库。
  void _performSearch(String query) {
    if (query.trim().isEmpty) {
      _searchDebounceTimer?.cancel();
      _setUiState(() => _searchResults = []);
      return;
    }
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer =
        Timer(_ChatRoomPageState._searchDebounceDuration, () {
      unawaited(_applySearch(query));
    });
  }

  /// 执行搜索并定位到第一条命中。
  Future<void> _applySearch(String query) async {
    if (!_canTouchUi) return;
    final q = query.toLowerCase();
    final results = await _repository.search(q);
    if (!_canTouchUi || _searchController.text.trim().toLowerCase() != q) {
      return;
    }
    _setUiState(() {
      _searchResults = results;
      _searchFocusIndex = _searchResults.isEmpty ? null : 0;
    });
    if (_searchResults.isNotEmpty) {
      await _focusSearchResult(_searchResults[0]);
    }
  }

  /// 滚动定位到某条搜索结果，必要时先加载消息所在分页。
  Future<void> _focusSearchResult(Message message) async {
    if (!_messages.any((loaded) => loaded.id == message.id)) {
      final page = await _repository.loadAround(message.id);
      if (!_canTouchUi) return;
      final byId = <String, Message>{
        for (final loaded in _messages) loaded.id: loaded,
        for (final loaded in page.messages) loaded.id: loaded,
      };
      final merged = byId.values.toList()
        ..sort((a, b) {
          final byTime = a.timestamp.compareTo(b.timestamp);
          return byTime != 0 ? byTime : a.id.compareTo(b.id);
        });
      _setUiState(() => _messages = merged);
    }
    _scrollToMessageIndex(
      _messages.indexWhere((loaded) => loaded.id == message.id),
    );
  }

  void _scrollToMessageIndex(int index) {
    if (index < 0 || index >= _messages.length) return;
    if (!_scrollController.hasClients) return;
    final keyContext = _messageListController.contextFor(_messages[index].id);
    if (keyContext != null) {
      Scrollable.ensureVisible(
        keyContext,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.2,
      );
      return;
    }
    final estimatedOffset = index * 80.0;
    _scrollController.jumpTo(
      estimatedOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _messageListController.contextFor(_messages[index].id);
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: 0.2,
        );
      }
    });
  }

  void _searchPrev() {
    if (_searchResults.isEmpty || _searchFocusIndex == null) return;
    _setUiState(() {
      _searchFocusIndex = ((_searchFocusIndex! - 1 + _searchResults.length) %
          _searchResults.length);
    });
    unawaited(_focusSearchResult(_searchResults[_searchFocusIndex!]));
  }

  void _searchNext() {
    if (_searchResults.isEmpty || _searchFocusIndex == null) return;
    _setUiState(() {
      _searchFocusIndex = (_searchFocusIndex! + 1) % _searchResults.length;
    });
    unawaited(_focusSearchResult(_searchResults[_searchFocusIndex!]));
  }

  String get _searchResultLabel {
    if (_searchResults.isEmpty) return '';
    if (_searchFocusIndex == null) return '${_searchResults.length} 条结果';
    return '${_searchFocusIndex! + 1} / ${_searchResults.length}';
  }

  Future<SearchTurnContext?> _regenerationSearchContext(
    Message original, {
    required bool forceRefresh,
  }) async {
    final existing =
        _searchTurnController.contextForRegeneration(original.id) ??
            _persistedSearchContext(original);
    if (existing != null &&
        _searchTurnController.contextForReply(original.id) == null) {
      _searchTurnController.bindReply(original.id, existing);
    }
    if (!forceRefresh) return existing;
    final refreshed = await _withSearchCancellation(
      (cancelToken) => _searchTurnController.refreshRegeneration(
        originalReplyId: original.id,
        requestConsent: _confirmWebSearch,
        onStatus: _handleWebSearchStatus,
        locale: _searchRuntimeSettings.locale,
        country: _searchRuntimeSettings.country,
        maxResults: _searchRuntimeSettings.maxResults,
        safeSearch: _searchRuntimeSettings.safeSearch,
        cancelToken: cancelToken,
      ),
    );
    if (refreshed != null) return refreshed;
    final source = _userMessageBefore(original);
    if (source == null || source.content.trim().isEmpty) return null;
    return _withSearchCancellation(
      (cancelToken) => _searchTurnController.prepareUserTurn(
        conversationId: widget.groupId,
        sourceMessageId: source.id,
        turnId: source.id,
        userMessage: source.content,
        requestConsent: _confirmWebSearch,
        origin: SearchMessageOrigin.regeneration,
        forceRefresh: true,
        onStatus: _handleWebSearchStatus,
        locale: _searchRuntimeSettings.locale,
        country: _searchRuntimeSettings.country,
        maxResults: _searchRuntimeSettings.maxResults,
        safeSearch: _searchRuntimeSettings.safeSearch,
        cancelToken: cancelToken,
      ),
    );
  }

  Message? _userMessageBefore(Message original) {
    final index = _messages.indexWhere((message) => message.id == original.id);
    if (index < 0) return null;
    for (var cursor = index - 1; cursor >= 0; cursor--) {
      final candidate = _messages[cursor];
      if (candidate.groupId == widget.groupId &&
          candidate.senderType == 'user') {
        return candidate;
      }
    }
    return null;
  }
}
