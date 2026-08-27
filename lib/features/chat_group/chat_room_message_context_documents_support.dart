part of 'chat_room_page.dart';

extension _ChatRoomMessageContextDocumentsSupport on _ChatRoomPageState {
  Future<String> _documentContextFor(
    String? query,
    List<Message> history,
    Message? current,
  ) {
    if (query == null || query.trim().isEmpty) return Future.value('');
    final messages = <Message>[...history];
    if (current != null && !messages.any((item) => item.id == current.id)) {
      messages.add(current);
    }
    final attachments = messages
        .expand((message) => message.media ?? const <MediaAttachment>[])
        .where(DocumentUnderstandingService.supports)
        .toList(growable: false);
    if (attachments.isEmpty) return Future.value('');
    final token = DocumentProcessingToken();
    _documentProcessingToken = token;
    _documentProcessingProgress = 0;
    if (_canTouchUi) _setUiState(() {});
    return DocumentUnderstandingService.buildPromptContext(
      query: query,
      attachments: attachments,
      cancelToken: token,
      onProgress: (value) {
        if (_canTouchUi && identical(_documentProcessingToken, token)) {
          _setUiState(() => _documentProcessingProgress = value);
        }
      },
    ).whenComplete(() {
      if (_canTouchUi && identical(_documentProcessingToken, token)) {
        _setUiState(() => _documentProcessingToken = null);
      }
    });
  }

  /// 取消正在进行的文档解析。
  void _stopDocumentProcessing() {
    _documentProcessingToken?.cancel();
  }

  /// 当用户一次 @ 多位角色做项目类任务时，生成"开发/验收"分工的协作提示。
  ///
  /// 触发条件：@ 到 ≥2 个已知角色，且文本含项目类关键词（开发/测试/BUG/代码…）。
  /// 分工规则：名字/角色/标签里带测试、QA、验收、质量的角色任验收者
  /// （找不到则取最后一个被 @ 的），另一位任开发者；当前角色按身份拿到对应指令。
  /// 不满足条件时返回空串，表示不注入协作提示。
  String _collaborationPromptFor({
    required String? userMessage,
    required AICharacter currentCharacter,
  }) {
    if (userMessage == null || userMessage.trim().isEmpty) return '';
    final mentioned = parseMentionedCharacterIds(userMessage, _characters);
    // 少于两人不构成协作，无需分工。
    if (mentioned.length < 2) return '';
    final lower = userMessage.toLowerCase();
    final looksLikeProjectTask = lower.contains('开发') ||
        lower.contains('项目') ||
        lower.contains('测试') ||
        lower.contains('验收') ||
        lower.contains('bug') ||
        lower.contains('修复') ||
        lower.contains('代码') ||
        lower.contains('实现') ||
        lower.contains('build') ||
        lower.contains('test');
    if (!looksLikeProjectTask) return '';

    final mentionedCharacters = <AICharacter>[];
    for (final id in mentioned) {
      for (final character in _characters) {
        if (character.id == id) {
          mentionedCharacters.add(character);
          break;
        }
      }
    }
    if (mentionedCharacters.length < 2) return '';

    // 从被 @ 的人里挑测试/验收角色：名字、职位、性格标签任一命中关键词即可。
    AICharacter? verifier;
    for (final character in mentionedCharacters) {
      final text = '${character.name} ${character.role} '
              '${character.personalityTags.join(' ')}'
          .toLowerCase();
      if (text.contains('测试') ||
          text.contains('qa') ||
          text.contains('验收') ||
          text.contains('质量')) {
        verifier = character;
        break;
      }
    }
    // 没有明显的测试角色时，约定最后一个被 @ 的人做验收，其余第一个做开发。
    verifier ??= mentionedCharacters.last;
    final executor = mentionedCharacters
        .firstWhere((character) => character.id != verifier!.id);

    // 同一段协作提示会发给每个角色，但"你的职责"随当前角色而变。
    final currentRole = currentCharacter.id == executor.id
        ? '你是本次任务的开发/执行者。先给出实现计划或交付内容；完成后必须 @${verifier.name} 请他验收。'
        : currentCharacter.id == verifier.id
            ? '你是本次任务的测试/验收者。等待开发者交付后进行验收；发现问题要明确 @${executor.name} 并列出 BUG 和复现/修改建议。'
            : '你不是主责角色，只在被点名时补充，不要抢主责。';

    return '【AI 协作任务】用户一次 @ 了多位 AI 做一个项目/任务。'
        '分工：${executor.name}=开发/执行，${verifier.name}=测试/验收。'
        '$currentRole'
        '不要替对方完成职责；用 @ 推动下一棒。';
  }

