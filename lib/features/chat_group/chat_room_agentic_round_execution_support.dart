part of 'chat_room_page.dart';

extension _ChatRoomAgenticRoundExecutionSupport on _ChatRoomPageState {
  Future<void> _runAiRound(
      {String? userMessage,
      List<String>? mentionedIds,
      bool isAutoChat = false,
      Message? currentUserMessage,
      UserMessageSentiment? userSentiment}) async {
    if (!isAutoChat && _consecutiveRound >= _ChatRoomPageState._maxAutoRounds) {
      if (_pendingMentionedIds.isNotEmpty) {
        _pendingMentionedIds.clear();
      }
      return;
    }

    final normalRunGuard =
        isAutoChat ? null : _conversationController.beginNormalGuard();
    final autoRunGuard =
        isAutoChat ? _conversationController.beginAutoGuard() : null;
    if (normalRunGuard == null && autoRunGuard == null) return;

    try {
      // Establishing the run guard precedes every operation that can throw;
      // even a runtime reload or UI bookkeeping failure must release it.
      if (!isAutoChat) {
        _reloadSearchRuntimeIfChanged();
        // 每个用户回合重新给模型选人一次机会：上一回合失败过也不例外。
        _speakerPickerDisabledForTurn = false;
      }
      _setUiState(() {
        if (!isAutoChat) _consecutiveRound++;
      });

      final roundtableMode =
          _roundtableModeEnabled && !_isDirectChat && !isAutoChat;
      final roundtableParticipants =
          roundtableMode ? _prepareRoundtableParticipants(mentionedIds) : null;
      if (roundtableMode && roundtableParticipants == null) return;

      // 私聊固定由对方回复；圆桌模式由所有可发言成员讨论搜索结果。
      // 普通群聊走逐次选人：每一步都基于**最新已确认的对话**决定下一位，
      // 而不是在用户发送时一次锁定整轮名单。
      await _dispatchReplyRound(
        userMessage: userMessage,
        mentionedIds: mentionedIds,
        isAutoChat: isAutoChat,
        currentUserMessage: currentUserMessage,
        userSentiment: userSentiment,
        roundtableMode: roundtableMode,
        roundtableParticipants: roundtableParticipants,
      );

      // widget 可能在 _maybeUpdateMemory 的 await 期间被 dispose。
      if (!_canTouchUi) return;
      _reloadSearchRuntimeIfChanged();
    } catch (_) {
      // Search preparation/audit persistence is best effort for chat.
      if (_canTouchUi) {
        _setUiState(() {
          _autoChatStatus = AutoChatStatus.error;
          _lastReplyBlockReason = ReplyBlockReason.networkError;
        });
      }
    } finally {
      // Completion is deliberately outside _setUiState: page deactivation
      // must not strand the controller in a generating phase.
      normalRunGuard?.finish();
      autoRunGuard?.finish();
      if (!isAutoChat) _consecutiveRound = 0;
      // A silent/short-circuited round can return from the try block before
      // reaching the normal tail. Drain here as well so queued user input is
      // never stranded while the page remains active.
      if (!isAutoChat) await _drainQueuedUserMessage();
    }
  }

  /// 按会话类型把本轮交给对应的执行路径。
  ///
  /// 私聊与圆桌的发言名单一次定好（私聊固定对方、圆桌全员讨论同一份搜索证据）；
  /// 只有普通群聊需要逐次选人。
  Future<void> _dispatchReplyRound({
    required String? userMessage,
    required List<String>? mentionedIds,
    required bool isAutoChat,
    required Message? currentUserMessage,
    required UserMessageSentiment? userSentiment,
    required bool roundtableMode,
    required List<AICharacter>? roundtableParticipants,
  }) async {
    if (!_isDirectChat && !roundtableMode) {
      await _runGroupSpeakerRounds(
        userMessage: userMessage,
        mentionedIds: mentionedIds,
        isAutoChat: isAutoChat,
        currentUserMessage: currentUserMessage,
        userSentiment: userSentiment,
      );
      return;
    }
    await _runFixedSpeakerRound(
      charactersToReply: _isDirectChat
          ? _directReplyCharacters()
          : roundtableParticipants!,
      userMessage: userMessage,
      mentionedIds: mentionedIds,
      isAutoChat: isAutoChat,
      currentUserMessage: currentUserMessage,
      userSentiment: userSentiment,
      roundtableMode: roundtableMode,
    );
  }

