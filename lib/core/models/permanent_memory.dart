import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'permanent_memory.g.dart';

/// 永久记忆种类。
@HiveType(typeId: 14)
enum MemoryKind {
  @HiveField(0)
  fact,

  @HiveField(1)
  preference,

  @HiveField(2)
  commitment,

  @HiveField(3)
  sharedExperience,

  @HiveField(4)
  relationshipNote,

  @HiveField(5)
  personaGrowth,

  @HiveField(6)
  explicitInstruction,
}

/// 记忆来源场合类型。
@HiveType(typeId: 15)
enum MemoryOriginType {
  @HiveField(0)
  group,

  @HiveField(1)
  direct,

  @HiveField(2)
  manual,

  /// 从旧 CharacterMemory / memorySummary 迁移而来，来源场合不一定精确。
  @HiveField(3)
  legacyMigration,
}

/// 永久记忆状态。
@HiveType(typeId: 18)
enum MemoryStatus {
  @HiveField(0)
  active,

  /// 被新记录取代，保留审计但不进入 Prompt。
  @HiveField(1)
  superseded,

  /// 被人物卡覆盖或用户删除意图，保留审计但不进入 Prompt。
  @HiveField(2)
  invalidated,
}

/// 观察者视角的单条永久记忆。
///
/// 归属键是 observerCharacterId，不是 conversationId。
/// 群聊和私聊只是记忆发生的场合，保留在 origin 字段中。
@HiveType(typeId: 19)
class PermanentMemory extends HiveObject {
  @HiveField(0)
  final String id;

  /// 记忆归属的观察者角色 ID；核心归属字段。
  @HiveField(1)
  final String observerCharacterId;

  @HiveField(2)
  final MemoryKind kind;

  /// 简洁记忆正文。
  @HiveField(3)
  String content;

  /// 涉及的主体 ID：'user' 或 AI character ID；允许多人事件。
  @HiveField(4)
  List<String> subjectIds;

  @HiveField(5)
  final MemoryStatus status;

  /// 重要度 0..100，用于检索排序。
  @HiveField(6)
  int importance;

  /// 置信度 0..1；人工输入和人物卡为 1.0。
  @HiveField(7)
  double confidence;

  /// 是否由"记住/永久"等明确意图触发。
  @HiveField(8)
  bool explicitlyRequested;

  /// 固定后自动流程不得使其失效。
  @HiveField(9)
  bool pinned;

  /// 本记录修正或取代的旧记忆 ID 列表。
  @HiveField(10)
  List<String> supersedesIds;

  @HiveField(11)
  final MemoryOriginType originType;

  /// 来源场合 ID（groupId 或 dm:{characterId}）；仅用于追溯和筛选。
  @HiveField(12)
  String? originConversationId;

  /// 删除/改名后仍能说明原场合的名称快照。
  @HiveField(13)
  String originNameSnapshot;

  /// 原始证据消息 ID 列表；人工输入为空。
  @HiveField(14)
  List<String> sourceMessageIds;

  /// 事件当时参与者。
  @HiveField(15)
  List<String> participantIds;

  /// 事件发生时间。
  @HiveField(16)
  DateTime occurredAt;

  /// 记忆记录创建时间。
  @HiveField(17)
  final DateTime createdAt;

  /// 编辑或状态变化时间。
  @HiveField(18)
  DateTime updatedAt;

  PermanentMemory({
    String? id,
    required this.observerCharacterId,
    required this.kind,
    required this.content,
    List<String>? subjectIds,
    required this.status,
    this.importance = 50,
    this.confidence = 1.0,
    this.explicitlyRequested = false,
    this.pinned = false,
    List<String>? supersedesIds,
    required this.originType,
    this.originConversationId,
    required this.originNameSnapshot,
    List<String>? sourceMessageIds,
    List<String>? participantIds,
    DateTime? occurredAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        subjectIds = subjectIds ?? const [],
        supersedesIds = supersedesIds ?? const [],
        sourceMessageIds = sourceMessageIds ?? const [],
        participantIds = participantIds ?? const [],
        occurredAt = occurredAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();
}
