part of 'observation_entry.dart';

extension _ObservationEntryDistillation on ObservationEntry {
  Future<void> _enqueueDistillation({
    required Message message,
    required List<String> observers,
    required String conversationId,
    required String conversationNameSnapshot,
    required List<AICharacter> allCharacters,
    required bool isGroupChat,
    UserMessageSentiment? sentiment,
    bool forceMemory = false,
    UserProfile? userProfile,
  }) async {
    final charactersById = {for (final c in allCharacters) c.id: c};

    for (final observerId in observers) {
      final character = charactersById[observerId];
      if (character == null) continue;

      final config = _resolveConfig(character);
      if (config == null) {
        await _enqueueRetry(
          message: message,
          observerId: observerId,
          conversationId: conversationId,
          conversationNameSnapshot: conversationNameSnapshot,
          forceMemory: forceMemory,
        );
        continue;
      }

      try {
        final apiKey = await credentialResolver.resolve(config);
        if (apiKey == null) {
          await _enqueueRetry(
            message: message,
            observerId: observerId,
            conversationId: conversationId,
            conversationNameSnapshot: conversationNameSnapshot,
            forceMemory: forceMemory,
          );
          continue;
        }

        final prompt = _buildDistillationPrompt(
          character: character,
          message: message,
          isGroupChat: isGroupChat,
          allCharacters: allCharacters,
          sentiment: sentiment,
          forceMemory: forceMemory,
        );

        final provider = ApiProvider.values.firstWhere(
          (p) => p.name == config.provider,
          orElse: () => ApiProvider.deepseek,
        );

        final result = await gateway.sendChatMessage(
          apiKey: apiKey,
          provider: provider,
          apiProtocol: config.protocol,
          customBaseUrl: config.customBaseUrl,
          model: config.modelName,
          messages: prompt,
          temperature: 0.3,
          purpose: AiRequestPurpose.summary,
          conversationId: 'memory_distill:$conversationId',
          characterId: observerId,
        );

        if (!(result['success'] ?? false)) {
          throw StateError('LLM distillation failed');
        }

        final raw = result['message']?.toString().trim() ?? '';
        if (raw.isEmpty) {
          await _enqueueRetry(
            message: message,
            observerId: observerId,
            conversationId: conversationId,
            conversationNameSnapshot: conversationNameSnapshot,
            forceMemory: forceMemory,
          );
          continue;
        }

        final success = await _processDistillationResult(
          raw: raw,
          observerId: observerId,
          message: message,
          conversationId: conversationId,
          conversationNameSnapshot: conversationNameSnapshot,
          visibleCharacterIds: message.visibleToCharacterIds,
          allCharacters: allCharacters,
          forceMemory: forceMemory,
          userProfile: userProfile,
        );
        if (!success) {
          await _enqueueRetry(
            message: message,
            observerId: observerId,
            conversationId: conversationId,
            conversationNameSnapshot: conversationNameSnapshot,
            forceMemory: forceMemory,
          );
        }
      } on Object {
        await _enqueueRetry(
          message: message,
          observerId: observerId,
          conversationId: conversationId,
          conversationNameSnapshot: conversationNameSnapshot,
          forceMemory: forceMemory,
        );
      }
    }
  }

  /// 构建 LLM 提炼 prompt。
  List<Map<String, dynamic>> _buildDistillationPrompt({
    required AICharacter character,
    required Message message,
    required bool isGroupChat,
    required List<AICharacter> allCharacters,
    UserMessageSentiment? sentiment,
    bool forceMemory = false,
  }) {
    final originLabel = isGroupChat ? '群聊' : '私聊';
    final visibleCharacters = allCharacters
        .where(
            (candidate) => message.visibleToCharacterIds.contains(candidate.id))
        .toList();
    final visibleAiMap = visibleCharacters.isEmpty
        ? '（无可见 AI）'
        : visibleCharacters.map((c) => '${c.name} → ${c.id}').join('、');
    final sender = message.senderType == 'user'
        ? '用户（ID:user）'
        : '${allCharacters.where((c) => c.id == message.senderId).firstOrNull?.name ?? "未知 AI"}（ID:${message.senderId}）';
    final sentimentLabel =
        message.senderType == 'user' ? '用户情感分析' : 'AI 发言情感分析';
    final sentimentHint =
        sentiment != null ? '\n\n$sentimentLabel：${sentiment.description}' : '';

    final forceHint =
        forceMemory ? '\n\n注意：用户明确说了"记住/永久"等词，这条内容必须作为永久记忆保存。' : '';

    return [
      {
        'role': 'system',
        'content': '你是${character.name}的记忆整理助手。'
            '当前观察者是${character.name}（ID:${character.id}）。'
            '你的任务是从对话中提取值得长期记住的内容，以严格 JSON 输出。'
            '只输出 JSON，不要 Markdown，不要解释。',
      },
      {
        'role': 'user',
        'content': '你在$originLabel中观察到以下消息：\n\n'
            '实际发言者是$sender，说：${message.content}\n'
            '本条消息可见的 AI 名称 → ID 映射：$visibleAiMap\n'
            '$sentimentHint$forceHint\n\n'
            '请输出 JSON 数组，每条记忆包含：'
            '{"kind":"fact|preference|commitment|sharedExperience|relationshipNote|personaGrowth|explicitInstruction",'
            '"content":"简洁记忆正文","subjectIds":["user"或AI ID],"importance":0-100,"confidence":0-1}'
            '\n\nAI 消息的实际发言者 ID 是 ${message.senderId}；请根据记忆内容选择 subjectIds，'
            '不要仅因观察者身份强行添加主体。subjectIds 只能使用上面的 user 或 AI ID。'
            '\n只提取值得长期记住的内容；普通寒暄不保存。'
            '\n如果这条消息不值得记住，输出空数组 []。',
      },
    ];
  }

