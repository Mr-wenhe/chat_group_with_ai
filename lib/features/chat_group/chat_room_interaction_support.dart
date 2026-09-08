part of 'chat_room_page.dart';

extension _ChatRoomInteractionSupport on _ChatRoomPageState {
  /// 长按消息弹出的操作面板。
  ///
  /// 仅 AI 消息（[sender] 非空）提供重新生成 / 引用回复 / @ 该角色；
  /// 朗读项受 TTS 总开关控制；推送到企业微信对所有消息可用。
  void _showMessageActionSheet(Message message, AICharacter? sender) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(
              sender != null ? '${sender.name} 的消息' : '消息',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            if (sender != null) ...[
              SheetButton(ctx, cs, Icons.refresh_rounded, '重新生成', () {
                Navigator.pop(ctx);
                _regenerateAiReply(message, sender);
              }),
              if (_searchTurnController.contextForRegeneration(message.id) !=
                      null ||
                  _snapshotFromMessage(message) != null ||
                  _userMessageBefore(message) != null) ...[
                const SizedBox(height: 8),
                SheetButton(
                  ctx,
                  cs,
                  Icons.public_rounded,
                  '刷新来源并重新生成',
                  () {
                    Navigator.pop(ctx);
                    _regenerateAiReply(
                      message,
                      sender,
                      forceRefresh: true,
                    );
                  },
                ),
              ],
              if (_searchTurnController.contextForReply(message.id) != null ||
                  _snapshotFromMessage(message) != null) ...[
                const SizedBox(height: 8),
                SheetButton(
                  ctx,
                  cs,
                  Icons.library_books_outlined,
                  '查看本条来源',
                  () {
                    Navigator.pop(ctx);
                    _showSourcesForReply(message);
                  },
                ),
              ],
              const SizedBox(height: 8),
              SheetButton(ctx, cs, Icons.format_quote_rounded, '引用回复', () {
                Navigator.pop(ctx);
                _quoteMessage(message);
              }),
              const SizedBox(height: 8),
              SheetButton(
                  ctx, cs, Icons.alternate_email_rounded, '@${sender.name}',
                  () {
                Navigator.pop(ctx);
                _insertMention(sender);
              }),
              const SizedBox(height: 8),
            ],
            if (_isTtsEnabled) ...[
              SheetButton(
                  ctx,
                  cs,
                  _isSpeaking && _speakingMessageId == message.id
                      ? Icons.stop_circle_rounded
                      : Icons.volume_up_rounded,
                  _isSpeaking && _speakingMessageId == message.id
                      ? '停止朗读'
                      : '朗读', () {
                Navigator.pop(ctx);
                if (_isSpeaking && _speakingMessageId == message.id) {
                  _ttsStop();
                } else {
                  _ttsSpeak(message);
                }
              }),
              const SizedBox(height: 8),
            ],
            SheetButton(ctx, cs, Icons.send_to_mobile_rounded, '推送到企业微信', () {
              Navigator.pop(ctx);
              _showWeComPushDialog(message.content);
            }),
          ],
        ),
      ),
    );
  }

  /// 弹出"推送到企业微信"对话框（可选发给同事 UserID 或群 Webhook）。
  void _showWeComPushDialog(String defaultContent) {
    final service = WeComPushService();
    var targetType = 'user';
    final userIdCtl = TextEditingController();
    final webhookCtl = TextEditingController();
    final contentCtl = TextEditingController(text: defaultContent);
    var sending = false;
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('推送到企业微信'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'user', label: Text('同事')),
                    ButtonSegment(value: 'group', label: Text('群')),
                  ],
                  selected: {targetType},
                  onSelectionChanged: (sel) =>
                      setSt(() => targetType = sel.first),
                ),
                const SizedBox(height: 12),
                if (targetType == 'user')
                  TextField(
                    controller: userIdCtl,
                    decoration: const InputDecoration(
                      labelText: '同事 UserID',
                      hintText: '如 zhangsan',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  )
                else
                  TextField(
                    controller: webhookCtl,
                    decoration: const InputDecoration(
                      labelText: '群机器人 Webhook Key',
                      hintText: '粘贴群机器人的 key',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentCtl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '内容',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: sending
                  ? null
                  : () async {
                      setSt(() => sending = true);
                      final content = contentCtl.text.trim();
                      final WeComPushResult res;
                      if (targetType == 'user') {
                        final uid = userIdCtl.text.trim();
                        if (uid.isEmpty) {
                          AppToast.show(context, '请填写同事 UserID');
                          setSt(() => sending = false);
                          return;
                        }
                        res = await service.sendToUser(uid, content);
                      } else {
                        final key = webhookCtl.text.trim();
                        if (key.isEmpty) {
                          AppToast.show(context, '请填写群 Webhook Key');
                          setSt(() => sending = false);
                          return;
                        }
                        res = await service.sendToGroup(key, content);
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        AppToast.show(
                          context,
                          res.ok ? '已推送到企业微信' : res.detail,
                          icon: res.ok ? Icons.check : Icons.error_outline,
                        );
                      }
                    },
              child: sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('发送'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _regenerateAiReply(Message original, AICharacter character,
      {bool forceRefresh = false}) async {
    if (_isRegenerating || _isAiReplying) return;
    final runGuard = _conversationController.beginNormalGuard();
    if (runGuard == null) return;
    _setUiState(() {
      _isRegenerating = true;
      _regenerateMessageId = original.id;
    });

    Message? temp;
    StreamingReplySession? session;
    var failed = false;
    var succeeded = false;
    try {
      final config = _resolveApiConfig(character);
      final apiKey =
          config == null ? null : await _credentialResolver.resolve(config);
      if (config == null || apiKey == null) return;

      final searchTurnContext = await _regenerationSearchContext(
        original,
        forceRefresh: forceRefresh,
      );
      final webSearch = searchTurnContext?.snapshot;

      // 上下文里剔除原消息本身，否则模型会看到"自己上次的答案"而倾向复读。
      final msgsBefore = _messages.where((m) => m.id != original.id).toList();
      _regenerateContext = msgsBefore.length > 20
          ? msgsBefore.sublist(msgsBefore.length - 20)
          : msgsBefore;

      final provider = ApiProvider.values.firstWhere(
          (p) => p.name == config.provider,
          orElse: () => ApiProvider.deepseek);
      final apiMessages = _withWebSearchContext(
        await _buildApiMessages(
          character,
          _regenerateContext,
          null,
          supportsVision:
              _aiGateway.capability(provider, config.modelName).supportsVision,
        ),
        webSearch,
      );
      if (!_pageActive || _disposed) return;

      temp = Message(
          groupId: widget.groupId,
          senderId: character.id,
          senderType: 'ai',
          content: '',
          webSearchSnapshot: webSearch?.toMap());
      _setUiState(() {
        _streamingMessage = temp;
        // 保留原消息在列表中，视觉上用流式占位覆盖；成功后移除原消息。
        _messages = List.from(_messages)..add(temp!);
      });
      _scrollToBottom();

      // 开启流式语音播报时，为这条回复新建切句缓冲（无音色则整条不朗读）。
      _beginVoiceReply(character);
      session = StreamingReplySession();
      _streamingSession = session;
      if (_canTouchUi) _setUiState(() {});
      final result = await session.run(
        _aiGateway.streamChatMessage(
          apiKey: apiKey,
          provider: provider,
          customBaseUrl: config.customBaseUrl,
          model: config.modelName,
          messages: apiMessages,
          purpose: AiRequestPurpose.reply,
          conversationId: widget.groupId,
          characterId: character.id,
          userInitiated: true,
        ),
        onDraft: (draft) {
          temp!.content = draft;
          _conversationController.updateStreamingDraft(draft);
          _flushStreamingUi();
          // 语音播报：把新增的增量喂给切句器，完整句即时入队朗读。
          _feedVoiceReplyDraft(draft);
        },
      );
      if (_disposed) return;
      bool shouldDiscardResult() =>
          _discardCurrentStream ||
          shouldDiscardStreamingReply(
            stopped: result.stopped,
            pageActive: _pageActive,
            conversationStopping: _conversationController.state.phase ==
                ConversationPhase.stopping,
          );
      if (shouldDiscardResult()) {
        _discardCurrentStream = false;
        _discardStreamingMessage(temp);
        return;
      }
      var fullContent = result.content;
      failed = result.failed;
      if (failed) {
        fullContent =
            '[${character.name} 重新生成失败: ${_safeChatFailureMessage(result.error)}]';
        temp.content = fullContent;
        _flushStreamingUi();
        // 流式过程已失败：丢弃切句残缓冲，避免把失败尾巴当流式朗读。
        _cancelVoiceReply();
      }
      if (_canTouchUi) _setUiState(() {});

      if (failed && !AiRequestGateway.isBlockedMessage(result.error)) {
        final retryContent = await _retryFailedReply(
          character: character,
          config: config,
          provider: provider,
          apiMessages: apiMessages,
          userInitiated: true,
        );
        if (retryContent != null && retryContent.trim().isNotEmpty) {
          failed = false;
          fullContent = retryContent.trim();
          temp.content = fullContent;
          if (_canTouchUi) _flushStreamingUi();
        }
      }
      if (shouldDiscardResult()) {
        _discardCurrentStream = false;
        _discardStreamingMessage(temp);
        return;
      }

      if (!failed && fullContent.trim().isEmpty) {
        fullContent = ChatActivityPolicy.emptyReplyFallback(
            characterName: character.name,
            role: character.role,
            groupTheme: _group?.theme ?? '',
            userMessage: null,
            isAutoChat: false,
            random: _random);
        temp.content = fullContent;
        _flushStreamingUi();
      }

      final mentionedIds = _isDirectChat
          ? const <String>[]
          : parseMentionedCharacterIds(fullContent, _characters);
      fullContent = _stripNamePrefix(fullContent, character.name);
      fullContent =
          _chatRoomSearchContextFormatter.sanitizeCitationsWithSourceIds(
        fullContent,
        webSearch == null
            ? const <String>[]
            : _chatRoomSearchContextFormatter.format(webSearch).sourceIds,
      );
      temp.content = fullContent;
      temp.isMention = mentionedIds.isNotEmpty;
      temp.mentionedAiIds = mentionedIds;
      if (shouldDiscardResult()) {
        _discardCurrentStream = false;
        _discardStreamingMessage(temp);
        return;
      }
      // 指回原消息，保留"这条是对哪条的重写"的可追溯关系。
      temp.replyToMessageId = original.id;
      if (!failed) {
        // 语音播报收尾：重新生成成功，把缓冲里的最后一句读完。
        _flushVoiceReply();
        await _appendMessage(temp);
        if (searchTurnContext != null) {
          _searchTurnController.bindReply(temp.id, searchTurnContext);
        }
        succeeded = true;
      }
      await _recordReplyUsage(character);
      _registerUserMentionIfNeeded(temp);
      if (!failed && fullContent.trim().isNotEmpty) {
        await _maybeUpdateMemory();
      }
    } catch (_) {
      failed = true;
      if (_canTouchUi) {
        _setUiState(() {
          _autoChatStatus = AutoChatStatus.error;
          _lastReplyBlockReason = ReplyBlockReason.networkError;
        });
      }
    } finally {
      // 丢弃/失败/提前返回路径的兜底：清掉切句缓冲（成功路径已 flush，幂等无害）。
      _cancelVoiceReply();
      if (session != null && identical(_streamingSession, session)) {
        _streamingSession = null;
      }
      runGuard.finish();
      _regenerateContext = [];
      _streamingMessage = null;
      _isRegenerating = false;
      _regenerateMessageId = '';
      if (_canTouchUi) {
        _setUiState(() {
          if (temp != null) {
            if (succeeded) {
              // 成功：移除原消息，保留新消息。
              _messages = _messages.where((m) => m.id != original.id).toList();
            } else if (failed) {
              // 失败或搜索准备异常：移除占位消息，保留原消息。
              _messages = _messages.where((m) => m.id != temp!.id).toList();
            }
          }
        });
        _reloadSearchRuntimeIfChanged();
      }
    }
  }

  /// 进入引用回复：记录被引用消息并聚焦输入框。
  void _quoteMessage(Message message) {
    _setUiState(() => _quotedMessage = message);
    _inputFocusNode.requestFocus();
  }

  /// 取消引用回复。
  void _cancelQuote() {
    _setUiState(() => _quotedMessage = null);
  }

  /// 按 senderId 取展示名；历史角色优先使用删除时保存的身份快照。
  String _senderNameById(String id) {
    if (id == 'user') return _ownerMentionName;
    return _displayCharacterById(id)?.name ?? _unknownCharacter().name;
  }

  AICharacter? _displayCharacterById(String id) {
    for (final character in _allGroupCharacters) {
      if (character.id == id) return character;
    }
    return DataLifecycleService(db: _db).characterOrDeleted(id);
  }

  /// 角色已被删除时的占位对象，避免历史消息渲染时空指针。
  AICharacter _unknownCharacter() {
    return AICharacter(
      name: '已删除角色',
      avatar: '?',
      age: 0,
      role: '',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'deepseek',
      apiConfigId: '',
    );
  }
}
