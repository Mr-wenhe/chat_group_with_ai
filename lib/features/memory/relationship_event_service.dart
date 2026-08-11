import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/user_message_sentiment.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/features/memory/relationship_direction_lock.dart';

/// Persists the direct relation and all visible bystander projections.
///
/// Callers await this boundary so deterministic relationship writes finish
/// before the surrounding reply round is considered complete.
Future<void> persistRelationshipEvents({
  required RelationshipEventService service,
  required String sourceCharacterId,
  required String targetId,
  required RelationshipTargetType targetType,
  required Message message,
  required String conversationId,
  required String conversationNameSnapshot,
  required List<AICharacter> allCharacters,
  required List<String> visibleCharacterIds,
  UserMessageSentiment? userSentiment,
}) async {
  final writes = <Future<bool>>[
    service
        .observeAndApply(
          sourceCharacterId: sourceCharacterId,
          targetId: targetId,
          targetType: targetType,
          message: message,
          conversationId: conversationId,
          conversationNameSnapshot: conversationNameSnapshot,
          allCharacters: allCharacters,
          userSentiment: userSentiment,
        )
        .catchError((_) => false),
  ];
  for (final observerId in visibleCharacterIds) {
    if (observerId == sourceCharacterId) continue;
    writes.add(
      service
          .observeAndApply(
            sourceCharacterId: observerId,
            targetId: sourceCharacterId,
            targetType: RelationshipTargetType.ai,
            message: message,
            conversationId: conversationId,
            conversationNameSnapshot: conversationNameSnapshot,
            allCharacters: allCharacters,
            userSentiment: userSentiment,
            isBystander: observerId != targetId,
          )
          .catchError((_) => false),
    );
  }
  await Future.wait(writes);
}

/// 关系变化描述。
class RelationshipDelta {
  final int affinityDelta;
  final int trustDelta;
  final int frictionDelta;
  final int familiarityDelta;
  final RelationshipMood targetMood;
  final String reason;
  final double confidence;

  const RelationshipDelta({
    this.affinityDelta = 0,
    this.trustDelta = 0,
    this.frictionDelta = 0,
    this.familiarityDelta = 0,
    required this.targetMood,
    required this.reason,
    this.confidence = 0.7,
  });
}

/// 关系快照的 After 值。
class _AfterSnapshot {
  final int affinity;
  final int trust;
  final int friction;
  final int familiarity;
  final RelationshipMood mood;
  final RelationshipStage stage;

  const _AfterSnapshot({
    required this.affinity,
    required this.trust,
    required this.friction,
    required this.familiarity,
    required this.mood,
    required this.stage,
  });
}

/// 关系事件服务。
///
/// 负责：
/// 1. 根据消息和触发条件生成方向性 RelationshipEvent
/// 2. 幂等更新 RelationshipState 当前快照（绝对 After 值，不是 delta）
/// 3. 阶段防跳变和 romantic 语义约束
class RelationshipEventService {
  final DatabaseService db;

  RelationshipEventService(this.db);

