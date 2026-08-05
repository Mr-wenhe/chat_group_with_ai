import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';

/// 统一全局记忆上下文选择器。
///
/// 按 **observerCharacterId**（当前发言 AI）读取永久记忆和关系，
/// 不按 conversationId 隔离。同一 AI 在群 1 / 群 2 / DM 中看到的是同一份记忆。
///
/// 隐私隔离由 [visibleToCharacterIds] 保证：
/// - 群聊消息可见范围内的 AI 才能建立观察者记忆；
/// - DM 只有对话双方在可见范围内；
/// - 查询时自动排除其他 AI 的私有记忆。
class MemoryContextSelector {
  final DatabaseService db;

  MemoryContextSelector(this.db);

  /// 默认永久记忆字符预算（~800 chars，集中管理，不散落魔法数字）。
  static const int defaultPermanentMemoryBudget = 800;

  /// 默认关系快照预算。
  static const int defaultRelationshipBudget = 400;

  MemoryContextSelector._(this.db);

  /// 构造缓存实例（当页面内多次调用时复用查询）。
  factory MemoryContextSelector.cached(DatabaseService db) =>
      MemoryContextSelector._(db);

  /// 选择全局记忆上下文并返回注入 Prompt 的片段。
  ///
  /// [observerCharacterId] — 当前发言 AI。
  /// [participantCharacterIds] — 当前会话可见的 AI ID 列表（用于隐私隔离）。
  /// [currentTargetId] — 本轮主要回应目标 ID（用于主体命中排序）。
  /// [userMessage] — 用户最新消息（用于关键词匹配）。
  /// [characterBudget] — 永久记忆字符预算（默认 [defaultPermanentMemoryBudget]）。
  Future<String> select({
    required String observerCharacterId,
    required List<String> participantCharacterIds,
    String? currentTargetId,
    String? userMessage,
    int characterBudget = defaultPermanentMemoryBudget,
  }) async {
    final profile = _loadUserProfile();
    final relations = _selectRelationships(
      observerCharacterId: observerCharacterId,
      participantCharacterIds: participantCharacterIds,
      currentTargetId: currentTargetId,
      budget: defaultRelationshipBudget,
    );
    final memories = _selectMemories(
      observerCharacterId: observerCharacterId,
      participantCharacterIds: participantCharacterIds,
      currentTargetId: currentTargetId,
      userMessage: userMessage,
      budget: characterBudget,
    );

    final parts = <String>[];

    // ── 优先级 1：人物信息卡（权威事实） ──
    if (profile != null) {
      parts.add(_profilePromptSection(profile));
    }

    // ── 优先级 2：全局关系快照 ──
    if (relations.isNotEmpty) {
      parts.add('【我的关系】${relations.join('；')}');
    }

    // ── 优先级 3：有效永久记忆 ──
    if (memories.isNotEmpty) {
      parts.add('【我的记忆】${memories.join('；')}');
    }

    if (parts.isEmpty) return '';

    // 在顶部说明优先级规则，但不暴露底层存储细节。
    final header = profile != null
        ? '以下是你了解的用户信息（人物信息卡优先于记忆）和你的相关记忆。'
        : '以下是你积累的相关记忆。';

    return '$header\n\n${parts.join('\n\n')}';
  }

  /// 加载全局用户人物信息卡。
  UserProfile? _loadUserProfile() {
    final box = db.userProfileBox;
    if (!box.isOpen) return null;
    final profile = box.get('me');
    if (profile == null) return null;
    // 只返回有实质内容的人物卡。
    if (profile.displayName.trim().isEmpty &&
        profile.bio.trim().isEmpty &&
        profile.interests.isEmpty &&
        profile.personality.isEmpty &&
        profile.importantBackground.isEmpty) {
      return null;
    }
    return profile;
  }

