import 'dart:io';

import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/relationship_snapshot_rebuilder.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

/// 重建必须幂等：心情时间戳取事件时刻，不能取 now，否则每次重建都会续命。
void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(directory));

  final relationshipId = RelationshipState.stableGlobalId(
    'a',
    RelationshipTargetType.ai,
    'b',
  );

  RelationshipEvent eventWith({
    required String id,
    required RelationshipMood moodAfter,
    required DateTime occurredAt,
  }) =>
      RelationshipEvent(
        id: id,
        sourceCharacterId: 'a',
        targetType: RelationshipTargetType.ai,
        targetId: 'b',
        reason: '测试',
        affinityBefore: 0,
        affinityAfter: 0,
        trustBefore: 0,
        trustAfter: 0,
        frictionBefore: 0,
        frictionAfter: 0,
        familiarityBefore: 0,
        familiarityAfter: 1,
        moodBefore: RelationshipMood.neutral,
        moodAfter: moodAfter,
        stageBefore: RelationshipStage.stranger,
        stageAfter: RelationshipStage.stranger,
        originNameSnapshot: 'TestGroup',
        revision: 1,
        occurredAt: occurredAt,
        confidence: 0.5,
        createdBy: RelationshipEventCreator.automatic,
      );

  Future<void> rebuild() => RelationshipSnapshotRebuilder(
        db: db,
        settings: DataLifecycleSettings(db),
      ).rebuildFor([relationshipId]);

  test('重建快照的心情时间戳取事件时刻', () async {
    final at = DateTime(2026, 9, 23, 10, 0);
    await db.relationshipEventBox.put(
      'e1',
      eventWith(id: 'e1', moodAfter: RelationshipMood.warm, occurredAt: at),
    );

    await rebuild();

    final state = db.relationshipStateBox.values.single;
    expect(state.recentMood, RelationshipMood.warm);
    expect(state.recentMoodAt, at);
  });

  test('moodAfter 为 neutral 时不写时间戳', () async {
    await db.relationshipEventBox.put(
      'e2',
      eventWith(
        id: 'e2',
        moodAfter: RelationshipMood.neutral,
        occurredAt: DateTime(2026, 9, 23, 10, 0),
      ),
    );

    await rebuild();

    final state = db.relationshipStateBox.values.single;
    expect(state.recentMood, RelationshipMood.neutral);
    expect(state.recentMoodAt, isNull);
  });
}
