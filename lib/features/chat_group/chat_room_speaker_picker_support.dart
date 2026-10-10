part of 'chat_room_page.dart';

/// 普通群聊的「逐次选人」接线：候选 → 选人器 → 本地兜底 → 发言意图。
///
/// 决策规则本身在 [GroupSpeakerSelection] 与 [AiSpeakerSelector] 里（都是纯函数，
/// 由单测钉住）；本文件只负责把它们接到页面上：谁有资格、用哪个配置、失败怎么
/// 退回本地编排器、页面不可见时怎么立刻收手。
extension _ChatRoomSpeakerPickerSupport on _ChatRoomPageState {
  /// 本轮可以被自动选中的成员（判据见 [GroupSpeakerSelection.candidates]）。
  List<AICharacter> _eligibleSpeakerCandidates({
    required Set<String> mentionedIds,
    required List<String> alreadySpoken,
  }) {
    return GroupSpeakerSelection.candidates(
      characters: _characters,
      isEligible: _isEligibleToReply,
      mayAutoPick: (character) =>
          _mayAutoPick(character, mentionedIds: mentionedIds),
      agenticRunningCharacterIds: _agenticRunningCharacterIds,
      alreadySpoken: alreadySpoken,
    );
  }

  /// 本回合最多产生几条 AI 回复（见 [GroupSpeakerSelection.maxReplies]）。
  int _maxRepliesForGroupRound({
    required List<String>? mentionedIds,
    required bool isAutoChat,
  }) =>
      GroupSpeakerSelection.maxReplies(
        hasMentions: (mentionedIds ?? const <String>[]).isNotEmpty,
        isAutoChat: isAutoChat,
      );

  /// 选人器能看到的对话：候选成员**共同可见**的那部分。
  ///
  /// 取交集而不是并集：选人器读到的每一句都会影响"下一位该接什么"，只有所有
  /// 候选都能看到的内容才是所有人都能接的。`visibleToCharacterIds` 为空的旧
  /// 消息没有授权快照，一律不传——失败关闭。
  List<Message> _sharedVisibleHistoryForSpeakers(
    List<AICharacter> candidates,
  ) {
    final candidateIds = {for (final character in candidates) character.id};
    if (candidateIds.isEmpty) return const [];
    return _recentMessagesForContext()
        .where((message) => message.visibleToCharacterIds.isNotEmpty &&
            candidateIds.every(message.visibleToCharacterIds.contains))
        .toList(growable: false);
  }

  /// 取消正在飞的选择请求（尽力而为，本地一定不采纳其结果）。
  void _cancelActiveSpeakerPick() {
    final token = _activeSpeakerPickerCancelToken;
    _activeSpeakerPickerCancelToken = null;
    token?.cancel('room-inactive');
  }