  /// Applies the default directional effects for a message created outside
  /// [ChatRoomPage] (for example a foreground proactive reply).
  Future<void> observeProactiveMessage({
    required Message message,
    required String conversationId,
    required String conversationNameSnapshot,
    required List<AICharacter> allCharacters,
  }) async {
    if (message.senderType != 'ai' || message.content.trim().isEmpty) return;
    final visibleIds = message.visibleToCharacterIds;
    final jobs = <Future<bool>>[];
    if (DirectChatSession.isDirectConversationId(conversationId)) {
      jobs.add(observeAndApply(
        sourceCharacterId: message.senderId,
        targetId: 'user',
        targetType: RelationshipTargetType.user,
        message: message,
        conversationId: conversationId,
        conversationNameSnapshot: conversationNameSnapshot,
        allCharacters: allCharacters,
        isBystander: false,
      ));
    } else {
      // 群聊主动消息只有明确 @ 到 AI 时才有可确认的直接目标；
      // 没有目标时不把群内发言伪造成对用户的关系变化。
      for (final targetId in message.mentionedAiIds) {
        if (!visibleIds.contains(targetId) || targetId == message.senderId) {
          continue;
        }
        jobs.add(observeAndApply(
          sourceCharacterId: message.senderId,
          targetId: targetId,
          targetType: RelationshipTargetType.ai,
          message: message,
          conversationId: conversationId,
          conversationNameSnapshot: conversationNameSnapshot,
          allCharacters: allCharacters,
          isBystander: false,
        ));
      }
    }
    for (final observerId in visibleIds) {
      if (observerId == message.senderId) continue;
      jobs.add(observeAndApply(
        sourceCharacterId: observerId,
        targetId: message.senderId,
        targetType: RelationshipTargetType.ai,
        message: message,
        conversationId: conversationId,
        conversationNameSnapshot: conversationNameSnapshot,
        allCharacters: allCharacters,
        isBystander: !message.mentionedAiIds.contains(observerId),
      ));
    }
    await Future.wait(jobs);
  }

  // ── 稳定 ID 生成 ─────────────────────────────────────────────────

  /// 为关系事件生成稳定 ID，保证重试幂等。
  ///
  /// 格式：`re:<source>:<targetType>:<target>:<messageId>`
  /// 使用完整的消息 ID，避免前 8 位碰撞导致事件被误判为重放。
  String _stableEventId({
    required String sourceCharacterId,
    required RelationshipTargetType targetType,
    required String targetId,
    required String messageId,
  }) {
    return 're:$sourceCharacterId:${targetType.name}:$targetId:$messageId';
  }

  // ── 事件创建 ─────────────────────────────────────────────────────

  /// 根据消息生成方向性关系事件并更新快照。
  ///
  /// [sourceCharacterId] — 事件发起方（在场 AI）。
  /// [targetId] / [targetType] — 事件接收方。
  /// [message] — 触发事件的消息。
  /// [conversationId] / [conversationNameSnapshot] — 来源场合。
  /// [allCharacters] — 用于参与者映射。
  /// [userSentiment] — 用户情感分析。
  /// [isBystander] — 是否为未直接承受/发起该事件的旁观者视角。
  ///
  /// 返回是否成功创建了新事件。
  Future<bool> observeAndApply({
    required String sourceCharacterId,
    required String targetId,
    required RelationshipTargetType targetType,
    required Message message,
    required String conversationId,
    required String conversationNameSnapshot,
    required List<AICharacter> allCharacters,
    UserMessageSentiment? userSentiment,
    bool isBystander = false,
  }) async {
    final stableId = RelationshipState.stableGlobalId(
      sourceCharacterId,
      targetType,
      targetId,
    );
    return RelationshipDirectionLock.run(
        db: db,
        relationshipId: stableId,
        action: () => _observeAndApplyLocked(
              sourceCharacterId: sourceCharacterId,
              targetId: targetId,
              targetType: targetType,
              message: message,
              conversationId: conversationId,
              conversationNameSnapshot: conversationNameSnapshot,
              allCharacters: allCharacters,
              userSentiment: userSentiment,
              isBystander: isBystander,
            ));
  }

