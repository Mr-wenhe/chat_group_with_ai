part of 'chat_room_page.dart';

/// 上下文超出模型窗口时的会话内压缩。
///
/// 单独一块的理由与别的失败路径一样：压缩是一次额外模型调用，还要把结果写进
/// [_transientContextCompression]，每一步都有自己的边界要守（阈值、凭据、轮次
/// 是否还有效）。
extension _ChatRoomContextCompactionSupport on _ChatRoomPageState {
  /// 上下文超出模型窗口时做压缩，返回压缩后的消息与摘要。
  ///
  /// 压缩摘要只写入 [_transientContextCompression]（仅本次会话有效）。
  ///
  /// 关闭自动记忆时直接返回原始上下文，不做任何压缩调用。
  ///
  /// 压缩本身是一次完整的外围模型请求，并且会把结果写进会话内缓存，因此凡是
  /// 实际发出请求或写入缓存的边界都按**原轮次**复检（[roundGeneration] /
  /// [autoChatGeneration]）：只比"用户还在看这个群"挡不住"离开又立刻回来"，
  /// 也挡不住"关掉自动发言又打开"。
  Future<({List<Message> messages, String? summary})> _compactContextIfNeeded({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required List<Message> fallbackContext,
    required Set<String> mentionedIds,
    required bool isAutoChat,
    required int roundGeneration,
    int? autoChatGeneration,
  }) async {
    bool invalidated() => _isReplyRoundInvalidated(
          isAutoChat: isAutoChat,
          generation: roundGeneration,
          autoChatGeneration: autoChatGeneration,
        );
    final transient = _transientContextCompression[character.id];
    final visibleFallbackContext = _visibleContextForCharacter(
      character.id,
      fallbackContext,
    );
    if (!_memoryControls.automaticMemoryEnabled) {
      return (messages: visibleFallbackContext, summary: transient?.summary);
    }
    final pending = _visibleContextForCharacter(character.id, _messages);
    final apiHistory = <Map<String, dynamic>>[
      if (transient != null)
        {
          'role': 'system',
          'content': '已有压缩摘要：${transient.summary}',
        },
      // 只有 AI 角色的发言是 assistant；真人（本人或多人联机里的其他成员）
      // 都算 user，否则压缩摘要会把客人说的话记成"助手说过"。
      ...pending.map((message) => <String, dynamic>{
            'role': message.senderType == Message.senderTypeAi
                ? 'assistant'
                : 'user',
            'content': message.content,
          }),
    ];
    final capability = _aiGateway.capability(provider, config.modelName);
    final summaryOutputLimit = max(1, capability.contextWindow);
    final summaryOutputTokens =
        capability.maxOutput.clamp(1, min(2048, summaryOutputLimit)).toInt();
    final summaryInputBudget = ContextWindowManager.inputBudget(
      contextWindow: capability.contextWindow,
      maxOutput: summaryOutputTokens,
    );
    final manager = ContextWindowManager(
      maxRetries: 0,
      complete: (messages) async {
        if (invalidated()) {
          return const {'success': false, 'message': '本轮已取消'};
        }
        if (!_mayAutoPick(character, mentionedIds: mentionedIds)) {
          return const {'success': false, 'message': '角色已禁言'};
        }
        final apiKey = await _credentialResolver.resolve(config);
        if (apiKey == null) {
          return const {'success': false, 'message': 'API 凭据不可用'};
        }
        // 凭据解析是异步的，期间页面可能已经不可见、或者这一轮已被取消；压缩是
        // 回合新触发的请求，同样必须在发出前复检。
        if (invalidated()) {
          return const {'success': false, 'message': '本轮已取消'};
        }
        if (!_mayAutoPick(character, mentionedIds: mentionedIds)) {
          return const {'success': false, 'message': '角色已禁言'};
        }
        return _aiGateway.sendChatMessage(
          apiKey: apiKey,
          provider: provider,
          apiProtocol: config.protocol,
          customBaseUrl: config.customBaseUrl,
          model: config.modelName,
          messages: messages,
          temperature: 0.3,
          maxTokens: summaryOutputTokens,
          purpose: AiRequestPurpose.summary,
          conversationId: widget.groupId,
          characterId: character.id,
        );
      },
      thresholdTokens:
          summaryInputBudget.clamp(1, kContextCompressThresholdTokens).toInt(),
    );
    // 没超过阈值就不压缩，省下一次 LLM 调用。
    if (!manager.shouldSummarize(apiHistory)) {
      return (messages: visibleFallbackContext, summary: transient?.summary);
    }

    try {
      final boundedHistory = ContextWindowManager.fitToTokenBudget(
        apiHistory,
        maxTokens: summaryInputBudget,
      );
      final summary = await manager.summarize(
        boundedHistory,
        isDirectChat: _isDirectChat,
      );
      // 压缩摘要可能在页面离开、或这一轮被取消之后才返回，此时不得写进会话内
      // 缓存：它属于"旧群 / 已取消的那一轮的上下文"。
      if (invalidated()) {
        return (messages: visibleFallbackContext, summary: transient?.summary);
      }
      // ponytail: transient-only compression, restore durable summaries if
      // cross-session context compression becomes a measured bottleneck.
      _transientContextCompression[character.id] = (
        checkpoint:
            pending.isEmpty ? (transient?.checkpoint ?? '') : pending.last.id,
        summary: summary.summary,
      );
      return (
        messages: ChatReplyPromptGuard.currentExchange(visibleFallbackContext),
        summary: summary.summary,
      );
    } catch (_) {
      // 压缩失败就退回完整上下文：宁可多花 token，也不能丢上下文。
      return (messages: visibleFallbackContext, summary: transient?.summary);
    }
  }
}
