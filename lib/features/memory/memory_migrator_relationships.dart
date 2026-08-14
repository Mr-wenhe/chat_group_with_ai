part of 'memory_migrator.dart';

extension _MemoryMigratorRelationships on MemoryMigrator {
  // ---- 4. RelationshipState -> 全局快照 + RelationshipEvent ----

  Future<_RelationshipMigrationResult> _migrateRelationshipStates() async {
    // A retry can run after the first pass has already written the global
    // snapshot but before the marker is durable. Only legacy per-group rows
    // are migration input; global rows are generated output.
    final oldStates = _db.relationshipStateBox.values
        .where((state) => state.groupId != 'global')
        .toList(growable: false);
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
      final key =
          '${rs.sourceCharacterId}|${rs.targetType.name}|${rs.targetId}';
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
          notesBefore: rs.notes,
          notesAfter: rs.notes,
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
    // Negative affinity takes precedence over familiarity. Otherwise a very
    // familiar relationship with strong hostility would be misclassified as
    // acquaintance, and the hostile branch would never be reachable.
    if (affinity < -40) return RelationshipStage.hostile;
    if (affinity < -20) return RelationshipStage.strained;
    if (familiarity == 0 && affinity <= 0) return RelationshipStage.stranger;
    if (familiarity < 20) return RelationshipStage.acquaintance;
    if (familiarity < 50) {
      if (affinity > 30) return RelationshipStage.friend;
      return RelationshipStage.acquaintance;
    }
    if (familiarity >= 50 && affinity > 40 && trust > 20) {
      return RelationshipStage.closeFriend;
    }
    if (familiarity >= 50) return RelationshipStage.friend;
    return RelationshipStage.acquaintance;
  }
}