  /// 普通群聊：逐次决定下一位发言者，说完再决定下一位。
  ///
  /// 每一步都重新读取最新已确认的对话，因此后一位是接着前一位说的，而不是
  /// 按发送时那一刻的名单照本宣科。名额是**整个回合**的上限（见
  /// [_maxRepliesForGroupRound]），每产生一条回复消耗一个。
  Future<void> _runGroupSpeakerRounds({
    required String? userMessage,
    required List<String>? mentionedIds,
    required bool isAutoChat,
    required Message? currentUserMessage,
    required UserMessageSentiment? userSentiment,
  }) async {
    // 用户手动发起的回合重新允许提示一次"共同设定放不下"：这是本轮唯一会写进
    // 会话的失败说明，隔了若干轮还不说的话，用户会以为自己的消息被吞了。
    if (!isAutoChat) _sharedContextOverflowReportedBlock = null;
    final mentionedSet = (mentionedIds ?? const <String>[]).toSet();
    final candidatesForRound = _eligibleSpeakerCandidates(
      mentionedIds: mentionedSet,
      alreadySpoken: const [],
    );
    if (candidatesForRound.isEmpty) {
      _reportNoGroupSpeakerAvailable();
      return;
    }

    // 搜索是**用户回合**级别的关注点：整轮只准备一次，此后每一位发言者
    // 共用同一份证据快照，动态改变发言人不会造成重复搜索。候选名单是这个
    // 回合可能发言者的超集，因此不会漏掉任何一位角色的联网设置。
    //
    // 名额是超集而不是"最终发言者"：某位成员在回合中途才变为可发言（例如它的
    // 工作任务刚好结束、执行锁被释放）时，命中这里算出的快照仍然成立——它本来
    // 就在超集里。若改用每步重新计算的候选，那种成员会拿着 null 快照发言。
    final searchTurnContext = await _prepareSearchTurnContext(
      userMessage: userMessage,
      currentUserMessage: currentUserMessage,
      isAutoChat: isAutoChat,
      searchEnabled: candidatesForRound.any((character) =>
          character.webSearchEnabled || character.zhipuSearchAnswerOnly),
      forceSearch:
          candidatesForRound.any((character) => character.zhipuSearchAnswerOnly),
    );

    final repliedIds = <String>[];
    final alreadySpoken = <String>[];
    final maxReplies = _maxRepliesForGroupRound(
      mentionedIds: mentionedIds,
      isAutoChat: isAutoChat,
    );
    for (var step = 0; step < maxReplies; step++) {
      // 每步之前复检：用户点了停止、切走页面、App 进后台都立刻收手。
      if (!_roomWorkAllowed) break;
      if (_conversationController.state.phase == ConversationPhase.stopping) {
        break;
      }
      final picked = await _selectNextGroupSpeaker(
        userMessage: userMessage,
        mentionedIds: mentionedIds,
        isAutoChat: isAutoChat,
        alreadySpoken: alreadySpoken,
        userSentiment: userSentiment,
      );
      if (picked == null) break;
      alreadySpoken.add(picked.character.id);
      await _replyAsSpeaker(
        character: picked.character,
        intent: picked.intent,
        userMessage: userMessage,
        mentionedIds: mentionedIds,
        isAutoChat: isAutoChat,
        currentUserMessage: currentUserMessage,
        userSentiment: userSentiment,
        searchTurnContext: searchTurnContext,
        repliedIds: repliedIds,
      );
    }

    await _sendProxyMentionReminder(
      mentionedIds: mentionedIds,
      repliedIds: repliedIds,
    );
    await _maybeUpdateMemory();
  }

