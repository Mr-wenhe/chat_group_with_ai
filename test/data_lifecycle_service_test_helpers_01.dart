part of 'data_lifecycle_service_test.dart';

DateTime testLifecycleDate(int second) =>
    DateTime.utc(2026, 8, 1, 0, 0, second);

PermanentMemory testPermanentMemory({
  required String id,
  String observerCharacterId = 'observer',
  MemoryKind kind = MemoryKind.fact,
  String content = 'memory',
  List<String> subjectIds = const [],
  MemoryStatus status = MemoryStatus.active,
  MemoryOriginType originType = MemoryOriginType.group,
  String? originConversationId,
  String originNameSnapshot = '',
  List<String> sourceMessageIds = const [],
}) {
  final timestamp = testLifecycleDate(id.hashCode.abs() % 50);
  return PermanentMemory(
    id: id,
    observerCharacterId: observerCharacterId,
    kind: kind,
    content: content,
    subjectIds: subjectIds,
    status: status,
    originType: originType,
    originConversationId: originConversationId,
    originNameSnapshot: originNameSnapshot,
    sourceMessageIds: sourceMessageIds,
    occurredAt: timestamp,
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}

RelationshipEvent testRelationshipEvent({
  required String id,
  String sourceCharacterId = 'source',
  RelationshipTargetType targetType = RelationshipTargetType.user,
  String targetId = 'user',
  String reason = 'test',
  int affinityBefore = 0,
  required int affinityAfter,
  int trustBefore = 0,
  int trustAfter = 0,
  int frictionBefore = 0,
  int frictionAfter = 0,
  int familiarityBefore = 0,
  int familiarityAfter = 0,
  RelationshipMood moodBefore = RelationshipMood.neutral,
  RelationshipMood moodAfter = RelationshipMood.neutral,
  RelationshipStage stageBefore = RelationshipStage.stranger,
  RelationshipStage stageAfter = RelationshipStage.acquaintance,
  String? originConversationId,
  String originNameSnapshot = '',
  List<String> sourceMessageIds = const [],
  required int revision,
  RelationshipEventCreator createdBy = RelationshipEventCreator.automatic,
  String notesBefore = '',
  String notesAfter = '',
}) {
  final timestamp = testLifecycleDate(revision);
  return RelationshipEvent(
    id: id,
    sourceCharacterId: sourceCharacterId,
    targetType: targetType,
    targetId: targetId,
    reason: reason,
    affinityBefore: affinityBefore,
    affinityAfter: affinityAfter,
    trustBefore: trustBefore,
    trustAfter: trustAfter,
    frictionBefore: frictionBefore,
    frictionAfter: frictionAfter,
    familiarityBefore: familiarityBefore,
    familiarityAfter: familiarityAfter,
    moodBefore: moodBefore,
    moodAfter: moodAfter,
    stageBefore: stageBefore,
    stageAfter: stageAfter,
    originConversationId: originConversationId,
    originNameSnapshot: originNameSnapshot,
    sourceMessageIds: sourceMessageIds,
    revision: revision,
    occurredAt: timestamp,
    createdBy: createdBy,
    createdAt: timestamp,
    notesBefore: notesBefore,
    notesAfter: notesAfter,
  );
}
