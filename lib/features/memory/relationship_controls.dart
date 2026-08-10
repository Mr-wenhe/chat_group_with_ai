import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/features/memory/relationship_direction_lock.dart';
import 'package:flutter/foundation.dart';

/// The persistence boundary for user-managed global relationships.
///
/// Widgets pass validated form values to this class. It owns the directional
/// lock, event idempotency, event-first write order, snapshot repair, pin
/// cleanup, and deletion scope.
class RelationshipControls {
  static const globalGroupId = 'global';

  final DatabaseService db;
  late final MemoryControls _memoryControls = MemoryControls(db);

  /// Test seam for the partial-write recovery contract.
  @visibleForTesting
  bool testFailStateWriteOnce = false;

  RelationshipControls(this.db);

  /// Returns one current global snapshot per stable directional relationship.
  /// Legacy per-group states are deliberately excluded.
  List<RelationshipState> globalRelationships() {
    final byStableId = <String, RelationshipState>{};
    for (final relationship in db.relationshipStateBox.values) {
      if (relationship.groupId != globalGroupId) continue;
      final stableId = _stableIdForState(relationship);
      final current = byStableId[stableId];
      if (current == null ||
          relationship.updatedAt.isAfter(current.updatedAt)) {
        byStableId[stableId] = relationship;
      }
    }
    final result = byStableId.values.toList()
      ..sort((a, b) {
        final updated = b.updatedAt.compareTo(a.updatedAt);
        if (updated != 0) return updated;
        return _stableIdForState(a).compareTo(_stableIdForState(b));
      });
    return result;
  }

  /// Returns all history for one direction, newest revision first.
  List<RelationshipEvent> eventsFor(
    RelationshipState relationship, {
    String? originConversationId,
  }) {
    final stableId = _stableIdForState(relationship);
    final events = db.relationshipEventBox.values.where((event) {
      if (_stableIdForEvent(event) != stableId) return false;
      if (originConversationId != null &&
          event.originConversationId != originConversationId) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final revision = b.revision.compareTo(a.revision);
        if (revision != 0) return revision;
        final occurred = b.occurredAt.compareTo(a.occurredAt);
        if (occurred != 0) return occurred;
        return b.id.compareTo(a.id);
      });
    return events;
  }

  bool isPinned(RelationshipState relationship) => _memoryControls
      .isPinned('relationship:${_stableIdForState(relationship)}');

  Future<void> setPinned(RelationshipState relationship, bool pinned) {
    return _memoryControls.setPinned(
      'relationship:${_stableIdForState(relationship)}',
      pinned,
    );
  }

  /// Applies absolute values from the manual editor.
  Future<RelationshipState?> applyManualUpdate({
    required RelationshipState relationship,
    required int affinity,
    required int trust,
    required int friction,
    required int familiarity,
    required RelationshipMood mood,
    required RelationshipStage stage,
    required String notes,
  }) {
    return _applyManualSnapshot(
      relationship: relationship,
      affinity: affinity,
      trust: trust,
      friction: friction,
      familiarity: familiarity,
      mood: mood,
      stage: stage,
      notes: notes,
      reason: '用户手动编辑关系',
      originNameSnapshot: '人工编辑',
    );
  }

  /// Resets one direction while retaining its state, history, and pin.
  Future<RelationshipState?> resetRelationship(
    RelationshipState relationship,
  ) {
    return _applyManualSnapshot(
      relationship: relationship,
      affinity: 0,
      trust: 0,
      friction: 0,
      familiarity: 0,
      mood: RelationshipMood.neutral,
      stage: RelationshipStage.stranger,
      notes: '',
      reason: '用户重置关系',
      originNameSnapshot: '人工重置',
    );
  }

  /// Deletes only the global state, events, and pin for one direction.
  Future<void> deleteRelationshipHistory(
    RelationshipState relationship,
  ) async {
    final stableId = _stableIdForState(relationship);
    await RelationshipDirectionLock.run<void>(
      db: db,
      relationshipId: stableId,
      action: () async {
        final eventEntries = [
          for (final key in db.relationshipEventBox.keys)
            if (_eventAtKeyMatches(db.relationshipEventBox.get(key), stableId))
              (key, db.relationshipEventBox.get(key)!),
        ];
        for (final entry in eventEntries) {
          await db.relationshipEventBox.delete(entry.$1);
        }

        final stateKeys = [
          for (final key in db.relationshipStateBox.keys)
            if (_stateAtKeyMatches(db.relationshipStateBox.get(key), stableId))
              key,
        ];
        for (final key in stateKeys) {
          await db.relationshipStateBox.delete(key);
        }

        // Keep the pin namespace clean even when the state was already gone.
        await _memoryControls.setPinned('relationship:$stableId', false);
      },
    );
  }

