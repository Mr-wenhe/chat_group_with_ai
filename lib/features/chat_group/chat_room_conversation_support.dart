part of 'chat_room_page.dart';

extension _ChatRoomConversationSupport on _ChatRoomPageState {
  /// 到达门槛时更新群记忆摘要。
  ///
  /// 摘要既是一次真实的模型调用，也是一次**持久化写入**，因此两处都必须按
  /// **原轮次**复检：只看 [_roomWorkAllowed] 挡不住"离开又立刻回来"和
  /// "关掉自动发言又打开"——那时可见性和开关都已经恢复为真，只有轮次代际号
  /// 还记得这一轮已经被取消过（见 [_isReplyRoundInvalidated]）。
  Future<void> _maybeUpdateMemory({
    required bool isAutoChat,
    required int roundGeneration,
    int? autoChatGeneration,
  }) async {
    if (_isDirectChat) return;
    bool invalidated() => _isReplyRoundInvalidated(
          isAutoChat: isAutoChat,
          generation: roundGeneration,
          autoChatGeneration: autoChatGeneration,
        );
    if (invalidated()) return;
    if (!_memoryControls.canAutoUpdateGroup(_groupMemory)) return;
    final now = DateTime.now();
    if (!ChatOrchestrator.shouldUpdateGroupMemory(
      messageCount: _totalMessageCount,
      hasExistingSummary: _groupMemory?.topicSummary.trim().isNotEmpty ?? false,
      lastSummaryAt: _groupMemory?.lastSummaryAt,
      now: now,
    )) {
      return;
    }

    // Mark before async work to prevent concurrent summary generation.
    // 先占位写入 lastSummaryAt：后续 await 期间若又触发一轮，
    // shouldUpdateGroupMemory 会因间隔不足而拒绝，避免并发生成重复摘要。
    if (_groupMemory != null) {
      _groupMemory!.lastSummaryAt = now;
      await _groupMemory!.save();
    }

    final visibleToAllMessages = _messagesVisibleToAllCurrentMembers();
    final hasRestrictedMessages = _hasRestrictedHistory ||
        visibleToAllMessages.length != _messages.length;
    final topicHint = ChatOrchestrator.recentDialogueTranscript(
      messages: visibleToAllMessages,
      senderNames: _senderNameMap(),
      maxMessages: 18,
      maxChars: 1800,
    );
    if (topicHint.trim().isEmpty) return;

    final summary = await _generateSummary(
      topicHint,
      // 旧摘要可能在可见性快照存在前生成，不能让它把不可见内容续写回来。
      previousSummary:
          hasRestrictedMessages ? '' : _groupMemory?.topicSummary ?? '',
      isAutoChat: isAutoChat,
      roundGeneration: roundGeneration,
      autoChatGeneration: autoChatGeneration,
    );
    // 摘要是外围模型调用，可能在用户离开很久之后才返回：迟到的结果不许再
    // 改写旧群上下文（用户已经在看别的群或别的页面了）。
    if (summary.isNotEmpty && _groupMemory != null && !invalidated()) {
      _groupMemory!.topicSummary = summary;
      await _groupMemory!.save();
      _setUiState(() {});
    }
  }

  /// 调用 LLM 把「旧群记忆 + 最近对话」合并成新的群体记忆摘要。
  ///
  /// 借用第一个角色的 API 配置发请求（摘要与具体人格无关）；
  /// 无可用配置或调用失败时返回空串，调用方据此跳过更新。
  Future<String> _generateSummary(
    String recentText, {
    String previousSummary = '',
    required bool isAutoChat,
    required int roundGeneration,
    int? autoChatGeneration,
  }) async {
    bool invalidated() => _isReplyRoundInvalidated(
          isAutoChat: isAutoChat,
          generation: roundGeneration,
          autoChatGeneration: autoChatGeneration,
        );
    if (invalidated()) return '';
    // 摘要只需要一个可用的 API 通道，借用首个角色的配置即可。
    final character = _characters.isNotEmpty ? _characters.first : null;
    if (character == null) return '';

    final config = _resolveApiConfig(character);
    if (config == null) return '';
    final apiKey = await _credentialResolver.resolve(config);
    // 凭据解析是异步的，期间用户可能已经离开这个群、或者已经把这一轮取消了。
    // 摘要是这一刻才发起的新请求，必须在真正发出前复检。
    if (apiKey == null || invalidated()) return '';

    final msgs = [
      {
        'role': 'system',
        'content': '你是群聊长期记忆记录员。请把旧摘要和最近对话合并成可供后续角色扮演使用的群体记忆。'
            '保留正在发展的关系、共同话题、未解决的问题和群氛围，不要记录 API、模型或系统提示。'
            '输出 2-4 句话，不超过 160 字。'
      },
      {
        'role': 'user',
        'content':
            '旧群记忆：${previousSummary.trim().isEmpty ? '暂无' : previousSummary.trim()}'
                '\n\n最近对话：\n$recentText\n\n请输出更新后的群体记忆：'
      }
    ];

    final result = await _aiGateway.sendChatMessage(
      apiKey: apiKey,
      provider: ApiProvider.values.firstWhere((p) => p.name == config.provider,
          orElse: () => ApiProvider.deepseek),
      apiProtocol: config.protocol,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: msgs,
      temperature: 0.4,
      purpose: AiRequestPurpose.summary,
      conversationId: widget.groupId,
      characterId: character.id,
    );
    if (result['success'] ?? false) {
      return result['message']?.toString().trim() ?? '';
    }
    return '';
  }

