import 'dart:math';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:uuid/uuid.dart';

/// UUID v5 URL namespace constant (RFC 4122).
const _kUuidNamespaceUrl = '6ba7b811-9dad-11d1-80b4-00c04fd430c8';

/// 迁移 schema marker 版本；每次结构性变更递增。
const _kMemoryMigratorSchemaVersion = 1;

/// app_settings 中存储迁移完成的 marker key。
const _kMemoryMigrationMarkerKey = 'memory_migration_marker_v1';

/// 迁移报告。
class MemoryMigrationReport {
  final bool alreadyMigrated;
  final int userProfileCreated;
  final int permanentMemoriesCreated;
  final int relationshipSnapshotsCreated;
  final int relationshipEventsCreated;
  final String? selectedOwnerName;
  final List<String> warnings;

  const MemoryMigrationReport({
    required this.alreadyMigrated,
    required this.userProfileCreated,
    required this.permanentMemoriesCreated,
    required this.relationshipSnapshotsCreated,
    required this.relationshipEventsCreated,
    this.selectedOwnerName,
    this.warnings = const [],
  });

  bool get hasChanges =>
      userProfileCreated > 0 ||
      permanentMemoriesCreated > 0 ||
      relationshipSnapshotsCreated > 0 ||
      relationshipEventsCreated > 0;
}

/// 幂等迁移：将旧数据结构迁移到全局永久记忆系统。
///
/// 可安全重复执行；已完成的迁移不会重复生成记录。
class MemoryMigrator {
  final DatabaseService _db;
  final Uuid _uuid;
  final int _schemaVersion;

  MemoryMigrator(this._db, {Uuid? uuid, int? schemaVersion})
      : _uuid = uuid ?? const Uuid(),
        _schemaVersion = schemaVersion ?? _kMemoryMigratorSchemaVersion;