  /// 组装私聊场景的 LLM 消息列表。
  ///
  /// 与群聊版的区别：没有群成员/场景/协作提示，改为注入私聊人格上下文，
  /// 且历史里只保留"用户消息 + 该角色自己的消息"（私聊本就只有两方）。
  Future<List<Map<String, dynamic>>> _buildDirectApiMessages(
    AICharacter character,
    List<Message> context,
    String? userMessage, {
    bool supportsVision = false,
    Message? currentUserMessage,
    String? transientContextSummary,
    bool isAutoChat = false,
  }) async {
    final msgs = <Map<String, dynamic>>[];
    // ── 1. 全局永久记忆（跨群/DM，按 observerCharacterId 读取） ─────────
    final permanentMemory = await _memoryContextSelector.select(
      observerCharacterId: character.id,
      participantCharacterIds: [character.id],
      currentTargetId: 'user',
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

    // 私聊关系行为准则：由 MemoryContextSelector 注入关系数值，
    // 这里仅补充行为规则（冷漠/热情/拒绝），不重复输出亲近/信任/摩擦等。
    for (final r in _relationshipStates.where(
      (r) =>
          r.sourceCharacterId == character.id &&
          r.targetType == RelationshipTargetType.user,
    )) {
      if (r.affinity < -20 && r.friction > 60) {
        msgs.add({
          'role': 'system',
          'content': '行为准则：你和用户关系很差，你会不耐烦、懒得认真回应，语气带刺、想尽快结束对话。',
        });
        break;
      } else if (r.affinity < 0 || r.friction > 50) {
        msgs.add({
          'role': 'system',
          'content': '行为准则：你和用户关系一般，不用刻意讨好，保持自然距离。',
        });
        break;
      }
    }

    msgs.add({
      'role': 'system',
      'content': DirectChatSession.buildPromptContext(
        ownerName: _ownerMentionName,
      ),
    });
    msgs.add({
      'role': 'system',
      'content': '当前真实时间：${DateTime.now().toLocal().toIso8601String()}。'
          '涉及当前事实、新闻、价格、职位、规则或你不知道的内容时，不要编造；请说明不确定，并建议联网搜索或让用户授权搜索。'
          '如果用户要求你贴图、发图或发送附件，可以自然说明“我附上了”，应用会把本轮产物作为图片或文件附件显示。'
          '${isAutoChat ? '用户暂时没有回复你，你主动发一条消息找他聊天，可以问问他近况、分享一件事或开启新话题，但不要重复之前说过的话。' : '用户刚给你发了一条消息，请自然回应。'}'
          '私聊主动找用户时最多连续三条，之后等待用户回复。',
    });
    msgs.add({'role': 'system', 'content': character.rolePlaySystemPrompt});

    // 私聊同样只保留最近 20 条历史。
    final recentHistory =
        context.length > 20 ? context.sublist(context.length - 20) : context;
    final documentContext = await _documentContextFor(
      userMessage,
      recentHistory,
      currentUserMessage,
    );
    if (documentContext.isNotEmpty) {
      msgs.add({'role': 'system', 'content': documentContext});
    }
    for (final message in recentHistory) {
      if (message.senderType == 'user') {
        // 含媒体时按多模态策略生成 content。
        msgs.add({
          'role': 'user',
          'content': await prepareUserMessageContent(
            message,
            supportsVision: supportsVision,
            documentQuery: userMessage,
            includeDocumentContext: false,
          ),
        });
      } else if (message.senderId == character.id) {
        msgs.add({'role': 'assistant', 'content': message.content});
      }
      // 其余（例如系统消息 / 别的角色残留消息）在私聊语境下忽略。
    }

    if (userMessage != null && recentHistory.isEmpty) {
      // 历史为空时当前用户消息尚未进入 context，直接基于其构建 content。
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

  /// 从最近的消息中提取对话焦点，帮助 AI 理解"现在在聊什么"。
  /// 取最近 3 条消息的内容拼成一段焦点摘要，注入到 system prompt 中。
}