  Future<bool> _observeAndApplyLocked({
    required String sourceCharacterId,
    required String targetId,
    required RelationshipTargetType targetType,
    required Message message,
    required String conversationId,
    required String conversationNameSnapshot,
    required List<AICharacter> allCharacters,
    UserMessageSentiment? userSentiment,
    required bool isBystander,
  }) async {
    if (sourceCharacterId == targetId) return false;

    // 旁观者关系：AI 对 AI 的行为，其他在场 AI 也能形成主观关系事件。
    final isWitnessing =
        message.visibleToCharacterIds.contains(sourceCharacterId);
    if (!isWitnessing) return false;

    // 查找或创建当前关系快照。
    final stableId = RelationshipState.stableGlobalId(
      sourceCharacterId,
      targetType,
      targetId,
    );

    final storedRelation = db.relationshipStateBox.get(stableId);
    var relation = storedRelation ??
        RelationshipState.global(
          sourceCharacterId: sourceCharacterId,
          targetType: targetType,
          targetId: targetId,
        );

    final eventId = _stableEventId(
      sourceCharacterId: sourceCharacterId,
      targetType: targetType,
      targetId: targetId,
      messageId: message.id,
    );
    final existingEvent = db.relationshipEventBox.get(eventId);
    final pendingEvents = db.relationshipEventBox.values
        .where(
          (event) =>
              event.sourceCharacterId == sourceCharacterId &&
              event.targetType == targetType &&
              event.targetId == targetId &&
              event.revision > relation.revision,
        )
        .toList()
      ..sort((a, b) => a.revision.compareTo(b.revision));
    var repairedPendingEvent = false;
    for (final pendingEvent in pendingEvents) {
      await _repairSnapshotFromEvent(relation, pendingEvent);
      relation = db.relationshipStateBox.get(stableId)!;
      repairedPendingEvent = true;
    }
    if (existingEvent != null) {
      return repairedPendingEvent;
    }

    if (!MemoryControls(db).canAutoUpdateRelationship(relation)) return false;

    // 计算变化量。
    final delta = _computeDelta(
      message: message,
      userSentiment: userSentiment,
      isGroupChat: !DirectChatSession.isDirectConversationId(conversationId),
      isBystander: isBystander,
    );

    // CAS 检查：重新读取快照，确认 revision 未被其他并发写入修改。
    final currentRelation = db.relationshipStateBox.get(stableId);
    if (currentRelation != null &&
        currentRelation.revision > relation.revision) {
      return false;
    }
    // 使用最新读取的快照（如果 CAS 通过，currentRelation 与 relation 一致）。
    if (currentRelation != null) relation = currentRelation;

    // 阶段防跳变：计算目标阶段并校验。
    final targetStage = _resolveStageTransition(
      currentStage: relation.stage,
      delta: delta,
    );

    // 构建绝对 After 快照。
    final afterSnapshot = _applyDelta(
      affinity: relation.affinity,
      trust: relation.trust,
      friction: relation.friction,
      familiarity: relation.familiarity,
      mood: relation.recentMood,
      stage: targetStage,
      delta: delta,
      isGroupChat: !DirectChatSession.isDirectConversationId(conversationId),
    );

    // 创建事件（存储绝对 After 快照）。
    final event = RelationshipEvent(
      id: eventId,
      sourceCharacterId: sourceCharacterId,
      targetType: targetType,
      targetId: targetId,
      reason: delta.reason,
      affinityBefore: relation.affinity,
      affinityAfter: afterSnapshot.affinity,
      trustBefore: relation.trust,
      trustAfter: afterSnapshot.trust,
      frictionBefore: relation.friction,
      frictionAfter: afterSnapshot.friction,
      familiarityBefore: relation.familiarity,
      familiarityAfter: afterSnapshot.familiarity,
      moodBefore: relation.recentMood,
      moodAfter: afterSnapshot.mood,
      stageBefore: relation.stage,
      stageAfter: afterSnapshot.stage,
      originConversationId: conversationId,
      originNameSnapshot: conversationNameSnapshot,
      sourceMessageIds: [message.id],
      notesBefore: relation.notes,
      notesAfter: relation.notes,
      revision: relation.revision + 1,
      occurredAt: message.timestamp,
      confidence: delta.confidence,
      createdBy: RelationshipEventCreator.automatic,
    );

    // 幂等更新关系快照（设置绝对 After 值）。
    final updatedRelation = RelationshipState(
      id: relation.id,
      groupId: 'global',
      sourceCharacterId: relation.sourceCharacterId,
      targetId: relation.targetId,
      targetType: relation.targetType,
      affinity: afterSnapshot.affinity,
      trust: afterSnapshot.trust,
      friction: afterSnapshot.friction,
      familiarity: afterSnapshot.familiarity,
      recentMood: afterSnapshot.mood,
      notes: relation.notes,
      lastInteractionAt: DateTime.now(),
      stage: afterSnapshot.stage,
      revision: relation.revision + 1,
      lastEventId: event.id,
      updatedAt: DateTime.now(),
    );

    // 先写事件，再更新快照（保证重放幂等）。
    await db.relationshipEventBox.put(event.id, event);
    await db.relationshipStateBox.put(updatedRelation.id, updatedRelation);

    return true;
  }

