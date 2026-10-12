part of 'chat_room_page.dart';

/// 一次回复**失败之后**的处置：明确报出装不下的必需内容、失败后的一次非流式重试。
///
/// 与 `_ChatRoomAgenticRoundSupport` 分开是为了让生成主流程只保留"正常怎么走"：
/// 这两件事都只在失败路径上发生，且各自带一份必须遵守的边界（失败提示有界且去重、
/// 重试是一次真实请求因此要自己复检轮次）。
extension _ChatRoomAgenticRoundFailureSupport on _ChatRoomPageState {
  /// 必需内容放不进模型窗口时的明确失败。
  ///
  /// 有界：写一条可见说明后立刻结束这次回复，不重试、不进循环，也不假装那些内容
  /// 已经生效。用户按提示缩短设定或换用窗口更大的模型即可。
  ///
  /// 同一份必需内容只提示一次：放不下的是"内容 × 模型窗口"，同一位角色的后续
  /// 步骤、空闲自动聊天的每一轮都会撞上同一堵墙，重复贴同样的气泡只是噪音。用户
  /// 手动发起的回合会在轮次开始时复位，因此每轮仍能看到一次明确解释。
  Future<String> _reportRequiredPromptDidNotFit(
      AICharacter character, String missing) async {
    // 去重键带上具体缺的那一项：换了原因（设定装得下、人设装不下）就该再说一次。
    final key = '$_groupSharedContextBlock|$missing';
    if (_promptOverflowReportedKey == key) return '';
    _promptOverflowReportedKey = key;
    final content = '[${character.name} 未回复：$missing 放不进当前模型的输入窗口。'
        '请缩短本群共同设定、该角色的角色设定或这条消息，减少历史消息，'
        '或为这个角色换用上下文窗口更大的模型。]';
    await _appendMessage(Message(
      groupId: widget.groupId,
      senderId: character.id,
      senderType: 'ai',
      content: content,
    ));
    if (_canTouchUi) {
      _setUiState(() => _autoChatStatus = AutoChatStatus.unavailable);
    }
    return content;
  }

  /// 对失败的回复做一次非流式重试，成功返回内容，否则返回 null。
  ///
  /// 用非流式接口重试是为了简化逻辑：此时 UI 上已有占位气泡，只需拿到完整文本替换。
  ///
  /// 重试同样是一次真实请求，且没有任何流与之绑定，因此可见性必须在这里自己
  /// 复检：页面在失败与重试之间离开时，这次调用不该再发出去。
  Future<String?> _retryFailedReply({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required List<Map<String, dynamic>> apiMessages,
    required int maxTokens,
    required bool userInitiated,
    required bool isAutoChat,
    required int roundGeneration,
    int? autoChatGeneration,
    Set<String>? autoPickMentionedIds,
  }) async {
    if (_isReplyRoundInvalidated(
        isAutoChat: isAutoChat,
        generation: roundGeneration,
        autoChatGeneration: autoChatGeneration)) {
      return null;
    }
    if (autoPickMentionedIds != null &&
        !_mayAutoPick(character, mentionedIds: autoPickMentionedIds)) {
      return null;
    }
    final apiKey = await _credentialResolver.resolve(config);
    if (apiKey == null) return null;
    if (_isReplyRoundInvalidated(
        isAutoChat: isAutoChat,
        generation: roundGeneration,
        autoChatGeneration: autoChatGeneration)) {
      return null;
    }
    if (autoPickMentionedIds != null &&
        !_mayAutoPick(character, mentionedIds: autoPickMentionedIds)) {
      return null;
    }
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
