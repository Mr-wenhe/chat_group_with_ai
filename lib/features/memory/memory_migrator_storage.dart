part of 'memory_migrator.dart';

extension _MemoryMigratorStorage on MemoryMigrator {
  // ---- Storage and diagnostics ----

  /// 早期迁移没有给“关系”类旧记录写入用户主体，导致私聊范围无法安全识别。
  /// 这里只补主体元数据，不改正文、状态或稳定 ID，也不把自身成长误归给用户。
  Future<int> _repairLegacyUserSubjects() async {
    final memories = _db.permanentMemoryBox.values.toList(growable: false);
    var failed = 0;
    for (final memory in memories) {
      if (memory.originType != MemoryOriginType.legacyMigration ||
          memory.kind == MemoryKind.personaGrowth ||
          memory.subjectIds.isNotEmpty) {
        continue;
      }
      final previousSubjects = memory.subjectIds;
      memory.subjectIds = ['user'];
      try {
        await _savePermanentMemory(memory);
      } on Object {
        memory.subjectIds = previousSubjects;
        failed++;
      }
    }
    return failed;
  }

  Future<void> _savePermanentMemory(PermanentMemory memory) async {
    if (savePermanentMemory case final save?) {
      await save(memory);
      return;
    }
    await memory.save();
  }

  Future<bool> _putPermanentMemory(PermanentMemory memory) async {
    final key = _stableMemoryKey(memory);
    if (_db.permanentMemoryBox.containsKey(key)) return false;
    await _db.permanentMemoryBox.put(key, memory);
    return true;
  }

  String _stableMemoryKey(PermanentMemory memory) {
    final contentHash = _uuid.v5(
      _kUuidNamespaceUrl,
      '${memory.observerCharacterId}|${memory.kind.name}|${memory.content}',
    );
    return 'pm:${memory.observerCharacterId}:${memory.kind.name}:$contentHash';
  }

  Future<String> _resolveOriginName(String? conversationId) async {
    if (conversationId == null) return '未知';
    if (conversationId.startsWith('dm:')) {
      final charId = conversationId.substring(3);
      final char = _db.aiCharacterBox.get(charId);
      return char != null ? '私聊:${char.name}' : '已删除私聊';
    }
    final group = _db.chatGroupBox.get(conversationId);
    if (group != null) return '群聊:${group.name}';
    return '已删除群聊';
  }

  Map<String, dynamic>? _readMarker() {
    final raw = _db.appSettingsBox.get(_kMemoryMigrationMarkerKey);
    if (raw is! Map) return null;
    return {
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  Future<void> _writeMarker(Map<String, dynamic> marker) async {
    await _db.appSettingsBox.put(_kMemoryMigrationMarkerKey, marker);
  }

  Future<void> _writeDiagnostic({
    required String status,
    required int warningCount,
    required Set<String> reasonCodes,
    MemoryMigrationReport? report,
    int userProfileCreated = 0,
    int permanentMemoriesCreated = 0,
    int relationshipSnapshotsCreated = 0,
    int relationshipEventsCreated = 0,
  }) async {
    try {
      final sortedReasonCodes = reasonCodes.toList()..sort();
      await _db.appSettingsBox.put(MemoryMigrator.diagnosticKey, {
        'status': status,
        'warningCount': warningCount,
        'reasonCodes': sortedReasonCodes,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'stats': {
          'userProfiles': report?.userProfileCreated ?? userProfileCreated,
          'permanentMemories':
              report?.permanentMemoriesCreated ?? permanentMemoriesCreated,
          'relationshipSnapshots': report?.relationshipSnapshotsCreated ??
              relationshipSnapshotsCreated,
          'relationshipEvents':
              report?.relationshipEventsCreated ?? relationshipEventsCreated,
        },
      });
    } on Object {
      // A diagnostic write must never turn a completed migration into a
      // failure, and the original storage error must not be persisted.
    }
  }

  int _parseVersion(Map<String, dynamic> marker) {
    final rawVersion = marker['version'];
    if (rawVersion is num) return rawVersion.toInt();
    return int.tryParse(rawVersion?.toString() ?? '') ?? 0;
  }
}
