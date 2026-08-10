import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'relationship_state.dart';

part 'relationship_event.g.dart';

/// 关系事件创建者。
@HiveType(typeId: 20)
enum RelationshipEventCreator {
  @HiveField(0)
  automatic,

  @HiveField(1)
  manual,

  /// 从旧 RelationshipState 快照迁移而来。
  @HiveField(2)
  legacyMigration,
}

/// 不可覆盖的关系历史事件。
///
/// 事件保存绝对的 After 快照；重放同一事件只是把当前状态设置为同一绝对值，
/// 不会重复加分，保证幂等。
@HiveType(typeId: 21)
class RelationshipEvent extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String sourceCharacterId;

  @HiveField(2)
  final RelationshipTargetType targetType;

  @HiveField(3)
  final String targetId;

  /// 为什么变化。
  @HiveField(4)
  String reason;

  /// 亲密前后值。
  @HiveField(5)
  int affinityBefore;

  @HiveField(6)
  int affinityAfter;

  /// 信任前后值。
  @HiveField(7)
  int trustBefore;

  @HiveField(8)
  int trustAfter;

  /// 摩擦前后值。
  @HiveField(9)
  int frictionBefore;

  @HiveField(10)
  int frictionAfter;

  /// 熟悉度前后值。
  @HiveField(11)
  int familiarityBefore;

  @HiveField(12)
  int familiarityAfter;

  /// 情绪变化。
  @HiveField(13)
  RelationshipMood moodBefore;

  @HiveField(14)
  RelationshipMood moodAfter;

  /// 关系阶段变化。
  @HiveField(15)
  RelationshipStage stageBefore;

  @HiveField(16)
  RelationshipStage stageAfter;

  /// 发生场合 ID。
  @HiveField(17)
  String? originConversationId;

  /// 删除/改名后仍能说明原场合的名称快照。
  @HiveField(18)
  String originNameSnapshot;

  /// 原始证据消息 ID 列表。
  @HiveField(19)
  List<String> sourceMessageIds;

  /// 对同一方向关系单调递增的版本号。
  @HiveField(20)
  int revision;

  /// 发生时间。
  @HiveField(21)
  DateTime occurredAt;

  /// 自动判断置信度。
  @HiveField(22)
  double confidence;

  @HiveField(23)
  final RelationshipEventCreator createdBy;

  /// 记忆记录创建时间。
  @HiveField(24)
  final DateTime createdAt;

  /// Manual edits also audit the notes field. Older events omit these fields
  /// and are read as empty strings for backward compatibility.
  @HiveField(25, defaultValue: '')
  final String notesBefore;

  @HiveField(26, defaultValue: '')
  final String notesAfter;

  RelationshipEvent({
    String? id,
    required this.sourceCharacterId,
    required this.targetType,
    required this.targetId,
    required this.reason,
    required this.affinityBefore,
    required this.affinityAfter,
    required this.trustBefore,
    required this.trustAfter,
    required this.frictionBefore,
    required this.frictionAfter,
    required this.familiarityBefore,
    required this.familiarityAfter,
    required this.moodBefore,
    required this.moodAfter,
    required this.stageBefore,
    required this.stageAfter,
    this.originConversationId,
    required this.originNameSnapshot,
    List<String>? sourceMessageIds,
    required this.revision,
    DateTime? occurredAt,
    this.confidence = 1.0,
    required this.createdBy,
    DateTime? createdAt,
    this.notesBefore = '',
    this.notesAfter = '',
  })  : id = id ?? const Uuid().v4(),
        sourceMessageIds = sourceMessageIds ?? const [],
        occurredAt = occurredAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();
}