  Future<MemoryMigrationReport> migrate() async {
    final marker = _readMarker();
    if (marker != null && _parseVersion(marker) == _schemaVersion) {
      return const MemoryMigrationReport(
        alreadyMigrated: true,
        userProfileCreated: 0,
        permanentMemoriesCreated: 0,
        relationshipSnapshotsCreated: 0,
        relationshipEventsCreated: 0,
      );
    }

    final warnings = <String>[];
    int userProfiles = 0;
    int memories = 0;
    int relSnapshots = 0;
    int relEvents = 0;
    String? selectedOwnerName;

    final profileResult = await _migrateUserProfile();
    userProfiles = profileResult.created;
    selectedOwnerName = profileResult.selectedName;
    if (profileResult.warning != null) warnings.add(profileResult.warning!);

    memories += await _migrateCharacterMemories();
    memories += await _migrateMemorySummaries();

    final relResult = await _migrateRelationshipStates();
    relSnapshots = relResult.snapshotsCreated;
    relEvents = relResult.eventsCreated;
    warnings.addAll(relResult.warnings);

    await _writeMarker({
      'version': _schemaVersion,
      'migratedAt': DateTime.now().toUtc().toIso8601String(),
      'stats': {
        'userProfiles': userProfiles,
        'permanentMemories': memories,
        'relationshipSnapshots': relSnapshots,
        'relationshipEvents': relEvents,
      },
    });

    return MemoryMigrationReport(
      alreadyMigrated: false,
      userProfileCreated: userProfiles,
      permanentMemoriesCreated: memories,
      relationshipSnapshotsCreated: relSnapshots,
      relationshipEventsCreated: relEvents,
      selectedOwnerName: selectedOwnerName,
      warnings: warnings,
    );
  }

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
        .where((g) => g.ownerName.trim().isNotEmpty && g.ownerName.trim() != '我')
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
      warning = '多个 ownerName 候选(${candidates.join(',')})，已选择 "$displayName"，请在人物卡中确认';
    }

    final profile = UserProfile(
      displayName: displayName,
      preferredAddress: displayName,
      avatar: '',
      bio: '',
    );
    await _db.userProfileBox.put('me', profile);

    return _ProfileResult(created: 1, selectedName: displayName, warning: warning);
  }

  // ---- 2. CharacterMemory -> PermanentMemory ----

  Future<int> _migrateCharacterMemories() async {
    final memories = _db.characterMemoryBox.values.toList(growable: false);
    if (memories.isEmpty) return 0;

    int created = 0;
    for (final cm in memories) {
      final originType =
          cm.groupId.startsWith('dm:') ? MemoryOriginType.direct : MemoryOriginType.group;
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
          subjectIds: const [],
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

  Future<int> _migrateMemorySummaries() async {
    final characters = _db.aiCharacterBox.values.toList(growable: false);
    int created = 0;

    for (final char in characters) {
      final summary = char.memorySummary.trim();
      if (summary.isEmpty) continue;

      // 按角色粒度检查是否已迁移，支持部分重试
      final charMigratedKey = 'memory_summary_migrated_${char.id}';
      final alreadyMigrated = _db.appSettingsBox.get(charMigratedKey);
      if (alreadyMigrated == true) continue;

      // 解析 【标签】内容【标签】内容 格式，内容内部按 ； 拆分
      final taggedEntries = <MemoryKind, List<String>>{};
      final tagPattern = RegExp(r'【(事实|关系|成长)】([^【]*)');
      for (final match in tagPattern.allMatches(summary)) {
        final tag = match.group(1)?.trim();
        final rawContent = match.group(2)?.trim() ?? '';
        if (tag == null) continue;

        final entries = rawContent
            .split('；')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (entries.isEmpty) continue;

        final kind = switch (tag) {
          '事实' => MemoryKind.fact,
          '关系' => MemoryKind.relationshipNote,
          '成长' => MemoryKind.personaGrowth,
          _ => null,
        };
        if (kind != null) {
          taggedEntries.putIfAbsent(kind, () => []).addAll(entries);
        }
      }

      for (final entry in taggedEntries.entries) {
        for (final content in entry.value) {
          if (await _putPermanentMemory(PermanentMemory(
            observerCharacterId: char.id,
            kind: entry.key,
            content: content,
            subjectIds: const [],
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

      // 标记该角色摘要已迁移（无论是否提取到条目）
      await _db.appSettingsBox.put(charMigratedKey, true);
    }
    return created;
  }

  // ---- 4. RelationshipState -> 全局快照 + RelationshipEvent ----

  Future<_RelationshipMigrationResult> _migrateRelationshipStates() async {
    final oldStates = _db.relationshipStateBox.values.toList(growable: false);
    if (oldStates.isEmpty) {
      return const _RelationshipMigrationResult(
        snapshotsCreated: 0,
        eventsCreated: 0,
      );
    }

    final warnings = <String>[];
    final snapshotsCreated = <String>{};
    final eventsCreated = <String>{};

    final grouped = <String, List<RelationshipState>>{};
    for (final rs in oldStates) {
      final key = '${rs.sourceCharacterId}|${rs.targetType.name}|${rs.targetId}';
      grouped.putIfAbsent(key, () => []).add(rs);
    }

    for (final entry in grouped.entries) {
      final states = entry.value;
      states.sort((a, b) => b.lastInteractionAt.compareTo(a.lastInteractionAt));
      final latest = states.first;

      var totalFamiliarity = 0;
      double weightedAffinity = 0;
      double weightedTrust = 0;
      double weightedFriction = 0;
      double totalWeight = 0;

      for (final rs in states) {
        totalFamiliarity += rs.familiarity;
        final weight = max(1, rs.familiarity);
        weightedAffinity += rs.affinity * weight;
        weightedTrust += rs.trust * weight;
        weightedFriction += rs.friction * weight;
        totalWeight += weight;
      }

      final mergedFamiliarity = totalFamiliarity.clamp(0, 100);
      final mergedAffinity = totalWeight > 0
          ? (weightedAffinity / totalWeight).round().clamp(-100, 100)
          : 0;
      final mergedTrust = totalWeight > 0
          ? (weightedTrust / totalWeight).round().clamp(-100, 100)
          : 0;
      final mergedFriction = totalWeight > 0
          ? (weightedFriction / totalWeight).round().clamp(-100, 100)
          : 0;
      final mergedMood = latest.recentMood;

      final derivedStage = _deriveStage(
        affinity: mergedAffinity,
        trust: mergedTrust,
        familiarity: mergedFamiliarity,
      );

      final stableRelationId = RelationshipState.stableGlobalId(
        latest.sourceCharacterId,
        latest.targetType,
        latest.targetId,
      );

      final existing = _db.relationshipStateBox.get(stableRelationId);
      if (existing == null) {
        final snapshot = RelationshipState.global(
          id: stableRelationId,
          sourceCharacterId: latest.sourceCharacterId,
          targetType: latest.targetType,
          targetId: latest.targetId,
          affinity: mergedAffinity,
          trust: mergedTrust,
          friction: mergedFriction,
          familiarity: mergedFamiliarity,
          recentMood: mergedMood,
          notes: latest.notes,
          lastInteractionAt: latest.lastInteractionAt,
          stage: derivedStage,
          revision: 1,
          updatedAt: DateTime.now(),
        );
        await _db.relationshipStateBox.put(stableRelationId, snapshot);
      }
      snapshotsCreated.add(stableRelationId);

      for (final rs in states) {
        final eventId =
            'relevt:${rs.sourceCharacterId}:${rs.targetType.name}:${rs.targetId}:${rs.groupId}';
        if (eventsCreated.contains(eventId)) continue;

        final event = RelationshipEvent(
          sourceCharacterId: rs.sourceCharacterId,
          targetType: rs.targetType,
          targetId: rs.targetId,
          reason: 'legacyMigration: ${rs.groupId}',
          affinityBefore: rs.affinity,
          affinityAfter: rs.affinity,
          trustBefore: rs.trust,
          trustAfter: rs.trust,
          frictionBefore: rs.friction,
          frictionAfter: rs.friction,
          familiarityBefore: rs.familiarity,
          familiarityAfter: rs.familiarity,
          moodBefore: rs.recentMood,
          moodAfter: rs.recentMood,
          stageBefore: _deriveStage(
            affinity: rs.affinity,
            trust: rs.trust,
            familiarity: rs.familiarity,
          ),
          stageAfter: _deriveStage(
            affinity: rs.affinity,
            trust: rs.trust,
            familiarity: rs.familiarity,
          ),
          originConversationId: rs.groupId,
          originNameSnapshot: await _resolveOriginName(rs.groupId),
          sourceMessageIds: const [],
          revision: 1,
          occurredAt: rs.lastInteractionAt,
          confidence: 0.4,
          createdBy: RelationshipEventCreator.legacyMigration,
        );

        await _db.relationshipEventBox.put(eventId, event);
        eventsCreated.add(eventId);
      }
    }

    if (grouped.isNotEmpty) {
      warnings.add(
        '关系迁移仅保留各场合最后快照，迁移前的完整事件历史不可重建',
      );
    }

    return _RelationshipMigrationResult(
      snapshotsCreated: snapshotsCreated.length,
      eventsCreated: eventsCreated.length,
      warnings: warnings,
    );
  }

  RelationshipStage _deriveStage({
    required int affinity,
    required int trust,
    required int familiarity,
  }) {
    if (familiarity == 0 && affinity <= 0) return RelationshipStage.stranger;
    if (familiarity < 20) return RelationshipStage.acquaintance;
    if (familiarity < 50) {
      if (affinity > 30) return RelationshipStage.friend;
      return RelationshipStage.acquaintance;
    }
    if (familiarity >= 50 && affinity > 40 && trust > 20) {
      return RelationshipStage.closeFriend;
    }
    if (affinity < -20) return RelationshipStage.strained;
    if (affinity < -40) return RelationshipStage.hostile;
    if (familiarity >= 50) return RelationshipStage.friend;
    return RelationshipStage.acquaintance;
  }

  // ---- Helpers ----

  Future<bool> _putPermanentMemory(PermanentMemory memory) async {
    final key = _stableMemoryKey(memory);
    final existed = _db.permanentMemoryBox.containsKey(key);
    await _db.permanentMemoryBox.put(key, memory);
    return !existed;
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
      return char != null ? '私聊:${char.name}' : '私聊:$charId';
    }
    final group = _db.chatGroupBox.get(conversationId);
    if (group != null) return '群聊:${group.name}';
    return '群聊:$conversationId';
  }

  Map<String, dynamic>? _readMarker() {
    final raw = _db.appSettingsBox.get(_kMemoryMigrationMarkerKey);
    if (raw is Map<String, dynamic>) return raw;
    return null;
  }

  Future<void> _writeMarker(Map<String, dynamic> marker) async {
    await _db.appSettingsBox.put(_kMemoryMigrationMarkerKey, marker);
  }

  int _parseVersion(Map<String, dynamic> marker) =>
      (marker['version'] as int?) ?? 0;
}

class _ProfileResult {
  final int created;
  final String? selectedName;
  final String? warning;

  const _ProfileResult({
    required this.created,
    this.selectedName,
    this.warning,
  });
}

class _RelationshipMigrationResult {
  final int snapshotsCreated;
  final int eventsCreated;
  final List<String> warnings;

  const _RelationshipMigrationResult({
    required this.snapshotsCreated,
    required this.eventsCreated,
    this.warnings = const [],
  });
}
