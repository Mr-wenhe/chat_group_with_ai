import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

/// A localized term used by the memory browser.
class MemoryAuditLabel {
  final String label;
  final String description;

  const MemoryAuditLabel(this.label, this.description);
}

/// The single source of user-facing memory terminology.
class MemoryAuditLabels {
  const MemoryAuditLabels._();

  static MemoryAuditLabel kind(MemoryKind value) => switch (value) {
        MemoryKind.fact => const MemoryAuditLabel('事实', '记录相对稳定的信息'),
        MemoryKind.preference => const MemoryAuditLabel('偏好', '记录喜欢或不喜欢的事物'),
        MemoryKind.commitment => const MemoryAuditLabel('承诺', '记录约定或计划'),
        MemoryKind.sharedExperience =>
          const MemoryAuditLabel('共同经历', '记录你们共同经历的事情'),
        MemoryKind.relationshipNote =>
          const MemoryAuditLabel('关系', '记录关系变化或相处信息'),
        MemoryKind.personaGrowth =>
          const MemoryAuditLabel('自身成长', '记录观察 AI 对自身的成长理解'),
        MemoryKind.explicitInstruction =>
          const MemoryAuditLabel('明确指令', '记录用户要求长期遵守的内容'),
      };

  static MemoryAuditLabel originType(MemoryOriginType value) => switch (value) {
        MemoryOriginType.group => const MemoryAuditLabel('群聊', '从群聊产生的记忆'),
        MemoryOriginType.direct => const MemoryAuditLabel('私聊', '从私聊产生的记忆'),
        MemoryOriginType.manual => const MemoryAuditLabel('手动', '由你明确创建或修正的记忆'),
        MemoryOriginType.legacyMigration =>
          const MemoryAuditLabel('旧版迁移', '从旧版记忆结构转换而来，来源可能不完整'),
      };

  static MemoryAuditLabel status(MemoryStatus value) => switch (value) {
        MemoryStatus.active => const MemoryAuditLabel('有效', '可进入当前记忆检索候选'),
        MemoryStatus.superseded =>
          const MemoryAuditLabel('已取代', '已被新记忆替代，仅供历史审计'),
        MemoryStatus.invalidated =>
          const MemoryAuditLabel('已失效', '不再用于 Prompt，仅供历史审计'),
      };

  static MemoryAuditLabel pinned(bool value) => value
      ? const MemoryAuditLabel('固定', '自动流程不能覆盖或使其失效')
      : const MemoryAuditLabel('未固定', '自动流程可以按规则更新或失效');
}

/// The fields exposed to local memory search. Internal IDs are deliberately
/// absent so a technical identifier cannot become a user-visible search hit.
class MemoryAuditSearchProjection {
  final String content;
  final String observerName;
  final List<String> subjectNames;
  final String originName;
  final String kindLabel;
  final String statusLabel;
  final String originTypeLabel;
  final String pinnedLabel;

  const MemoryAuditSearchProjection({
    required this.content,
    required this.observerName,
    required this.subjectNames,
    required this.originName,
    required this.kindLabel,
    required this.statusLabel,
    this.originTypeLabel = '',
    this.pinnedLabel = '',
  });

  String get searchableText => [
        content,
        observerName,
        ...subjectNames,
        originName,
        kindLabel,
        statusLabel,
        originTypeLabel,
        pinnedLabel,
      ].join(' · ');
}

/// Immutable display data for one [PermanentMemory]. Only values needed by the
/// audit UI are copied; [memoryId] is used to resolve the current model for
/// actions.
class MemoryAuditRow {
  final String memoryId;
  final String content;
  final int importance;
  final double confidence;
  final bool explicitlyRequested;
  final bool pinnedValue;
  final DateTime updatedAt;
  final DateTime occurredAt;
  final String? invalidationReason;
  final List<String> sourceMessageIds;
  final int supersedesCount;
  final String observerName;
  final String observerAvatar;
  final List<String> subjectNames;
  final String originName;
  final MemoryAuditLabel kind;
  final MemoryAuditLabel originType;
  final MemoryAuditLabel status;
  final MemoryAuditLabel pinned;
  final MemoryOriginType originTypeValue;
  final MemoryStatus statusValue;

  MemoryAuditRow({
    required this.memoryId,
    required this.content,
    required this.importance,
    required this.confidence,
    required this.explicitlyRequested,
    required this.pinnedValue,
    required this.updatedAt,
    required this.occurredAt,
    required this.invalidationReason,
    required List<String> sourceMessageIds,
    required this.supersedesCount,
    required this.observerName,
    this.observerAvatar = '',
    required List<String> subjectNames,
    required this.originName,
    required this.kind,
    required this.originType,
    required this.status,
    required this.pinned,
    required this.originTypeValue,
    required this.statusValue,
  })  : sourceMessageIds = List.unmodifiable(sourceMessageIds),
        subjectNames = List.unmodifiable(subjectNames);

