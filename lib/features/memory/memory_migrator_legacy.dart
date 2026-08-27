part of 'memory_migrator.dart';

extension _MemoryMigratorLegacy on MemoryMigrator {
  // ---- 1. ownerName -> UserProfile ----

  Future<_ProfileResult> _migrateUserProfile() async {
    final groups = _db.chatGroupBox.values.toList(growable: false);
    final existing = _db.userProfileBox.get('me');
    if (existing != null) {
      return _ProfileResult(
        created: 0,
        selectedName: existing.displayName,
      );
    }

    final candidates = groups
        .where(
            (g) => g.ownerName.trim().isNotEmpty && g.ownerName.trim() != '我')
        .map((g) => g.ownerName.trim())
        .toSet()
        .toList();

    String displayName;
    String? warning;
    if (candidates.isEmpty) {
      displayName = '我';
    } else if (candidates.length == 1) {
      displayName = candidates.first;
    } else {
      candidates.sort((a, b) {
        final ga = groups.firstWhere((g) => g.ownerName.trim() == a,
            orElse: () => groups.first);
        final gb = groups.firstWhere((g) => g.ownerName.trim() == b,
            orElse: () => groups.first);
        return gb.createdAt.compareTo(ga.createdAt);
      });
      displayName = candidates.first;
      warning = '存在多个资料名称候选，已选择最近创建群组中的名称，请在人物卡中确认。';
    }

    final profile = UserProfile(
      displayName: displayName,
      preferredAddress: displayName,
      avatar: '',
      bio: '',
    );
    var created = false;
    await _runMigrationMutation(() async {
      // Re-check inside the gate so a profile created while the migration was
      // reading its snapshot is never overwritten by the legacy candidate.
      if (_db.userProfileBox.get('me') != null) return;
      await _db.userProfileBox.put('me', profile);
      created = true;
    });

    return _ProfileResult(
        created: created ? 1 : 0, selectedName: displayName, warning: warning);
  }

  // ---- 2. CharacterMemory -> PermanentMemory ----

  Future<int> _migrateCharacterMemories() async {
    final memories = _db.characterMemoryBox.values.toList(growable: false);
    if (memories.isEmpty) return 0;

    int created = 0;
    for (final cm in memories) {
      final originType = cm.groupId.startsWith('dm:')
          ? MemoryOriginType.direct
          : MemoryOriginType.group;
      final originName = await _resolveOriginName(cm.groupId);

      for (final fact in cm.facts) {
        if (await _putPermanentMemory(PermanentMemory(
          observerCharacterId: cm.characterId,
          kind: MemoryKind.fact,
          content: fact,
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          importance: 60,
          confidence: 0.5,
          originType: originType,
          originConversationId: cm.groupId,
          originNameSnapshot: originName,
          sourceMessageIds: const [],
          participantIds: const [],
          occurredAt: cm.lastUpdatedAt,
        ))) {
          created++;
        }
      }
      for (final note in cm.relationshipNotes) {
        if (await _putPermanentMemory(PermanentMemory(
          observerCharacterId: cm.characterId,
          kind: MemoryKind.relationshipNote,
          content: note,
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          importance: 55,
          confidence: 0.5,
          originType: originType,
          originConversationId: cm.groupId,
          originNameSnapshot: originName,
          sourceMessageIds: const [],
          participantIds: const [],
          occurredAt: cm.lastUpdatedAt,
        ))) {
          created++;
        }
      }
      for (final growth in cm.personaGrowth) {
        if (await _putPermanentMemory(PermanentMemory(
          observerCharacterId: cm.characterId,
          kind: MemoryKind.personaGrowth,
          content: growth,
          subjectIds: const [],
          status: MemoryStatus.active,
          importance: 50,
          confidence: 0.5,
          originType: originType,
          originConversationId: cm.groupId,
          originNameSnapshot: originName,
          sourceMessageIds: const [],
          participantIds: const [],
          occurredAt: cm.lastUpdatedAt,
        ))) {
          created++;
        }
      }
    }
    return created;
  }

  // ---- 3. memorySummary -> legacyMigration memories ----

  Future<_MemorySummaryMigrationResult> _migrateMemorySummaries() async {
    final characters = _db.aiCharacterBox.values.toList(growable: false);
    int created = 0;
    final failedCharacterIds = <String>[];
    final warnings = <String>[];

    for (final char in characters) {
      final summary = char.memorySummary.trim();
      if (summary.isEmpty) continue;

      // 按角色粒度检查是否已迁移，支持部分重试
      final charMigratedKey = 'memory_summary_migrated_v2_${char.id}';
      final alreadyMigrated = _db.appSettingsBox.get(charMigratedKey);
      if (alreadyMigrated == true) continue;

      try {
        // 解析 【标签】内容【标签】内容 格式，内容内部按 ； 拆分。
        // 整段无法完整解析时保留原文，避免部分提取造成不可逆丢失。
        final taggedEntries = _parseTaggedSummary(summary) ??
            <MemoryKind, List<String>>{
              MemoryKind.personaGrowth: [summary],
            };

        for (final entry in taggedEntries.entries) {
          for (final content in entry.value) {
            if (await _putPermanentMemory(PermanentMemory(
              observerCharacterId: char.id,
              kind: entry.key,
              content: content,
              subjectIds: entry.key == MemoryKind.personaGrowth
                  ? const []
                  : const ['user'],
              status: MemoryStatus.active,
              importance: 45,
              confidence: 0.3,
              originType: MemoryOriginType.legacyMigration,
              originConversationId: null,
              originNameSnapshot: '旧版跨会话摘要，原场合未知',
              sourceMessageIds: const [],
              participantIds: const [],
              occurredAt: char.createdAt,
            ))) {
              created++;
            }
          }
        }

        // 只有该角色的所有记录都写入成功后才落角色 marker。
        await _runMigrationMutation(
          () => _db.appSettingsBox.put(charMigratedKey, true),
        );
      } on StaleMigrationWrite {
        rethrow;
      } on Object {
        failedCharacterIds.add(char.id);
      }
    }
    if (failedCharacterIds.isNotEmpty) {
      warnings.add('部分角色的旧版摘要迁移失败，下次启动将重试。');
    }
    return _MemorySummaryMigrationResult(
      created: created,
      failedCharacterIds: failedCharacterIds,
      warnings: warnings,
    );
  }

  Map<MemoryKind, List<String>>? _parseTaggedSummary(String summary) {
    final tagPattern = RegExp(r'【(事实|关系|成长)】([^【]*)');
    final matches = tagPattern.allMatches(summary).toList(growable: false);
    if (matches.isEmpty) return null;

    final entries = <MemoryKind, List<String>>{};
    var cursor = 0;
    for (final match in matches) {
      if (summary.substring(cursor, match.start).trim().isNotEmpty) {
        return null;
      }
      final rawContent = match.group(2)?.trim() ?? '';
      final values = rawContent
          .split('；')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList();
      if (values.isEmpty) return null;

      final kind = switch (match.group(1)?.trim()) {
        '事实' => MemoryKind.fact,
        '关系' => MemoryKind.relationshipNote,
        '成长' => MemoryKind.personaGrowth,
        _ => null,
      };
      if (kind == null) return null;
      entries.putIfAbsent(kind, () => []).addAll(values);
      cursor = match.end;
    }
    if (summary.substring(cursor).trim().isNotEmpty) return null;
    return entries.isEmpty ? null : entries;
  }
}