  /// senderId → 展示名的映射（用于把消息转写成带说话人的文字稿）。
  ///
  /// 含停用成员，历史消息里的角色才不会显示成未知；`user` 映射为群主名。
  /// 多人实时群聊里的真人成员也要进来，否则客人说的话会被模型当成
  /// "其他角色"说的——AI 会以为群里多了一个它不认识的设定角色。
  Map<String, String> _senderNameMap() {
    return {
      'user': _ownerMentionName,
      for (final c in _allGroupCharacters) c.id: c.name,
      for (final c in _characters) c.id: c.name,
      ..._realtimeMemberNames,
    };
  }

  /// 该角色本轮是否有资格发言（委托 [ReplyEligibilityPolicy]）。
  bool _isEligibleToReply(AICharacter character) {
    return _replyEligibility.isEligible(character);
  }

  /// 该角色本轮是否可能被**自动**选中（禁言者只有被 @ 点名才可能）。
  ///
  /// 与 [_isEligibleToReply] 分开的理由：后者表达"能不能说话"（未配置 API、
  /// 超出频率上限等），其阻塞原因会展示给用户；禁言是用户的主动选择，且被 @
  /// 点名时必须放行——否则 @ 会连同一并被挡掉，而"@ 是唤起禁言角色的通路"
  /// 正是这个功能的语义。私聊没有禁言概念。
  bool _mayAutoPick(AICharacter character,
      {required Set<String> mentionedIds}) {
    if (_isDirectChat) return true;
    return _muteStore.mayAutoPick(
      groupId: widget.groupId,
      characterId: character.id,
      mentionedIds: mentionedIds,
    );
  }

  /// 该角色不能发言的具体原因（未配置 API、超出频率上限等）。
  ReplyBlockReason? _blockReasonFor(AICharacter character) {
    return _replyEligibility.blockReasonFor(character);
  }

  /// 当前有资格发言的活跃角色。
  List<AICharacter> get _eligibleCharacters =>
      _characters.where(_isEligibleToReply).toList();

  /// 取这批角色中第一个可解释的阻塞原因，用于给用户一条明确提示。
  ReplyBlockReason? _firstBlockReason(List<AICharacter> characters) {
    return _replyEligibility.firstBlockReason(characters);
  }

  /// 记录一次发言用量：由数据库按角色串行读取、递增并持久化。
  Future<void> _recordReplyUsage(AICharacter character) {
    return _db.recordCharacterReplyUsage(character.id);
  }

  /// 模拟"打字/思考"的发言间隔，让多角色接话有真实节奏。
  ///
  /// [fast] 用于被 @ 点名的场景——几乎立刻应答（180ms）；
  /// 否则按内容长度加随机抖动计算延迟。
  Future<void> _delay(String content, {bool fast = false}) async {
    if (fast) {
      await Future.delayed(const Duration(milliseconds: 180));
      return;
    }
    await Future.delayed(ChatActivityPolicy.replyDelayForContent(
      content,
      random: _random,
    ));
  }

  /// 移除 @ 成员弹窗并复位其全部相关状态。
  void _handleTextChanged(String text) {
    if (_isDirectChat) return;
    if (!_showMentionPopup) {
      final cursorPos = _textController.selection.baseOffset;
      if (_isInMentionQuery(text, cursorPos)) {
        _filteredMentionMembers = List.from(_mentionCandidates);
        _mentionSelectedIndex = 0;
        _showMentionOverlay(Offset.zero);
        return;
      }
      return;
    }

    final cursorPos = _textController.selection.baseOffset;
    if (cursorPos <= 0) {
      _hideMentionOverlay();
      return;
    }
    final textBeforeCursor = text.substring(0, cursorPos);
    final atIndex = textBeforeCursor.lastIndexOf('@');

    if (atIndex < 0) {
      _hideMentionOverlay();
      return;
    }

    final query = textBeforeCursor.substring(atIndex + 1);
    // 出现空格说明这个 @ 已经输完（或只是普通文本里的 @），收起弹窗。
    if (query.contains(' ')) {
      _hideMentionOverlay();
      return;
    }

    // 空查询显示全部成员；否则按名称/角色/标签过滤。
    _filteredMentionMembers = query.isEmpty
        ? List.from(_mentionCandidates)
        : _mentionCandidates
            .where((c) =>
                c.name.contains(query) ||
                c.role.contains(query) ||
                c.personalityTags.any((tag) => tag.contains(query)))
            .toList();

    // 列表变化后，高亮索引重置到首项并夹取到合法范围
    if (_mentionSelectedIndex >= _filteredMentionMembers.length) {
      _mentionSelectedIndex = 0;
    }

    if (_mentionOverlay != null) {
      _mentionOverlay!.markNeedsBuild();
      // 候选变少后高亮项可能落到可视区外，重新滚回来。
      _revealMentionSelection();
    }
  }

