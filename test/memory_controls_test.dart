// ignore_for_file: prefer_const_constructors, prefer_const_declarations
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/humanized_memory_service.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
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
    await db.permanentMemoryBox.clear();
    await db.aiCharacterBox.clear();
    await db.characterMemoryBox.clear();
    await db.messageBox.clear();
    await db.appSettingsBox.clear();
    await closeLifecycleHive(directory, db);
  });

  test('deleting a structured memory also removes the legacy prompt copy',
      () async {
    final character = testCharacter('c1')
      ..memorySummary = '【事实】用户住在上海；用户养猫\n【成长】喜欢简洁回答';
    final memory = CharacterMemory(
      id: 'm1',
      groupId: 'g1',
      characterId: character.id,
      facts: ['用户住在上海', '用户养猫'],
      personaGrowth: ['喜欢简洁回答'],
    );
    await db.aiCharacterBox.put(character.id, character);
    await db.characterMemoryBox.put(memory.id, memory);

    await MemoryControls(db).deleteCharacterEntry(
      memory: memory,
      character: character,
      layer: CharacterMemoryLayer.facts,
      index: 0,
    );

    expect(db.characterMemoryBox.get(memory.id)!.facts, ['用户养猫']);
    expect(db.aiCharacterBox.get(character.id)!.memorySummary,
        isNot(contains('用户住在上海')));
    expect(
        db.aiCharacterBox.get(character.id)!.memorySummary, contains('用户养猫'));
  });

  test('pinned memory and disabled automatic memory block automatic updates',
      () async {
    final character = testCharacter('c1');
    final memory = CharacterMemory(
      id: 'm1',
      groupId: 'g1',
      characterId: character.id,
    );
    final controls = MemoryControls(db);

    expect(controls.canAutoUpdateCharacter(memory, character), isTrue);
    await controls.setPinned(controls.characterKey(memory), true);
    expect(controls.canAutoUpdateCharacter(memory, character), isFalse);

    await controls.setPinned(controls.characterKey(memory), false);
    await controls.setAutomaticMemoryEnabled(false);
    expect(controls.canAutoUpdateCharacter(memory, character), isFalse);
    expect(controls.automaticMemoryEnabled, isFalse);
  });

  test(
      'a pinned character entry survives automatic updates without freezing its layer',
      () async {
    final character = testCharacter('c1')..memorySummary = '【事实】用户住在上海；旧事实';
    final memory = CharacterMemory(
      id: 'm1',
      groupId: 'g1',
      characterId: character.id,
      facts: ['用户住在上海', '旧事实'],
    );
    final controls = MemoryControls(db);
    await controls.setPinned(
      controls.characterEntryKey(
        memory,
        CharacterMemoryLayer.facts,
        '用户住在上海',
      ),
      true,
    );
    final update = LayeredMemoryUpdate(
      facts: List.generate(10, (index) => '新事实$index'),
    );

    controls.mergeAutomaticCharacterMemory(memory, update);
    character.memorySummary = controls.mergeAutomaticGlobalSummary(
      character: character,
      memory: memory,
      update: update,
    );

    expect(memory.facts, contains('用户住在上海'));
    expect(memory.facts, contains('新事实9'));
    expect(memory.facts, isNot(contains('旧事实')));
    expect(character.memorySummary, contains('用户住在上海'));
  });

  test('editing a pinned entry moves its pin to the new value', () async {
    final character = testCharacter('c1')..memorySummary = '【事实】旧值';
    final memory = CharacterMemory(
      id: 'm1',
      groupId: 'g1',
      characterId: character.id,
      facts: ['旧值'],
    );
    final controls = MemoryControls(db);
    final oldKey = controls.characterEntryKey(
      memory,
      CharacterMemoryLayer.facts,
      '旧值',
    );
    await controls.setPinned(oldKey, true);

    await controls.updateCharacterEntry(
      memory: memory,
      character: character,
      layer: CharacterMemoryLayer.facts,
      index: 0,
      value: '新值',
    );

    expect(controls.isPinned(oldKey), isFalse);
    expect(
      controls.isPinned(controls.characterEntryKey(
        memory,
        CharacterMemoryLayer.facts,
        '新值',
      )),
      isTrue,
    );
  });

  test('a pinned relationship rejects local automatic updates', () async {
    final relationship = RelationshipState(
      id: 'r1',
      groupId: 'g1',
      sourceCharacterId: 'c1',
      targetId: 'user',
      targetType: RelationshipTargetType.user,
    );
    final controls = MemoryControls(db);

    expect(controls.canAutoUpdateRelationship(relationship), isTrue);
    await controls.setPinned(controls.relationshipKey(relationship), true);
    expect(controls.canAutoUpdateRelationship(relationship), isFalse);
  });

  test('forgetting a group topic clears the source record without deleting it',
      () async {
    final memory = GroupMemory(groupId: 'g1', topicSummary: '旧话题');
    await db.groupMemoryBox.put('g1_week', memory);

    await MemoryControls(db).forgetTopic('g1');

    expect(db.groupMemoryBox.containsKey('g1_week'), isTrue);
    expect(db.groupMemoryBox.get('g1_week')!.topicSummary, isEmpty);
  });

  test('forgetting user content clears structured and legacy injection paths',
      () async {
    final character = testCharacter('c1')..memorySummary = '用户的敏感偏好';
    final memory = CharacterMemory(
      id: 'm1',
      groupId: 'g1',
      characterId: character.id,
      facts: ['用户的敏感偏好'],
      relationshipNotes: ['用户不喜欢被追问'],
      personaGrowth: ['角色说话更简洁'],
    );
    await db.aiCharacterBox.put(character.id, character);
    await db.chatGroupBox.put(
      'g1',
      ChatGroup(
        id: 'g1',
        name: '测试群',
        theme: '测试',
        aiCharacterIds: [character.id],
      ),
    );
    await db.characterMemoryBox.put(memory.id, memory);

    await MemoryControls(db).forgetAboutUser('g1');

    final stored = db.characterMemoryBox.get(memory.id)!;
    expect(stored.facts, isEmpty);
    expect(stored.relationshipNotes, isEmpty);
    expect(stored.personaGrowth, ['角色说话更简洁']);
    expect(db.aiCharacterBox.get(character.id)!.memorySummary, isEmpty);
  });

  group('MemoryControls permanent memory operations', () {
    test('pinPermanent persists and un-pin clears', () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final memory = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '用户喜欢苹果',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
      );
      await db.permanentMemoryBox.put(memory.id, memory);
      final controls = MemoryControls(db);

      await controls.pinPermanent(memory);
      expect(db.permanentMemoryBox.get(memory.id)!.pinned, isTrue);

      await controls.unpinPermanent(memory);
      expect(db.permanentMemoryBox.get(memory.id)!.pinned, isFalse);
    });

    test('editPermanent creates new manual record and supersedes old',
        () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final old = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '用户喜欢吃苹果',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        subjectIds: const ['user'],
      );
      await db.permanentMemoryBox.put(old.id, old);
      final controls = MemoryControls(db);

      final newMemory = await controls.editPermanent(
        old,
        correctedContent: '用户喜欢吃苹果和香蕉',
        subjectIds: const ['user'],
      );

      expect(newMemory.status, MemoryStatus.active);
      expect(newMemory.originType, MemoryOriginType.manual);
      expect(newMemory.confidence, 1.0);
      expect(newMemory.sourceMessageIds, isEmpty);
      expect(newMemory.supersedesIds, contains(old.id));
      expect(newMemory.content, '用户喜欢吃苹果和香蕉');
      expect(
          db.permanentMemoryBox.get(old.id)!.status, MemoryStatus.superseded);
    });

    test('editPermanent with stable key != memory.id works correctly',
        () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      // Simulate migrator: stable key differs from memory.id.
      final old = PermanentMemory(
        id: 'migrated-uuid-123',
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '迁移内容',
        status: MemoryStatus.active,
        originType: MemoryOriginType.legacyMigration,
        originNameSnapshot: '旧数据',
        subjectIds: const ['user'],
      );
      final stableKey = 'pm:c1:fact:migrated-stable-hash';
      await db.permanentMemoryBox.put(stableKey, old);
      final controls = MemoryControls(db);

      final result = await controls.editPermanent(
        old,
        correctedContent: '修正后的迁移内容',
        subjectIds: const ['user'],
      );

      // The old record at stable key should now be superseded.
      final storedOld = db.permanentMemoryBox.get(stableKey);
      expect(storedOld, isNotNull);
      expect(storedOld!.status, MemoryStatus.superseded);
      // New record should be a separate entry with a new id.
      expect(result.id, isNot('migrated-uuid-123'));
      expect(result.content, '修正后的迁移内容');
      expect(result.supersedesIds, contains('migrated-uuid-123'));
    });

    test(
        'editPermanent is idempotent — duplicate save does not create extra records',
        () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final old = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '用户住在上海',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        subjectIds: const ['user'],
      );
      await db.permanentMemoryBox.put(old.id, old);
      final controls = MemoryControls(db);

      final first = await controls.editPermanent(old,
          correctedContent: '用户住在北京', subjectIds: const ['user']);
      final second = await controls.editPermanent(first,
          correctedContent: '用户住在北京', subjectIds: const ['user']);

      expect(first.id, second.id);
      final allActive = db.permanentMemoryBox.values
          .where((m) => m.status == MemoryStatus.active)
          .toList();
      expect(allActive.length, 1);
    });

    test('concurrent identical corrections create one replacement', () async {
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final old = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '原内容',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        subjectIds: const ['user'],
      );
      await db.permanentMemoryBox.put(old.id, old);

      final first = MemoryControls(db);
      final second = MemoryControls(db);
      final results = await Future.wait([
        first.editPermanent(
          old,
          correctedContent: '并发修正',
          subjectIds: const ['user'],
        ),
        second.editPermanent(
          old,
          correctedContent: '并发修正',
          subjectIds: const ['user'],
        ),
      ]);

      final active = db.permanentMemoryBox.values
          .where((memory) => memory.status == MemoryStatus.active)
          .toList();
      expect(results[0].id, results[1].id);
      expect(active, hasLength(1));
      expect(active.single.content, '并发修正');
    });

    test('editPermanent does not self-supersede when old is already superseded',
        () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final old = PermanentMemory(
        id: 'old-id',
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '旧内容',
        status: MemoryStatus.superseded,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        subjectIds: const ['user'],
      );
      final existingCorrection = PermanentMemory(
        id: 'existing-correct',
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '修正内容',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '群1',
        subjectIds: const ['user'],
        supersedesIds: ['old-id'],
      );
      await db.permanentMemoryBox
          .putAll({'old-id': old, 'existing-correct': existingCorrection});
      final controls = MemoryControls(db);

      final result = await controls.editPermanent(
        old,
        correctedContent: '修正内容',
        subjectIds: const ['user'],
      );

      // Should return the existing correction without creating a new one.
      expect(result.id, 'existing-correct');
      final activeCount = db.permanentMemoryBox.values
          .where((m) => m.status == MemoryStatus.active)
          .length;
      expect(activeCount, 1);
    });

    test('editPermanent on pinned record warns and still supersedes', () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final old = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '用户住在上海',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        pinned: true,
        subjectIds: const ['user'],
      );
      await db.permanentMemoryBox.put(old.id, old);
      final controls = MemoryControls(db);

      final newMemory = await controls.editPermanent(old,
          correctedContent: '用户住在北京', subjectIds: const ['user']);

      expect(newMemory.status, MemoryStatus.active);
      expect(
          db.permanentMemoryBox.get(old.id)!.status, MemoryStatus.superseded);
      expect(db.permanentMemoryBox.get(old.id)!.pinned,
          isTrue); // pin flag preserved on old
    });

    test('deletePermanent physically removes record', () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final memory = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '用户住在上海',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
      );
      await db.permanentMemoryBox.put(memory.id, memory);
      final controls = MemoryControls(db);

      await controls.deletePermanent(memory);
      expect(db.permanentMemoryBox.get(memory.id), isNull);
    });

    test(
        'deletePermanent does not delete other records in the same correction chain',
        () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final v1 = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: 'v1',
        status: MemoryStatus.superseded,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
      );
      final v2 = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: 'v2',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        supersedesIds: [v1.id],
      );
      await db.permanentMemoryBox.putAll({v1.id: v1, v2.id: v2});
      final controls = MemoryControls(db);

      await controls.deletePermanent(v2);
      expect(db.permanentMemoryBox.get(v1.id), isNotNull);
      expect(db.permanentMemoryBox.get(v2.id), isNull);
    });

    test('supersededByCount computes reverse chain correctly', () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final v1 = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: 'v1',
        status: MemoryStatus.superseded,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
      );
      final v2 = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: 'v2',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        supersedesIds: [v1.id],
      );
      final v3 = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: 'v3',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        supersedesIds: [v1.id],
      );
      await db.permanentMemoryBox.putAll({v1.id: v1, v2.id: v2, v3.id: v3});
      final controls = MemoryControls(db);

      expect(controls.supersededByCount(v1.id), 2);
      expect(controls.supersededByCount(v2.id), 0);
    });

    test('editPermanent normalizes subjectIds (trim, dedup)', () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final old = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '原内容',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        subjectIds: const ['user'],
      );
      await db.permanentMemoryBox.put(old.id, old);
      final controls = MemoryControls(db);

      final result = await controls.editPermanent(
        old,
        correctedContent: '修正',
        subjectIds: [' user ', 'c2', 'c2', ''],
      );

      expect(result.subjectIds, contains('user'));
      expect(result.subjectIds, contains('c2'));
      expect(result.subjectIds.length, 2);
    });

    test(
        'editPermanent with matching active existing: record count unchanged, '
        'old is superseded, returned and stored existing contain old.id',
        () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final old = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '原内容',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        subjectIds: const ['user'],
      );
      final existing = PermanentMemory(
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '修正内容',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '群1',
        subjectIds: const ['user'],
        supersedesIds: const [],
      );
      await db.permanentMemoryBox.putAll({old.id: old, existing.id: existing});
      final controls = MemoryControls(db);

      final result = await controls.editPermanent(
        old,
        correctedContent: '修正内容',
        subjectIds: const ['user'],
      );

      // Record count does not increase.
      expect(db.permanentMemoryBox.length, 2);
      // Old is superseded.
      expect(
          db.permanentMemoryBox.get(old.id)!.status, MemoryStatus.superseded);
      // Returned object contains old.id.
      expect(result.supersedesIds, contains(old.id));
      expect(result.id, existing.id);
      // Stored existing also contains old.id.
      expect(db.permanentMemoryBox.get(existing.id)!.supersedesIds,
          contains(old.id));
    });

    test('editPermanent rollback: second-write failure restores old to active',
        () async {
      final db = DatabaseService();
      final char = testCharacter('c1');
      await db.aiCharacterBox.put(char.id, char);
      final old = PermanentMemory(
        id: 'old-rollback',
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '原内容',
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群1',
        subjectIds: const ['user'],
      );
      final existing = PermanentMemory(
        id: 'existing-rollback',
        observerCharacterId: 'c1',
        kind: MemoryKind.fact,
        content: '修正内容',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '群1',
        subjectIds: const ['user'],
        supersedesIds: const [],
      );
      await db.permanentMemoryBox
          .putAll({'old-rollback': old, 'existing-rollback': existing});
      final controls = MemoryControls(db);
      controls.testFailExistingSupersedesWrite = true;

      expect(
        () => controls.editPermanent(
          old,
          correctedContent: '修正内容',
          subjectIds: const ['user'],
        ),
        throwsA(isA<Exception>()),
      );

      // After rollback: old is still active, existing is unchanged.
      expect(db.permanentMemoryBox.get('old-rollback')!.status,
          MemoryStatus.active);
      expect(db.permanentMemoryBox.get('old-rollback')!.content, '原内容');
      expect(db.permanentMemoryBox.get('existing-rollback')!.supersedesIds,
          isEmpty);
      // Record count unchanged.
      expect(db.permanentMemoryBox.length, 2);
    });

    group('Stable Hive key resolution', () {
      test('stable key with wrong-id record is rejected; editPermanent throws',
          () async {
        final db = DatabaseService();
        final char = testCharacter('c1');
        await db.aiCharacterBox.put(char.id, char);
        // Stable key holds a different-id record.
        final impostor = PermanentMemory(
          id: 'wrong-id',
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '冒名内容',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: '群1',
          subjectIds: const ['user'],
        );
        final stableKey = 'pm:c1:fact:stable-hash';
        await db.permanentMemoryBox.put(stableKey, impostor);
        // The real target memory has the same stable key but different id.
        final target = PermanentMemory(
          id: 'real-id',
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '真实内容',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: '群1',
          subjectIds: const ['user'],
        );
        final controls = MemoryControls(db);

        expect(
          () => controls.pinPermanent(target),
          throwsA(isA<StateError>()),
        );
        expect(
          () => controls.unpinPermanent(target),
          throwsA(isA<StateError>()),
        );
        expect(
          () => controls.editPermanent(
            target,
            correctedContent: '修正',
            subjectIds: const ['user'],
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          () => controls.deletePermanent(target),
          throwsA(isA<StateError>()),
        );
        // Impostor record is untouched.
        expect(db.permanentMemoryBox.get(stableKey)!.id, 'wrong-id');
        expect(db.permanentMemoryBox.length, 1);
      });

      test('editPermanent on detached memory with missing record throws',
          () async {
        final db = DatabaseService();
        final char = testCharacter('c1');
        await db.aiCharacterBox.put(char.id, char);
        // Create a detached memory object — no record exists in box.
        final detached = PermanentMemory(
          id: 'phantom-id',
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '不存在的内容',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: '群1',
          subjectIds: const ['user'],
        );
        final controls = MemoryControls(db);
        expect(
          () => controls.editPermanent(
            detached,
            correctedContent: '修正',
            subjectIds: const ['user'],
          ),
          throwsA(isA<StateError>()),
        );
        // No replacement record was created.
        expect(
          db.permanentMemoryBox.values.any((m) => m.content == '修正'),
          isFalse,
        );
        expect(db.permanentMemoryBox.length, 0);
      });
    });

    group('editPermanent dedup behavior', () {
      test(
          'reuses existing active record with same content/subjects '
          'and updates supersedesIds', () async {
        final db = DatabaseService();
        final char = testCharacter('c1');
        await db.aiCharacterBox.put(char.id, char);
        final old = PermanentMemory(
          observerCharacterId: 'c1',
          kind: MemoryKind.fact,
          content: '原内容',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: '群1',
          subjectIds: const ['user'],
        );
        // Box has old + another active record with same content/subjects
        // but supersedesIds does not contain old.id.
        final existing = PermanentMemory(
          observerCharacterId: 'c1', kind: MemoryKind.fact,
          content: '修正内容', status: MemoryStatus.active,
          originType: MemoryOriginType.manual, originNameSnapshot: '群1',
          subjectIds: const ['user'],
          supersedesIds: const [], // intentionally empty
        );
        await db.permanentMemoryBox
            .putAll({old.id: old, existing.id: existing});
        final controls = MemoryControls(db);

        final _ = await controls.editPermanent(
          old,
          correctedContent: '修正内容',
          subjectIds: const ['user'],
        );

        // Record count should not increase.
        final totalRecords = db.permanentMemoryBox.length;
        expect(totalRecords, 2);
        // The existing record should now include old.id in supersedesIds.
        final updatedExisting = db.permanentMemoryBox.get(existing.id)!;
        expect(updatedExisting.supersedesIds, contains(old.id));
        // old should be superseded.
        expect(
            db.permanentMemoryBox.get(old.id)!.status, MemoryStatus.superseded);
      });
    });
  });
}