  /// 决定下一位由谁来说；返回 null 表示这一轮到此为止。
  ///
  /// 每一步都读取**最新已确认的对话**：上一位说完再决定下一位，而不是在用户
  /// 发送时一次锁定整轮名单。没有任何候选、页面不可见、App 不在前台时都不
  /// 发起模型调用。
  Future<_SelectedSpeaker?> _selectNextGroupSpeaker({
    required String? userMessage,
    required List<String>? mentionedIds,
    required bool isAutoChat,
    required List<String> alreadySpoken,
    required UserMessageSentiment? userSentiment,
  }) async {
    if (!_roomWorkAllowed) return null;
    final resolved = _resolveSpeakerStep(
      mentionedIds: mentionedIds,
      alreadySpoken: alreadySpoken,
    );
    final candidates = resolved.candidates;
    final step = resolved.step;
    if (step.kind == SpeakerStepKind.finished) return null;
    // 明确点名或有唯一候选时直接选人，省掉一次无意义的模型调用。
    if (step.kind == SpeakerStepKind.decided) {
      return _speakerPickFor(
        characterId: step.characterId!,
        candidates: candidates,
        userMessage: userMessage,
        mentionedIds: mentionedIds,
        isAutoChat: isAutoChat,
        userSentiment: userSentiment,
      );
    }

    final outcome = await _askSpeakerPicker(
      candidates: candidates,
      isAutoChat: isAutoChat,
    );
    // 等待期间这一轮可能已经失效：用户离开本群、进后台又回来、关掉自动聊天，
    // 或点了停止。失效后既不能采纳迟到的决定，也不能把它降级成本地选人——
    // 那结果和"停止之后照常发言"没有区别。
    if (_isSpeakerRoundInvalidated(isAutoChat: isAutoChat)) return null;
    if (outcome.status == _SpeakerPickStatus.endRound) return null;

    // 成员、禁言与资格都可能在等待期间变化，因此用**当前**候选重新校验：
    // 迟到的决定只能落在这一刻仍然成立的名单上。
    final refreshed = _resolveSpeakerStep(
      mentionedIds: mentionedIds,
      alreadySpoken: alreadySpoken,
    ).candidates;
    if (refreshed.isEmpty) return null;
    final decision = outcome.decision;
    if (decision != null) {
      // 模型明确要求结束本轮：正常收尾，不兜底再拉一个人出来说话。
      if (decision.status == AiSpeakerDecisionStatus.finished) return null;
      if (decision.status == AiSpeakerDecisionStatus.chosen) {
        final picked = _speakerPickFor(
          characterId: decision.speakerId!,
          candidates: refreshed,
          userMessage: userMessage,
          mentionedIds: mentionedIds,
          isAutoChat: isAutoChat,
          userSentiment: userSentiment,
        );
        if (picked != null) return picked;
      }
    }
    // 选人器不可用：这一步改用本地编排器完成，且本轮不再反复请求选择器。
    _speakerPickerDisabledForTurn = true;
    return _localSpeakerPick(
      candidates: refreshed,
      userMessage: userMessage,
      mentionedIds: mentionedIds,
      isAutoChat: isAutoChat,
      userSentiment: userSentiment,
    );
  }

  /// 这一步的选人是否已经失效。
  ///
  /// 三条判据都必须成立才能继续：用户真的在看这个群；自动回合的开关没被关掉；
  /// 这一轮没有被标记为停止。只看 [_roomWorkAllowed] 挡不住"进后台又立刻回来"
  /// ——它那时已经恢复为真，而飞行中的请求早已被取消。
  bool _isSpeakerRoundInvalidated({required bool isAutoChat}) {
    if (!_roomWorkAllowed) return true;
    if (isAutoChat && !_isAutoChatEnabled) return true;
    return _conversationController.state.phase == ConversationPhase.stopping;
  }

  /// 算出这一步的候选名单与判定依据。
  ///
  /// 候选、连说保护与点名优先级都是纯规则（见 [GroupSpeakerSelection]）；
  /// 这一步只负责把页面上的实时事实喂进去——谁有资格、谁刚说过、谁在等回应。
  ({List<AICharacter> candidates, SpeakerStep step}) _resolveSpeakerStep({
    required List<String>? mentionedIds,
    required List<String> alreadySpoken,
  }) {
    final mentionedSet = (mentionedIds ?? const <String>[]).toSet();
    final candidates = GroupSpeakerSelection.avoidConsecutiveSpeaker(
      candidates: _eligibleSpeakerCandidates(
        mentionedIds: mentionedSet,
        alreadySpoken: alreadySpoken,
      ),
      lastAiSenderId: _lastAiSenderId,
      hasMentions: mentionedSet.isNotEmpty,
    );
    final priorityIds = GroupSpeakerSelection.priorityMentionIds(
      mentionedIds: mentionedIds,
      pendingMentionedIds: _pendingMentionedIds,
      candidates: candidates,
    );
    return (
      candidates: candidates,
      step: GroupSpeakerSelection.nextStep(
        candidates: candidates,
        priorityMentionIds: priorityIds,
      ),
    );
  }

