part of 'observation_entry.dart';

extension ObservationEntryRetry on ObservationEntry {
  Future<ConflictResult> handleMemoryConflict({
    required String observerId,
    required MemoryKind kind,
    required String content,
    required List<String> subjectIds,
    required String conversationId,
    required List<String> participants,
    UserProfile? userProfile,
  }) =>
      conflictResolver.resolve(
        observerId: observerId,
        kind: kind,
        content: content,
        subjectIds: subjectIds,
        userProfile: userProfile,
      );

  // ── 重试队列 ───────────────────────────────────────────────────

  Future<void> _enqueueRetry({
    required Message message,
    required String observerId,
    required String conversationId,
    required String conversationNameSnapshot,
    bool forceMemory = false,
  }) async {
    await retryQueue.enqueue(
      messageId: message.id,
      observerId: observerId,
      conversationId: conversationId,
      conversationNameSnapshot: conversationNameSnapshot,
      forceMemory: forceMemory,
    );
  }

  List<dynamic> loadRetryQueue() {
    return retryQueue.load();
  }

  /// 处理重试队列中的待提炼任务。
  ///
  /// 通常在应用启动或空闲时调用。每次最多处理 [maxBatch] 条。
  Future<int> processRetryQueue({
    int maxBatch = 5,
    List<AICharacter>? allCharacters,
  }) async {
    if (!MemoryControls(db).automaticMemoryEnabled) return 0;
    return retryQueue.process(
      maxBatch: maxBatch,
      allCharacters: allCharacters,
      processItem: _processRetryTask,
    );
  }

  Future<RetryTaskOutcome> _processRetryTask({
    required Map<String, dynamic> item,
    required Map<String, AICharacter> charactersById,
  }) async {
    if (!MemoryControls(db).automaticMemoryEnabled) {
      return RetryTaskOutcome.keep;
    }
    final messageId = (item['messageId'] ?? '') as String;
    final conversationId = (item['conversationId'] ?? '') as String;
    final observerId = (item['observerId'] ?? '') as String;
    final message = db.messageBox.get(messageId);
    if (message == null) return RetryTaskOutcome.drop;

    final character = charactersById[observerId];
    if (character == null) return RetryTaskOutcome.drop;

    final config = _resolveConfig(character);
    if (config == null) return RetryTaskOutcome.keep;

    try {
      final apiKey = await credentialResolver.resolve(config);
      if (apiKey == null) return RetryTaskOutcome.retry;
      if (!message.visibleToCharacterIds.contains(observerId)) {
        return RetryTaskOutcome.drop;
      }

      final forceMemory = item['forceMemory'] == true;
      final provider = ApiProvider.values.firstWhere(
        (p) => p.name == config.provider,
        orElse: () => ApiProvider.deepseek,
      );
      final prompt = _buildDistillationPrompt(
        character: character,
        message: message,
        isGroupChat: !DirectChatSession.isDirectConversationId(conversationId),
        allCharacters: charactersById.values.toList(),
        sentiment: message.senderType == 'user'
            ? UserMessageSentimentAnalyzer.analyze(message.content)
            : null,
        forceMemory: forceMemory,
      );
      final result = await gateway.sendChatMessage(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        messages: prompt,
        temperature: 0.3,
        purpose: AiRequestPurpose.summary,
        conversationId: 'memory_retry:$conversationId',
        characterId: observerId,
      );
      if (!(result['success'] ?? false)) return RetryTaskOutcome.retry;

      final raw = result['message']?.toString().trim() ?? '';
      if (raw.isEmpty) return RetryTaskOutcome.retry;

      final success = await _processDistillationResult(
        raw: raw,
        observerId: observerId,
        message: message,
        conversationId: conversationId,
        conversationNameSnapshot:
            (item['conversationNameSnapshot'] as String?) ?? '',
        visibleCharacterIds: message.visibleToCharacterIds,
        allCharacters: charactersById.values.toList(),
        forceMemory: forceMemory,
        userProfile: db.userProfileBox.get('me'),
      );
      return success ? RetryTaskOutcome.completed : RetryTaskOutcome.retry;
    } on Object {
      return RetryTaskOutcome.retry;
    }
  }

  // ── 辅助方法 ───────────────────────────────────────────────────
}
