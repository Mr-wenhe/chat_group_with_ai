import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'relationship_state.g.dart';

/// 心情的存活时长。超过此时长未被新的明确情绪信号刷新，即回落 [RelationshipMood.neutral]。
///
/// 单一定义，便于日后调整；不逐处传入。
const Duration kRelationshipMoodTtl = Duration(minutes: 30);

@HiveType(typeId: 6)
enum RelationshipTargetType {
  @HiveField(0)
  ai,
  @HiveField(1)
  user,
}

@HiveType(typeId: 7)
enum RelationshipMood {
  @HiveField(0)
  neutral,
  @HiveField(1)
  warm,
  @HiveField(2)
  annoyed,
  @HiveField(3)
  awkward,
  @HiveField(4)
  protective,
  @HiveField(5)
  cold,
}

/// 关系阶段枚举。
@HiveType(typeId: 23)
enum RelationshipStage {
  @HiveField(0)
  stranger,

  @HiveField(1)
  acquaintance,

  @HiveField(2)
  friend,

  @HiveField(3)
  closeFriend,

  @HiveField(4)
  romantic,

  @HiveField(5)
  strained,

  @HiveField(6)
  hostile,
}

@HiveType(typeId: 8)
class RelationshipState extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String groupId;

  @HiveField(2)
  final String sourceCharacterId;

  @HiveField(3)
  final String targetId;

  @HiveField(4, defaultValue: RelationshipTargetType.ai)
  RelationshipTargetType targetType;

  @HiveField(5, defaultValue: 0)
  int affinity;

  @HiveField(6, defaultValue: 0)
  int trust;

  @HiveField(7, defaultValue: 0)
  int friction;

  @HiveField(8, defaultValue: 0)
  int familiarity;

  @HiveField(9, defaultValue: RelationshipMood.neutral)
  RelationshipMood recentMood;

  @HiveField(10, defaultValue: '')
  String notes;

  @HiveField(11)
  DateTime lastInteractionAt;

  @HiveField(12)
  final DateTime createdAt;

  /// 关系阶段；迁移后运行时唯一键从 (groupId, source, target) 改为 (source, targetType, targetId)。
  @HiveField(13, defaultValue: RelationshipStage.stranger)
  RelationshipStage stage;

  /// 事件版本号；每次关系事件写入单调递增。
  @HiveField(14, defaultValue: 0)
  int revision;

  /// 最新关系事件 ID。
  @HiveField(15)
  String? lastEventId;

  /// 最后更新时间。
  @HiveField(16)
  DateTime updatedAt;

  /// 心情（[recentMood]）被设定的时刻。
  ///
  /// 不变量：非空当且仅当 [recentMood] 非 neutral。心情只在收到明确情绪信号时
  /// 更新，普通事件既不改变心情也不刷新此时间戳——否则活跃会话会不断续命，
  /// 使过期心情永不失效。读取一律走 [effectiveMood]，不一致状态安全降级为 neutral。
  @HiveField(17)
  DateTime? recentMoodAt;

  RelationshipState({
    String? id,
    required this.groupId,
    required this.sourceCharacterId,
    required this.targetId,
    required this.targetType,
    this.affinity = 0,
    this.trust = 0,
    this.friction = 0,
    this.familiarity = 0,
    this.recentMood = RelationshipMood.neutral,
    this.recentMoodAt,
    this.notes = '',
    DateTime? lastInteractionAt,
    DateTime? createdAt,
    this.stage = RelationshipStage.stranger,
    this.revision = 0,
    this.lastEventId,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        lastInteractionAt = lastInteractionAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// 从旧的 per-group 快照创建全局关系状态。
  factory RelationshipState.global({
    String? id,
    required String sourceCharacterId,
    required RelationshipTargetType targetType,
    required String targetId,
    int affinity = 0,
    int trust = 0,
    int friction = 0,
    int familiarity = 0,
    RelationshipMood recentMood = RelationshipMood.neutral,
    DateTime? recentMoodAt,
    String notes = '',
    DateTime? lastInteractionAt,
    RelationshipStage stage = RelationshipStage.stranger,
    int revision = 0,
    String? lastEventId,
    DateTime? updatedAt,
    DateTime? createdAt,
  }) {
    return RelationshipState(
      id: id ?? _stableId(sourceCharacterId, targetType, targetId),
      groupId: 'global',
      sourceCharacterId: sourceCharacterId,
      targetId: targetId,
      targetType: targetType,
      affinity: affinity,
      trust: trust,
      friction: friction,
      familiarity: familiarity,
      recentMood: recentMood,
      recentMoodAt: recentMoodAt,
      notes: notes,
      lastInteractionAt: lastInteractionAt,
      createdAt: createdAt,
      stage: stage,
      revision: revision,
      lastEventId: lastEventId,
      updatedAt: updatedAt,
    );
  }

  /// 生成稳定的全局关系 ID：rel:<source>:<targetType>:<target>
  static String stableGlobalId(String sourceCharacterId,
      RelationshipTargetType targetType, String targetId) {
    return 'rel:$sourceCharacterId:${targetType.name}:$targetId';
  }

  /// Selects one snapshot per directional relationship for reads.
  ///
  /// A global snapshot is authoritative over legacy per-group snapshots. If
  /// several snapshots share that scope, the newest [updatedAt] wins; the
  /// remaining fields make equal timestamps deterministic.
  static List<RelationshipState> selectStableSnapshots(
    Iterable<RelationshipState> relationships,
  ) {
    final bestByStableId = <String, RelationshipState>{};
    for (final candidate in relationships) {
      if (candidate.sourceCharacterId.isEmpty) continue;
      final stableId = stableGlobalId(
        candidate.sourceCharacterId,
        candidate.targetType,
        candidate.targetId,
      );
      final current = bestByStableId[stableId];
      if (current == null || _isPreferredSnapshot(candidate, current)) {
        bestByStableId[stableId] = candidate;
      }
    }

    final entries = bestByStableId.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [for (final entry in entries) entry.value];
  }

  static bool _isPreferredSnapshot(
    RelationshipState candidate,
    RelationshipState current,
  ) {
    final candidateIsGlobal = candidate.groupId == 'global';
    final currentIsGlobal = current.groupId == 'global';
    if (candidateIsGlobal != currentIsGlobal) return candidateIsGlobal;

    final updatedAt = candidate.updatedAt.compareTo(current.updatedAt);
    if (updatedAt != 0) return updatedAt > 0;
    final revision = candidate.revision.compareTo(current.revision);
    if (revision != 0) return revision > 0;
    final createdAt = candidate.createdAt.compareTo(current.createdAt);
    if (createdAt != 0) return createdAt > 0;
    return candidate.id.compareTo(current.id) > 0;
  }

  static String _stableId(String sourceCharacterId,
      RelationshipTargetType targetType, String targetId) {
    return 'rel:$sourceCharacterId:${targetType.name}:$targetId';
  }

  void clampScores() {
    affinity = affinity.clamp(-100, 100).toInt();
    trust = trust.clamp(-100, 100).toInt();
    friction = friction.clamp(0, 100).toInt();
    familiarity = familiarity.clamp(0, 100).toInt();
  }

  /// 是否有仍然有效的心情。
  ///
  /// 时间戳为空视为已过期：老数据没有该字段，其历史心情在升级后一律回落 neutral
  /// （一次性、已知的行为变化）。不回填是因为只能靠 [updatedAt] 猜测，而 updatedAt
  /// 会被后续普通事件推进，等于给过期心情续命。
  static bool hasActiveMood(
    RelationshipMood mood,
    DateTime? at, {
    DateTime? now,
  }) {
    if (mood == RelationshipMood.neutral || at == null) return false;
    return (now ?? DateTime.now()).difference(at) < kRelationshipMoodTtl;
  }

  /// 读取时生效的心情：过期即回落 [RelationshipMood.neutral]。
  ///
  /// 行为侧与展示侧统一走此方法，避免「存的是心情、读的是另一套口径」。
  RelationshipMood effectiveMood({DateTime? now}) =>
      hasActiveMood(recentMood, recentMoodAt, now: now)
          ? recentMood
          : RelationshipMood.neutral;
}