  Future<void> _repairSnapshotFromEvent(
    RelationshipState relation,
    RelationshipEvent event,
  ) async {
    final now = DateTime.now();
    final interactionAt = event.createdBy == RelationshipEventCreator.manual
        ? relation.lastInteractionAt
        : event.occurredAt;
    await db.relationshipStateBox.put(
      relation.id,
      RelationshipState(
        id: relation.id,
        groupId: 'global',
        sourceCharacterId: relation.sourceCharacterId,
        targetId: relation.targetId,
        targetType: relation.targetType,
        affinity: event.affinityAfter,
        trust: event.trustAfter,
        friction: event.frictionAfter,
        familiarity: event.familiarityAfter,
        recentMood: event.moodAfter,
        notes: _notesAfterReplay(relation, event),
        lastInteractionAt: interactionAt,
        stage: event.stageAfter,
        revision: event.revision,
        lastEventId: event.id,
        updatedAt: now,
      ),
    );
  }

  String _notesAfterReplay(
    RelationshipState relation,
    RelationshipEvent event,
  ) {
    // Automatic events created before notes auditing deserialize with an empty
    // After value and must not erase a newer manual note on the snapshot.
    if (event.createdBy == RelationshipEventCreator.automatic &&
        event.notesAfter.isEmpty) {
      return relation.notes;
    }
    return event.notesAfter;
  }

  // ── Delta 计算 ───────────────────────────────────────────────────

