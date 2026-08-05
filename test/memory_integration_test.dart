import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/chat_group/chat_room_loader.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/humanized_prompt_builder.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  group('Memory pipeline integration checks', () {
    late Directory tempDir;
    late DatabaseService db;

    setUp(() async {
      tempDir = await openLifecycleHive();
      db = DatabaseService();
      await db.aiCharacterBox.put(
          'char-a',
          AICharacter(
            id: 'char-a',
            name: '阿月',
            avatar: '🌙',
            age: 25,
            role: '插画师',
            personalityTags: const [],
            systemPrompt: '你是阿月',
            apiKey: 'test-key',
            apiProvider: 'deepseek',
          ));
      await db.aiCharacterBox.put(
          'char-b',
          AICharacter(
            id: 'char-b',
            name: '小林',
            avatar: '💻',
            age: 28,
            role: '程序员',
            personalityTags: const [],
            systemPrompt: '你是小林',
            apiKey: 'test-key',
            apiProvider: 'deepseek',
          ));
      await db.aiCharacterBox.put(
          'char-c',
          AICharacter(
            id: 'char-c',
            name: '小红',
            avatar: '🌸',
            age: 26,
            role: '产品经理',
            personalityTags: const [],
            systemPrompt: '你是小红',
            apiKey: 'test-key',
            apiProvider: 'deepseek',
          ));
      await db.chatGroupBox.put(
          'group-1',
          ChatGroup(
            id: 'group-1',
            name: '测试群',
            theme: '日常聊天',
            description: '',
            aiCharacterIds: const ['char-a', 'char-b', 'char-c'],
            ownerName: '老张',
          ));
      await db.chatGroupBox.put(
          'group-2',
          ChatGroup(
            id: 'group-2',
            name: '项目群',
            theme: '工作协作',
            description: '',
            aiCharacterIds: const ['char-a', 'char-b'],
            ownerName: '老张',
          ));
      await db.userProfileBox.put(
          'me',
          UserProfile(
            id: 'me',
            displayName: '老张',
            preferredAddress: '张哥',
            avatar: '',
            pronouns: '',
            age: 35,
            bio: '团队负责人',
            personality: const ['沉稳', '务实'],
            interests: const ['技术', '咖啡'],
            importantBackground: const [],
            updatedAt: DateTime.now(),
            createdAt: DateTime.now(),
          ));
    });

    tearDown(() async {
      await closeLifecycleHive(tempDir);
    });

    // ─── Fix 3: ChatRoomLoader per-stableId relationship fallback ──────────────

    test('group chat: A→global + A→user legacy → user NOT dropped', () async {
      // A→user has both global and legacy → global wins for user.
      await db.relationshipStateBox.put(
          'rel:global-user',
          RelationshipState(
            id: 'rel:char-a:user:global',
            groupId: 'global',
            sourceCharacterId: 'char-a',
            targetId: 'user',
            targetType: RelationshipTargetType.user,
            affinity: 80,
            familiarity: 70,
            trust: 60,
            friction: 10,
            updatedAt: DateTime.now().subtract(const Duration(days: 1)),
          ));
      await db.relationshipStateBox.put(
          'rel:legacy-user',
          RelationshipState(
            id: 'rel:char-a:user:g1:v1',
            groupId: 'group-1',
            sourceCharacterId: 'char-a',
            targetId: 'user',
            targetType: RelationshipTargetType.user,
            affinity: 50,
            familiarity: 40,
            trust: 30,
            friction: 20,
            updatedAt: DateTime.now().subtract(const Duration(days: 5)),
          ));
      // A→B has global.
      await db.relationshipStateBox.put(
          'rel:global-b',
          RelationshipState(
            id: 'rel:char-a:ai:char-b:global',
            groupId: 'global',
            sourceCharacterId: 'char-a',
            targetId: 'char-b',
            targetType: RelationshipTargetType.ai,
            affinity: 90,
            familiarity: 80,
            trust: 70,
            friction: 5,
            updatedAt: DateTime.now().subtract(const Duration(days: 1)),
          ));
      // A→B also has legacy.
      await db.relationshipStateBox.put(
          'rel:legacy-b',
          RelationshipState(
            id: 'rel:char-a:ai:char-b:v1',
            groupId: 'group-1',
            sourceCharacterId: 'char-a',
            targetId: 'char-b',
            targetType: RelationshipTargetType.ai,
            affinity: 30,
            familiarity: 20,
            trust: 10,
            friction: 40,
            updatedAt: DateTime.now().subtract(const Duration(days: 10)),
          ));

      final loader = ChatRoomLoader(
        db: db,
        resolveApiConfig: (c) => null,
      );
      final context = await loader.load('group-1');

      // Should have exactly 2 relationships (one per stableGlobalId).
      expect(context.relationships.length, 2);
      final userRels =
          context.relationships.where((r) => r.targetId == 'user').toList();
      expect(userRels.length, 1);
      expect(userRels.first.affinity, 80); // global wins for user
      final bRels =
          context.relationships.where((r) => r.targetId == 'char-b').toList();
      expect(bRels.length, 1);
      expect(bRels.first.affinity, 90); // global wins for B
      expect(bRels.first.groupId, 'global');
    });

    test('group chat: no global → falls back to latest legacy per stableId',
        () async {
      await db.relationshipStateBox.put(
          'rel:old1',
          RelationshipState(
            id: 'rel:char-a:user:g1',
            groupId: 'group-1',
            sourceCharacterId: 'char-a',
            targetId: 'user',
            targetType: RelationshipTargetType.user,
            affinity: 50,
            familiarity: 40,
            trust: 30,
            friction: 20,
            updatedAt: DateTime.now().subtract(const Duration(days: 3)),
          ));
      await db.relationshipStateBox.put(
          'rel:old2',
          RelationshipState(
            id: 'rel:char-a:user:g2',
            groupId: 'group-2',
            sourceCharacterId: 'char-a',
            targetId: 'user',
            targetType: RelationshipTargetType.user,
            affinity: 10,
            familiarity: 10,
            trust: 5,
            friction: 50,
            updatedAt: DateTime.now().subtract(const Duration(days: 10)),
          ));

      final loader = ChatRoomLoader(
        db: db,
        resolveApiConfig: (c) => null,
      );
      final context = await loader.load('group-1');

      expect(context.relationships.length, 1);
      expect(context.relationships.first.affinity, 50); // latest legacy wins
      expect(context.relationships.first.groupId, 'group-1');
    });

    test('Fix 5: ChatRoomLoader returns UserProfile from userProfileBox',
        () async {
      final loader = ChatRoomLoader(
        db: db,
        resolveApiConfig: (c) => null,
      );
      final context = await loader.load('group-1');
      expect(context.userProfile, isNotNull);
      expect(context.userProfile!.displayName, '老张');
      expect(context.userProfile!.preferredAddress, '张哥');
    });

    // ─── Fix 4: MemoryContextSelector relationship dedup ───────────────────────

    test('selector: global and legacy for same target → only global in output',
        () async {
      await db.relationshipStateBox.put(
          'rel:global-user',
          RelationshipState(
            id: 'rel:char-a:user:global',
            groupId: 'global',
            sourceCharacterId: 'char-a',
            targetId: 'user',
            targetType: RelationshipTargetType.user,
            affinity: 80,
            familiarity: 70,
            trust: 60,
            friction: 10,
            updatedAt: DateTime.now().subtract(const Duration(days: 1)),
          ));
      await db.relationshipStateBox.put(
          'rel:legacy-user',
          RelationshipState(
            id: 'rel:char-a:user:g1:v1',
            groupId: 'group-1',
            sourceCharacterId: 'char-a',
            targetId: 'user',
            targetType: RelationshipTargetType.user,
            affinity: 50,
            familiarity: 40,
            trust: 30,
            friction: 20,
            updatedAt: DateTime.now().subtract(const Duration(days: 5)),
          ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a', 'char-b'],
        currentTargetId: 'user',
      );

      // Should contain the global affinity (80), not the legacy (50).
      expect(result, contains('亲近80'));
      expect(result, isNot(contains('亲近50')));
      // Should contain only ONE entry for user relations.
      final userRelationMatches = RegExp(r'亲近\d+').allMatches(result).length;
      expect(userRelationMatches, 1);
    });

    test('selector: permanent memory supersedesIds does not filter relations',
        () async {
      // A PermanentMemory supersedes 'some-old-id'.
      await db.permanentMemoryBox.put(
          'pm-new',
          PermanentMemory(
            id: 'pm-new',
            observerCharacterId: 'char-a',
            kind: MemoryKind.fact,
            content: '用户现在在上海',
            subjectIds: const ['user'],
            status: MemoryStatus.active,
            importance: 80,
            supersedesIds: const ['some-old-id'],
            originType: MemoryOriginType.manual,
            originNameSnapshot: '手动',
            occurredAt: DateTime.now(),
          ));
      // A relationship whose id happens to match a superseded memory id.
      await db.relationshipStateBox.put(
          'rel-kept',
          RelationshipState(
            id: 'some-old-id',
            groupId: 'group-1',
            sourceCharacterId: 'char-a',
            targetId: 'user',
            targetType: RelationshipTargetType.user,
            affinity: 60,
            familiarity: 50,
            trust: 40,
            friction: 15,
            updatedAt: DateTime.now().subtract(const Duration(days: 2)),
          ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a', 'char-b'],
        currentTargetId: 'user',
      );

      // The relationship should still be present — supersedesIds applies to
      // memories only, not relationships.
      expect(result, contains('亲近60'));
    });

    // ─── Fix 1: Unified selector replaces legacySummary + characterMemory ───────

    test('unified selector does not include character.memorySummary', () async {
      final char = db.aiCharacterBox.get('char-a')!;
      char.memorySummary = '这是旧版自我记忆摘要';
      await db.aiCharacterBox.put('char-a', char);

      await db.permanentMemoryBox.put(
          'pm-real',
          PermanentMemory(
            id: 'pm-real',
            observerCharacterId: 'char-a',
            kind: MemoryKind.fact,
            content: '用户是团队负责人',
            subjectIds: const ['user'],
            status: MemoryStatus.active,
            importance: 80,
            originType: MemoryOriginType.manual,
            originNameSnapshot: '手动',
            occurredAt: DateTime.now(),
          ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a', 'char-b', 'char-c'],
      );

      // Legacy memorySummary must NOT appear.
      expect(result, isNot(contains('这是旧版自我记忆摘要')));
      // Real permanent memory must appear.
      expect(result, contains('团队负责人'));
    });

    test('unified selector: user profile and permanent memory both present',
        () async {
      await db.permanentMemoryBox.put(
          'pm-coffee',
          PermanentMemory(
            id: 'pm-coffee',
            observerCharacterId: 'char-a',
            kind: MemoryKind.preference,
            content: '用户早上喜欢喝咖啡',
            subjectIds: const ['user'],
            status: MemoryStatus.active,
            importance: 50,
            originType: MemoryOriginType.group,
            originConversationId: 'group-1',
            originNameSnapshot: '测试群',
          ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a', 'char-b', 'char-c'],
        userMessage: '大家早',
      );

      expect(result, contains('咖啡'));
      expect(result, contains('老张'));
    });

    // ─── Fix 2: MemoryContextSelector includes recentMood ───────────────────────

    test('selector: relationship output includes recentMood', () async {
      await db.relationshipStateBox.put(
          'rel:user',
          RelationshipState(
            id: 'rel:char-a:user:global',
            groupId: 'global',
            sourceCharacterId: 'char-a',
            targetId: 'user',
            targetType: RelationshipTargetType.user,
            affinity: 60,
            familiarity: 50,
            trust: 40,
            friction: 20,
            recentMood: RelationshipMood.warm,
            notes: '最近关系不错',
            updatedAt: DateTime.now().subtract(const Duration(days: 1)),
          ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'],
        currentTargetId: 'user',
      );

      expect(result, isNotEmpty);
      expect(result, contains('最近情绪warm'));
      expect(result, contains('亲近60'));
      expect(result, contains('信任40'));
    });

    // ─── Fix 2: relationship numbers come only from the unified selector ────────

    test(
        'relationship prompt: selector owns numbers for user behavior branches',
        () async {
      final character = db.aiCharacterBox.get('char-a')!;
      const intent = ReplyIntent(
        speakerId: 'char-a',
        action: ReplyAction.agree,
        targetId: 'user',
        lengthHint: ReplyLengthHint.normal,
        toneHint: '轻松',
        reason: 'test',
      );

      final cases = [
        (
          affinity: 80,
          trust: 60,
          friction: 10,
          familiarity: 70,
          mood: RelationshipMood.warm,
          expectedBehavior: '关系很好',
          numericValues: ['亲近80', '信任60', '摩擦10'],
        ),
        (
          affinity: -30,
          trust: 20,
          friction: 70,
          familiarity: 15,
          mood: RelationshipMood.annoyed,
          expectedBehavior: '关系很差',
          numericValues: ['亲近-30', '信任20', '摩擦70'],
        ),
      ];

      for (final testCase in cases) {
        await db.relationshipStateBox.clear();
        final relation = RelationshipState(
          groupId: 'global',
          id: 'rel:char-a:user:global',
          sourceCharacterId: 'char-a',
          targetId: 'user',
          targetType: RelationshipTargetType.user,
          affinity: testCase.affinity,
          trust: testCase.trust,
          friction: testCase.friction,
          familiarity: testCase.familiarity,
          recentMood: testCase.mood,
        );
        await db.relationshipStateBox.put(relation.id, relation);

        final selectorContext = await MemoryContextSelector(db).select(
          observerCharacterId: 'char-a',
          participantCharacterIds: const ['char-a'],
          currentTargetId: 'user',
        );
        final behaviorContext = HumanizedPromptBuilder.buildRelationContext(
          character: character,
          intent: intent,
          relationships: [relation],
          charactersById: const {},
        );
        final prompt = '$selectorContext\n$behaviorContext';

        expect(behaviorContext, contains(testCase.expectedBehavior));
        expect(behaviorContext, contains('本轮动作：agree'));
        expect(behaviorContext, contains('本轮语气：轻松'));
        expect(behaviorContext, contains('长度要求：2-4 句'));
        expect(behaviorContext, contains('不要带自己的名字前缀'));
        expect(behaviorContext, isNot(contains('最近情绪')));
        expect(selectorContext, contains('最近情绪${testCase.mood.name}'));
        expect(prompt.split('最近情绪${testCase.mood.name}').length - 1, 1);

        for (final numericValue in testCase.numericValues) {
          expect(selectorContext, contains(numericValue));
          expect(behaviorContext, isNot(contains(numericValue)));
          expect(prompt.split(numericValue).length - 1, 1);
        }
      }
    });
  });
}
