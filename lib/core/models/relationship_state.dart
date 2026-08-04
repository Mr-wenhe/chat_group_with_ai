import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'relationship_state.g.dart';

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
    String notes = '',
    DateTime? lastInteractionAt,
    RelationshipStage stage = RelationshipStage.stranger,
    int revision = 0,
    String? lastEventId,
    DateTime? updatedAt,
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
      notes: notes,
      lastInteractionAt: lastInteractionAt,
      stage: stage,
      revision: revision,
      lastEventId: lastEventId,
      updatedAt: updatedAt,
    );
  }

  /// 生成稳定的全局关系 ID：rel:<source>:<targetType>:<target>
  static String stableGlobalId(
      String sourceCharacterId, RelationshipTargetType targetType, String targetId) {
    return 'rel:$sourceCharacterId:${targetType.name}:$targetId';
  }

  static String _stableId(
      String sourceCharacterId, RelationshipTargetType targetType, String targetId) {
    return 'rel:$sourceCharacterId:${targetType.name}:$targetId';
  }

  void clampScores() {
    affinity = affinity.clamp(-100, 100).toInt();
    trust = trust.clamp(-100, 100).toInt();
    friction = friction.clamp(0, 100).toInt();
    familiarity = familiarity.clamp(0, 100).toInt();
  }
}