  RelationshipDelta _computeDelta({
    required Message message,
    required UserMessageSentiment? userSentiment,
    required bool isGroupChat,
    required bool isBystander,
  }) {
    final content = message.content.toLowerCase();
    String reason = '普通互动';
    int familiarityDelta = 1;
    int affinityDelta = 0;
    int trustDelta = 0;
    int frictionDelta = 0;
    RelationshipMood targetMood = RelationshipMood.neutral;
    double confidence = 0.5;

    // 高影响行为检测。明确的浪漫语义优先于通用情绪分类，避免“喜欢你”
    // 被只标记为友好互动而永远无法触发 romantic 阶段候选。
    if (_hasRomanticCue(content)) {
      affinityDelta = 12;
      trustDelta = 8;
      familiarityDelta = isGroupChat ? 3 : 6;
      targetMood = RelationshipMood.warm;
      reason = '浪漫表达';
      confidence = 0.9;
    } else if (message.senderType == 'user' &&
        userSentiment?.isEmotional == true) {
      affinityDelta = userSentiment!.affinityDelta;
      frictionDelta = userSentiment.frictionDelta;
      familiarityDelta = isGroupChat ? 3 : 6;
      if (userSentiment.isOffensive) {
        targetMood = RelationshipMood.annoyed;
        reason = '用户冒犯';
        confidence = 0.8;
      } else if (userSentiment.isCold) {
        targetMood = RelationshipMood.cold;
        reason = '用户冷淡';
        confidence = 0.6;
      } else if (userSentiment.isRespectful) {
        targetMood = RelationshipMood.warm;
        reason = '用户友好';
        confidence = 0.6;
      }
    } else if (content.contains('攻击') ||
        content.contains('冒犯') ||
        content.contains('侮辱')) {
      frictionDelta = 15;
      affinityDelta = -5;
      trustDelta = -3;
      targetMood = RelationshipMood.annoyed;
      reason = '冒犯/攻击';
      confidence = 0.9;
    } else if (content.contains('安慰') || content.contains('保护')) {
      affinityDelta = 10;
      trustDelta = 8;
      targetMood = RelationshipMood.warm;
      reason = '安慰/保护';
      confidence = 0.85;
    } else if (content.contains('背叛') || content.contains('站队')) {
      trustDelta = -15;
      frictionDelta = 10;
      affinityDelta = -8;
      targetMood = RelationshipMood.cold;
      reason = '背叛/站队';
      confidence = 0.9;
    } else if (content.contains('支持') || content.contains('信任')) {
      trustDelta = 8;
      affinityDelta = 5;
      targetMood = RelationshipMood.warm;
      reason = '支持/信任';
      confidence = 0.8;
    } else if (content.contains('怀疑')) {
      trustDelta = -5;
      frictionDelta = 3;
      targetMood = RelationshipMood.awkward;
      reason = '怀疑';
      confidence = 0.7;
    } else if (message.senderType == 'user') {
      // 用户消息：基于情感分析。
      familiarityDelta = isGroupChat ? 3 : 6;
      if (userSentiment != null) {
        affinityDelta = userSentiment.affinityDelta;
        frictionDelta = userSentiment.frictionDelta;
        if (userSentiment.isOffensive) {
          targetMood = RelationshipMood.annoyed;
          reason = '用户冒犯';
          confidence = 0.8;
        } else if (userSentiment.isCold) {
          targetMood = RelationshipMood.cold;
          reason = '用户冷淡';
          confidence = 0.6;
        } else if (userSentiment.isRespectful) {
          targetMood = RelationshipMood.warm;
          reason = '用户友好';
          confidence = 0.6;
        }
      }
    } else {
      // AI 消息：普通互动。
      familiarityDelta = isGroupChat ? 2 : 4;
      affinityDelta = isGroupChat ? 1 : 2;
    }

    if (isBystander) {
      // 旁观者能感知事件，但缺少直接承受/发起关系变化的上下文。
      affinityDelta = _dampenDelta(affinityDelta);
      trustDelta = _dampenDelta(trustDelta);
      frictionDelta = _dampenDelta(frictionDelta);
      familiarityDelta = _dampenDelta(familiarityDelta);
    }

    return RelationshipDelta(
      affinityDelta: affinityDelta,
      trustDelta: trustDelta,
      frictionDelta: frictionDelta,
      familiarityDelta: familiarityDelta,
      targetMood: targetMood,
      reason: reason,
      confidence: confidence,
    );
  }

  int _dampenDelta(int value) => value.sign * (value.abs() ~/ 2);

  static final _romanticNegationPattern = RegExp(
    r'(?:不|没|无|别|不要|不是|没有|并不|绝不|从不|不太|不想|不愿|不会)',
  );
  static final _romanticObjectContinuationPattern = RegExp(
    r'^(?:的|推荐|分享|说|写|发|拍|做|选|提供|送|制作|电影|歌曲|视频|书|建议|意见|答案|方案)',
  );

  bool _hasRomanticCue(String content) {
    final normalized = content.replaceAll(RegExp(r'\s+'), '');
    if (_containsPositiveCue(
      normalized,
      const ['喜欢你', '爱你'],
      rejectObjectContext: true,
    )) {
      return true;
    }

    const directedCues = [
      '和你约会',
      '跟你约会',
      '与你约会',
      '和你谈恋爱',
      '跟你谈恋爱',
      '与你谈恋爱',
      '和你在一起',
      '跟你在一起',
      '与你在一起',
      '我们在一起',
      '向你表白',
      '对你表白',
      '向你告白',
      '对你告白',
    ];
    if (_containsPositiveCue(normalized, directedCues)) return true;

    // Standalone confession/romance language remains supported, but still
    // respects nearby negation (for example, "不是来表白的").
    return _containsPositiveCue(normalized, const ['表白', '告白', '浪漫']);
  }

