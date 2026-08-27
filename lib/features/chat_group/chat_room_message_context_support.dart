part of 'chat_room_page.dart';

extension _ChatRoomMessageContextSupport on _ChatRoomPageState {
  /// 根据本次发言意图更新并落库角色关系状态（好感/亲密度等）。
  ///
  /// 目标对象取意图指定的 targetId；意图没指定但本轮由用户触发时视为对 `user`。
  /// 尊重记忆控制开关：全局关闭自动记忆、或该条关系被用户锁定时直接跳过。
  ///
  /// 不再直接写 per-group RelationshipState，改为通过全局事件 → 全局快照路径。
  /// [aiReplyMessage] 是 AI 实际回复的消息，用于关系事件的消息内容和事件溯源。
  Future<void> _persistRelationshipForIntent({
    required AICharacter character,
    required ReplyIntent intent,
    required Message aiReplyMessage,
    String? userMessage,
    UserMessageSentiment? userSentiment,
  }) async {
    final targetId = intent.targetId ?? (userMessage != null ? 'user' : null);
    if (targetId == null || targetId.isEmpty) return;
    final targetType = targetId == 'user'
        ? RelationshipTargetType.user
        : RelationshipTargetType.ai;
    if (!_memoryControls.automaticMemoryEnabled) return;

    await persistRelationshipEvents(
      service: _relationshipEventService,
      sourceCharacterId: character.id,
      targetId: targetId,
      targetType: targetType,
      message: aiReplyMessage,
      conversationId: widget.groupId,
      conversationNameSnapshot: _group?.name ?? '',
      allCharacters: _allGroupCharacters,
      visibleCharacterIds: _visibleCharacterIdsForMessage(),
      userSentiment: userSentiment,
    );
    _relationshipStates = _loader.stableGlobalRelationships();
  }

  /// 解析角色可用的 API 配置；未绑定或没有凭据时返回 null（视为不可回复）。
  ApiConfig? _resolveApiConfig(AICharacter character) {
    if (character.apiConfigId.isNotEmpty) {
      final config = _db.apiConfigBox.get(character.apiConfigId);
      if (config?.hasCredential == true) return config;
    }
    return null;
  }

  /// 组装发给 LLM 的完整消息列表（群聊版；私聊转交 [_buildDirectApiMessages]）。
  ///
  /// system 消息按固定顺序层层叠加，顺序即优先级：
  /// 1. 群聊记忆摘要 → 2. 角色自我记忆 / 会话内压缩摘要 / 发言意图上下文
  /// → 3. 群聊场景与当前话题焦点 → 3.5 当前需回应的那条消息
  /// → 4. 自动聊天提示 → 5. 角色人设 → 6. 其他成员信息 → 历史对话。
  ///
  /// [supportsVision] 为 true 时图片附件会拼成多模态内容，否则退化为文字描述。
  Future<List<Map<String, dynamic>>> _buildPromptMessagesInternal({
    required AICharacter character,
    required List<Message> context,
    String? userMessage,
    bool isAutoChat = false,
    ReplyIntent? intent,
    bool supportsVision = false,
    Message? currentUserMessage,
    String? transientContextSummary,
  }) {
    return _buildApiMessages(
      character,
      context,
      userMessage,
      isAutoChat: isAutoChat,
      intent: intent,
      supportsVision: supportsVision,
      currentUserMessage: currentUserMessage,
      transientContextSummary: transientContextSummary,
    );
  }

