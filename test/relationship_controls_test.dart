import 'dart:io';

import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/relationship_snapshot_rebuilder.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/memory/relationship_controls.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() async {
    await closeLifecycleHive(directory, db);
  });

  RelationshipState relation({
    String source = 'a',
    String target = 'b',
    RelationshipTargetType targetType = RelationshipTargetType.ai,
    int affinity = 10,
    int trust = 20,
    int friction = 3,
    int familiarity = 30,
    RelationshipMood mood = RelationshipMood.neutral,
    RelationshipStage stage = RelationshipStage.acquaintance,
    String notes = '旧备注',
  }) {
    return RelationshipState.global(
      sourceCharacterId: source,
      targetType: targetType,
      targetId: target,
      affinity: affinity,
      trust: trust,
      friction: friction,
      familiarity: familiarity,
      recentMood: mood,
      stage: stage,
      notes: notes,
      lastInteractionAt: DateTime(2026, 8, 1, 12),
    );
  }

  Future<void> put(RelationshipState value) =>
      db.relationshipStateBox.put(value.id, value);

  test('manual update writes a complete event before the global snapshot',
      () async {
    final initial = relation();
    await put(initial);
    final controls = RelationshipControls(db);

    final updated = await controls.applyManualUpdate(
      relationship: initial,
      affinity: 55,
      trust: 66,
      friction: 7,
      familiarity: 77,
      mood: RelationshipMood.warm,
      stage: RelationshipStage.romantic,
      notes: '  人工备注  ',
    );

    expect(updated, isNotNull);
    final event = db.relationshipEventBox.values.single;
    expect(event.createdBy, RelationshipEventCreator.manual);
    expect(event.reason, contains('用户手动编辑关系'));
    expect(event.revision, 1);
    expect(event.confidence, 1.0);
    expect(event.originConversationId, isNull);
    expect(event.originNameSnapshot, '人工编辑');
    expect(event.sourceMessageIds, isEmpty);
    expect(event.affinityBefore, 10);
    expect(event.affinityAfter, 55);
    expect(event.trustBefore, 20);
    expect(event.trustAfter, 66);
    expect(event.frictionBefore, 3);
    expect(event.frictionAfter, 7);
    expect(event.familiarityBefore, 30);
    expect(event.familiarityAfter, 77);
    expect(event.moodBefore, RelationshipMood.neutral);
    expect(event.moodAfter, RelationshipMood.warm);
    expect(event.stageBefore, RelationshipStage.acquaintance);
    expect(event.stageAfter, RelationshipStage.romantic);
    expect(event.notesBefore, '旧备注');
    expect(event.notesAfter, '人工备注');

    final stored = db.relationshipStateBox.get(initial.id)!;
    expect(stored.id,
        RelationshipState.stableGlobalId('a', RelationshipTargetType.ai, 'b'));
    expect(stored.groupId, 'global');
    expect(stored.revision, event.revision);
    expect(stored.lastEventId, event.id);
    expect(stored.affinity, event.affinityAfter);
    expect(stored.trust, event.trustAfter);
    expect(stored.friction, event.frictionAfter);
    expect(stored.familiarity, event.familiarityAfter);
    expect(stored.recentMood, event.moodAfter);
    expect(stored.stage, event.stageAfter);
    expect(stored.notes, event.notesAfter);
    expect(stored.lastInteractionAt, initial.lastInteractionAt);
  });

  test('manual update is idempotent and retry repairs a failed state write',
      () async {
    final initial = relation();
    await put(initial);
    final controls = RelationshipControls(db);
    controls.testFailStateWriteOnce = true;

    await expectLater(
      controls.applyManualUpdate(
        relationship: initial,
        affinity: 42,
        trust: 43,
        friction: 4,
        familiarity: 44,
        mood: RelationshipMood.awkward,
        stage: RelationshipStage.friend,
        notes: '重试备注',
      ),
      throwsA(isA<Object>()),
    );
    expect(db.relationshipEventBox.length, 1);
    expect(db.relationshipStateBox.get(initial.id)!.revision, 0);

    final repaired = await controls.applyManualUpdate(
      relationship: initial,
      affinity: 42,
      trust: 43,
      friction: 4,
      familiarity: 44,
      mood: RelationshipMood.awkward,
      stage: RelationshipStage.friend,
      notes: '重试备注',
    );
    expect(repaired!.revision, 1);
    expect(db.relationshipEventBox.length, 1);

    final noOp = await controls.applyManualUpdate(
      relationship: initial,
      affinity: 42,
      trust: 43,
      friction: 4,
      familiarity: 44,
      mood: RelationshipMood.awkward,
      stage: RelationshipStage.friend,
      notes: '重试备注',
    );
    expect(noOp!.revision, 1);
    expect(db.relationshipEventBox.length, 1);
  });

  test('old automatic replay preserves the current notes', () async {
    final initial = relation(notes: '人工备注');
    await put(initial);
    final event = RelationshipEvent(
      id: 'old-automatic-event',
      sourceCharacterId: initial.sourceCharacterId,
      targetType: initial.targetType,
      targetId: initial.targetId,
      reason: '旧自动事件',
      affinityBefore: initial.affinity,
      affinityAfter: 21,
      trustBefore: initial.trust,
      trustAfter: 31,
      frictionBefore: initial.friction,
      frictionAfter: initial.friction + 1,
      familiarityBefore: initial.familiarity,
      familiarityAfter: initial.familiarity + 2,
      moodBefore: initial.recentMood,
      moodAfter: RelationshipMood.warm,
      stageBefore: initial.stage,
      stageAfter: RelationshipStage.friend,
      originConversationId: 'g1',
      originNameSnapshot: '旧群聊',
      sourceMessageIds: const ['old-message'],
      revision: 1,
      occurredAt: DateTime(2026, 8, 2, 12),
      confidence: 0.8,
      createdBy: RelationshipEventCreator.automatic,
    );
    await db.relationshipEventBox.put(event.id, event);

    final repaired = await RelationshipControls(db).applyManualUpdate(
      relationship: initial,
      affinity: event.affinityAfter,
      trust: event.trustAfter,
      friction: event.frictionAfter,
      familiarity: event.familiarityAfter,
      mood: event.moodAfter,
      stage: event.stageAfter,
      notes: initial.notes,
    );

    expect(event.notesAfter, isEmpty);
    expect(repaired!.notes, initial.notes);
    expect(repaired.revision, event.revision);
    expect(db.relationshipEventBox.length, 1);
  });

  test('reset appends one manual event, keeps history and preserves pin',
      () async {
    final initial = relation();
    await put(initial);
    final controls = RelationshipControls(db);
    final edited = await controls.applyManualUpdate(
      relationship: initial,
      affinity: 50,
      trust: 40,
      friction: 10,
      familiarity: 60,
      mood: RelationshipMood.warm,
      stage: RelationshipStage.friend,
      notes: '需要保留的历史',
    );
    await controls.setPinned(edited!, true);

    final pinnedEdit = await controls.applyManualUpdate(
      relationship: edited,
      affinity: 51,
      trust: edited.trust,
      friction: edited.friction,
      familiarity: edited.familiarity,
      mood: edited.recentMood,
      stage: edited.stage,
      notes: edited.notes,
    );
    expect(controls.isPinned(pinnedEdit!), isTrue);

    final reset = await controls.resetRelationship(pinnedEdit);
    expect(reset!.affinity, 0);
    expect(reset.trust, 0);
    expect(reset.friction, 0);
    expect(reset.familiarity, 0);
    expect(reset.recentMood, RelationshipMood.neutral);
    expect(reset.stage, RelationshipStage.stranger);
    expect(reset.notes, isEmpty);
    expect(controls.isPinned(reset), isTrue);
    expect(db.relationshipEventBox.length, 3);
    expect(
      db.relationshipEventBox.values.where(
        (event) => event.reason == '用户重置关系',
      ),
      hasLength(1),
    );

    await controls.resetRelationship(reset);
    expect(db.relationshipEventBox.length, 3);
    expect(db.relationshipStateBox.get(initial.id), isNotNull);
  });

  test('delete removes one direction across global and legacy snapshots',
      () async {
    final aToB = relation();
    final bToA = relation(source: 'b', target: 'a');
    final cToB = relation(source: 'c', target: 'b');
    final legacy = RelationshipState(
      id: 'legacy-a-b',
      groupId: 'old-group',
      sourceCharacterId: 'a',
      targetType: RelationshipTargetType.ai,
      targetId: 'b',
    );
    await put(aToB);
    await put(bToA);
    await put(cToB);
    await db.relationshipStateBox.put(legacy.id, legacy);

    final controls = RelationshipControls(db);
    for (final value in [aToB, bToA, cToB]) {
      await controls.applyManualUpdate(
        relationship: value,
        affinity: value.affinity + 1,
        trust: value.trust,
        friction: value.friction,
        familiarity: value.familiarity,
        mood: value.recentMood,
        stage: value.stage,
        notes: value.notes,
      );
    }
    await controls.setPinned(aToB, true);

    await controls.deleteRelationshipHistory(aToB);

    expect(db.relationshipStateBox.get(aToB.id), isNull);
    expect(db.relationshipStateBox.get(bToA.id), isNotNull);
    expect(db.relationshipStateBox.get(cToB.id), isNotNull);
    expect(db.relationshipStateBox.get(legacy.id), isNull);
    expect(
      db.relationshipEventBox.values.where(
        (event) =>
            event.sourceCharacterId == 'a' &&
            event.targetType == RelationshipTargetType.ai &&
            event.targetId == 'b',
      ),
      isEmpty,
    );
    expect(controls.isPinned(aToB), isFalse);
    expect(
      db.relationshipEventBox.values.where(
        (event) => event.sourceCharacterId != 'a' || event.targetId != 'b',
      ),
      hasLength(2),
    );
    expect(
      controls.globalRelationships().map((value) => value.id),
      isNot(contains(aToB.id)),
    );
    expect(
      controls.globalRelationships().map((value) => value.id),
      containsAll(<String>[bToA.id, cToB.id]),
    );
  });

  test('deleted relationship stays absent after snapshot rebuild', () async {
    final global = relation(notes: '要删除的关系');
    final legacy = RelationshipState(
      id: 'legacy-a-b',
      groupId: 'old-group',
      sourceCharacterId: global.sourceCharacterId,
      targetType: global.targetType,
      targetId: global.targetId,
      notes: global.notes,
    );
    await put(global);
    await db.relationshipStateBox.put(legacy.id, legacy);

    await RelationshipControls(db).deleteRelationshipHistory(global);
    await RelationshipSnapshotRebuilder(
      db: db,
      settings: DataLifecycleSettings(db),
    ).rebuildFor([global.id]);

    final prompt = await MemoryContextSelector(db).select(
      observerCharacterId: global.sourceCharacterId,
      participantCharacterIds: [
        global.sourceCharacterId,
        global.targetId,
      ],
      currentTargetId: global.targetId,
    );
    expect(prompt, isEmpty);
    expect(db.relationshipStateBox.get(legacy.id), isNull);
  });

  test('manual score ranges reject invalid values', () async {
    final initial = relation();
    await put(initial);
    final controls = RelationshipControls(db);

    await expectLater(
      controls.applyManualUpdate(
        relationship: initial,
        affinity: 101,
        trust: 0,
        friction: 0,
        familiarity: 0,
        mood: RelationshipMood.neutral,
        stage: RelationshipStage.stranger,
        notes: '',
      ),
      throwsA(isA<RangeError>()),
    );
    expect(db.relationshipEventBox, isEmpty);
  });
}
