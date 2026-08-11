import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/chat_group/user_message_sentiment.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/memory/memory_conflict_resolver.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/features/memory/observation_retry_queue.dart';
import 'package:chat_group/features/memory/relationship_event_service.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/services/chat_api_service.dart';

export 'memory_conflict_resolver.dart';

// ── 触发器结果 ───────────────────────────────────────────────────

/// 记忆触发器的确定性结果。
///
/// 在调用 LLM 之前先用本地规则判断是否需要进入提炼流程。
/// 显式记忆词即使没有 API 也会强制创建本地记录。
class MemoryTriggerResult {
  /// 是否触发了强制记忆（"记住/永久"等关键词命中）。
  final bool forceMemory;

  /// 是否触发了遗忘意图（"忘记/别记"等关键词命中）。
  final bool forceForget;

  /// 是否需要常规提炼（情绪转折、关系事件、承诺等）。
  final bool needsDistillation;

  /// 用户消息的情感分析结果。
  final UserMessageSentiment? sentiment;

  /// 触发关键词（用于调试）。
  final String? triggeredKeyword;

  const MemoryTriggerResult({
    this.forceMemory = false,
    this.forceForget = false,
    this.needsDistillation = false,
    this.sentiment,
    this.triggeredKeyword,
  });

  bool get isEmpty => !forceMemory && !forceForget && !needsDistillation;
}

// ── 主服务 ───────────────────────────────────────────────────────

/// 统一全局永久记忆观察入口。
///
/// 所有普通、自动、主动、群聊、私聊消息在成功落库后调用此入口。
/// 即使 LLM 失败也不影响聊天流程。
class ObservationEntry {
  final DatabaseService db;
  final AiRequestGateway gateway;
  final ApiCredentialResolver credentialResolver;
  final MemoryConflictResolver conflictResolver;
  final ObservationRetryQueue retryQueue;

  ObservationEntry({
    required this.db,
    ChatApiService? chatApi,
    ApiCredentialResolver? credentialResolver,
  })  : gateway = AiRequestGateway(
          store: AiGovernanceStore.forDatabase(db),
          client: chatApi,
        ),
        credentialResolver =
            credentialResolver ?? SecureApiCredentialResolver(),
        conflictResolver = MemoryConflictResolver(db),
        retryQueue = ObservationRetryQueue(db);

  // ── 确定性触发器关键词 ──────────────────────────────────────────

  static const _forceMemoryPatterns = <String>[
    '记住',
    '记忆',
    '记得',
    '别忘',
    '不要忘',
    '永久',
    '一直记着',
    '牢记',
    '记下来',
    '记好',
    '不要忘记',
  ];

  static const _forceForgetPatterns = <String>[
    '忘记',
    '别记',
    '不要记住',
    '删除记忆',
    '忘掉',
    '不记得',
    '忘了',
  ];

  static const _commitmentPatterns = <String>[
    '我保证',
    '我承诺',
    '答应你',
    '一定',
    '保证',
    '发誓',
    '说到做到',
    '绝不会',
    '我发誓',
    '担保',
  ];

  static const _identityPatterns = <String>[
    '我叫',
    '我是',
    '我的名字',
    '我来自',
    '我在',
    '我的职业',
    '我今年',
    '我岁',
    '我的生日',
    '我住在',
  ];

  static const _preferencePatterns = <String>[
    '喜欢',
    '偏好',
    '不喜欢',
    '讨厌',
    '爱吃',
    '爱好',
    '习惯',
    '更喜欢',
    '最喜欢',
  ];

  static const _highImpactPatterns = <String>[
    '攻击',
    '冒犯',
    '侮辱',
    '背叛',
    '站队',
    '支持',
    '保护',
    '安慰',
    '信任',
    '怀疑',
  ];

  // ── 主入口 ─────────────────────────────────────────────────────

  /// 新消息落库后的统一观察入口。
  ///
  /// [visibleCharacterIds] 消息发送时在场/可见的 AI 角色 ID 列表。
  /// [conversationNameSnapshot] 用于来源追溯（删除/改名后仍能识别场合）。
  /// [userProfile] 用户人物卡（用于检测与 LLM 记忆的冲突）。
  Future<void> observeMessage({
    required Message message,
    required List<String> visibleCharacterIds,
    required String conversationId,
    required String conversationNameSnapshot,
    required List<AICharacter> allCharacters,
    required bool isGroupChat,
    UserProfile? userProfile,
  }) async {
    await observeDeterministic(
      message: message,
      visibleCharacterIds: visibleCharacterIds,
      conversationId: conversationId,
      conversationNameSnapshot: conversationNameSnapshot,
      allCharacters: allCharacters,
    );
    await distillMessage(
      message: message,
      conversationId: conversationId,
      conversationNameSnapshot: conversationNameSnapshot,
      allCharacters: allCharacters,
      isGroupChat: isGroupChat,
      userProfile: userProfile,
    );
  }