  Future<List<Map<String, dynamic>>> _buildApiMessages(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false,
      ReplyIntent? intent,
      bool supportsVision = false,
      Message? currentUserMessage,
      String? transientContextSummary}) async {
    final visibleContext = _visibleContextForCharacter(character.id, context);
    if (_isDirectChat) {
      return _buildDirectApiMessages(character, visibleContext, userMessage,
          supportsVision: supportsVision,
          currentUserMessage: currentUserMessage,
          transientContextSummary: transientContextSummary,
          isAutoChat: isAutoChat);
    }

    final msgs = <Map<String, dynamic>>[];

    // ── 1. 群聊记忆摘要 ───────────────────────────────────────────────
    // 群记忆是共享摘要；只要当前上下文存在角色不可见的消息，就不能把
    // 这份摘要继续发给该角色，避免摘要成为绕过消息可见性的旁路。
    final hasHiddenContext = _hasRestrictedHistory ||
        _visibleContextForCharacter(character.id, _messages).length !=
            _messages.length ||
        visibleContext.length != context.length;
    final selectedGroupMemory =
        hasHiddenContext ? '' : MemoryPromptSelector.groupSummary(_groupMemory);
    if (selectedGroupMemory.isNotEmpty) {
      msgs.add({'role': 'system', 'content': '【群聊记忆】$selectedGroupMemory'});
    }

    // ── 1.5 统一全局永久记忆（跨群/DM，按 observerCharacterId 读取） ──
    final permanentMemory = await _memoryContextSelector.select(
      observerCharacterId: character.id,
      participantCharacterIds: _characters.map((c) => c.id).toList(),
      currentTargetId: intent?.targetId,
      userMessage: userMessage,
    );
    if (permanentMemory.isNotEmpty) {
      msgs.add({'role': 'system', 'content': permanentMemory});
    }

    if (transientContextSummary?.isNotEmpty == true) {
      msgs.add({
        'role': 'system',
        'content': '【会话内压缩摘要】$transientContextSummary',
      });
    }

    if (intent != null) {
      msgs.add({
        'role': 'system',
        'content': HumanizedPromptBuilder.buildRelationContext(
          character: character,
          intent: intent,
          relationships: _relationshipStates,
          charactersById: {for (final c in _characters) c.id: c},
          ownerName: _ownerMentionName,
        ),
      });
    }

    // ── 3. 群聊场景 + 当前对话焦点 ─────────────────────────────────
    final groupName = _group?.name ?? '这个群';
    final groupTheme = _group?.theme ?? '日常聊天';
    final groupDescription = _group?.description ?? '';
    final announcement = _group?.announcement.trim() ?? '';
    final groupMemory = selectedGroupMemory;
    final isGroupAddressed = userMessage != null &&
        ChatActivityPolicy.isGroupAddressedMessage(userMessage);
    final scene = SceneBehavior.resolve(groupTheme);
    final scenarioPrompt = scene.scenarioPrompt;
    final recentContext = _extractRecentFocus(visibleContext);
    final nameById = {for (final c in _characters) c.id: c.name};
    final personaContext = ChatOrchestrator.buildPersonaGrowthContext(
      character: character,
      groupName: groupName,
      groupTheme: groupTheme,
      groupDescription: groupDescription,
      groupMemory: groupMemory,
    );
    msgs.add({
      'role': 'system',
      'content': '$personaContext\n\n'
          '你正在参加一个高活跃度群聊「$groupName」，主题是「$groupTheme」。'
          '${announcement.isEmpty ? '' : '群公告：$announcement。'}'
          '回复要像真实聊天群：自然接话、简短、有个人观点，可以顺手回应上一位成员或点名邀请别人，但不要每次都长篇总结。'
          '${HumanizedPromptBuilder.ownerMentionInstruction(_ownerMentionName)}'
          '当前真实时间：${DateTime.now().toLocal().toIso8601String()}。'
          '如果用户询问时间、日期、今天/明天/昨天，必须以这个真实时间为准。'
          '如果用户问到你不知道或可能过期的信息，必须明确说不确定，并建议或请求联网搜索；不要编造事实、价格、新闻、人物职位或链接。'
          '如果用户要求你贴图、发图或发送附件，可以在文字中自然说明“我附上了”，应用会把本轮产物作为图片或文件附件显示。'
          '如果正在执行协作任务，开发完成后要明确 @ 测试/验收角色，测试发现问题要 @ 开发角色并列出 BUG。'
          '重要：你的回复不要带自己的名字前缀（如「张三：」或「【张三】：」），直接说内容即可，头像和名字由界面自动显示。'
          '$scenarioPrompt'
          '$recentContext'
    });

    if (!scene.isGeneral) {
      final otherCharacters =
          _characters.where((c) => c.id != character.id).toList();
      final candidates = otherCharacters.isEmpty
          ? '暂无其他 AI 角色'
          : otherCharacters
              .map((c) => '${c.promptIdentity}，${c.personalityTags.join('/')} ')
              .join('；');
      final sceneContext = scene.roomContextPrompt(candidates);
      if (sceneContext.isNotEmpty) {
        msgs.add({'role': 'system', 'content': sceneContext});
      }
    }

    if (isGroupAddressed) {
      msgs.add({
        'role': 'system',
        'content': '【多人接力发言】用户这次是在问大家，不是只问你一个人。'
            '本轮会有多位群成员依次回应；你只代表自己说一小段，通常 1-2 句即可。'
            '如果你的角色没有特别新增观点，可以自然地短附和，比如“是的”“对”“+1”“我也这么想”，但尽量带一点你的角色语气。'
            '不要替其他人总结，也不要写成大段正式回答。'
      });
    }

    final collaborationPrompt = _collaborationPromptFor(
      userMessage: userMessage,
      currentCharacter: character,
    );
    if (collaborationPrompt.isNotEmpty) {
      msgs.add({'role': 'system', 'content': collaborationPrompt});
    }

    // ── 3.5 最后一条用户消息强调 ──────────────────────────────────
    if (visibleContext.isNotEmpty && !isAutoChat) {
      final lastUserMsg = visibleContext.lastWhere(
          (m) => m.senderType == 'user',
          orElse: () => visibleContext.first);
      if (lastUserMsg.senderType == 'user') {
        final speakerName = nameById[lastUserMsg.senderId] ?? '一位群友';
        final truncated = lastUserMsg.content.length > 100
            ? '${lastUserMsg.content.substring(0, 100)}...'
            : lastUserMsg.content;
        msgs.add({
          'role': 'system',
          'content':
              '【当前任务】$speakerName 刚说："$truncated" —— 请作为 ${character.name} 针对这条消息做出自然回应。'
        });
      }
    } else if (visibleContext.isNotEmpty && isAutoChat) {
      final last = visibleContext.last;
      final speakerName = last.senderType == 'user'
          ? _ownerMentionName
          : nameById[last.senderId] ?? '一位群友';
      final truncated = last.content.length > 100
          ? '${last.content.substring(0, 100)}...'
          : last.content;
      msgs.add({
        'role': 'system',
        'content': '【当前任务】$speakerName 刚说："$truncated" —— '
            '请作为 ${character.name} 自然接住这条群聊，可以回应、追问、转给某位成员，或轻轻换个相关话题。'
      });
    }

    // ── 4. 自动聊天提示（仅 auto-chat 模式） ────────────────────────
    if (isAutoChat) {
      final otherCharacters =
          _characters.where((c) => c.id != character.id).toList();
      if (otherCharacters.isNotEmpty) {
        final charInfo = otherCharacters
            .map((c) =>
                '${c.name}(${c.displayGenderLabel}, ${c.role}, ${c.age}岁)')
            .join('、');
        msgs.add({
          'role': 'system',
          'content':
              '现在群聊中正在自动对话。在场的其他角色：$charInfo。请主动抛话题、接上一条发言，或把话题递给某位成员，让群显得有人气。'
        });
      }
    }

    // ── 5. 角色人设 ─────────────────────────────────────────────────
    msgs.add({'role': 'system', 'content': character.rolePlaySystemPrompt});

    // ── 6. 其他角色信息 ─────────────────────────────────────────────
    final otherCharacters2 =
        _characters.where((c) => c.id != character.id).toList();
    if (otherCharacters2.isNotEmpty) {
      final characterInfo = otherCharacters2
          .map((c) =>
              '${c.name}(${c.displayGenderLabel}, ${c.role}, ${c.age}岁, ${c.personalityTags.join('/')})')
          .join('；');
      msgs.add({'role': 'system', 'content': '群聊中的其他角色：$characterInfo'});
    }

    // ── 7. 聊天历史（最多 20 条） ──────────────────────────────────
    // 截断到最近 20 条：够维持话题连贯，又不会把 token 预算耗在远古历史上。
    final historyMessages = visibleContext;
    final recentHistory = historyMessages.length > 20
        ? historyMessages.sublist(historyMessages.length - 20)
        : historyMessages;
    final documentContext = await _documentContextFor(
      userMessage,
      recentHistory,
      currentUserMessage,
    );
    if (documentContext.isNotEmpty) {
      msgs.add({'role': 'system', 'content': documentContext});
    }
    for (final m in recentHistory) {
      if (m.senderType == 'user') {
        // 真人用户消息 → user 角色；含媒体时按多模态策略生成 content。
        msgs.add({
          'role': 'user',
          'content': await prepareUserMessageContent(
            m,
            supportsVision: supportsVision,
            documentQuery: userMessage,
            includeDocumentContext: false,
          ),
        });
      } else if (m.senderId == character.id) {
        // 当前角色自己的消息 → assistant 角色（LLM 看到自己的历史发言）。
        msgs.add({'role': 'assistant', 'content': m.content});
      } else {
        // 其他 AI 角色的消息 → user 角色 + 发言者标注（LLM 知道这是别人说的话）。
        final speakerName = nameById[m.senderId] ?? '其他角色';
        final content = m.content.startsWith('【$speakerName】：')
            ? m.content
            : '【$speakerName】：${m.content}';
        msgs.add({'role': 'user', 'content': content});
      }
    }

    // ── 8. 当前用户消息（仅当历史为空时） ──────────────────────────
    if (userMessage != null && historyMessages.isEmpty) {
      // 历史为空时当前用户消息尚未进入 context，需直接基于其构建 content。
      dynamic content = userMessage;
      if (currentUserMessage != null) {
        content = await prepareUserMessageContent(
          currentUserMessage,
          supportsVision: supportsVision,
          documentQuery: userMessage,
          includeDocumentContext: false,
        );
      }
      msgs.add({'role': 'user', 'content': content});
    }

    return msgs;
  }

  /// 解析历史与当前消息里的文档附件，生成可注入 prompt 的文档上下文。
  ///
  /// 无查询词或无可解析附件时返回空串（不触发任何解析开销）。
  /// 解析过程可能较慢，通过 [DocumentProcessingToken] 支持用户中途取消，
  /// 并用 identical 校验确保只有"当前那次"解析才更新进度 UI。
  String _extractRecentFocus(List<Message> messages) {
    return ChatOrchestrator.extractRecentFocus(messages);
  }

  /// 移除 LLM 回复中可能附带的名字前缀（如「张三：」「【张三】：」）。
  /// UI 已独立显示角色名，内容中不应重复。
  String _stripNamePrefix(String content, String characterName) {
    return ChatOrchestrator.stripNamePrefix(content, characterName);
  }

  /// 落库并追加一条消息到列表末尾，然后滚动到底部。
  ///
  /// AI 消息会顺带推进已读位置——用户正看着这条消息，没有理由算作未读。
  Future<void> _appendMessage(Message message) async {
    // 页面离开后，任何已经结束但尚未提交的 AI 流结果都必须丢弃。
    // 这道仓储边界防止停流检查与真正写入之间的异步窗口再次落库。
    if (message.senderType == 'ai' && !_canTouchUi) return;
    final visibleIds = _visibleCharacterIdsForMessage();
    if (message.visibleToCharacterIds.isEmpty) {
      message.visibleToCharacterIds = List<String>.from(visibleIds);
    }
    if (!_isDirectChat &&
        message.visibleToCharacterIds.isNotEmpty &&
        !_characters.every((character) =>
            message.visibleToCharacterIds.contains(character.id))) {
      _hasRestrictedHistory = true;
    }
    await _repository.persistNewMessage(message);
    if (message.senderType == 'ai') {
      await _markCurrentConversationRead(throughMessage: message);
    }
    // 本地记忆/遗忘/关系必须在返回前落库；只有 LLM 提炼后台执行。
    await _observationEntry.observeDeterministic(
      message: message,
      visibleCharacterIds: visibleIds,
      conversationId: widget.groupId,
      conversationNameSnapshot:
          _isDirectChat ? _directChatName() : (_group?.name ?? ''),
      allCharacters: _allGroupCharacters,
    );
    _relationshipStates = _loader.stableGlobalRelationships();
    unawaited(_observationEntry
        .distillMessage(
          message: message,
          conversationId: widget.groupId,
          conversationNameSnapshot:
              _isDirectChat ? _directChatName() : (_group?.name ?? ''),
          allCharacters: _allGroupCharacters,
          isGroupChat: !_isDirectChat,
          userProfile: _userProfile,
        )
        .catchError((_) {}));
    if (!_canTouchUi) return;
    final existingIndex =
        _messages.indexWhere((existing) => existing.id == message.id);
    _setUiState(() {
      if (existingIndex < 0) {
        _messages = List.from(_messages)..add(message);
        _totalMessageCount++;
      } else {
        _messages = List.from(_messages)..[existingIndex] = message;
      }
    });
    _scrollToBottom();
  }

  /// 消息发送时在场/可见的 AI 角色 ID 列表。
  ///
  /// 群聊：所有活跃成员；私聊：只有目标角色。
  List<String> _visibleCharacterIdsForMessage() {
    if (_isDirectChat) {
      final charId = _directCharacterId;
      return charId != null && _characters.any((c) => c.id == charId)
          ? [charId]
          : _characters.map((c) => c.id).toList();
    }
    return _characters.map((c) => c.id).toList();
  }

  String _directChatName() {
    final charId = _directCharacterId;
    if (charId == null) return '私聊';
    for (final c in _allGroupCharacters) {
      if (c.id == charId) return c.name;
    }
    return '私聊';
  }

  /// 用户在群里被称呼时使用的名字：取人物卡显示名，为空则用"我"。
  String get _ownerMentionName {
    final profile = _userProfile;
    return profile?.displayName.trim().isNotEmpty ?? false
        ? profile!.displayName.trim()
        : '我';
  }

  /// 若这条 AI 消息 @ 到了用户，登记为"待查看的 @我"以显示提醒横幅。
  ///
  /// 用户正在看这个会话时不登记——他已经看到了，弹提醒只是噪音。
  void _registerUserMentionIfNeeded(Message message) {
    if (!_canTouchUi || message.senderType != 'ai') return;
    if (ConversationPresenceService.instance.isActive(widget.groupId)) return;
    if (!ChatActivityPolicy.contentMentionsUser(
      message.content,
      _ownerMentionName,
    )) {
      return;
    }
    if (_pendingUserMentionMessageIds.contains(message.id)) return;
    _setUiState(() => _pendingUserMentionMessageIds.add(message.id));
  }

  /// 标记已读时清掉"@我"横幅（带 _canTouchUi 守卫，可在异步流程中调用）。
  void _clearActiveUserMentionBanner() {
    if (!_canTouchUi || _pendingUserMentionMessageIds.isEmpty) return;
    _setUiState(() => _pendingUserMentionMessageIds.clear());
  }

  /// 用户手动点"忽略"时清空全部待查看的 @我 提醒。
  void _clearUserMentions() {
    if (_pendingUserMentionMessageIds.isEmpty) return;
    _setUiState(() => _pendingUserMentionMessageIds.clear());
  }

  /// 跳转到下一条 @我 的消息并高亮。
  ///
  /// 逐个出队：若目标消息已不在当前分页窗口内（index < 0）则跳过继续找下一条，
  /// 全部找不到时也要 setState 一次，让横幅上的计数归零。
  void _jumpToNextUserMention() {
    while (_pendingUserMentionMessageIds.isNotEmpty) {
      final messageId = _pendingUserMentionMessageIds.removeAt(0);
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index < 0) continue;
      _highlightMessageTemporarily(messageId);
      _scrollToMessageIndex(index);
      return;
    }
    if (_canTouchUi) _setUiState(() {});
  }

  /// 临时高亮某条消息 2 秒（跳转定位后帮助用户找到目标）。
  ///
  /// 定时器回调里比对 messageId，避免连续跳转时旧定时器误清新高亮。
  void _highlightMessageTemporarily(String messageId) {
    if (!_canTouchUi) return;
    _setUiState(() => _highlightedMentionMessageId = messageId);
    _mentionHighlightTimer?.cancel();
    _mentionHighlightTimer = Timer(const Duration(seconds: 2), () {
      if (_canTouchUi && _highlightedMentionMessageId == messageId) {
        _setUiState(() => _highlightedMentionMessageId = null);
      }
    });
  }

  /// 按策略条件（消息量、距上次摘要的间隔等）更新群周记忆摘要。
  ///
  /// 私聊没有群记忆，直接返回；用户手动锁定群记忆时也不自动覆盖。
}