  bool _containsPositiveCue(
    String content,
    Iterable<String> cues, {
    bool rejectObjectContext = false,
  }) {
    for (final cue in cues) {
      var index = content.indexOf(cue);
      while (index >= 0) {
        if (!_isNegatedCue(content, index)) {
          final end = index + cue.length;
          final continuation = content.substring(end);
          if (!rejectObjectContext ||
              !_romanticObjectContinuationPattern.hasMatch(continuation)) {
            return true;
          }
        }
        index = content.indexOf(cue, index + cue.length);
      }
    }
    return false;
  }

  bool _isNegatedCue(String content, int cueStart) {
    final prefixStart = cueStart > 8 ? cueStart - 8 : 0;
    final prefix = content.substring(prefixStart, cueStart);
    return _romanticNegationPattern.hasMatch(prefix);
  }

  // ── 阶段防跳变 ───────────────────────────────────────────────────

  /// 关系阶段升级路径（只允许正向逐步升级）。
  static const _forwardStages = <RelationshipStage, List<RelationshipStage>>{
    RelationshipStage.stranger: [RelationshipStage.acquaintance],
    RelationshipStage.acquaintance: [RelationshipStage.friend],
    RelationshipStage.friend: [RelationshipStage.closeFriend],
    RelationshipStage.closeFriend: [
      RelationshipStage.romantic,
      RelationshipStage.strained
    ],
    RelationshipStage.strained: [
      RelationshipStage.hostile,
      RelationshipStage.acquaintance
    ],
    RelationshipStage.hostile: [RelationshipStage.strained],
  };

  /// 关系阶段降级路径（只允许逐步降级）。
  static const _backwardStages = <RelationshipStage, List<RelationshipStage>>{
    RelationshipStage.romantic: [
      RelationshipStage.closeFriend,
      RelationshipStage.strained
    ],
    RelationshipStage.closeFriend: [RelationshipStage.friend],
    RelationshipStage.friend: [RelationshipStage.acquaintance],
    RelationshipStage.acquaintance: [RelationshipStage.stranger],
    RelationshipStage.strained: [
      RelationshipStage.friend,
      RelationshipStage.hostile
    ],
    RelationshipStage.hostile: [RelationshipStage.strained],
  };

  /// 普通事件最多允许的阶段变化步数。
  static const int _maxStageStepPerEvent = 1;

  RelationshipStage _resolveStageTransition({
    required RelationshipStage currentStage,
    required RelationshipDelta delta,
  }) {
    // 阶段变化需要最低置信度。
    if (delta.confidence < 0.5) return currentStage;

    final targetStage = _suggestStageFromDelta(currentStage, delta);
    if (targetStage == currentStage) return currentStage;

    // 检查是否只跨越了允许的阶段步数。
    final distance = _stageDistance(currentStage, targetStage);
    if (distance > _maxStageStepPerEvent) {
      // 跳变过多，只移动到允许的下一级。
      return _stepToward(currentStage, delta);
    }

    // romantic 必须有明确语义证据或手动确认，不能仅凭数值推断。
    if (targetStage == RelationshipStage.romantic &&
        !_hasRomanticEvidence(delta)) {
      return currentStage;
    }

    return targetStage;
  }

  /// 根据 delta 建议目标阶段。
  RelationshipStage _suggestStageFromDelta(
    RelationshipStage current,
    RelationshipDelta delta,
  ) {
    // Only a positive delta carrying explicit romantic language may propose
    // this stage; _resolveStageTransition performs the final evidence check.
    if (_hasRomanticEvidence(delta) &&
        delta.affinityDelta > 0 &&
        delta.trustDelta > 0) {
      return RelationshipStage.romantic;
    }
    // 高摩擦 + 低亲密 → 负面阶段。
    if (delta.frictionDelta > 10 && delta.affinityDelta <= -5) {
      return RelationshipStage.strained;
    }
    // 高摩擦 + 攻击行为 → 敌对。
    if (delta.frictionDelta > 12) {
      return RelationshipStage.hostile;
    }
    // 高亲密 + 信任 → 正面升级。
    if (delta.affinityDelta > 8 && delta.trustDelta > 5) {
      return RelationshipStage.closeFriend;
    }
    // 普通友好互动。
    if (delta.affinityDelta > 3 && delta.frictionDelta <= 0) {
      return RelationshipStage.friend;
    }
    // 修复关系：从负面阶段改善。
    if (current == RelationshipStage.strained && delta.affinityDelta > 5) {
      return RelationshipStage.friend;
    }
    if (current == RelationshipStage.hostile && delta.trustDelta > 3) {
      return RelationshipStage.strained;
    }
    // 低摩擦友好 → 从陌生到认识。
    if (current == RelationshipStage.stranger && delta.familiarityDelta >= 3) {
      return RelationshipStage.acquaintance;
    }

    return current;
  }