  Future<RelationshipState?> _applyManualSnapshot({
    required RelationshipState relationship,
    required int affinity,
    required int trust,
    required int friction,
    required int familiarity,
    required RelationshipMood mood,
    required RelationshipStage stage,
    required String notes,
    required String reason,
    required String originNameSnapshot,
  }) async {
    _validateScores(
      affinity: affinity,
      trust: trust,
      friction: friction,
      familiarity: familiarity,
    );
    final normalizedNotes = notes.trim();
    final stableId = _stableIdForState(relationship);

    return RelationshipDirectionLock.run<RelationshipState?>(
      db: db,
      relationshipId: stableId,
      action: () async {
        var current = _readGlobalOrSeed(relationship, stableId);
        current = await _repairPendingEvents(current);

        if (_sameEditableValues(
          current,
          affinity: affinity,
          trust: trust,
          friction: friction,
          familiarity: familiarity,
          mood: mood,
          stage: stage,
          notes: normalizedNotes,
        )) {
          return current;
        }

        final nextRevision = current.revision + 1;
        final eventId = _manualEventId(stableId, nextRevision, reason);
        final existingEvent = db.relationshipEventBox.get(eventId);
        if (existingEvent != null) {
          if (!_sameEventAfter(
            existingEvent,
            affinity: affinity,
            trust: trust,
            friction: friction,
            familiarity: familiarity,
            mood: mood,
            stage: stage,
            notes: normalizedNotes,
          )) {
            throw StateError('关系事件幂等键冲突：$eventId');
          }
          final repaired = _stateFromEvent(current, existingEvent);
          await _writeState(repaired);
          return repaired;
        }

        final now = DateTime.now();
        final event = RelationshipEvent(
          id: eventId,
          sourceCharacterId: current.sourceCharacterId,
          targetType: current.targetType,
          targetId: current.targetId,
          reason: reason,
          affinityBefore: current.affinity,
          affinityAfter: affinity,
          trustBefore: current.trust,
          trustAfter: trust,
          frictionBefore: current.friction,
          frictionAfter: friction,
          familiarityBefore: current.familiarity,
          familiarityAfter: familiarity,
          moodBefore: current.recentMood,
          moodAfter: mood,
          stageBefore: current.stage,
          stageAfter: stage,
          originConversationId: null,
          originNameSnapshot: originNameSnapshot,
          sourceMessageIds: const [],
          notesBefore: current.notes,
          notesAfter: normalizedNotes,
          revision: nextRevision,
          occurredAt: now,
          confidence: 1.0,
          createdBy: RelationshipEventCreator.manual,
        );

        // The event is the durable intent. If the snapshot write fails, the
        // next locked call can replay this absolute After state.
        await db.relationshipEventBox.put(event.id, event);
        final updated = _copyState(
          current,
          affinity: affinity,
          trust: trust,
          friction: friction,
          familiarity: familiarity,
          mood: mood,
          stage: stage,
          notes: normalizedNotes,
          revision: nextRevision,
          lastEventId: event.id,
          updatedAt: now,
        );
        await _writeState(updated);
        return updated;
      },
    );
  }

  Future<RelationshipState> _repairPendingEvents(
    RelationshipState relation,
  ) async {
    var current = relation;
    final pending = eventsFor(current)
        .where((event) => event.revision > current.revision)
        .toList()
      ..sort((a, b) => a.revision.compareTo(b.revision));
    for (final event in pending) {
      current = _stateFromEvent(current, event);
      await _writeState(current);
    }
    return current;
  }

  RelationshipState _stateFromEvent(
    RelationshipState current,
    RelationshipEvent event,
  ) {
    final interactionAt = event.createdBy == RelationshipEventCreator.manual
        ? current.lastInteractionAt
        : event.occurredAt;
    return _copyState(
      current,
      affinity: event.affinityAfter,
      trust: event.trustAfter,
      friction: event.frictionAfter,
      familiarity: event.familiarityAfter,
      mood: event.moodAfter,
      stage: event.stageAfter,
      notes: _notesAfterReplay(current, event),
      revision: event.revision,
      lastEventId: event.id,
      lastInteractionAt: interactionAt,
      updatedAt: DateTime.now(),
    );
  }

  String _notesAfterReplay(
    RelationshipState current,
    RelationshipEvent event,
  ) {
    // Older automatic events have no audited notes and deserialize as empty.
    if (event.createdBy == RelationshipEventCreator.automatic &&
        event.notesAfter.isEmpty) {
      return current.notes;
    }
    return event.notesAfter;
  }

  Future<void> _writeState(RelationshipState state) async {
    if (testFailStateWriteOnce) {
      testFailStateWriteOnce = false;
      throw StateError('测试模拟关系快照写入失败');
    }
    await db.relationshipStateBox.put(state.id, state);
  }