  // ── 提炼结果处理（校验、冲突、去重） ───────────────────────────

  Future<bool> _processDistillationResult({
    required String raw,
    required String observerId,
    required Message message,
    required String conversationId,
    required String conversationNameSnapshot,
    required List<String> visibleCharacterIds,
    required List<AICharacter> allCharacters,
    bool forceMemory = false,
    UserProfile? userProfile,
  }) async {
    final List<dynamic> parsed;
    try {
      final decoded = jsonDecode(raw.trim());
      if (decoded is! List) return false;
      parsed = decoded;
    } on Object {
      return false;
    }

    if (parsed.isEmpty) return !forceMemory;

    final now = DateTime.now();
    final participants = message.visibleToCharacterIds;
    var validItemCount = 0;
    final explicitId = forceMemory
        ? _explicitMemoryId(
            observerId: observerId,
            conversationId: conversationId,
            messageId: message.id,
          )
        : null;

    for (final item in parsed) {
      if (item is! Map<String, dynamic>) continue;

      final kind = _parseKind(item['kind']);
      if (kind == null) continue;

      final contentValue = item['content'];
      if (contentValue is! String || contentValue.trim().isEmpty) continue;
      final subjectIds = _parseSubjectIds(
        item['subjectIds'],
        visibleCharacterIds,
      );
      if (subjectIds == null ||
          (subjectIds.isEmpty && kind != MemoryKind.personaGrowth)) {
        continue;
      }
      final importanceValue = item['importance'];
      final confidenceValue = item['confidence'];
      if (importanceValue is! num || confidenceValue is! num) continue;
      final importance = importanceValue.round().clamp(0, 100).toInt();
      final confidence = confidenceValue.toDouble().clamp(0.0, 1.0).toDouble();
      final content = contentValue.trim();
      validItemCount++;

      // 冲突处理。
      final conflictResult = await handleMemoryConflict(
        observerId: observerId,
        kind: kind,
        content: content,
        subjectIds: subjectIds,
        conversationId: conversationId,
        participants: participants,
        userProfile: userProfile,
      );

      if (conflictResult.action == ConflictAction.duplicate) continue;

      final memory = PermanentMemory(
        observerCharacterId: observerId,
        kind: kind,
        content: content,
        subjectIds: subjectIds,
        status: conflictResult.action == ConflictAction.profileOverride
            ? MemoryStatus.invalidated
            : MemoryStatus.active,
        importance: importance,
        confidence: confidence,
        explicitlyRequested: forceMemory,
        pinned: forceMemory,
        originType: _originTypeForConversation(conversationId),
        originConversationId: conversationId,
        originNameSnapshot: conversationNameSnapshot,
        sourceMessageIds: [message.id],
        participantIds: participants,
        occurredAt: message.timestamp,
        createdAt: now,
        updatedAt: now,
        invalidationReason:
            conflictResult.action == ConflictAction.profileOverride
                ? MemoryConflictResolver.profileOverrideReason
                : null,
      );

      if (explicitId != null) {
        memory.supersedesIds = [explicitId];
      }
      if (conflictResult.supersededIds.isNotEmpty) {
        memory.supersedesIds = {
          ...memory.supersedesIds,
          ...conflictResult.supersededIds,
        }.toList();
      }

      await db.permanentMemoryBox.put(memory.id, memory);

      // profile override 是审计性失效；普通 supersede 才改变为 superseded。
      final replacementStatus =
          conflictResult.action == ConflictAction.profileOverride
              ? MemoryStatus.invalidated
              : MemoryStatus.superseded;
      for (final oldId in conflictResult.supersededIds) {
        final old = db.permanentMemoryBox.get(oldId);
        if (old == null || old.pinned || old.status != MemoryStatus.active) {
          continue;
        }
        final updated = PermanentMemory(
          id: old.id,
          observerCharacterId: old.observerCharacterId,
          kind: old.kind,
          content: old.content,
          subjectIds: old.subjectIds,
          status: replacementStatus,
          importance: old.importance,
          confidence: old.confidence,
          explicitlyRequested: old.explicitlyRequested,
          pinned: old.pinned,
          supersedesIds: old.supersedesIds,
          originType: old.originType,
          originConversationId: old.originConversationId,
          originNameSnapshot: old.originNameSnapshot,
          sourceMessageIds: old.sourceMessageIds,
          participantIds: old.participantIds,
          occurredAt: old.occurredAt,
          createdAt: old.createdAt,
          updatedAt: now,
          invalidationReason: replacementStatus == MemoryStatus.invalidated
              ? MemoryConflictResolver.profileOverrideReason
              : old.invalidationReason,
        );
        await db.permanentMemoryBox.put(updated.id, updated);
      }
    }
    return validItemCount > 0;
  }

  // ── 冲突处理 ───────────────────────────────────────────────────
}