  /// 是否有明确的浪漫关系语义证据。
  bool _hasRomanticEvidence(RelationshipDelta delta) {
    final reason = delta.reason.toLowerCase();
    return reason.contains('表白') ||
        reason.contains('恋爱') ||
        reason.contains('喜欢') ||
        reason.contains('浪漫') ||
        reason.contains('告白') ||
        reason.contains('约会');
  }

  /// 计算两个阶段之间的距离。
  int _stageDistance(RelationshipStage from, RelationshipStage to) {
    if (from == to) return 0;
    // BFS follows the declared branch graph; enum order is not a relationship path.
    final distances = <RelationshipStage, int>{from: 0};
    final pending = <RelationshipStage>[from];
    for (var index = 0; index < pending.length; index++) {
      final current = pending[index];
      final nextDistance = distances[current]! + 1;
      for (final neighbor in _stageNeighbors(current)) {
        if (distances.containsKey(neighbor)) continue;
        if (neighbor == to) return nextDistance;
        distances[neighbor] = nextDistance;
        pending.add(neighbor);
      }
    }
    return 1 << 30;
  }

  Set<RelationshipStage> _stageNeighbors(RelationshipStage stage) {
    final neighbors = <RelationshipStage>{
      ...?_forwardStages[stage],
      ...?_backwardStages[stage],
    };
    for (final entry in _forwardStages.entries) {
      if (entry.value.contains(stage)) neighbors.add(entry.key);
    }
    for (final entry in _backwardStages.entries) {
      if (entry.value.contains(stage)) neighbors.add(entry.key);
    }
    return neighbors;
  }

  /// 向目标方向移动一步（不跨越）。
  RelationshipStage _stepToward(
    RelationshipStage current,
    RelationshipDelta delta,
  ) {
    final target = _suggestStageFromDelta(current, delta);
    if (target == current) return current;

    final isNegative = delta.affinityDelta < 0 ||
        delta.trustDelta < 0 ||
        delta.frictionDelta > 0;
    final candidates =
        (isNegative ? _backwardStages[current] : _forwardStages[current]) ??
            const <RelationshipStage>[];
    if (candidates.contains(target)) return target;

    // 只选择仍朝目标阶段靠近的候选；没有合适路径时保持当前阶段。
    final currentDistance = _stageDistance(current, target);
    for (final candidate in candidates) {
      if (_stageDistance(candidate, target) < currentDistance) return candidate;
    }

    // A strong negative event must still move an established relationship
    // down one level even when the negative branch is not connected to target.
    if (isNegative && candidates.isNotEmpty) return candidates.first;

    return current;
  }

  // ── Delta 应用 ───────────────────────────────────────────────────

  /// 应用 delta 到当前快照，返回绝对 After 值。
  _AfterSnapshot _applyDelta({
    required int affinity,
    required int trust,
    required int friction,
    required int familiarity,
    required RelationshipMood mood,
    required RelationshipStage stage,
    required RelationshipDelta delta,
    required bool isGroupChat,
  }) {
    return _AfterSnapshot(
      affinity: (affinity + delta.affinityDelta).clamp(-100, 100),
      trust: (trust + delta.trustDelta).clamp(-100, 100),
      friction: (friction + delta.frictionDelta).clamp(0, 100),
      familiarity: (familiarity + delta.familiarityDelta).clamp(0, 100),
      mood: delta.targetMood,
      stage: stage,
    );
  }
}
