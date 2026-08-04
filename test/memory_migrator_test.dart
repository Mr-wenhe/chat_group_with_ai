import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/memory/memory_migrator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() async {
    await closeLifecycleHive(hiveDirectory);
  });

  group('MemoryMigrator', () {
    test('second run returns alreadyMigrated=true with zero counts', () async {
      final migrator = MemoryMigrator(db);
      final first = await migrator.migrate();
      expect(first.alreadyMigrated, isFalse);

      final second = await migrator.migrate();
      expect(second.alreadyMigrated, isTrue);
      expect(second.permanentMemoriesCreated, 0);
      expect(second.relationshipSnapshotsCreated, 0);
      expect(second.relationshipEventsCreated, 0);
    });

    group('ownerName -> UserProfile', () {
      test('single non-default ownerName becomes displayName', () async {
        await db.chatGroupBox.put('g1', ChatGroup(
          id: 'g1', name: '一群', theme: '', aiCharacterIds: [], ownerName: '小明',
        ));

        final migrator = MemoryMigrator(db);
        final report = await migrator.migrate();

        expect(report.userProfileCreated, 1);
        expect(report.selectedOwnerName, '小明');

        final profile = db.userProfileBox.get('me');
        expect(profile, isNotNull);
        expect(profile!.displayName, '小明');
      });

      test('only default ownerName falls back to "我"', () async {
        await db.chatGroupBox.put('g1', ChatGroup(
          id: 'g1', name: '一群', theme: '', aiCharacterIds: [], ownerName: '我',
        ));

        final migrator = MemoryMigrator(db);
        final report = await migrator.migrate();

        expect(report.userProfileCreated, 1);
        final profile = db.userProfileBox.get('me');
        expect(profile, isNotNull);
        expect(profile!.displayName, '我');
      });

      test('existing profile is not overwritten', () async {
        await db.chatGroupBox.put('g1', ChatGroup(
          id: 'g1', name: '一群', theme: '', aiCharacterIds: [], ownerName: '小明',
        ));
        await db.userProfileBox.put('me', UserProfile(
          id: 'me', displayName: '已存在的资料', preferredAddress: '老大',
          avatar: '', bio: '',
        ));

        final migrator = MemoryMigrator(db);
        final report = await migrator.migrate();

        expect(report.userProfileCreated, 0);
        final profile = db.userProfileBox.get('me');
        expect(profile, isNotNull);
        expect(profile!.displayName, '已存在的资料');
      });
    });

    group('CharacterMemory -> PermanentMemory', () {
      test('expands facts, relationshipNotes, personaGrowth', () async {
        const charId = 'char-1';
        await db.characterMemoryBox.put('cm1', CharacterMemory(
          groupId: 'group-1',
          characterId: charId,
          facts: ['用户喜欢猫', '用户来自北京'],
          relationshipNotes: ['我对用户有点尊敬'],
          personaGrowth: ['我现在更自信了'],
          lastUpdatedAt: DateTime(2024, 6, 1),
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();

        final memories = db.permanentMemoryBox.values
            .where((m) => m.observerCharacterId == charId)
            .toList();

        // 2 facts + 1 relationshipNote + 1 personaGrowth = 4
        expect(memories.length, 4);

        final facts = memories.where((m) => m.kind == MemoryKind.fact).toList();
        expect(facts.length, 2);
        expect(facts.any((m) => m.content == '用户喜欢猫'), isTrue);
        expect(facts.any((m) => m.content == '用户来自北京'), isTrue);
        expect(facts.every((m) => m.subjectIds.contains('user')), isTrue);

        final notes = memories.where((m) => m.kind == MemoryKind.relationshipNote).toList();
        expect(notes.length, 1);

        final growth = memories.where((m) => m.kind == MemoryKind.personaGrowth).toList();
        expect(growth.length, 1);
      });

      test('preserves origin conversation type (group vs dm)', () async {
        await db.characterMemoryBox.put('cm-group', CharacterMemory(
          groupId: 'group-1',
          characterId: 'char-1',
          facts: ['群聊事实'],
        ));
        await db.characterMemoryBox.put('cm-dm', CharacterMemory(
          groupId: 'dm:char-2',
          characterId: 'char-2',
          facts: ['私聊事实'],
        ));

        await db.chatGroupBox.put('group-1', ChatGroup(
          id: 'group-1', name: '测试群', theme: '', aiCharacterIds: [],
        ));
        await db.aiCharacterBox.put('char-2', AICharacter(
          id: 'char-2', name: '小月', avatar: '月', age: 22, role: '助手',
          personalityTags: [], systemPrompt: '', apiKey: '', apiProvider: '',
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();

        final groupMemories = db.permanentMemoryBox.values
            .where((m) => m.observerCharacterId == 'char-1')
            .toList();
        expect(groupMemories.length, 1);
        expect(groupMemories.first.originType, MemoryOriginType.group);
        expect(groupMemories.first.originConversationId, 'group-1');

        final dmMemories = db.permanentMemoryBox.values
            .where((m) => m.observerCharacterId == 'char-2')
            .toList();
        expect(dmMemories.length, 1);
        expect(dmMemories.first.originType, MemoryOriginType.direct);
        expect(dmMemories.first.originConversationId, 'dm:char-2');
      });

      test('stable key prevents duplicate memories on re-run', () async {
        await db.characterMemoryBox.put('cm1', CharacterMemory(
          groupId: 'group-1',
          characterId: 'char-1',
          facts: ['用户喜欢猫', '用户来自北京'],
          personaGrowth: ['更自信了'],
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();
        final countAfterFirst = db.permanentMemoryBox.length;

        await migrator.migrate();
        expect(db.permanentMemoryBox.length, countAfterFirst);
      });

      test('no fabricated sourceMessageIds', () async {
        await db.characterMemoryBox.put('cm1', CharacterMemory(
          groupId: 'group-1',
          characterId: 'char-1',
          facts: ['事实'],
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();

        final memories = db.permanentMemoryBox.values.toList();
        for (final m in memories) {
          expect(m.sourceMessageIds, isEmpty,
              reason: '迁移的记忆不应伪造 sourceMessageIds');
        }
      });

      test('old CharacterMemory records are not deleted', () async {
        await db.characterMemoryBox.put('cm1', CharacterMemory(
          groupId: 'group-1',
          characterId: 'char-1',
          facts: ['保留的事实'],
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();

        expect(db.characterMemoryBox.containsKey('cm1'), isTrue);
        expect(db.characterMemoryBox.get('cm1')!.facts, ['保留的事实']);
      });
    });

    group('memorySummary -> legacyMigration memories', () {
      test('parses tagged summary into kinded memories', () async {
        await db.aiCharacterBox.put('char-1', AICharacter(
          id: 'char-1', name: '小月', avatar: '月', age: 22, role: '助手',
          personalityTags: [], systemPrompt: '',
          memorySummary: '【事实】用户来自上海【关系】我和用户比较熟【成长】我变得更开朗了',
          apiKey: '', apiProvider: '',
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();

        final charMemories = db.permanentMemoryBox.values
            .where((m) => m.observerCharacterId == 'char-1')
            .toList();
        expect(charMemories.length, 3);
        expect(charMemories.any((m) => m.kind == MemoryKind.fact && m.content == '用户来自上海'), isTrue);
        expect(charMemories.any((m) => m.kind == MemoryKind.relationshipNote && m.content == '我和用户比较熟'), isTrue);
        expect(charMemories.any((m) => m.kind == MemoryKind.personaGrowth && m.content == '我变得更开朗了'), isTrue);
      });

      test('skips characters with no memorySummary', () async {
        await db.aiCharacterBox.put('char-1', AICharacter(
          id: 'char-1', name: '小月', avatar: '月', age: 22, role: '助手',
          personalityTags: [], systemPrompt: '',
          memorySummary: '',
          apiKey: '', apiProvider: '',
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();

        final charMemories = db.permanentMemoryBox.values
            .where((m) => m.observerCharacterId == 'char-1')
            .toList();
        expect(charMemories, isEmpty);
      });
    });

    group('RelationshipState -> global snapshot + RelationshipEvent', () {
      test('creates global snapshot and events', () async {
        await db.chatGroupBox.put('g1', ChatGroup(
          id: 'g1', name: '一群', theme: '', aiCharacterIds: ['c1'],
        ));
        await db.chatGroupBox.put('g2', ChatGroup(
          id: 'g2', name: '二群', theme: '', aiCharacterIds: ['c1'],
        ));
        await db.relationshipStateBox.put('rs-g1', RelationshipState(
          groupId: 'g1',
          sourceCharacterId: 'c1',
          targetId: 'user',
          targetType: RelationshipTargetType.user,
          affinity: 30,
          trust: 20,
          friction: 5,
          familiarity: 40,
          lastInteractionAt: DateTime(2024, 1, 1),
        ));
        await db.relationshipStateBox.put('rs-g2', RelationshipState(
          groupId: 'g2',
          sourceCharacterId: 'c1',
          targetId: 'user',
          targetType: RelationshipTargetType.user,
          affinity: 10,
          trust: 5,
          friction: 0,
          familiarity: 10,
          lastInteractionAt: DateTime(2024, 6, 1),
        ));

        final migrator = MemoryMigrator(db);
        final report = await migrator.migrate();

        expect(report.relationshipSnapshotsCreated, 1);
        expect(report.relationshipEventsCreated, 2);
      });

      test('global snapshot key is stable (source|type|target)', () async {
        await db.relationshipStateBox.put('rs1', RelationshipState(
          groupId: 'g1',
          sourceCharacterId: 'c1',
          targetId: 'user',
          targetType: RelationshipTargetType.user,
          affinity: 50,
          familiarity: 60,
          lastInteractionAt: DateTime(2024, 1, 1),
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();

        final stableId = RelationshipState.stableGlobalId(
          'c1', RelationshipTargetType.user, 'user',
        );
        expect(db.relationshipStateBox.containsKey(stableId), isTrue);
      });

      test('merges multiple group snapshots with weighted average', () async {
        await db.relationshipStateBox.put('rs1', RelationshipState(
          groupId: 'g1',
          sourceCharacterId: 'c1',
          targetId: 'c2',
          targetType: RelationshipTargetType.ai,
          affinity: 80,
          trust: 60,
          friction: 10,
          familiarity: 90,
          lastInteractionAt: DateTime(2024, 1, 1),
        ));
        await db.relationshipStateBox.put('rs2', RelationshipState(
          groupId: 'g2',
          sourceCharacterId: 'c1',
          targetId: 'c2',
          targetType: RelationshipTargetType.ai,
          affinity: 0,
          trust: 0,
          friction: 20,
          familiarity: 5,
          lastInteractionAt: DateTime(2024, 6, 1),
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();

        final stableId = RelationshipState.stableGlobalId(
          'c1', RelationshipTargetType.ai, 'c2',
        );
        final snapshot = db.relationshipStateBox.get(stableId)!;
        // familiarity: 90 + 5 = 95 (not clamped)
        expect(snapshot.familiarity, 95);
        // affinity: weighted avg (80*90 + 0*5) / 95 ≈ 75
        expect(snapshot.affinity, greaterThan(70));
        // recentMood from latest interaction (rs2)
        expect(snapshot.recentMood, RelationshipMood.neutral);
      });

      test('re-run does not duplicate snapshots or events', () async {
        await db.relationshipStateBox.put('rs1', RelationshipState(
          groupId: 'g1',
          sourceCharacterId: 'c1',
          targetId: 'user',
          targetType: RelationshipTargetType.user,
          affinity: 50,
          familiarity: 60,
          lastInteractionAt: DateTime(2024, 1, 1),
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();
        final eventCountAfterFirst = db.relationshipEventBox.length;
        final snapshotCountAfterFirst = db.relationshipStateBox.length;

        await migrator.migrate();
        expect(db.relationshipEventBox.length, eventCountAfterFirst);
        // snapshot count unchanged (the old per-group state + 1 new global = 2)
        expect(db.relationshipStateBox.length, snapshotCountAfterFirst);
      });

      test('old RelationshipState records are not deleted', () async {
        await db.relationshipStateBox.put('rs1', RelationshipState(
          groupId: 'g1',
          sourceCharacterId: 'c1',
          targetId: 'user',
          targetType: RelationshipTargetType.user,
          affinity: 50,
          familiarity: 60,
          lastInteractionAt: DateTime(2024, 1, 1),
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();

        expect(db.relationshipStateBox.containsKey('rs1'), isTrue);
      });

      test('relationship events have correct originConversationId', () async {
        await db.chatGroupBox.put('g1', ChatGroup(
          id: 'g1', name: '测试群', theme: '', aiCharacterIds: [],
        ));
        await db.relationshipStateBox.put('rs1', RelationshipState(
          groupId: 'g1',
          sourceCharacterId: 'c1',
          targetId: 'user',
          targetType: RelationshipTargetType.user,
          affinity: 50,
          familiarity: 60,
          lastInteractionAt: DateTime(2024, 1, 1),
        ));

        final migrator = MemoryMigrator(db);
        await migrator.migrate();

        final events = db.relationshipEventBox.values
            .where((e) => e.sourceCharacterId == 'c1')
            .toList();
        expect(events.length, 1);
        expect(events.first.originConversationId, 'g1');
        expect(events.first.reason, contains('g1'));
      });
    });

    group('complete migration flow', () {
      test('full scenario: groups, characters, memories, relationships',
          () async {
        // Seed data
        await db.aiCharacterBox.put('c1', AICharacter(
          id: 'c1', name: '小月', avatar: '月', age: 22, role: '助手',
          personalityTags: [], systemPrompt: '',
          memorySummary: '【事实】用户喜欢喝咖啡【成长】我学会主动关心人',
          apiKey: '', apiProvider: '',
        ));
        await db.chatGroupBox.put('g1', ChatGroup(
          id: 'g1', name: '一群', theme: '', aiCharacterIds: ['c1'], ownerName: '小明',
        ));
        await db.characterMemoryBox.put('cm1', CharacterMemory(
          groupId: 'g1',
          characterId: 'c1',
          facts: ['用户每周三跑步'],
          relationshipNotes: ['我和用户关系不错'],
          personaGrowth: ['我学会主动开启话题'],
          lastUpdatedAt: DateTime(2024, 6, 1),
        ));
        await db.relationshipStateBox.put('rs1', RelationshipState(
          groupId: 'g1',
          sourceCharacterId: 'c1',
          targetId: 'user',
          targetType: RelationshipTargetType.user,
          affinity: 60,
          trust: 40,
          friction: 5,
          familiarity: 50,
          lastInteractionAt: DateTime(2024, 6, 1),
        ));

        final migrator = MemoryMigrator(db);
        final report = await migrator.migrate();

        // UserProfile
        expect(report.userProfileCreated, 1);
        final profile = db.userProfileBox.get('me');
        expect(profile, isNotNull);
        expect(profile!.displayName, '小明');

        // CharacterMemory -> PermanentMemory (3 from cm + 2 from summary = 5)
        expect(report.permanentMemoriesCreated, 5);

        // RelationshipState -> 1 snapshot + 1 event
        expect(report.relationshipSnapshotsCreated, 1);
        expect(report.relationshipEventsCreated, 1);

        // Old data preserved
        expect(db.characterMemoryBox.containsKey('cm1'), isTrue);
        expect(db.relationshipStateBox.containsKey('rs1'), isTrue);
        expect(db.aiCharacterBox.get('c1')!.memorySummary, isNotEmpty);

        // Second run is idempotent
        final report2 = await migrator.migrate();
        expect(report2.alreadyMigrated, isTrue);
        expect(db.permanentMemoryBox.length, report.permanentMemoriesCreated);
      });
    });
  });
}