  bool get isActiveSection =>
      statusValue == MemoryStatus.active &&
      originTypeValue != MemoryOriginType.legacyMigration;

  MemoryAuditSearchProjection get searchProjection =>
      MemoryAuditSearchProjection(
        content: content,
        observerName: observerName,
        subjectNames: subjectNames,
        originName: originName,
        kindLabel: kind.label,
        statusLabel: status.label,
        originTypeLabel: originType.label,
        pinnedLabel: pinned.label,
      );

  /// Useful for assertions and accessibility tests; it contains no IDs.
  String get userVisibleText => [
        observerName,
        ...subjectNames,
        originName,
        content,
        kind.label,
        originType.label,
        status.label,
        pinned.label,
      ].join(' · ');
}

class MemoryAuditSections {
  final List<MemoryAuditRow> active;
  final List<MemoryAuditRow> history;

  MemoryAuditSections(
      {required List<MemoryAuditRow> active,
      required List<MemoryAuditRow> history})
      : active = List.unmodifiable(active),
        history = List.unmodifiable(history);

  List<MemoryAuditRow> get all => List.unmodifiable([...active, ...history]);
}

/// Resolves memory IDs into text for the audit UI without changing storage.
class MemoryAuditPresenter {
  static const _deletedCharacterName = '已删除角色';
  static const _deletedGroupName = '已删除群聊';
  static const _deletedDirectName = '已删除私聊';
  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  final Map<String, String> characterNames;
  final Map<String, String> characterAvatars;
  final Map<String, String> characterSnapshotNames;
  final Map<String, String> conversationNames;

  MemoryAuditPresenter({
    Map<String, String> characterNames = const {},
    Map<String, String> characterAvatars = const {},
    Map<String, String> characterSnapshotNames = const {},
    Map<String, String> conversationNames = const {},
  })  : characterNames = Map.unmodifiable(characterNames),
        characterAvatars = Map.unmodifiable(characterAvatars),
        characterSnapshotNames = Map.unmodifiable(characterSnapshotNames),
        conversationNames = Map.unmodifiable(conversationNames);

  MemoryAuditRow present(PermanentMemory memory) {
    return MemoryAuditRow(
      memoryId: memory.id,
      content: memory.content,
      importance: memory.importance,
      confidence: memory.confidence,
      explicitlyRequested: memory.explicitlyRequested,
      pinnedValue: memory.pinned,
      updatedAt: memory.updatedAt,
      occurredAt: memory.occurredAt,
      invalidationReason: memory.invalidationReason,
      sourceMessageIds: List.unmodifiable(memory.sourceMessageIds),
      supersedesCount: memory.supersedesIds.length,
      observerName: _characterName(memory.observerCharacterId),
      observerAvatar: characterAvatars[memory.observerCharacterId] ?? '',
      subjectNames: List.unmodifiable(
        memory.subjectIds.map(_characterName),
      ),
      originName: _conversationName(memory),
      kind: MemoryAuditLabels.kind(memory.kind),
      originType: MemoryAuditLabels.originType(memory.originType),
      status: MemoryAuditLabels.status(memory.status),
      pinned: MemoryAuditLabels.pinned(memory.pinned),
      originTypeValue: memory.originType,
      statusValue: memory.status,
    );
  }

  List<MemoryAuditRow> presentAll(Iterable<PermanentMemory> memories) {
    return List.unmodifiable(memories.map(present));
  }

  MemoryAuditSections sections(Iterable<PermanentMemory> memories) {
    final active = <MemoryAuditRow>[];
    final history = <MemoryAuditRow>[];
    for (final row in presentAll(memories)) {
      (row.isActiveSection ? active : history).add(row);
    }
    return MemoryAuditSections(
      active: _sort(active),
      history: _sort(history),
    );
  }

  String _characterName(String id) {
    if (id == 'user') return '我';
    return _safeName(characterNames[id], id) ??
        _safeName(characterSnapshotNames[id], id) ??
        _deletedCharacterName;
  }

