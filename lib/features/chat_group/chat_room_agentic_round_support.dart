part of 'chat_room_page.dart';

extension _ChatRoomAgenticRoundSupport on _ChatRoomPageState {
  /// 生成单个角色的一条回复（流式打字机路径），返回最终文本。
  ///
  /// 主要步骤：
  /// 1. 解析 API 配置与密钥，缺失则写入占位消息并置位阻塞原因；
  /// 2. 必要时压缩上下文（[_compactContextIfNeeded]）；
  /// 3. 按策略决定是否联网搜索，并把搜索结果作为 system 上下文注入；
  /// 4. 插入一条内存态空消息用于逐 token 渲染，**不立即落库**；
  /// 5. 失败则重试一次；空回复用兜底文案；重复回复直接丢弃；
  /// 6. 完成后清洗内容（去名字前缀、去 tool_call 协议泄漏），只落库一次；
  /// 7. 更新用量、关系态与角色记忆。
  Future<String> _generateAiReply(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false,
      ReplyIntent? intent,
      Message? currentUserMessage,
      UserMessageSentiment? userSentiment,
      SearchTurnContext? searchTurnContext}) async {
    if (isAutoChat && _workModeEnabled) {
      // No stream is created on this path, so any transition latch must not
      // survive until the next unrelated automatic reply.
      if (!_isStreaming) _discardCurrentStream = false;
      return '';
    }
    // 并发兜底：同一角色正在执行 agentic 任务时，auto-chat / 其他并发路径
    // 不得触发同一角色的普通 LLM 回复，否则会出现「agentic 兜底文案 + 普通
    // LLM 泄漏代码」两条消息的 Bug（auto-chat 传 userMessage=null 会绕过工作任务
    // 分支直接走流式路径，因此这里也必须检查角色执行锁）。
    if (_agenticRunningCharacterIds.contains(character.id)) {
      return '';
    }

    final config = _resolveApiConfig(character);
    final apiKey =
        config == null ? null : await _credentialResolver.resolve(config);
    if (!_pageActive || _disposed) return '';
    if (config == null || apiKey == null) {
      if (_canTouchUi) {
        _setUiState(() {
          _autoChatStatus = AutoChatStatus.unavailable;
          _lastReplyBlockReason = ReplyBlockReason.noApiConfig;
        });
      }
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: '[${character.name} 未配置 API]',
      ));
      return '[${character.name} 未配置 API]';
    }

    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );
    // 上下文超出模型窗口时先做压缩，拿到压缩后的消息与摘要。
    final compactedContext = await _compactContextIfNeeded(
      character: character,
      config: config,
      provider: provider,
      fallbackContext: context,
    );

    // The snapshot was prepared once by _runAiRound. A missing snapshot is a
    // valid outcome (policy off, consent denied, stable question, or failure),
    // and must not cause this character to search again.
    final webSearch = searchTurnContext?.snapshot;
    // 查询模型能力（是否支持图片输入），决定要不要拼多模态内容。
    final capability = _aiGateway.capability(provider, config.modelName);
    final apiMessages = _withWebSearchContext(
      await buildPromptMessages(
        character: character,
        context: compactedContext.messages,
        userMessage: userMessage,
        isAutoChat: isAutoChat,
        intent: intent,
        supportsVision: capability.supportsVision,
        currentUserMessage: currentUserMessage,
        transientContextSummary: compactedContext.summary,
      ),
      webSearch,
      allowSourceLinks: searchTurnContext?.allowSourceLinks == true,
    );
    // The context compressor runs before persona, memory, document and search
    // prompts are assembled. Fit the final request as a second deterministic
    // boundary so a large attachment/system prompt cannot make the gateway
    // reject an otherwise valid reply on small custom model windows.
    final replyOutputLimit = max(1, capability.contextWindow);
    final replyOutputTokens =
        capability.maxOutput.clamp(1, min(1024, replyOutputLimit)).toInt();
    final replyInputBudget = ContextWindowManager.inputBudget(
      contextWindow: capability.contextWindow,
      maxOutput: replyOutputTokens,
    );
    final boundedApiMessages = ContextWindowManager.fitToTokenBudget(
      apiMessages,
      maxTokens: replyInputBudget,
    );
    // 上面的 await 期间用户可能切到工作模式，此时放弃这次自动聊天回复。
    if (isAutoChat && _workModeEnabled) {
      _discardCurrentStream = false;
      return '';
    }
    if (!_pageActive || _disposed) return '';
    // —— 内存态临时消息：先以空内容入列用于增量渲染，整条完成后再落库一次 ——
    final temp = Message(
      groupId: widget.groupId,
      senderId: character.id,
      senderType: 'ai',
      content: '',
      webSearchSnapshot: webSearch?.toMap(),
    );
    if (mounted) {
      _setUiState(() {
        _streamingMessage = temp;
        _messages = List.from(_messages)..add(temp);
      });
    }
    _scrollToBottom();

    // 开启流式语音播报时，为这条回复新建切句缓冲（无音色则整条不朗读）。
    _beginVoiceReply(character);
    final session = StreamingReplySession();
    _streamingSession = session;
    if (_canTouchUi) _setUiState(() {});
    final result = await session.run(
      _aiGateway.streamChatMessage(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: config.protocol,
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        messages: boundedApiMessages,
        maxTokens: replyOutputTokens,
        purpose:
            isAutoChat ? AiRequestPurpose.autoChat : AiRequestPurpose.reply,
        conversationId: widget.groupId,
        characterId: character.id,
        userInitiated: !isAutoChat,
      ),
      // 每收到一段增量就直接改临时消息的 content 并请求重绘（不走 setState 全量重建）。
      onDraft: (draft) {
        temp.content = draft;
        _conversationController.updateStreamingDraft(draft);
        _flushStreamingUi();
        // 语音播报：把新增的增量喂给切句器，完整句即时入队朗读。
        _feedVoiceReplyDraft(draft);
      },
    );
    if (_disposed) return '';
    var fullContent = result.content;
    var failed = result.failed;
    if (failed) {
      _lastReplyBlockReason = ReplyBlockReason.networkError;
      fullContent =
          '[${character.name} 回复失败: ${_safeChatFailureMessage(result.error)}]';
      temp.content = fullContent;
      // 流式过程已失败：丢弃切句残缓冲，避免把失败尾巴或重试内容当流式朗读。
      _cancelVoiceReply();
      if (_canTouchUi) {
        _setUiState(() => _autoChatStatus = AutoChatStatus.error);
      }
    }
    // 仅当 _streamingSession 还是本次会话时才清空，避免误清后来者。
    if (identical(_streamingSession, session)) _streamingSession = null;

    // 停止、页面离开和工作模式切换都把当前输出视为不可提交结果。
    // stopped 必须在 fallback/retry/usage/audit/persistence 之前消费，避免
    // 用户明确取消后仍把部分内容或空回复兜底写入会话。
    bool shouldDiscardResult() =>
        _discardCurrentStream ||
        shouldDiscardStreamingReply(
          stopped: result.stopped,
          pageActive: _pageActive,
          conversationStopping:
              _conversationController.state.phase == ConversationPhase.stopping,
        );
    if (shouldDiscardResult()) {
      _discardCurrentStream = false;
      _discardStreamingMessage(temp);
      return '';
    }

    if (_canTouchUi) _setUiState(() {});

    // 空内容也给出可见反馈，否则 @ 触发会像没有人理会。
    if (!failed && fullContent.trim().isEmpty) {
      fullContent = ChatActivityPolicy.emptyReplyFallback(
        characterName: character.name,
        role: character.role,
        groupTheme: _group?.theme ?? '',
        userMessage: userMessage,
        isAutoChat: isAutoChat,
        random: _random,
      );
      temp.content = fullContent;
      _flushStreamingUi();
    }

    // 失败重试一次；但被治理网关拦下（超预算/限流）时不重试，否则只是重复挨拒。
    if (failed && !AiRequestGateway.isBlockedMessage(result.error)) {
      final retryContent = await _retryFailedReply(
        character: character,
        config: config,
        provider: provider,
        apiMessages: boundedApiMessages,
        maxTokens: replyOutputTokens,
        userInitiated: !isAutoChat,
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
      return '';
    }

    // 解析 @ 提及 → mentionedAiIds（未知名称忽略，避免误指向第一个成员）。
    final mentionedIds = _isDirectChat
        ? const <String>[]
        : parseMentionedCharacterIds(fullContent, _characters);

    // 移除 LLM 可能附带的名字前缀（UI 已独立显示角色名）。
    fullContent = _stripNamePrefix(fullContent, character.name);
    fullContent =
        _chatRoomSearchContextFormatter.sanitizeCitationsWithSourceIds(
      fullContent,
      webSearch == null
          ? const <String>[]
          : _chatRoomSearchContextFormatter.format(webSearch).sourceIds,
    );
    if (webSearch != null) {
      fullContent = _chatRoomSearchContextFormatter.sanitizeAnswerLinks(
        fullContent,
        allowLinks: searchTurnContext?.allowSourceLinks == true,
      );
    }
    // 防御：非 agentic 路径下 LLM 可能自发输出 tool_call 协议标签文本
    // （尤其使用过 agentic 能力的角色，system prompt 里可能残留工具说明）。
    // 在落库与返回前清洗之，避免协议泄漏被当作普通聊天贴出来。
    fullContent = sanitizeNonAgenticReply(fullContent);
    // 与近期消息重复时直接丢弃这条（只记用量），避免刷屏式复读。
    if (shouldDiscardResult()) {
      _discardCurrentStream = false;
      _discardStreamingMessage(temp);
      return '';
    }
    if (!failed &&
        isDuplicateAiReply(
          fullContent,
          _messages,
          excludeMessageId: temp.id,
        )) {
      await _recordReplyUsage(character);
      if (_canTouchUi) {
        _setUiState(() {
          _messages = List.from(_messages)
            ..removeWhere((message) => message.id == temp.id);
          _streamingMessage = null;
        });
      }
      return '';
    }
    // 持久化纪律：仅完成时 put 一次（包含失败占位消息）。
    temp.content = fullContent;
    temp.isMention = mentionedIds.isNotEmpty;
    temp.mentionedAiIds = mentionedIds;
    if (shouldDiscardResult()) {
      _discardCurrentStream = false;
      _discardStreamingMessage(temp);
      return '';
    }
    // media 置空：AI 流式回复不携带附件，清掉以免残留脏数据落库。
    temp.media = null;
    // 语音播报收尾：成功回复把缓冲的最后一句读完；失败/占位则放弃残句。
    if (failed) {
      _cancelVoiceReply();
    } else {
      _flushVoiceReply();
    }
    await _appendMessage(temp);
    if (searchTurnContext != null) {
      _searchTurnController.bindReply(temp.id, searchTurnContext);
    }
    await _recordReplyUsage(character);
    _registerUserMentionIfNeeded(temp);
    // 关系态与角色记忆只在成功回复后更新，失败占位不该污染长期状态。
    if (!failed) {
      // 私聊中 _directReplyCharacters 清空了 _pendingReplyIntents，但实际
      // 传进来的 intent 可能 targetId=null（来源待查），需同时兜底这两种情况。
      final effectiveIntent = (intent == null || intent.targetId == null)
          ? (_isDirectChat
              ? ReplyIntent(
                  speakerId: character.id,
                  action: ReplyAction.answer,
                  targetId: 'user',
                  lengthHint: ReplyLengthHint.normal,
                  toneHint: 'neutral',
                  reason: 'Direct chat reply',
                )
              : null)
          : intent;
      if (effectiveIntent != null) {
        await _persistRelationshipForIntent(
          character: character,
          intent: effectiveIntent,
          aiReplyMessage: temp,
          userMessage: userMessage,
          userSentiment: userSentiment,
        );
      }
    }
    if (_canTouchUi) _setUiState(() => _streamingMessage = null);
    return fullContent;
  }

  /// Removes a streaming placeholder without touching persistence.
  ///
  /// This also updates the in-memory list while the page is inactive so a
  /// later reactivation cannot render a cancelled placeholder from stale state.
  void _discardStreamingMessage(Message message) {
    _streamingMessage = null;
    _messages = _messages
        .where((candidate) => candidate.id != message.id)
        .toList(growable: false);
    if (_canTouchUi) _setUiState(() {});
  }

  /// 对失败的回复做一次非流式重试，成功返回内容，否则返回 null。
  ///
  /// 用非流式接口重试是为了简化逻辑：此时 UI 上已有占位气泡，只需拿到完整文本替换。
  Future<String?> _retryFailedReply({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required List<Map<String, dynamic>> apiMessages,
    required int maxTokens,
    required bool userInitiated,
  }) async {
    final apiKey = await _credentialResolver.resolve(config);
    if (apiKey == null) return null;
    final result = await _aiGateway.sendChatMessageStreamed(
      apiKey: apiKey,
      provider: provider,
      apiProtocol: config.protocol,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: apiMessages,
      temperature: 0.75,
      purpose: AiRequestPurpose.retry,
      conversationId: widget.groupId,
      characterId: character.id,
      maxTokens: maxTokens,
      userInitiated: userInitiated,
    );
    if (result['success'] == true) {
      final content = result['message']?.toString().trim() ?? '';
      if (content.isNotEmpty) return content;
    }
    return null;
  }

  /// 展示 AI 治理网关的告警（预算即将耗尽 / 被限流等）。
  void _showGovernanceWarning(String warning) {
    if (!_canTouchUi) return;
    AppToast.show(
      context,
      warning,
      icon: Icons.account_balance_wallet_outlined,
    );
  }
}

/// Converts provider-controlled failures into a short, persistence-safe label.
///
/// The transport layer already sanitizes its own errors, but this boundary is
/// also used by test doubles and future clients. Keeping the final message
/// safe here prevents an accidental raw body from reaching Hive.
String _safeChatFailureMessage(String? error) {
  final value = error?.trim() ?? '';
  if (value.isEmpty) return '请求失败';
  if (AiRequestGateway.isBlockedMessage(value)) return '请求被治理策略拦截';
  final status = RegExp(r'\bHTTP\s+(\d{3})\b', caseSensitive: false)
      .firstMatch(value)
      ?.group(1);
  if (status != null) return 'HTTP ${int.parse(status)} 请求失败';
  if (value.contains('超时') || value.toLowerCase().contains('timeout')) {
    return '请求超时';
  }
  if (value.contains('网络') || value.toLowerCase().contains('connection')) {
    return '网络连接失败';
  }
  return '模型请求失败';
}