  /// 为已确定的角色生成针对其可见最新对话的发言意图。
  _SelectedSpeaker? _speakerPickFor({
    required String characterId,
    required List<AICharacter> candidates,
    required String? userMessage,
    required List<String>? mentionedIds,
    required bool isAutoChat,
    required UserMessageSentiment? userSentiment,
  }) {
    AICharacter? character;
    for (final candidate in candidates) {
      if (candidate.id == characterId) {
        character = candidate;
        break;
      }
    }
    if (character == null) return null;
    final intent = HumanizedChatOrchestrator.intentForSpeaker(
      character: character,
      allCharacters: _characters,
      recentMessages:
          _visibleContextForCharacter(character.id, _recentMessagesForContext()),
      groupId: widget.groupId,
      groupTheme: _group?.theme ?? '日常聊天',
      userMessage: userMessage,
      mentionedIds: mentionedIds ?? const [],
      memories: _characterMemories,
      relationships: _relationshipStates,
      random: isAutoChat ? _autoChatRandom : _random,
      isAutoChat: isAutoChat,
      userSentiment: userSentiment,
    );
    return _SelectedSpeaker(character, intent);
  }

  /// 选人器不可用时，用本地编排器的既有评分挑一位发言者。
  ///
  /// 只补**这一步**：分数仍然由原来的拟人化编排器给出，因此关系、心情、
  /// 话题契合度与沉默倾向都照常生效。返回 null 表示本轮没人需要开口。
  _SelectedSpeaker? _localSpeakerPick({
    required List<AICharacter> candidates,
    required String? userMessage,
    required List<String>? mentionedIds,
    required bool isAutoChat,
    required UserMessageSentiment? userSentiment,
  }) {
    final candidateIds = {for (final character in candidates) character.id};
    final intents = HumanizedChatOrchestrator.selectReplyIntents(
      characters: _characters,
      recentMessages: _recentMessagesForContext(),
      recentMessagesForCharacter: (character) => _visibleContextForCharacter(
        character.id,
        _recentMessagesForContext(),
      ),
      groupId: widget.groupId,
      groupTheme: _group?.theme ?? '日常聊天',
      userMessage: userMessage,
      mentionedIds: mentionedIds ?? const [],
      memories: _characterMemories,
      relationships: _relationshipStates,
      isEligible: (character) => candidateIds.contains(character.id),
      random: isAutoChat ? _autoChatRandom : _random,
      isAutoChat: isAutoChat,
      userSentiment: userSentiment,
    );
    if (intents.isEmpty) return null;
    return _speakerPickFor(
      characterId: intents.first.speakerId,
      candidates: candidates,
      userMessage: userMessage,
      mentionedIds: mentionedIds,
      isAutoChat: isAutoChat,
      userSentiment: userSentiment,
    );
  }