  String resolveConversationName(
    String conversationId, {
    String snapshotName = '',
  }) {
    final id = conversationId.trim();
    if (id.isEmpty) {
      final directSnapshot = normalizeLegacyOriginSnapshot(
        snapshotName,
        originType: MemoryOriginType.direct,
      );
      if (snapshotName.trim().startsWith('私聊:')) {
        return _isUsefulDirectName(directSnapshot)
            ? '与 $directSnapshot 的私聊'
            : _deletedDirectName;
      }
      return normalizeLegacyOriginSnapshot(
            snapshotName,
            originType: MemoryOriginType.group,
          ) ??
          '来源场合不可用';
    }

    if (id.startsWith(DirectChatSession.prefix)) {
      final characterId = DirectChatSession.characterIdFrom(id);
      final characterName =
          characterId == null ? null : _characterNameOrNull(characterId);
      if (characterName != null) return '与 $characterName 的私聊';

      final conversationName = normalizeLegacyOriginSnapshot(
        conversationNames[id],
        originType: MemoryOriginType.direct,
        conversationId: id,
      );
      if (_isUsefulDirectName(conversationName)) {
        return '与 $conversationName 的私聊';
      }
      final snapshot = normalizeLegacyOriginSnapshot(
        snapshotName,
        originType: MemoryOriginType.direct,
        conversationId: id,
      );
      if (_isUsefulDirectName(snapshot)) return '与 $snapshot 的私聊';
      return _deletedDirectName;
    }

    return normalizeLegacyOriginSnapshot(
          conversationNames[id],
          originType: MemoryOriginType.group,
          conversationId: id,
        ) ??
        normalizeLegacyOriginSnapshot(
          snapshotName,
          originType: MemoryOriginType.group,
          conversationId: id,
        ) ??
        _deletedGroupName;
  }

  String _conversationName(PermanentMemory memory) {
    final id = memory.originConversationId?.trim();
    if (id == null || id.isEmpty) {
      final snapshot = normalizeLegacyOriginSnapshot(
        memory.originNameSnapshot,
        originType: memory.originType,
      );
      return switch (memory.originType) {
        MemoryOriginType.direct =>
          snapshot == null ? _deletedDirectName : '与 $snapshot 的私聊',
        MemoryOriginType.group => snapshot ?? _deletedGroupName,
        MemoryOriginType.manual => snapshot ?? '手动记录',
        MemoryOriginType.legacyMigration => snapshot ?? '旧版来源未知',
      };
    }
    return resolveConversationName(id, snapshotName: memory.originNameSnapshot);
  }

  String? _characterNameOrNull(String id) {
    if (id == 'user') return '我';
    return _safeName(characterNames[id], id) ??
        _safeName(characterSnapshotNames[id], id);
  }

  bool _isUsefulDirectName(String? value) {
    return value != null && value != '私聊' && value != '一对一私聊';
  }

  /// Removes the prefix written by the legacy migration and rejects its
  /// payload when it is the source conversation/character ID.
  static String? normalizeLegacyOriginSnapshot(
    String? value, {
    required MemoryOriginType originType,
    String? conversationId,
  }) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) return null;

    final prefix = RegExp(r'^(?:私聊|群聊)\s*:\s*').firstMatch(raw);
    final candidate = (prefix == null ? raw : raw.substring(prefix.end)).trim();
    if (candidate.isEmpty) return null;

    final ids = <String?>[
      conversationId,
      if (originType == MemoryOriginType.direct)
        DirectChatSession.characterIdFrom(conversationId ?? ''),
    ];
    if (ids.any((id) => isTechnicalName(candidate, id))) return null;
    return candidate;
  }

  static bool isTechnicalName(String value, [String? id]) {
    final normalized = _legacySnapshotPayload(value);
    return normalized == id ||
        normalized == _directCharacterId(id) ||
        normalized.startsWith(DirectChatSession.prefix) ||
        _uuidPattern.hasMatch(normalized);
  }

  static String safeDisplayName(String? value, [String? id]) {
    final name = value?.trim() ?? '';
    return name.isNotEmpty && !isTechnicalName(name, id) ? name : '已删除角色';
  }

  static String _legacySnapshotPayload(String value) {
    final raw = value.trim();
    final prefix = RegExp(r'^(?:私聊|群聊)\s*:\s*').firstMatch(raw);
    return prefix == null ? raw : raw.substring(prefix.end).trim();
  }

  static String? _directCharacterId(String? value) {
    if (value?.startsWith(DirectChatSession.prefix) != true) return null;
    return value!.substring(DirectChatSession.prefix.length);
  }

  String? _safeName(String? value, [String? id]) {
    final name = value?.trim() ?? '';
    if (name.isEmpty || isTechnicalName(name, id)) return null;
    return name;
  }

  List<MemoryAuditRow> _sort(List<MemoryAuditRow> rows) {
    final indexed = [
      for (var index = 0; index < rows.length; index++)
        (row: rows[index], index: index),
    ];
    indexed.sort((left, right) {
      final pinned = _boolRank(right.row.pinnedValue)
          .compareTo(_boolRank(left.row.pinnedValue));
      if (pinned != 0) return pinned;

      final updated = right.row.updatedAt.compareTo(left.row.updatedAt);
      if (updated != 0) return updated;

      final occurred = right.row.occurredAt.compareTo(left.row.occurredAt);
      if (occurred != 0) return occurred;

      final id = left.row.memoryId.compareTo(right.row.memoryId);
      return id != 0 ? id : left.index.compareTo(right.index);
    });
    return List.unmodifiable(indexed.map((entry) => entry.row));
  }

  int _boolRank(bool value) => value ? 1 : 0;
}
