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
      if (!isAutoChat) _reloadSearchRuntimeIfChanged();
      _setUiState(() {
        if (!isAutoChat) _consecutiveRound++;
      });

      // 私聊固定由对方角色回复；群聊则由意图编排器挑选发言者。
      var charactersToReply = _isDirectChat
          ? _directReplyCharacters()
          : _charactersForIntents(_selectGroupReplyIntents(
              userMessage:
                  userMessage!, // nullable param, non-null at this point
              mentionedIds: mentionedIds,
              isAutoChat: isAutoChat,
              userSentiment: userSentiment,
            ));
      if (charactersToReply.isEmpty) {
        // 有人有资格但编排器选择“本轮沉默”：静默收尾，不算异常。
        if (_characters.any(_isEligibleToReply)) return;
        // 确实没人能回复：记录原因并给出可操作提示（如跳转设置页配 API Key）。
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
        searchEnabled: charactersToReply.any((character) =>
            character.webSearchEnabled),
      );
      final repliedIds = <String>[];
      for (final character in charactersToReply) {
        final wasPendingReply = _pendingMentionedIds.contains(character.id);
        late final String replyContent;
        try {
          replyContent = await _generateAiReply(
            character,
            _recentMessagesForContext(),
            userMessage,
            isAutoChat: isAutoChat,
            intent: _pendingReplyIntents[character.id],
            currentUserMessage: currentUserMessage,
            userSentiment: userSentiment,
            searchTurnContext: searchTurnContext,
          );
        } catch (e) {
          // 单个角色失败不中断整轮：写入可见的失败气泡，继续下一个角色。
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
        repliedIds.add(character.id);
        if (_conversationController.state.phase == ConversationPhase.stopping) {
          break;
        }
        // 被 @ 的角色回复更快，符合“被点名会立刻应答”的直觉。
        await _delay(
          replyContent,
          fast: mentionedIds?.contains(character.id) ?? false,
        );
        if (wasPendingReply) _pendingMentionedIds.remove(character.id);
      }

      // 代 @ 提醒：用户 @ 的人本轮都没回复时，让另一个在场角色帮忙 @ 一下。
      if (!_isDirectChat &&
          mentionedIds != null &&
          mentionedIds.isNotEmpty &&
          repliedIds.every((id) => !mentionedIds.contains(id)) &&
          _pendingMentionedIds.isNotEmpty) {
        final notMentionedPending = _pendingMentionedIds
            .where((id) => !mentionedIds.contains(id))
            .toList();
        if (notMentionedPending.isNotEmpty) {
          final proxyId = notMentionedPending.first;
          // 仅在 proxyId 真实对应一个角色时才播报提醒，也清理脏 id。
          final matched = _characters.where((c) => c.id == proxyId).toList();
          if (matched.isNotEmpty && _isEligibleToReply(matched.first)) {
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
      }

      await _maybeUpdateMemory();

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
}
