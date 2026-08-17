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
  final String? searchQuery;

  const RelationshipAuditFilter({
    this.observerCharacterId,
    this.targetType,
    this.targetAiId,
    this.stage,
    this.pinnedOnly,
    this.originConversationId,
    this.searchQuery,
  });

  RelationshipAuditFilter copyWith({
    bool clearObserverCharacterId = false,
    bool clearTargetType = false,
    bool clearTargetAiId = false,
    bool clearStage = false,
    bool clearPinnedOnly = false,
    bool clearOriginConversationId = false,
    bool clearSearchQuery = false,
    String? observerCharacterId,
    RelationshipTargetType? targetType,
    String? targetAiId,
    RelationshipStage? stage,
    bool? pinnedOnly,
    String? originConversationId,
    String? searchQuery,
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
      searchQuery: clearSearchQuery ? null : (searchQuery ?? this.searchQuery),
    );
  }

  bool get isEmpty =>
      observerCharacterId == null &&
      targetType == null &&
      targetAiId == null &&
      stage == null &&
      pinnedOnly == null &&
      originConversationId == null &&
      (searchQuery == null || searchQuery!.trim().isEmpty);

  int get advancedCriterionCount => [
        targetAiId,
        stage,
        pinnedOnly,
        originConversationId,
      ].whereType<Object>().length;

  bool get hasAdvancedCriteria => advancedCriterionCount > 0;

  RelationshipAuditFilter clearAdvancedFilters() => copyWith(
        clearTargetAiId: true,
        clearStage: true,
        clearPinnedOnly: true,
        clearOriginConversationId: true,
      );

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