  /// 问一次选人器。
  ///
  /// [AiSpeakerDecision] 里是模型的正常决定（含"结束本轮"与"响应无效"）；
  /// 没有决定时由 [_SpeakerPickStatus] 说明这一步该怎么办：选人器不可用可以
  /// 降级成本地选人，被硬拒绝或飞行途中取消则必须结束这一轮。
  ///
  /// 每一步最多一次实际请求：关闭网关内部自动重试（`maxRetries: 0`），不做
  /// JSON 修复，也不"再选一次"。
  Future<_SpeakerPickOutcome> _askSpeakerPicker({
    required List<AICharacter> candidates,
    required bool isAutoChat,
  }) async {
    if (_speakerPickerDisabledForTurn) {
      return const _SpeakerPickOutcome.unavailable();
    }
    final config = _speakerPickerSettings.resolveConfig();
    if (config == null) return const _SpeakerPickOutcome.unavailable();
    final apiKey = await _credentialResolver.resolve(config);
    // 上面的 await 期间页面可能已经不可见或被停止。这不是"选人器不可用"，
    // 而是这一轮已经不该继续，因此必须结束本轮，而不是退回本地选人。
    if (!_roomWorkAllowed) return const _SpeakerPickOutcome.endRound();
    if (apiKey == null || apiKey.trim().isEmpty) {
      return const _SpeakerPickOutcome.unavailable();
    }
    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );
    final request = _buildSpeakerPickerRequest(
      candidates: candidates,
      provider: provider,
      model: config.modelName,
    );
    // 连协议与候选稳定 ID 都装不进这个模型的窗口：这一步不发起请求，回落本地。
    if (request == null) return const _SpeakerPickOutcome.unavailable();
    return _sendSpeakerPickerRequest(
      apiKey: apiKey,
      provider: provider,
      config: config,
      request: request,
      isAutoChat: isAutoChat,
      candidateIds: {for (final character in candidates) character.id},
    );
  }

  /// 按所选模型的能力，把选择器的输入与输出压进真实上限之内。
  ///
  /// [AiSpeakerSelector] 里的常量只是工程起点：真正的上限由能力表决定——输出
  /// 取"协议上限"与模型声明输出的较小者；输入取"估算上限"与该模型输入预算的
  /// 较小者，避免小窗口模型收到一个装不下的请求。
  ///
  /// 装不下时返回 null：候选稳定 ID 是选择器的必需协议，缺一个就会让那位角色
  /// 永远选不上，宁可这一步回落本地规则。
  ({List<Map<String, dynamic>> messages, int maxOutputTokens})?
      _buildSpeakerPickerRequest({
    required List<AICharacter> candidates,
    required ApiProvider provider,
    required String model,
  }) {
    final capability = _aiGateway.capability(provider, model);
    final maxOutputTokens = max(
      1,
      min(AiSpeakerSelector.maxOutputTokens, capability.maxOutput),
    );
    final inputBudget = ContextWindowManager.inputBudget(
      contextWindow: capability.contextWindow,
      maxOutput: maxOutputTokens,
    );
    final messages = AiSpeakerSelector.buildBoundedMessages(
      groupTheme: _group?.theme ?? '日常聊天',
      candidates: candidates,
      visibleHistory: _sharedVisibleHistoryForSpeakers(candidates),
      senderNames: _senderNameMap(),
      ownerName: _ownerMentionName,
      // 只读当前这个群的固定共同设定；不查询其他群、私聊或私有记忆。
      sharedContext: _groupSharedContextBlock,
      maxInputTokens: max(1, min(AiSpeakerSelector.maxInputTokens, inputBudget)),
    );
    if (messages == null) return null;
    return (messages: messages, maxOutputTokens: maxOutputTokens);
  }

  /// 发出一次选择请求，并把结果归一成决定。
  ///
  /// 失败分三类，处置完全不同：治理网关的**硬拒绝**（超预算 / 限流）说明这一轮
  /// 该停了，回落本地选人只会在同一个预算下再发一次请求；飞行途中被**我们自己
  /// 取消**（离页、进后台、停止）说明迟到的结果不再属于这一轮；其余（超时、
  /// 断网、空响应、非法响应）才是可降级的"选人器不可用"。
  Future<_SpeakerPickOutcome> _sendSpeakerPickerRequest({
    required String apiKey,
    required ApiProvider provider,
    required ApiConfig config,
    required ({List<Map<String, dynamic>> messages, int maxOutputTokens})
        request,
    required bool isAutoChat,
    required Set<String> candidateIds,
  }) async {
    final cancelToken = CancelToken();
    _activeSpeakerPickerCancelToken = cancelToken;
    // 超时也会取消令牌，但它属于可降级失败；用独立标记把两者分开，
    // 免得一次普通的选人超时被当成"用户已经离开"而终止整轮。
    var timedOut = false;
    try {
      final result = await _aiGateway
          .sendChatMessageWithResponseLimit(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: config.protocol,
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        messages: request.messages,
        temperature: 0.2,
        maxTokens: request.maxOutputTokens,
        receiveTimeout: AiSpeakerSelector.timeout,
        maxRetries: 0,
        // 手动用户回合与空闲自动回合分别沿用对应的预算用途：选择器的费用
        // 因此计入同一个会话与自动聊天预算，不会绕过自动聊天开关。
        purpose:
            isAutoChat ? AiRequestPurpose.autoChat : AiRequestPurpose.reply,
        conversationId: widget.groupId,
        characterId: AiSpeakerSelector.ledgerCharacterId,
        userInitiated: !isAutoChat,
        maxResponseBytes: AiSpeakerSelector.maxResponseBytes,
        cancelToken: cancelToken,
      )
          .timeout(
        AiSpeakerSelector.timeout,
        onTimeout: () {
          // 只看 receive timeout 不够：dio 的 receive timeout 会被每个数据块
          // 重置。整次选择的时限一到就同时取消这次请求。
          timedOut = true;
          cancelToken.cancel('speaker-picker-timeout');
          return const {'success': false, 'message': '选人超时'};
        },
      );
      return _outcomeForResult(
        result,
        cancelToken: cancelToken,
        timedOut: timedOut,
        candidateIds: candidateIds,
      );
    } on Object {
      return _failureOutcome(
        null,
        cancelToken: cancelToken,
        timedOut: timedOut,
      );
    } finally {
      if (identical(_activeSpeakerPickerCancelToken, cancelToken)) {
        _activeSpeakerPickerCancelToken = null;
      }
    }
  }

  /// 把一次返回归一成决定。
  ///
  /// 先看取消状态再看成败：请求被我们自己取消时（离页、进后台、停止），上游
  /// 完全可能把取消转成一个**正常响应**，只看成败就会把这次结果当成有效的。
  _SpeakerPickOutcome _outcomeForResult(
    Map<String, dynamic> result, {
    required CancelToken cancelToken,
    required bool timedOut,
    required Set<String> candidateIds,
  }) {
    if (!timedOut && cancelToken.isCancelled) {
      return const _SpeakerPickOutcome.endRound();
    }
    if (result['success'] != true) {
      return _failureOutcome(
        result['message']?.toString(),
        cancelToken: cancelToken,
        timedOut: timedOut,
      );
    }
    return _SpeakerPickOutcome.decided(AiSpeakerSelector.parseResponse(
      result['message']?.toString(),
      candidateIds: candidateIds,
    ));
  }

  /// 把一次失败归一成"可降级"还是"必须结束本轮"。
  _SpeakerPickOutcome _failureOutcome(
    String? message, {
    required CancelToken cancelToken,
    required bool timedOut,
  }) {
    if (!timedOut && cancelToken.isCancelled) {
      return const _SpeakerPickOutcome.endRound();
    }
    if (AiRequestGateway.isBlockedMessage(message)) {
      return const _SpeakerPickOutcome.endRound();
    }
    return const _SpeakerPickOutcome.unavailable();
  }
}

