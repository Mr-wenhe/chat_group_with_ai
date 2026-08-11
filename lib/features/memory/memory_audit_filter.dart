import 'package:chat_group/core/models/permanent_memory.dart';

enum MemoryConversationScopeType { settings, direct, group }

/// Limits chat-entry memory views without changing the global memory model.
class MemoryConversationScope {
  final MemoryConversationScopeType type;
  final String? directCharacterId;
  final Set<String> groupCharacterIds;

  const MemoryConversationScope.settings()
      : type = MemoryConversationScopeType.settings,
        directCharacterId = null,
        groupCharacterIds = const {};

  MemoryConversationScope.direct(String characterId)
      : type = MemoryConversationScopeType.direct,
        directCharacterId = characterId,
        groupCharacterIds = const {};

  MemoryConversationScope.group(Set<String> characterIds)
      : type = MemoryConversationScopeType.group,
        directCharacterId = null,
        groupCharacterIds = Set.unmodifiable(characterIds);

  bool get isReadOnly => type != MemoryConversationScopeType.settings;

  List<PermanentMemory> apply(List<PermanentMemory> memories) {
    return memories.where((memory) {
      if (type == MemoryConversationScopeType.settings) return true;
      if (type == MemoryConversationScopeType.direct) {
        return memory.observerCharacterId == directCharacterId &&
            memory.subjectIds.contains('user');
      }
      if (!groupCharacterIds.contains(memory.observerCharacterId)) return false;
      if (memory.subjectIds.isEmpty) return true;
      final visibleSubjects = {'user', ...groupCharacterIds};
      return memory.subjectIds.every(visibleSubjects.contains);
    }).toList(growable: false);
  }
}

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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubjectFilter &&
          runtimeType == other.runtimeType &&
          characterId == other.characterId;

  @override
  int get hashCode => characterId.hashCode;
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

  /// Copy with explicit-clear semantics: a parameter value of `clear: true`
  /// resets that field to its default; `clear: false` keeps the current value;
  /// a non-null non-boolean parameter sets the new value.
  MemoryAuditFilter copyWith({
    bool clearObserverCharacterId = false,
    bool clearSubjectFilter = false,
    bool clearOriginType = false,
    bool clearOriginConversationId = false,
    bool clearStatus = false,
    bool clearMemoryKind = false,
    bool clearPinnedOnly = false,
    String? observerCharacterId,
    SubjectFilter? subjectFilter,
    MemoryOriginType? originType,
    String? originConversationId,
    MemoryStatus? status,
    MemoryKind? memoryKind,
    bool? pinnedOnly,
  }) {
    return MemoryAuditFilter(
      observerCharacterId: clearObserverCharacterId
          ? null
          : (observerCharacterId ?? this.observerCharacterId),
      subjectFilter: clearSubjectFilter
          ? SubjectFilter.all
          : (subjectFilter ?? this.subjectFilter),
      originType: clearOriginType ? null : (originType ?? this.originType),
      originConversationId: clearOriginConversationId
          ? null
          : (originConversationId ?? this.originConversationId),
      status: clearStatus ? null : (status ?? this.status),
      memoryKind: clearMemoryKind ? null : (memoryKind ?? this.memoryKind),
      pinnedOnly: clearPinnedOnly ? null : (pinnedOnly ?? this.pinnedOnly),
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
      if (observerCharacterId != null &&
          m.observerCharacterId != observerCharacterId) {
        return false;
      }
      if (originType != null && m.originType != originType) {
        return false;
      }
      if (originConversationId != null &&
          m.originConversationId != originConversationId) {
        return false;
      }
      if (status != null && m.status != status) return false;
      if (memoryKind != null && m.kind != memoryKind) return false;
      if (pinnedOnly != null) {
        if (pinnedOnly! && !m.pinned) return false;
        if (!pinnedOnly! && m.pinned) return false;
      }
      if (subjectFilter == SubjectFilter.all) {
        // no subject filtering
      } else if (subjectFilter == SubjectFilter.aboutMe) {
        if (!m.subjectIds.contains('user')) {
          return false;
        }
      } else if (subjectFilter == SubjectFilter.selfGrowth) {
        if (m.kind != MemoryKind.personaGrowth && m.subjectIds.isNotEmpty) {
          return false;
        }
      } else {
        if (!m.subjectIds.contains(subjectFilter.characterId)) {
          return false;
        }
      }
      return true;
    }).toList(growable: false);
  }
}
