part of 'chat_room_page.dart';

extension _ChatRoomPageBuildSupport on _ChatRoomPageState {
  Widget _buildPage(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // 首屏加载中：只渲染标题栏 + loading，避免读到未初始化的 _group 等字段。
    if (_isLoading) {
      return Scaffold(
        backgroundColor: WeComChatTokens.chatBackground(context),
        appBar: AppBar(
          backgroundColor: WeComChatTokens.chatBackground(context),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text(_group?.name ?? '加载中...',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: cs.onSurface)),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // 私聊需要知道哪些用户消息已被对方"读过"，以渲染已读标记。
    final readUserMessageIds =
        _isDirectChat ? directReadUserMessageIds(_messages) : const <String>{};
    // #5 性能：消息/角色索引 Map 在父页预计算一次，避免在子组件每次 build 重建。
    final messageIndex = {for (final message in _messages) message.id: message};
    // 被引用的消息可能已滑出当前分页窗口，按需回库补齐，否则引用条显示不出来。
    for (final message in _messages) {
      final quotedId = message.replyToMessageId;
      if (quotedId == null || messageIndex.containsKey(quotedId)) continue;
      final quoted = _db.messageBox.get(quotedId);
      if (quoted != null) messageIndex[quotedId] = quoted;
    }
    final characterIndex = <String, AICharacter>{
      for (final character in _allGroupCharacters) character.id: character,
    };
    final lifecycle = DataLifecycleService(db: _db);
    for (final message in _messages) {
      if (message.senderType == 'user' ||
          characterIndex.containsKey(message.senderId)) {
        continue;
      }
      final character = lifecycle.characterOrDeleted(message.senderId);
      if (character != null) characterIndex[character.id] = character;
    }
    return Scaffold(
      backgroundColor: WeComChatTokens.chatBackground(context),
      appBar: ChatRoomAppBar(
        title: _group?.name ?? '群聊',
        subtitle:
            !_isDirectChat && (_groupMemory?.topicSummary.isNotEmpty ?? false)
                ? _groupMemory!.topicSummary
                : null,
        isSearching: _isSearching,
        searchController: _searchController,
        hasSearchResults: _searchResults.isNotEmpty,
        searchResultLabel: _searchResultLabel,
        showGroupActions: !_isDirectChat,
        onSearchChanged: _performSearch,
        onEnterSearch: _enterSearch,
        onPreviousResult: _searchPrev,
        onNextResult: _searchNext,
        onExitSearch: _exitSearch,
        onExport: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ExportPage(initialGroupId: widget.groupId),
        )),
        onOpenMemory: _openMemoryManagement,
        onOpenRelationship: _openRelationshipAudit,
        relationshipTooltip: _isDirectChat ? '查看 AI 对我的关系' : '查看关系',
        webSearchIcon: _webSearchPolicyIcon,
        webSearchTooltip: _webSearchUnsupported
            ? '联网搜索：当前平台不支持'
            : '联网搜索：${_effectiveWebSearchPolicy.label}',
        onConfigureWebSearch: _configureWebSearchPolicy,
        onClearConversation: _showClearConversationDialog,
        onOpenMembers: _isDirectChat ? null : _showMembersSheet,
      ),
      body: Column(
        children: [
          // 未配置 API Key 时给出醒目提示，避免「发了消息 AI 不回复」的困惑
          if (!_hasAnyApiConfig)
            ApiWarningBanner(
              message: _isDirectChat
                  ? _replyBlockText(_lastReplyBlockReason)
                  : '尚未配置 API Key，AI 不会回复或自动聊天',
              onConfigure: () => Navigator.pushNamed(context, '/settings'),
            ),
          if (!_isDirectChat &&
              (_group?.announcement.trim().isNotEmpty ?? false))
            AnnouncementBanner(
              announcement: _group!.announcement.trim(),
              onEdit: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ChatGroupFormPage(group: _group),
              )),
            ),
          ChatRoomSearchStatus(
            state: _webSearchState,
            message: _webSearchStatusText,
            onOpenDetails:
                _webSearchState.snapshot == null ? null : _showWebSearchSources,
          ),
          _buildConversationControls(cs),
          if (_pendingUserMentionMessageIds.isNotEmpty &&
              !ConversationPresenceService.instance.isActive(widget.groupId))
            UserMentionBanner(
              count: _pendingUserMentionMessageIds.length,
              onTap: _jumpToNextUserMention,
              onClear: _clearUserMentions,
            ),
          if (_isLoadingOlder) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState(cs)
                : ChatMessageList(
                    messages: _messages,
                    characters: _allGroupCharacters,
                    progressStartTimes: _progressStartTimes,
                    messageIndex: messageIndex,
                    characterIndex: characterIndex,
                    scrollController: _scrollController,
                    controller: _messageListController,
                    streamingMessageId: _streamingMessage?.id,
                    regeneratingMessageId:
                        _isRegenerating ? _regenerateMessageId : null,
                    highlightedMentionMessageId: _highlightedMentionMessageId,
                    isDirectChat: _isDirectChat,
                    readUserMessageIds: readUserMessageIds,
                    ownerName: _ownerMentionName,
                    unknownCharacter: _unknownCharacter(),
                    senderColor: _senderColor,
                    senderNameById: _senderNameById,
                    onLongPress: _showMessageActionSheet,
                    onSenderTap: _openCharacterSettings,
                    onMentionSender: _insertMention,
                    onQuotedTap: (message) =>
                        unawaited(_focusSearchResult(message)),
                  ),
          ),
          // 底部状态区：文档解析进度优先于"AI 正在回复"提示（前者更需要可取消）。
          if (_documentProcessingToken != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: _documentProcessingProgress,
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: _stopDocumentProcessing,
                    icon: const Icon(Icons.stop_rounded, size: 16),
                    label: const Text('取消文档解析'),
                  ),
                ],
              ),
            )
          else if (_isAiReplying)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Text(
                    _isStreaming ? 'AI 正在生成...' : 'AI 正在回复...',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  if (_isStreaming) ...[
                    const SizedBox(width: 10),
                    // 「停止生成」按钮：取消当前流订阅
                    TextButton.icon(
                      onPressed: _stopStreaming,
                      icon: const Icon(Icons.stop_rounded, size: 16),
                      label: const Text('停止生成'),
                      style: TextButton.styleFrom(
                        foregroundColor: cs.error,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          _buildInputArea(),
        ],
      ),
    );
  }
}
