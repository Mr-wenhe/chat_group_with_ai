part of 'observation_entry.dart';

extension _ObservationEntryTriggers on ObservationEntry {
  MemoryTriggerResult _runTriggers(
    Message message, {
    required bool allowExplicitCommands,
  }) {
    final content = message.content.trim();
    if (content.isEmpty) return const MemoryTriggerResult();

    final lower = content.toLowerCase();

    // 1. 遗忘/否定意图检测（必须在强制记忆之前，否则"不要记住"会被匹配为"记住"）。
    if (allowExplicitCommands) {
      for (final pattern in ObservationEntry._forceForgetPatterns) {
        if (lower.contains(pattern)) {
          return MemoryTriggerResult(
            forceForget: true,
            triggeredKeyword: pattern,
          );
        }
      }
    }

    // 2. 强制记忆词检测。
    if (allowExplicitCommands) {
      for (final pattern in ObservationEntry._forceMemoryPatterns) {
        if (lower.contains(pattern)) {
          return MemoryTriggerResult(
            forceMemory: true,
            needsDistillation: true,
            triggeredKeyword: pattern,
          );
        }
      }
    }

    // 3. 情感分析。
    final sentiment = UserMessageSentimentAnalyzer.analyze(content);

    // 4. 重大承诺 / 身份信息 / 高关系影响行为。
    bool needsDistillation = false;
    String? triggeredKeyword;

    if (ObservationEntry._commitmentPatterns.any(lower.contains)) {
      needsDistillation = true;
      triggeredKeyword = '承诺';
    }
    if (ObservationEntry._identityPatterns.any(lower.contains)) {
      needsDistillation = true;
      triggeredKeyword ??= '身份';
    }
    if (ObservationEntry._preferencePatterns.any(lower.contains)) {
      needsDistillation = true;
      triggeredKeyword ??= '偏好';
    }
    if (ObservationEntry._highImpactPatterns.any(lower.contains)) {
      needsDistillation = true;
      triggeredKeyword ??= '高影响行为';
    }

    // 5. 显著情绪变化。
    if (sentiment.isEmotional && sentiment.severity >= 1) {
      needsDistillation = true;
      triggeredKeyword ??= '情绪转折';
    }

    return MemoryTriggerResult(
      forceMemory: false,
      forceForget: false,
      needsDistillation: needsDistillation,
      sentiment: sentiment,
      triggeredKeyword: triggeredKeyword,
    );
  }

  // ── 显式记忆指令（本地落库，无需 API） ─────────────────────────

  Future<void> _createExplicitMemoryInstruction({
    required Message message,
    required List<String> observers,
    required String conversationId,
    required String conversationNameSnapshot,
  }) async {
    final now = DateTime.now();
    for (final observerId in observers) {
      final stableId = _explicitMemoryId(
        observerId: observerId,
        conversationId: conversationId,
        messageId: message.id,
      );
      if (db.permanentMemoryBox.containsKey(stableId)) continue;
      // 幂等：同一条消息不重复创建。
      final existing = db.permanentMemoryBox.values.any(
        (m) =>
            m.observerCharacterId == observerId &&
            m.kind == MemoryKind.explicitInstruction &&
            m.status == MemoryStatus.active &&
            m.originConversationId == conversationId &&
            m.sourceMessageIds.contains(message.id),
      );
      if (existing) continue;

      final memory = PermanentMemory(
        id: stableId,
        observerCharacterId: observerId,
        kind: MemoryKind.explicitInstruction,
        content: message.content,
        status: MemoryStatus.active,
        importance: 80,
        confidence: 1.0,
        explicitlyRequested: true,
        pinned: true,
        originType: _originTypeForConversation(conversationId),
        originConversationId: conversationId,
        originNameSnapshot: conversationNameSnapshot,
        sourceMessageIds: [message.id],
        subjectIds: const ['user'],
        participantIds: observers,
        occurredAt: message.timestamp,
        createdAt: now,
        updatedAt: now,
      );
      await db.permanentMemoryBox.put(memory.id, memory);
    }
  }

  // ── 遗忘意图处理 ───────────────────────────────────────────────

  Future<void> _handleForgetIntent({
    required Message message,
    required List<String> observers,
  }) async {
    // 提取遗忘关键词：从消息中去除常见的遗忘前缀后取剩余内容。
    final forgetPrefixPatterns = <String>[
      '忘记',
      '忘掉',
      '不要记住',
      '别记',
      '删除记忆',
      '不记得',
      '忘了',
    ];
    var content = message.content;
    for (final prefix in forgetPrefixPatterns) {
      if (content.contains(prefix)) {
        content = content.replaceFirst(prefix, '').trim();
        break;
      }
    }
    content = _normalizeForgetContent(content);
    if (content.isEmpty) return;

    final related = db.permanentMemoryBox.values.where((m) {
      // 场合只是来源证据；真人明确遗忘应作用于该观察者的全局记忆。
      if (!observers.contains(m.observerCharacterId)) return false;
      if (m.status != MemoryStatus.active) return false;

      // 只失效内容相符的记忆；遗忘前缀本身不能扩大为全局清除。
      final memoryContent = _normalizeForgetContent(m.content);
      return m.content.contains(content) ||
          content.contains(m.content) ||
          memoryContent.contains(content) ||
          content.contains(memoryContent);
    }).toList();

    final now = DateTime.now();
    for (final memory in related) {
      final updated = PermanentMemory(
        id: memory.id,
        observerCharacterId: memory.observerCharacterId,
        kind: memory.kind,
        content: memory.content,
        subjectIds: memory.subjectIds,
        status: MemoryStatus.invalidated,
        importance: memory.importance,
        confidence: memory.confidence,
        explicitlyRequested: memory.explicitlyRequested,
        pinned: memory.pinned,
        supersedesIds: memory.supersedesIds,
        originType: memory.originType,
        originConversationId: memory.originConversationId,
        originNameSnapshot: memory.originNameSnapshot,
        sourceMessageIds: memory.sourceMessageIds,
        participantIds: memory.participantIds,
        occurredAt: memory.occurredAt,
        createdAt: memory.createdAt,
        updatedAt: now,
        invalidationReason: MemoryConflictResolver.userForgetReason,
      );
      await db.permanentMemoryBox.put(updated.id, updated);
    }
  }

  /// Makes user-facing forget commands comparable with normalized memory text.
  String _normalizeForgetContent(String value) => value
      .replaceAll('我的', '用户的')
      .replaceAll('我', '用户')
      .replaceAll(RegExp(r'(这|那)(件|个)事'), '')
      .replaceAll(RegExp(r'[，。！？、,.!?；;：:"「」『』【】]'), '')
      .trim();

  // ── LLM 提炼排队 ───────────────────────────────────────────────
}