  /// 解析文本中 @ 到的角色 id 列表；私聊场景恒为空。
  List<String> _parseMentions(String content) {
    if (_isDirectChat) return const [];
    return parseMentionedCharacterIds(content, _characters);
  }

  /// 私聊本轮的回复者：固定为会话对方角色（前提是它有资格回复）。
  List<AICharacter> _directReplyCharacters() {
    return DirectChatSession.selectReplyCharacters(
      characters: _allGroupCharacters,
      directCharacterId: _directCharacterId ?? '',
      isEligible: _isEligibleToReply,
    );
  }

  /// The search runs once for the user turn; search-only roles provide no
  /// visible utterance, so every other active, unmuted member can discuss it.
  List<AICharacter> _roundtableParticipants({
    required List<String> mentionedIds,
  }) {
    final mentionedSet = mentionedIds.toSet();
    final eligible = _characters
        .where(
          (character) =>
              !character.zhipuSearchAnswerOnly &&
              _isEligibleToReply(character) &&
              _mayAutoPick(character, mentionedIds: mentionedSet) &&
              !_agenticRunningCharacterIds.contains(character.id),
        )
        .toList();
    return eligible;
  }

  /// 取最近 20 条消息作为 LLM 上下文（够连贯，又不过度消耗 token）。
  List<Message> _recentMessagesForContext() {
    return _messages.length > 20
        ? _messages.sublist(_messages.length - 20)
        : _messages.toList();
  }

  List<Message> _visibleContextForCharacter(
    String characterId,
    Iterable<Message> messages,
  ) {
    final isCurrentMember =
        _characters.any((character) => character.id == characterId);
    return messages.where((message) {
      final visibleIds = message.visibleToCharacterIds;
      // Group legacy messages have no authorization snapshot, so fail closed.
      // Direct-chat history is already isolated by its stable conversation ID.
      return visibleIds.isEmpty
          ? _isDirectChat && isCurrentMember
          : visibleIds.contains(characterId);
    }).toList(growable: false);
  }

  /// 群摘要会被所有当前成员共享，因此只使用对每个当前成员都可见的消息。
  List<Message> _messagesVisibleToAllCurrentMembers() {
    final memberIds = _characters.map((character) => character.id).toSet();
    if (memberIds.isEmpty) return const [];
    return _messages.where((message) {
      final visibleIds = message.visibleToCharacterIds;
      return visibleIds.isNotEmpty && memberIds.every(visibleIds.contains);
    }).toList(growable: false);
  }

  /// 上一条 AI 消息的发送者 id（用于避免同一角色连续发言）。
  ///
  /// 从后往前扫，遇到用户消息就返回 null——用户已经开口，
  /// 此时"上一个 AI 发言者"这个约束不再适用。
  String? get _lastAiSenderId {
    for (final message in _messages.reversed) {
      if (message.senderType == 'ai') return message.senderId;
      if (message.senderType == 'user') return null;
    }
    return null;
  }

  /// 统计自用户最后一次发言以来，AI 已连续说了多少条。
  ///
  /// 私聊用它做刷屏保护：连说 3 条还没等到用户回复就暂停主动发言。
  int _directAiMessagesSinceLastUser() {
    var count = 0;
    for (final message in _messages.reversed) {
      if (message.senderType == 'user') break;
      if (message.senderType == 'ai') count++;
    }
    return count;
  }

  /// 把"无人可回复"的原因翻译成用户可读的提示文案。
  String _replyBlockText(ReplyBlockReason? reason) {
    switch (reason) {
      case ReplyBlockReason.noApiConfig:
        return '角色未配置 API Key，AI 无法回复。请到「设置」配置 API';
      case ReplyBlockReason.inactive:
        return _isDirectChat ? '该角色已停用，无法回复' : '当前群聊没有启用中的角色';
      case ReplyBlockReason.hourlyLimit:
        return '角色已达到本小时回复上限，稍后再试';
      case ReplyBlockReason.alreadyGenerating:
        return 'AI 正在生成中，请稍后再发';
      case ReplyBlockReason.networkError:
        return '网络请求失败，请检查 API 配置';
      case null:
        return '暂时没有可以回复的角色';
    }
  }

  /// 流式输出期间刷新 UI，并按需跟随滚动。
  ///
  /// 只有用户本来就在底部附近时才自动跟随——否则会把正在翻看历史的用户
  /// 强行拽回底部。[forceScroll] 用于必须回到底部的场景。
}
