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

part 'observation_entry_triggers.dart';
part 'observation_entry_distillation.dart';
part 'observation_entry_retry.dart';
part 'observation_entry_helpers.dart';

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

    // 群聊中的 AI 发言是其他在场 AI 建立相互记忆的唯一输入。即使文本
    // 没有命中用户侧关键词，也交给提炼模型判断是否值得保留；私聊不变。
    final isAiMessageVisibleToAnotherAi = isGroupChat &&
        message.senderType == 'ai' &&
        observers.any((observerId) => observerId != message.senderId);
    if (triggerResult.isEmpty && !isAiMessageVisibleToAnotherAi) return;
    if (observers.isEmpty) return;

    // 需要 LLM 提炼。
    if (triggerResult.needsDistillation ||
        triggerResult.forceMemory ||
        isAiMessageVisibleToAnotherAi) {
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
}