  RelationshipState _readGlobalOrSeed(
    RelationshipState supplied,
    String stableId,
  ) {
    if (supplied.groupId != globalGroupId) {
      throw StateError('旧版 per-group 关系不可编辑');
    }
    RelationshipState? stored = db.relationshipStateBox.get(stableId);
    stored ??=
        db.relationshipStateBox.values.cast<RelationshipState?>().firstWhere(
              (value) =>
                  value?.groupId == globalGroupId &&
                  value != null &&
                  _stableIdForState(value) == stableId,
              orElse: () => null,
            );
    if (stored == null) {
      return RelationshipState.global(
        id: stableId,
        sourceCharacterId: supplied.sourceCharacterId,
        targetType: supplied.targetType,
        targetId: supplied.targetId,
        affinity: supplied.affinity,
        trust: supplied.trust,
        friction: supplied.friction,
        familiarity: supplied.familiarity,
        recentMood: supplied.recentMood,
        notes: supplied.notes,
        lastInteractionAt: supplied.lastInteractionAt,
        stage: supplied.stage,
        revision: supplied.revision,
        lastEventId: supplied.lastEventId,
        updatedAt: supplied.updatedAt,
      );
    }
    if (stored.groupId != globalGroupId) {
      throw StateError('稳定关系 ID 被旧版 per-group 记录占用');
    }
    return stored.id == stableId ? stored : _copyState(stored);
  }

  RelationshipState _copyState(
    RelationshipState source, {
    int? affinity,
    int? trust,
    int? friction,
    int? familiarity,
    RelationshipMood? mood,
    RelationshipStage? stage,
    String? notes,
    DateTime? lastInteractionAt,
    int? revision,
    String? lastEventId,
    DateTime? updatedAt,
  }) {
    final stableId = _stableIdForState(source);
    return RelationshipState(
      id: stableId,
      groupId: globalGroupId,
      sourceCharacterId: source.sourceCharacterId,
      targetId: source.targetId,
      targetType: source.targetType,
      affinity: affinity ?? source.affinity,
      trust: trust ?? source.trust,
      friction: friction ?? source.friction,
      familiarity: familiarity ?? source.familiarity,
      recentMood: mood ?? source.recentMood,
      notes: notes ?? source.notes,
      lastInteractionAt: lastInteractionAt ?? source.lastInteractionAt,
      createdAt: source.createdAt,
      stage: stage ?? source.stage,
      revision: revision ?? source.revision,
      lastEventId: lastEventId ?? source.lastEventId,
      updatedAt: updatedAt ?? source.updatedAt,
    );
  }

  bool _sameEditableValues(
    RelationshipState current, {
    required int affinity,
    required int trust,
    required int friction,
    required int familiarity,
    required RelationshipMood mood,
    required RelationshipStage stage,
    required String notes,
  }) {
    return current.affinity == affinity &&
        current.trust == trust &&
        current.friction == friction &&
        current.familiarity == familiarity &&
        current.recentMood == mood &&
        current.stage == stage &&
        current.notes == notes;
  }

  bool _sameEventAfter(
    RelationshipEvent event, {
    required int affinity,
    required int trust,
    required int friction,
    required int familiarity,
    required RelationshipMood mood,
    required RelationshipStage stage,
    required String notes,
  }) {
    return event.affinityAfter == affinity &&
        event.trustAfter == trust &&
        event.frictionAfter == friction &&
        event.familiarityAfter == familiarity &&
        event.moodAfter == mood &&
        event.stageAfter == stage &&
        event.notesAfter == notes &&
        event.createdBy == RelationshipEventCreator.manual;
  }

  void _validateScores({
    required int affinity,
    required int trust,
    required int friction,
    required int familiarity,
  }) {
    if (affinity < -100 || affinity > 100) {
      throw RangeError.range(affinity, -100, 100, 'affinity');
    }
    if (trust < -100 || trust > 100) {
      throw RangeError.range(trust, -100, 100, 'trust');
    }
    if (friction < 0 || friction > 100) {
      throw RangeError.range(friction, 0, 100, 'friction');
    }
    if (familiarity < 0 || familiarity > 100) {
      throw RangeError.range(familiarity, 0, 100, 'familiarity');
    }
  }

  String _manualEventId(String stableId, int revision, String reason) =>
      're:manual:$stableId:$revision:${reason == '用户重置关系' ? 'reset' : 'edit'}';

  String _stableIdForState(RelationshipState relationship) =>
      RelationshipState.stableGlobalId(
        relationship.sourceCharacterId,
        relationship.targetType,
        relationship.targetId,
      );

  String _stableIdForEvent(RelationshipEvent event) =>
      RelationshipState.stableGlobalId(
        event.sourceCharacterId,
        event.targetType,
        event.targetId,
      );

  bool _eventAtKeyMatches(RelationshipEvent? event, String stableId) =>
      event != null && _stableIdForEvent(event) == stableId;

  bool _stateAtKeyMatches(RelationshipState? state, String stableId) =>
      state != null &&
      state.groupId == globalGroupId &&
      _stableIdForState(state) == stableId;
}
