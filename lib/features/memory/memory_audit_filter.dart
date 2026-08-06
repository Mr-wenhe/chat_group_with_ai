import 'package:chat_group/core/models/permanent_memory.dart';

class SubjectFilter {
  final String? characterId;

  const SubjectFilter._(this.characterId);

  static const SubjectFilter all = SubjectFilter._('__all__');
  static const SubjectFilter aboutMe = SubjectFilter._('__about_me__');
  static const SubjectFilter selfGrowth = SubjectFilter._('__self_growth__');

  static SubjectFilter aboutCharacter(String characterId) {
    return SubjectFilter._(characterId);
  }

  SubjectFilter call() => this;
}

class MemoryAuditFilter {
  final String? observerCharacterId;
  final SubjectFilter subjectFilter;
  final MemoryOriginType? originType;
  final String? originConversationId;
  final MemoryStatus? status;
  final MemoryKind? memoryKind;
  final bool? pinnedOnly;

  const MemoryAuditFilter({
    this.observerCharacterId,
    this.subjectFilter = SubjectFilter.all,
    this.originType,
    this.originConversationId,
    this.status,
    this.memoryKind,
    this.pinnedOnly,
  });

  MemoryAuditFilter copyWith({
    String? observerCharacterId,
    SubjectFilter? subjectFilter,
    MemoryOriginType? originType,
    String? originConversationId,
    MemoryStatus? status,
    MemoryKind? memoryKind,
    bool? pinnedOnly,
  }) {
    return MemoryAuditFilter(
      observerCharacterId: observerCharacterId,
      subjectFilter: subjectFilter ?? this.subjectFilter,
      originType: originType,
      originConversationId: originConversationId,
      status: status,
      memoryKind: memoryKind,
      pinnedOnly: pinnedOnly ?? this.pinnedOnly,
    );
  }

  bool get isEmpty =>
      observerCharacterId == null &&
      subjectFilter == SubjectFilter.all &&
      originType == null &&
      originConversationId == null &&
      status == null &&
      memoryKind == null &&
      pinnedOnly == null;

  List<PermanentMemory> apply(List<PermanentMemory> memories) {
    if (isEmpty) return List.unmodifiable(memories);
    return memories.where((m) {
      if (observerCharacterId != null && m.observerCharacterId != observerCharacterId) return false;
      if (originType != null && m.originType != originType) return false;
      if (originConversationId != null && m.originConversationId != originConversationId) return false;
      if (status != null && m.status != status) return false;
      if (memoryKind != null && m.kind != memoryKind) return false;
      if (pinnedOnly != null) {
        if (pinnedOnly! && !m.pinned) return false;
        if (!pinnedOnly! && m.pinned) return false;
      }
      if (subjectFilter == SubjectFilter.all) {
        // no subject filtering
      } else if (subjectFilter == SubjectFilter.aboutMe) {
        if (!m.subjectIds.contains('user')) return false;
      } else if (subjectFilter == SubjectFilter.selfGrowth) {
        if (m.subjectIds.isNotEmpty) return false;
      } else {
        if (!m.subjectIds.contains(subjectFilter.characterId)) return false;
      }
      return true;
    }).toList(growable: false);
  }
}