  /// 选择关系快照。
  ///
  /// 返回当前 AI 对 [currentTargetId] 或用户的关系描述行。
  /// 按 stableGlobalId 去重：全局快照优先，无全局时取最新 legacy。
  List<String> _selectRelationships({
    required String observerCharacterId,
    required List<String> participantCharacterIds,
    String? currentTargetId,
    required int budget,
  }) {
    // 按 stableGlobalId 逐项选最优（全局 > 最新 legacy）。
    final bestByStableId = <String, RelationshipState>{};
    for (final relation in db.relationshipStateBox.values) {
      if (relation.sourceCharacterId != observerCharacterId) continue;
      if (relation.targetId == observerCharacterId) continue;
      final stableId = RelationshipState.stableGlobalId(
        relation.sourceCharacterId,
        relation.targetType,
        relation.targetId,
      );
      final existing = bestByStableId[stableId];
      if (existing == null) {
        bestByStableId[stableId] = relation;
      } else if (relation.groupId == 'global' && existing.groupId != 'global') {
        bestByStableId[stableId] = relation;
      } else if (relation.groupId != 'global' &&
          existing.groupId != 'global' &&
          relation.updatedAt.isAfter(existing.updatedAt)) {
        bestByStableId[stableId] = relation;
      }
    }
    final candidates = bestByStableId.values.toList();

    // 优先：对当前目标的关系；其次：对用户的关系。
    candidates.sort((a, b) {
      final aTarget = _relationTargetPriority(a, currentTargetId);
      final bTarget = _relationTargetPriority(b, currentTargetId);
      if (aTarget != bTarget) return aTarget.compareTo(bTarget);
      // 同等优先级下按熟悉度降序。
      return b.familiarity.compareTo(a.familiarity);
    });

    final lines = <String>[];
    var used = 0;
    for (final r in candidates.take(4)) {
      final name = r.targetType == RelationshipTargetType.user
          ? '真人用户'
          : 'AI:${r.targetId}';
      final stage = r.stage.name;
      final note = r.notes.trim().isEmpty ? '' : '，${r.notes.trim()}';
      final line = '$name($stage)：亲近${r.affinity}，信任${r.trust}，摩擦${r.friction}，熟悉度${r.familiarity}，最近情绪${r.recentMood.name}$note';
      final needed = line.length;
      if (used + needed > budget) break;
      lines.add(line);
      used += needed;
    }
    return lines;
  }

  /// 选择有效永久记忆。
  ///
  /// 按以下结构化分数排序后取预算内最高分记录：
  /// 1. pinned / explicitlyRequested 优先
  /// 2. 主体命中（用户或当前目标）
  /// 3. 重要度
  /// 4. 置信度
  /// 5. 关键词重合
  /// 6. 新近度
  List<String> _selectMemories({
    required String observerCharacterId,
    required List<String> participantCharacterIds,
    String? currentTargetId,
    String? userMessage,
    required int budget,
  }) {
    // 先构建被 supersede 的 ID 集合。
    final supersededIds = <String>{};
    for (final memory in db.permanentMemoryBox.values) {
      if (memory.observerCharacterId != observerCharacterId) continue;
      if (memory.status == MemoryStatus.active &&
          memory.supersedesIds.isNotEmpty) {
        supersededIds.addAll(memory.supersedesIds);
      }
    }

    // 收集候选。
    final allMemories = <PermanentMemory>[];
    for (final memory in db.permanentMemoryBox.values) {
      if (memory.observerCharacterId != observerCharacterId) continue;
      if (memory.status != MemoryStatus.active) continue;
      // 排除被其他有效记录 supersede 的旧记录。
      if (supersededIds.contains(memory.id)) continue;
      if (memory.pinned) {
        // pinned 记忆直接收录，不受 participant 限制（用户明确固定）。
        allMemories.add(memory);
        continue;
      }
      // 非 pinned 记忆：只收录当前观察者的记忆（observer 过滤已做），
      // 以及当前会话可见范围内的来源记忆。
      // privacyGate 已在写入时保证只有可见 AI 有记录，这里做二次确认。
      if (memory.subjectIds.isEmpty) {
        // 无主体的自身成长记忆允许通过。
        allMemories.add(memory);
        continue;
      }
      // 有主体：检查主体是否在当前参与者中或就是用户。
      final relevant = memory.subjectIds.any((sid) =>
          sid == 'user' ||
          participantCharacterIds.contains(sid));
      if (relevant) {
        allMemories.add(memory);
      }
    }

    // 结构化排序。
    final keywords = _tokenize(userMessage ?? '');
    allMemories.sort((a, b) {
      // pinned / explicitlyRequested 优先。
      final aPin = (a.pinned ? 4 : 0) + (a.explicitlyRequested ? 3 : 0);
      final bPin = (b.pinned ? 4 : 0) + (b.explicitlyRequested ? 3 : 0);
      if (aPin != bPin) return bPin.compareTo(aPin);

      // 主体命中。
      final aHit = _subjectHit(a, currentTargetId);
      final bHit = _subjectHit(b, currentTargetId);
      if (aHit != bHit) return bHit.compareTo(aHit);

      // 重要度。
      if (a.importance != b.importance) return b.importance.compareTo(a.importance);

      // 置信度。
      if (a.confidence != b.confidence) return b.confidence.compareTo(a.confidence);

      // 关键词重合。
      final aKw = _keywordOverlap(a, keywords);
      final bKw = _keywordOverlap(b, keywords);
      if (aKw != bKw) return bKw.compareTo(aKw);

      // 新近度。
      return b.occurredAt.compareTo(a.occurredAt);
    });

    // 在预算内取记忆。预算内一条都放不下时返回空列表，不强行塞入。
    final lines = <String>[];
    var used = 0;
    for (final memory in allMemories) {
      final line = _memoryLine(memory);
      final needed = line.length + (lines.isEmpty ? 0 : 1); // +1 for separator
      // 预算不足：不加入本条，也不加入后续更长的记录。
      if (used + needed > budget) break;
      lines.add(line);
      used += needed;
    }
    return lines;
  }