  /// 名单已确定的回合（私聊 / 圆桌会议）：按名单依次生成回复。
  Future<void> _runFixedSpeakerRound({
    required List<AICharacter> charactersToReply,
    required String? userMessage,
    required List<String>? mentionedIds,
    required bool isAutoChat,
    required Message? currentUserMessage,
    required UserMessageSentiment? userSentiment,
    required bool roundtableMode,
  }) async {
    if (!isAutoChat) _sharedContextOverflowReportedBlock = null;
    if (charactersToReply.isEmpty) {
      _reportNoGroupSpeakerAvailable(isAutoChat: isAutoChat);
      return;
    }

    // Search is a user-turn concern, not a character concern. Prepare once
    // before the reply loop so every group member and the DM counterpart see
    // exactly the same evidence snapshot. Auto-chat returns a suppressed
    // context without touching a third-party Provider.
    final searchTurnContext = await _prepareSearchTurnContext(
      userMessage: userMessage,
      currentUserMessage: currentUserMessage,
      isAutoChat: isAutoChat,
      searchEnabled: roundtableMode ||
          charactersToReply.any((character) =>
              character.webSearchEnabled || character.zhipuSearchAnswerOnly),
      category: roundtableMode ? web_search.SearchCategory.news : null,
      freshness: roundtableMode ? web_search.SearchFreshness.week : null,
      forceSearch: roundtableMode ||
          charactersToReply
              .any((character) => character.zhipuSearchAnswerOnly),
    );
    if (roundtableMode && searchTurnContext.snapshot?.hasResults != true) {
      _clearPendingRoundtableMentions(mentionedIds);
      if (mounted && !isAutoChat) {
        AppToast.show(
          context,
          '未获得可用的热点搜索结果，本轮圆桌讨论未开始。请检查当前群聊的联网搜索设置和搜索服务状态。',
          icon: Icons.info_outline_rounded,
        );
      }
      return;
    }

    final repliedIds = <String>[];
    for (final character in charactersToReply) {
      // 与普通群聊同一条收手口径：用户点了停止、切走页面或 App 进后台，
      // 名单里剩下的角色不再逐个产生回复与"打字延迟"。
      if (!_roomWorkAllowed) break;
      if (_conversationController.state.phase == ConversationPhase.stopping) {
        break;
      }
      // 私聊与圆桌都不走意图编排：私聊固定由对方回答，圆桌每人围绕同一份
      // 搜索证据各说一段，因此这里没有需要复用的发言意图。
      await _replyAsSpeaker(
        character: character,
        intent: null,
        userMessage: userMessage,
        mentionedIds: mentionedIds,
        isAutoChat: isAutoChat,
        currentUserMessage: currentUserMessage,
        userSentiment: userSentiment,
        searchTurnContext: searchTurnContext,
        repliedIds: repliedIds,
      );
    }

    await _sendProxyMentionReminder(
      mentionedIds: mentionedIds,
      repliedIds: repliedIds,
    );
    await _maybeUpdateMemory();
  }