  /// 完成不依赖网络的记忆、遗忘和关系写入。
  ///
  /// 消息生产入口必须等待此方法；只有 [distillMessage] 可以后台执行。
  Future<void> observeDeterministic({
    required Message message,
    required List<String> visibleCharacterIds,
    required String conversationId,
    required String conversationNameSnapshot,
    required List<AICharacter> allCharacters,
  }) async {
    if (message.senderType != 'user' && message.senderType != 'ai') return;

    // 确保 visibleToCharacterIds 已设置。
    if (message.visibleToCharacterIds.isEmpty) {
      message.visibleToCharacterIds = List<String>.from(visibleCharacterIds);
      await db.messageBox.put(message.id, message);
    }

    final triggerResult = _runTriggers(
      message,
      allowExplicitCommands: message.senderType == 'user',
    );
    final observers = message.visibleToCharacterIds;

    // 真人显式记住/忘记是本地确定性操作，不受普通自动记忆开关影响。
    if (triggerResult.forceMemory && observers.isNotEmpty) {
      await _createExplicitMemoryInstruction(
        message: message,
        observers: observers,
        conversationId: conversationId,
        conversationNameSnapshot: conversationNameSnapshot,
      );
    }
    if (triggerResult.forceForget && observers.isNotEmpty) {
      await _handleForgetIntent(
        message: message,
        observers: observers,
      );
      return;
    }

    if (!MemoryControls(db).automaticMemoryEnabled) return;

    if (message.senderType == 'user' && message.content.trim().isNotEmpty) {
      final sentiment = UserMessageSentimentAnalyzer.analyze(message.content);
      await Future.wait([
        for (final observerId in message.visibleToCharacterIds)
          RelationshipEventService(db)
              .observeAndApply(
                sourceCharacterId: observerId,
                targetId: 'user',
                targetType: RelationshipTargetType.user,
                message: message,
                conversationId: conversationId,
                conversationNameSnapshot: conversationNameSnapshot,
                allCharacters: allCharacters,
                userSentiment: sentiment,
              )
              .catchError((_) => false),
      ]);
    }
  }

  /// 执行可能访问 LLM 的永久记忆提炼；失败由持久化重试队列接管。
  Future<void> distillMessage({
    required Message message,
    required String conversationId,
    required String conversationNameSnapshot,
    required List<AICharacter> allCharacters,
    required bool isGroupChat,
    UserProfile? userProfile,
  }) async {
    if (message.senderType != 'user' && message.senderType != 'ai') return;
    if (!MemoryControls(db).automaticMemoryEnabled) return;

    final triggerResult = _runTriggers(
      message,
      allowExplicitCommands: message.senderType == 'user',
    );
    if (triggerResult.forceForget) return;

    final observers = message.visibleToCharacterIds;

    if (triggerResult.isEmpty) return;
    if (observers.isEmpty) return;

    // 需要 LLM 提炼。
    if (triggerResult.needsDistillation || triggerResult.forceMemory) {
      await _enqueueDistillation(
        message: message,
        observers: observers,
        conversationId: conversationId,
        conversationNameSnapshot: conversationNameSnapshot,
        allCharacters: allCharacters,
        isGroupChat: isGroupChat,
        sentiment: triggerResult.sentiment,
        forceMemory: triggerResult.forceMemory,
        userProfile: userProfile,
      );
    }
  }

  // ── 确定性触发器 ───────────────────────────────────────────────

  MemoryTriggerResult _runTriggers(
    Message message, {
    required bool allowExplicitCommands,
  }) {
    final content = message.content.trim();
    if (content.isEmpty) return const MemoryTriggerResult();

    final lower = content.toLowerCase();

    // 1. 遗忘/否定意图检测（必须在强制记忆之前，否则"不要记住"会被匹配为"记住"）。
    if (allowExplicitCommands) {
      for (final pattern in _forceForgetPatterns) {
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
      for (final pattern in _forceMemoryPatterns) {
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

    if (_commitmentPatterns.any(lower.contains)) {
      needsDistillation = true;
      triggeredKeyword = '承诺';
    }
    if (_identityPatterns.any(lower.contains)) {
      needsDistillation = true;
      triggeredKeyword ??= '身份';
    }
    if (_preferencePatterns.any(lower.contains)) {
      needsDistillation = true;
      triggeredKeyword ??= '偏好';
    }
    if (_highImpactPatterns.any(lower.contains)) {
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

  ApiConfig? _resolveConfig(AICharacter character) {
    if (character.apiConfigId.isEmpty) return null;
    return db.apiConfigBox.get(character.apiConfigId);
  }

  String _explicitMemoryId({
    required String observerId,
    required String conversationId,
    required String messageId,
  }) =>
      'explicit:$observerId:$conversationId:$messageId';

  MemoryKind? _parseKind(Object? raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'fact':
        return MemoryKind.fact;
      case 'preference':
        return MemoryKind.preference;
      case 'commitment':
        return MemoryKind.commitment;
      case 'sharedExperience':
        return MemoryKind.sharedExperience;
      case 'relationshipNote':
        return MemoryKind.relationshipNote;
      case 'personaGrowth':
        return MemoryKind.personaGrowth;
      case 'explicitInstruction':
        return MemoryKind.explicitInstruction;
      default:
        return null;
    }
  }

  List<String>? _parseSubjectIds(Object? raw, List<String> visibleIds) {
    if (raw is! List) return null;
    final result = <String>[];
    for (final item in raw) {
      if (item is! String) return null;
      final id = item.trim();
      if (id.isEmpty) return null;
      if (id == 'user') {
        if (!result.contains('user')) result.add('user');
      } else if (visibleIds.contains(id)) {
        if (!result.contains(id)) result.add(id);
      } else {
        return null;
      }
    }
    return result;
  }

  MemoryOriginType _originTypeForConversation(String conversationId) {
    if (DirectChatSession.isDirectConversationId(conversationId)) {
      return MemoryOriginType.direct;
    }
    return MemoryOriginType.group;
  }
}
