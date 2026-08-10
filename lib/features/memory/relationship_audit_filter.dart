import 'package:chat_group/core/models/relationship_state.dart';

/// Filters current global directional snapshots. Conversation filtering is
/// intentionally kept separate and is applied only to event timelines.
class RelationshipAuditFilter {
  final String? observerCharacterId;
  final RelationshipTargetType? targetType;
  final String? targetAiId;
  final RelationshipStage? stage;
  final bool? pinnedOnly;
  final String? originConversationId;

  const RelationshipAuditFilter({
    this.observerCharacterId,
    this.targetType,
    this.targetAiId,
    this.stage,
    this.pinnedOnly,
    this.originConversationId,
  });

  RelationshipAuditFilter copyWith({
    bool clearObserverCharacterId = false,
    bool clearTargetType = false,
    bool clearTargetAiId = false,
    bool clearStage = false,
    bool clearPinnedOnly = false,
    bool clearOriginConversationId = false,
    String? observerCharacterId,
    RelationshipTargetType? targetType,
    String? targetAiId,
    RelationshipStage? stage,
    bool? pinnedOnly,
    String? originConversationId,
  }) {
    return RelationshipAuditFilter(
      observerCharacterId: clearObserverCharacterId
          ? null
          : (observerCharacterId ?? this.observerCharacterId),
      targetType: clearTargetType ? null : (targetType ?? this.targetType),
      targetAiId: clearTargetAiId ? null : (targetAiId ?? this.targetAiId),
      stage: clearStage ? null : (stage ?? this.stage),
      pinnedOnly: clearPinnedOnly ? null : (pinnedOnly ?? this.pinnedOnly),
      originConversationId: clearOriginConversationId
          ? null
          : (originConversationId ?? this.originConversationId),
    );
  }

  bool get isEmpty =>
      observerCharacterId == null &&
      targetType == null &&
      targetAiId == null &&
      stage == null &&
      pinnedOnly == null &&
      originConversationId == null;

  List<RelationshipState> apply(
    Iterable<RelationshipState> relationships, {
    required bool Function(RelationshipState relationship) isPinned,
  }) {
    return relationships.where((relationship) {
      if (observerCharacterId != null &&
          relationship.sourceCharacterId != observerCharacterId) {
        return false;
      }
      if (targetType != null && relationship.targetType != targetType) {
        return false;
      }
      if (targetAiId != null &&
          (relationship.targetType != RelationshipTargetType.ai ||
              relationship.targetId != targetAiId)) {
        return false;
      }
      if (stage != null && relationship.stage != stage) return false;
      if (pinnedOnly != null && isPinned(relationship) != pinnedOnly) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }
}