/// 一次选人的结果。
///
/// 与协议层的 [AiSpeakerDecision] 分开：决定是模型给的，而"没有可用决定时这一
/// 步该怎么办"由客户端判断，两者的处置完全不同。
enum _SpeakerPickStatus {
  /// 拿到了可用决定（可能是选中某人，也可能是模型要求结束本轮）。
  decided,

  /// 可降级的失败：未配置、引用失效、凭据缺失、超时、断网、空响应、非法响应、
  /// 指向不存在的成员。调用方改用本地编排器完成这一步。
  unavailable,

  /// 这一轮必须结束，且**不得**降级成本地选人：被治理网关硬拒（预算 / 权限），
  /// 或这次请求在飞行途中被我们自己取消（离页、进后台、停止）。
  endRound,
}

class _SpeakerPickOutcome {
  final _SpeakerPickStatus status;
  final AiSpeakerDecision? decision;

  const _SpeakerPickOutcome._(this.status, this.decision);

  const _SpeakerPickOutcome.decided(AiSpeakerDecision decision)
      : this._(_SpeakerPickStatus.decided, decision);

  const _SpeakerPickOutcome.unavailable()
      : this._(_SpeakerPickStatus.unavailable, null);

  const _SpeakerPickOutcome.endRound()
      : this._(_SpeakerPickStatus.endRound, null);
}

/// 一步选人的结果：发言者及其针对其可见最新对话算出的发言意图。
///
/// 意图与发言者一起返回，避免"换了发言人却沿用另一位角色的动作/对象/语气"。
class _SelectedSpeaker {
  final AICharacter character;
  final ReplyIntent intent;

  const _SelectedSpeaker(this.character, this.intent);
}