  /// 让一位角色发言一次，并把结果计入本轮。
  ///
  /// 单个角色失败不中断整轮：写入可见的失败气泡，继续下一位。
  Future<void> _replyAsSpeaker({
    required AICharacter character,
    required ReplyIntent? intent,
    required String? userMessage,
    required List<String>? mentionedIds,
    required bool isAutoChat,
    required Message? currentUserMessage,
    required UserMessageSentiment? userSentiment,
    required SearchTurnContext? searchTurnContext,
    required List<String> repliedIds,
  }) async {
    final wasPendingReply = _pendingMentionedIds.contains(character.id);
    late final String replyContent;
    try {
      replyContent = await _generateAiReply(
        character,
        _recentMessagesForContext(),
        userMessage,
        isAutoChat: isAutoChat,
        intent: intent,
        currentUserMessage: currentUserMessage,
        userSentiment: userSentiment,
        searchTurnContext: searchTurnContext,
      );
    } catch (e) {
      replyContent =
          '[${character.name} 回复失败: ${_safeChatFailureMessage('$e')}]';
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: replyContent,
      ));
      if (_canTouchUi) {
        _setUiState(() {
          _autoChatStatus = AutoChatStatus.error;
          _lastReplyBlockReason = ReplyBlockReason.networkError;
        });
      }
    }
    // 没有真的产生回复（页面已不可见、被禁言、流式结果被丢弃、或设定放不下
    // 且已经提示过）：不计入本轮已回复名单，也不占用一次"打字延迟"。
    if (replyContent.trim().isEmpty) return;
    repliedIds.add(character.id);
    if (wasPendingReply) _pendingMentionedIds.remove(character.id);
    if (_conversationController.state.phase == ConversationPhase.stopping) {
      return;
    }
    // 被 @ 的角色回复更快，符合“被点名会立刻应答”的直觉。
    await _delay(
      replyContent,
      fast: mentionedIds?.contains(character.id) ?? false,
    );
  }

  /// 代 @ 提醒：用户 @ 的人本轮都没回复时，让另一个在场角色帮忙 @ 一下。
  ///
  /// 与回合内的其它写入同口径：用户已经不看这个群时不再往群里补一条气泡。
  /// `_appendMessage` 只挡 `_canTouchUi`，而页面被别的路由盖住时它仍为真。
  Future<void> _sendProxyMentionReminder({
    required List<String>? mentionedIds,
    required List<String> repliedIds,
  }) async {
    if (!_roomWorkAllowed) return;
    if (_isDirectChat ||
        mentionedIds == null ||
        mentionedIds.isEmpty ||
        !repliedIds.every((id) => !mentionedIds.contains(id)) ||
        _pendingMentionedIds.isEmpty) {
      return;
    }
    final notMentionedPending =
        _pendingMentionedIds.where((id) => !mentionedIds.contains(id)).toList();
    if (notMentionedPending.isEmpty) return;
    final proxyId = notMentionedPending.first;
    // 仅在 proxyId 真实对应一个角色时才播报提醒，也清理脏 id。
    final matched = _characters.where((c) => c.id == proxyId).toList();
    if (matched.isNotEmpty &&
        _isEligibleToReply(matched.first) &&
        _mayAutoPick(matched.first, mentionedIds: mentionedIds.toSet())) {
      final proxyChar = matched.first;
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: proxyChar.id,
        senderType: 'ai',
        content: '${proxyChar.name} 刚才没看到，我帮你@他一下 @${proxyChar.name}',
        isMention: true,
        mentionedAiIds: [proxyId],
      ));
    }
    _pendingMentionedIds.remove(proxyId);
  }

  /// 本轮没有任何可自动发言的候选者时，给出可操作提示并静默收尾。
  void _reportNoGroupSpeakerAvailable({bool isAutoChat = false}) {
    if (_characters.any(_isEligibleToReply)) {
      // 有人有资格但本轮没人开口（例如全员被禁言、或编排器选择沉默）：
      // 静默收尾，不算异常。
      return;
    }
    final blockReason = _firstBlockReason(_characters);
    _setUiState(() {
      _lastReplyBlockReason = blockReason;
      _autoChatStatus = AutoChatStatus.unavailable;
    });
    if (mounted && !isAutoChat) {
      AppToast.show(
        context,
        _replyBlockText(blockReason),
        icon: Icons.info_outline_rounded,
        actionLabel:
            blockReason == ReplyBlockReason.noApiConfig ? '去设置' : null,
        onTap: blockReason == ReplyBlockReason.noApiConfig
            ? () => Navigator.pushNamed(context, '/settings')
            : null,
      );
    }
  }

  List<AICharacter>? _prepareRoundtableParticipants(
    List<String>? mentionedIds,
  ) {
    final hiddenNewsCharacterIds = _characters
        .where((character) => character.zhipuSearchAnswerOnly)
        .map((character) => character.id)
        .toList(growable: false);
    _clearPendingRoundtableMentions(hiddenNewsCharacterIds);
    final participants = _roundtableParticipants(
      mentionedIds: mentionedIds ?? const [],
    );
    if (participants.isEmpty) {
      _clearPendingRoundtableMentions(mentionedIds);
      if (mounted) {
        AppToast.show(
          context,
          '圆桌会议需要至少一位当前可发言的普通群成员；新闻角色只用于辅助联网搜索，不会在群聊中发言。',
          icon: Icons.info_outline_rounded,
        );
      }
      return null;
    }
    return participants;
  }

  void _clearPendingRoundtableMentions(List<String>? mentionedIds) {
    if (mentionedIds == null || mentionedIds.isEmpty) return;
    final mentioned = mentionedIds.toSet();
    _pendingMentionedIds.removeWhere(mentioned.contains);
  }
}
