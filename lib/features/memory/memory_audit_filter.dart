import 'package:chat_group/core/models/permanent_memory.dart';

enum MemoryConversationScopeType { settings, direct, group }

enum MemoryAuditSortOrder {
  updatedAtDescending,
  occurredAtDescending,
}

/// The complete user-visible search projection for one memory row.
///
/// The filter searches every field in this object. Callers that have friendly
/// character names should provide them here instead of passing a pre-joined
/// string, so observer, subject, source, kind, and status remain part of the
/// contract.
class MemoryAuditSearchProjection {
  final String content;
  final String observerName;
  final List<String> subjectNames;
  final String originName;
  final String kindLabel;
  final String statusLabel;

  const MemoryAuditSearchProjection({
    required this.content,
    required this.observerName,
    required this.subjectNames,
    required this.originName,
    required this.kindLabel,
    required this.statusLabel,
  });

  String get searchableText => [
        content,
        observerName,
        ...subjectNames,
        originName,
        kindLabel,
        statusLabel,
      ].join(' · ');
}

typedef MemoryAuditSearchText = MemoryAuditSearchProjection Function(
    PermanentMemory memory);

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

  /// Null means that the settings entry point has no scope restriction.
  Set<String>? get allowedObserverCharacterIds {
    return switch (type) {
      MemoryConversationScopeType.settings => null,
      MemoryConversationScopeType.direct =>
        Set.unmodifiable({directCharacterId!}),
      MemoryConversationScopeType.group => groupCharacterIds,
    };
  }

  /// Candidate subject IDs for the page; self-growth is represented by
  /// [SubjectFilter.selfGrowth] rather than an ID.
  ///
  /// In group scope the selected observer is removed by the page when it
  /// presents "other characters"; [apply] still enforces that distinction for
  /// ordinary subject records.
  Set<String>? get allowedSubjectIds {
    return switch (type) {
      MemoryConversationScopeType.settings => null,
      MemoryConversationScopeType.direct => const {'user'},
      MemoryConversationScopeType.group =>
        Set.unmodifiable({'user', ...groupCharacterIds}),
    };
  }

  /// Returns ordinary subject candidates for a selected observer. Self-growth
  /// remains a separate page option and is not represented by an ID here.
  Set<String>? subjectIdsForObserver(String observerCharacterId) {
    if (type == MemoryConversationScopeType.settings) return null;
    if (type == MemoryConversationScopeType.direct) {
      return observerCharacterId == directCharacterId
          ? const {'user'}
          : const {};
    }
    if (!groupCharacterIds.contains(observerCharacterId)) return const {};
    final subjects = {...allowedSubjectIds!}..remove(observerCharacterId);
    return Set.unmodifiable(subjects);
  }

  bool get isReadOnly => type != MemoryConversationScopeType.settings;

  List<PermanentMemory> apply(List<PermanentMemory> memories) {
    return memories.where(_allows).toList(growable: false);
  }

  bool _allows(PermanentMemory memory) {
    switch (type) {
      case MemoryConversationScopeType.settings:
        return true;
      case MemoryConversationScopeType.direct:
        return memory.observerCharacterId == directCharacterId &&
            memory.subjectIds.contains('user');
      case MemoryConversationScopeType.group:
        return _allowsGroupMemory(memory);
    }
  }

  bool _allowsGroupMemory(PermanentMemory memory) {
    if (!groupCharacterIds.contains(memory.observerCharacterId)) {
      return false;
    }

    // Only personaGrowth may use an empty subject list as a self-growth
    // record. Ordinary empty records have no defined safe audience.
    if (memory.subjectIds.isEmpty) {
      return memory.kind == MemoryKind.personaGrowth;
    }

    final allowedSubjects = {'user', ...groupCharacterIds};
    if (memory.kind != MemoryKind.personaGrowth) {
      // A normal record about the observing AI is not an "other character"
      // record; only personaGrowth may describe the observer itself.
      allowedSubjects.remove(memory.observerCharacterId);
    }
    return memory.subjectIds.every(allowedSubjects.contains);
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
  final String? searchQuery;
  final MemoryAuditSortOrder sortOrder;

  const MemoryAuditFilter({
    this.observerCharacterId,
    this.subjectFilter = SubjectFilter.all,
    this.originType,
    this.originConversationId,
    this.status,
    this.memoryKind,
    this.pinnedOnly,
    this.searchQuery,
    this.sortOrder = MemoryAuditSortOrder.updatedAtDescending,
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
    bool clearSearchQuery = false,
    bool clearSortOrder = false,
    String? observerCharacterId,
    SubjectFilter? subjectFilter,
    MemoryOriginType? originType,
    String? originConversationId,
    MemoryStatus? status,
    MemoryKind? memoryKind,
    bool? pinnedOnly,
    String? searchQuery,
    MemoryAuditSortOrder? sortOrder,
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
      searchQuery: clearSearchQuery ? null : (searchQuery ?? this.searchQuery),
      sortOrder: clearSortOrder
          ? MemoryAuditSortOrder.updatedAtDescending
          : (sortOrder ?? this.sortOrder),
    );
  }

  bool get isEmpty =>
      observerCharacterId == null &&
      subjectFilter == SubjectFilter.all &&
      originType == null &&
      originConversationId == null &&
      status == null &&
      memoryKind == null &&
      pinnedOnly == null &&
      (searchQuery == null || searchQuery!.trim().isEmpty) &&
      sortOrder == MemoryAuditSortOrder.updatedAtDescending;

  List<PermanentMemory> apply(
    List<PermanentMemory> memories, {
    MemoryConversationScope? scope,
    MemoryAuditSearchText? searchText,
  }) {
    // Apply the entry boundary before user-controlled filters so a filter can
    // only narrow the result, never add records back into it.
    final scopedMemories = scope?.apply(memories) ?? memories;
    final filtered = scopedMemories.where((m) {
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
        if (m.kind != MemoryKind.personaGrowth) {
          return false;
        }
      } else {
        if (!m.subjectIds.contains(subjectFilter.characterId)) {
          return false;
        }
      }
      if (!_matchesSearch(m, searchText)) return false;
      return true;
    }).toList(growable: false);
    return _sort(filtered);
  }

  bool _matchesSearch(
    PermanentMemory memory,
    MemoryAuditSearchText? searchText,
  ) {
    final query = searchQuery?.trim().toLowerCase();
    if (query == null || query.isEmpty) return true;
    final projection = searchText?.call(memory) ??
        MemoryAuditSearchProjection(
          content: memory.content,
          observerName: '',
          subjectNames: const [],
          originName: memory.originNameSnapshot,
          kindLabel: _kindLabel(memory.kind),
          statusLabel: _statusLabel(memory.status),
        );
    return projection.searchableText.toLowerCase().contains(query);
  }

  List<PermanentMemory> _sort(List<PermanentMemory> memories) {
    final indexed = [
      for (var index = 0; index < memories.length; index++)
        (memory: memories[index], index: index),
    ];
    indexed.sort((left, right) {
      final pinned = _rank(left.memory.pinned).compareTo(
        _rank(right.memory.pinned),
      );
      if (pinned != 0) return pinned;

      final history =
          _rank(left.memory.status == MemoryStatus.active).compareTo(
        _rank(right.memory.status == MemoryStatus.active),
      );
      if (history != 0) return history;

      final useOccurredAt =
          sortOrder == MemoryAuditSortOrder.occurredAtDescending &&
              left.memory.status == MemoryStatus.active &&
              right.memory.status == MemoryStatus.active;
      final primaryDate = useOccurredAt
          ? right.memory.occurredAt.compareTo(left.memory.occurredAt)
          : right.memory.updatedAt.compareTo(left.memory.updatedAt);
      if (primaryDate != 0) return primaryDate;

      final secondaryDate =
          sortOrder == MemoryAuditSortOrder.occurredAtDescending
              ? right.memory.updatedAt.compareTo(left.memory.updatedAt)
              : right.memory.occurredAt.compareTo(left.memory.occurredAt);
      if (secondaryDate != 0) return secondaryDate;

      final stableId = left.memory.id.compareTo(right.memory.id);
      if (stableId != 0) return stableId;
      return left.index.compareTo(right.index);
    });
    return List.unmodifiable(indexed.map((entry) => entry.memory));
  }

  int _rank(bool value) => value ? 0 : 1;

  String _kindLabel(MemoryKind kind) {
    return switch (kind) {
      MemoryKind.fact => '事实 知',
      MemoryKind.preference => '偏好',
      MemoryKind.commitment => '承诺',
      MemoryKind.sharedExperience => '经历',
      MemoryKind.relationshipNote => '关系',
      MemoryKind.personaGrowth => '成长',
      MemoryKind.explicitInstruction => '指令',
    };
  }

  String _statusLabel(MemoryStatus status) {
    return switch (status) {
      MemoryStatus.active => '有效',
      MemoryStatus.superseded => '已取代',
      MemoryStatus.invalidated => '已失效',
    };
  }
}

/// Immutable browsing state shared by the settings and chat memory entries.
class MemoryAuditPageState {
  final MemoryConversationScope scope;
  final MemoryAuditFilter filter;
  final bool historyExpanded;
  final double scrollOffset;

  const MemoryAuditPageState({
    this.scope = const MemoryConversationScope.settings(),
    this.filter = const MemoryAuditFilter(),
    this.historyExpanded = false,
    this.scrollOffset = 0,
  });

  MemoryAuditPageState copyWith({
    MemoryConversationScope? scope,
    MemoryAuditFilter? filter,
    bool? historyExpanded,
    double? scrollOffset,
  }) {
    return MemoryAuditPageState(
      scope: scope ?? this.scope,
      filter: filter ?? this.filter,
      historyExpanded: historyExpanded ?? this.historyExpanded,
      scrollOffset: scrollOffset ?? this.scrollOffset,
    );
  }
}