  /// 关系目标优先级：当前目标 > 用户 > 其他 AI。
  static int _relationTargetPriority(RelationshipState r, String? currentTargetId) {
    if (currentTargetId != null && r.targetId == currentTargetId) return 0;
    if (r.targetType == RelationshipTargetType.user) return 1;
    return 2;
  }

  /// 主体命中分数：当前目标 = 2，用户 = 1，其他 = 0。
  int _subjectHit(PermanentMemory memory, String? currentTargetId) {
    if (memory.subjectIds.contains(currentTargetId)) return 2;
    if (memory.subjectIds.contains('user')) return 1;
    return 0;
  }

  /// 记忆内容与用户消息关键词重合度。
  int _keywordOverlap(PermanentMemory memory, Set<String> keywords) {
    if (keywords.isEmpty) return 0;
    final content = memory.content.toLowerCase();
    var count = 0;
    for (final kw in keywords) {
      if (kw.length < 2) continue;
      if (content.contains(kw)) count++;
    }
    return count;
  }

  /// 将文本分词为字符 bigram（中文友好，无外部依赖）。
  static Set<String> _tokenize(String text) {
    final result = <String>{};
    final normalized = text.toLowerCase();
    // 按空白和标点分词。
    final segments = normalized.split(RegExp(r'\s+|[，。！？、,.!?；;：:""「」『』【】\s]'));
    for (final segment in segments) {
      if (segment.length < 2) continue;
      // 单字符也加入（避免中文 bigram 遗漏短词）。
      if (segment.length == 2) {
        result.add(segment);
      } else {
        // bigram。
        for (var i = 0; i < segment.length - 1; i++) {
          result.add(segment.substring(i, i + 2));
        }
      }
    }
    return result;
  }

  /// 将单条记忆格式化为 Prompt 行。
  String _memoryLine(PermanentMemory memory) {
    final kindLabel = switch (memory.kind) {
      MemoryKind.fact => '知',
      MemoryKind.preference => '偏好',
      MemoryKind.commitment => '承诺',
      MemoryKind.sharedExperience => '经历',
      MemoryKind.relationshipNote => '关系',
      MemoryKind.personaGrowth => '成长',
      MemoryKind.explicitInstruction => '指令',
    };
    final originLabel = switch (memory.originType) {
      MemoryOriginType.group => '群',
      MemoryOriginType.direct => '私聊',
      MemoryOriginType.manual => '手动',
      MemoryOriginType.legacyMigration => '历史',
    };
    return '$kindLabel[$originLabel]${memory.content}';
  }

  /// 人物信息卡 Prompt 片段。
  String _profilePromptSection(UserProfile profile) {
    final parts = <String>['【关于我的人物信息卡】'];
    if (profile.displayName.trim().isNotEmpty) {
      parts.add('名字：${profile.displayName.trim()}');
    }
    if (profile.preferredAddress.trim().isNotEmpty) {
      parts.add('称呼：${profile.preferredAddress.trim()}');
    }
    if (profile.bio.trim().isNotEmpty) {
      parts.add('简介：${profile.bio.trim()}');
    }
    if (profile.personality.isNotEmpty) {
      parts.add('性格：${profile.personality.join('、')}');
    }
    if (profile.interests.isNotEmpty) {
      parts.add('兴趣：${profile.interests.join('、')}');
    }
    if (profile.importantBackground.isNotEmpty) {
      parts.add('背景：${profile.importantBackground.join('、')}');
    }
    if (profile.age != null) {
      parts.add('年龄：${profile.age}');
    }
    return parts.join('\n');
  }

  /// 获取所有当前 AI 的全局关系快照（用于 Orchestrator 发言选择）。
  ///
  /// 返回 Map<characterId, List<RelationshipState>>，每个角色的关系列表
  /// 按 targetType（ai 优先）+ familiarity 排序。
  Future<Map<String, List<RelationshipState>>> globalRelationships(
    List<String> characterIds,
  ) async {
    final result = <String, List<RelationshipState>>{};
    for (final cid in characterIds) {
      final relations = <RelationshipState>[];
      for (final r in db.relationshipStateBox.values) {
        if (r.sourceCharacterId != cid) continue;
        relations.add(r);
      }
      relations.sort((a, b) {
        if (a.targetType != b.targetType) {
          // user 关系优先。
          return a.targetType == RelationshipTargetType.user ? -1 : 1;
        }
        return b.familiarity.compareTo(a.familiarity);
      });
      result[cid] = relations;
    }
    return result;
  }
}
