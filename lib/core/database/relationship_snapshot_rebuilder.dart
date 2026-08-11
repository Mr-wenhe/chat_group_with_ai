import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';

/// Rebuilds one deterministic global relationship snapshot from its remaining
/// event history after a scoped event deletion.
///
/// Events contain absolute After values, so replay never accumulates a delta.
/// The ordered event list and the resulting state are therefore stable across
/// retries and repeated rebuilds.
class RelationshipSnapshotRebuilder {
  final DatabaseService db;
  final DataLifecycleSettings settings;

  const RelationshipSnapshotRebuilder({
    required this.db,
    required this.settings,
  });

  Future<void> rebuildFor(Iterable<String> relationshipIds) async {
    final ids = relationshipIds.toSet().toList()..sort();
    for (final relationshipId in ids) {
      await _rebuildOne(relationshipId);
    }
  }

  Future<void> _rebuildOne(String relationshipId) async {
    final events = db.relationshipEventBox.values
        .where((event) => _stableIdForEvent(event) == relationshipId)
        .toList()
      ..sort(_compareEvents);
    final stateEntries = [
      for (final key in db.relationshipStateBox.keys)
        if (_stateAtKeyMatches(
            db.relationshipStateBox.get(key), relationshipId))
          (key, db.relationshipStateBox.get(key)!),
    ];

    if (events.isEmpty) {
      for (final entry in stateEntries) {
        await db.relationshipStateBox.delete(entry.$1);
      }
      await settings.removeRelationshipPin(relationshipId);
      return;
    }

    final existing = stateEntries
        .map((entry) => entry.$2)
        .fold<RelationshipState?>(null, (current, candidate) {
      if (current == null || candidate.updatedAt.isAfter(current.updatedAt)) {
        return candidate;
      }
      return current;
    });
    // Automatic events copy the current note for replay compatibility, but do
    // not represent a note edit. Only explicit note-bearing events may change
    // the rebuilt value, otherwise a later automatic event can resurrect a
    // note whose manual event was deleted.
    final noteEvents = events
        .where((event) =>
            event.createdBy == RelationshipEventCreator.manual ||
            event.createdBy == RelationshipEventCreator.legacyMigration)
        .toList(growable: false);
    var notes = noteEvents.isEmpty ? '' : noteEvents.first.notesBefore;
    for (final event in noteEvents) {
      notes = event.notesAfter;
    }
    final last = events.last;
    final rebuilt = RelationshipState.global(
      id: relationshipId,
      sourceCharacterId: last.sourceCharacterId,
      targetType: last.targetType,
      targetId: last.targetId,
      affinity: last.affinityAfter,
      trust: last.trustAfter,
      friction: last.frictionAfter,
      familiarity: last.familiarityAfter,
      recentMood: last.moodAfter,
      notes: notes,
      lastInteractionAt: last.occurredAt,
      createdAt: existing?.createdAt ?? events.first.createdAt,
      stage: last.stageAfter,
      revision: last.revision,
      lastEventId: last.id,
      updatedAt: last.createdAt,
    );

    for (final entry in stateEntries) {
      if (entry.$1 != relationshipId) {
        await db.relationshipStateBox.delete(entry.$1);
      }
    }
    await db.relationshipStateBox.put(relationshipId, rebuilt);
  }

  static int compareEvents(RelationshipEvent a, RelationshipEvent b) =>
      _compareEvents(a, b);

  static String stableIdForEvent(RelationshipEvent event) =>
      _stableIdForEvent(event);

  static String stableIdForState(RelationshipState state) =>
      RelationshipState.stableGlobalId(
        state.sourceCharacterId,
        state.targetType,
        state.targetId,
      );

  static int _compareEvents(RelationshipEvent a, RelationshipEvent b) {
    final revision = a.revision.compareTo(b.revision);
    if (revision != 0) return revision;
    final occurred = a.occurredAt.compareTo(b.occurredAt);
    if (occurred != 0) return occurred;
    final created = a.createdAt.compareTo(b.createdAt);
    if (created != 0) return created;
    return a.id.compareTo(b.id);
  }

  static String _stableIdForEvent(RelationshipEvent event) =>
      RelationshipState.stableGlobalId(
        event.sourceCharacterId,
        event.targetType,
        event.targetId,
      );

  bool _stateAtKeyMatches(RelationshipState? state, String relationshipId) {
    return state?.groupId == 'global' &&
        state != null &&
        stableIdForState(state) == relationshipId;
  }
}
