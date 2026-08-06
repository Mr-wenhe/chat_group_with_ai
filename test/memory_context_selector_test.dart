import 'dart:io';
import 'dart:math';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/chat_group/chat_room_loader.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

Future<void> main() async {
  late Directory tempDir;

  setUp(() async {
    tempDir = await openLifecycleHive();
  });

  tearDown(() async {
    await closeLifecycleHive(tempDir);
  });

  // ─── Cross-group memory access ────────────────────────────────────────────────

  group('MemoryContextSelector cross-group access', () {
    test('same AI can read its memory from any group', () async {
      final db = DatabaseService();
      final char = AICharacter(
        id: 'char-a',
        name: '阿月',
        avatar: '🌙',
        age: 25,
        role: '插画师',
        personalityTags: ['creative'],
        systemPrompt: '你是阿月',
        apiKey: 'k',
        apiProvider: 'deepseek',
      );
      await db.aiCharacterBox.put('char-a', char);

      // 在群 1 中形成的记忆。
      await db.permanentMemoryBox.put('pm:1', PermanentMemory(
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '用户住在上海',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 70,
        originType: MemoryOriginType.group,
        originConversationId: 'group-1',
        originNameSnapshot: '群聊:测试群1',
      ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a', 'char-b'],
        currentTargetId: 'user',
        userMessage: '你家在哪',
      );

      expect(result, contains('上海'));
    });

    test('group 1 memory is visible in group 2 context', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));

      await db.permanentMemoryBox.put('pm:2', PermanentMemory(
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '用户喜欢蓝色',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 60,
        originType: MemoryOriginType.group,
        originConversationId: 'group-1', // 来自群 1
        originNameSnapshot: '群聊:设计讨论',
      ));

      final selector = MemoryContextSelector(db);
      // 在群 2 中请求 char-a 的记忆。
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a', 'char-b', 'char-c'],
        currentTargetId: 'user',
      );

      expect(result, contains('蓝色'));
    });
  });

  // ─── DM access ───────────────────────────────────────────────────────────────

  group('DM memory access', () {
    test('group memory is readable in DM context', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));

      await db.permanentMemoryBox.put('pm:3', PermanentMemory(
        observerCharacterId: 'char-a',
        kind: MemoryKind.sharedExperience,
        content: '用户曾说过周末想去爬山',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 50,
        originType: MemoryOriginType.group,
        originConversationId: 'group-1',
        originNameSnapshot: '群聊:户外爱好者',
      ));

      final selector = MemoryContextSelector(db);
      // DM 场景：participantCharacterIds 只有对话双方。
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'], // DM 中只有对方可见
        currentTargetId: 'user',
      );

      expect(result, contains('爬山'));
    });
  });

  // ─── Privacy isolation ───────────────────────────────────────────────────────

  group('Privacy isolation', () {
    test('A cannot read B private chat memory', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));
      await db.aiCharacterBox.put('char-b', AICharacter(
        id: 'char-b', name: '小林', avatar: '💻', age: 28, role: '程序员',
        personalityTags: const [], systemPrompt: '你是小林', apiKey: 'k', apiProvider: 'deepseek',
      ));

      // B 与用户的私聊记忆。
      await db.permanentMemoryBox.put('pm:b-private', PermanentMemory(
        observerCharacterId: 'char-b',
        kind: MemoryKind.fact,
        content: '用户告诉小林自己的工资是 30k',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 80,
        originType: MemoryOriginType.direct,
        originConversationId: 'dm:char-b',
        originNameSnapshot: '私聊:小林',
      ));

      final selector = MemoryContextSelector(db);
      // A 在自己的 DM 中请求记忆，不应该看到 B 的私聊内容。
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'],
        currentTargetId: 'user',
      );

      expect(result, isNot(contains('30k')));
      expect(result, isNot(contains('工资')));
    });

    test('superseded and invalidated memories are excluded', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));

      // 已过时的记忆。
      await db.permanentMemoryBox.put('pm:old', PermanentMemory(
        id: 'pm-old',
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '用户住在北京',
        subjectIds: const ['user'],
        status: MemoryStatus.superseded,
        importance: 60,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊:旧',
      ));
      // 被人物卡覆盖的记忆。
      await db.permanentMemoryBox.put('pm:inv', PermanentMemory(
        id: 'pm-inv',
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '用户叫张三',
        subjectIds: const ['user'],
        status: MemoryStatus.invalidated,
        importance: 60,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊:旧',
      ));
      // 有效记忆。
      await db.permanentMemoryBox.put('pm:active', PermanentMemory(
        id: 'pm-active',
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '用户现在叫李四',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 60,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊:新',
      ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'],
        currentTargetId: 'user',
      );

      expect(result, contains('李四'));
      expect(result, isNot(contains('北京')));
      expect(result, isNot(contains('张三')));
    });

    test('other AI private memories are not returned', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));
      await db.aiCharacterBox.put('char-b', AICharacter(
        id: 'char-b', name: '小林', avatar: '💻', age: 28, role: '程序员',
        personalityTags: const [], systemPrompt: '你是小林', apiKey: 'k', apiProvider: 'deepseek',
      ));

      // B 的自身成长记忆（无主体），A 不应该看到。
      await db.permanentMemoryBox.put('pm:b-growth', PermanentMemory(
        observerCharacterId: 'char-b',
        kind: MemoryKind.personaGrowth,
        content: '小林觉得自己代码写得不够好',
        subjectIds: const [],
        status: MemoryStatus.active,
        importance: 40,
        originType: MemoryOriginType.group,
        originConversationId: 'group-1',
        originNameSnapshot: '群聊:技术',
      ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'],
        currentTargetId: 'user',
      );

      expect(result, isNot(contains('代码写得不够好')));
    });
  });

  // ─── User profile ────────────────────────────────────────────────────────────

  group('User profile', () {
    test('empty profile returns no profile section', () async {
      final db = DatabaseService();
      await db.userProfileBox.put('me', UserProfile(
        displayName: '',
        preferredAddress: '',
        avatar: '',
        bio: '',
      ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const [],
        currentTargetId: 'user',
      );

      expect(result, isNot(contains('人物信息卡')));
    });

    test('non-empty profile is included', () async {
      final db = DatabaseService();
      await db.userProfileBox.put('me', UserProfile(
        displayName: '小明',
        preferredAddress: '小明',
        avatar: '',
        bio: '喜欢画画',
        personality: const ['内向'],
        interests: const ['插画'],
      ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const [],
        currentTargetId: 'user',
      );

      expect(result, contains('人物信息卡'));
      expect(result, contains('小明'));
      expect(result, contains('喜欢画画'));
    });
  });

  // ─── User profile refresh ───────────────────────────────────────────────────

  group('User profile refresh', () {
    test('updated profile replaces old data in selector output', () async {
      final db = DatabaseService();
      await db.userProfileBox.put('me', UserProfile(
        displayName: '旧名',
        preferredAddress: '',
        avatar: '',
        bio: '旧简介',
      ));

      final selector = MemoryContextSelector(db);
      var result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const [],
        currentTargetId: 'user',
      );
      expect(result, contains('旧名'));
      expect(result, contains('旧简介'));

      // 更新人物卡。
      await db.userProfileBox.put('me', UserProfile(
        displayName: '新名',
        preferredAddress: '称呼',
        avatar: '',
        bio: '新简介',
      ));

      // 重新创建 selector（复用 db 实例即可，数据来自 Hive）。
      final selector2 = MemoryContextSelector(db);
      result = await selector2.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const [],
        currentTargetId: 'user',
      );
      expect(result, contains('新名'));
      expect(result, contains('称呼'));
      expect(result, contains('新简介'));
      expect(result, isNot(contains('旧名')));
      expect(result, isNot(contains('旧简介')));
    });
  });

  // ─── Relationship selection ──────────────────────────────────────────────────

  group('Relationship selection', () {
    test('returns empty when no relationships', () async {
      final db = DatabaseService();
      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const [],
        currentTargetId: 'user',
      );

      expect(result, isNot(contains('关系')));
    });

    test('prioritizes current target over user over other AI', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));
      await db.aiCharacterBox.put('char-b', AICharacter(
        id: 'char-b', name: '小林', avatar: '💻', age: 28, role: '程序员',
        personalityTags: const [], systemPrompt: '你是小林', apiKey: 'k', apiProvider: 'deepseek',
      ));

      await db.relationshipStateBox.put('rel-user', RelationshipState(
        id: 'rel:char-a:user:user',
        groupId: 'global',
        sourceCharacterId: 'char-a',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
        familiarity: 50,
        affinity: 30,
      ));
      await db.relationshipStateBox.put('rel-b', RelationshipState(
        id: 'rel:char-a:ai:char-b',
        groupId: 'global',
        sourceCharacterId: 'char-a',
        targetId: 'char-b',
        targetType: RelationshipTargetType.ai,
        familiarity: 80,
        affinity: 70,
      ));

      final selector = MemoryContextSelector(db);

      // 当 currentTargetId 是 user 时，用户关系应优先。
      final resultUser = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a', 'char-b'],
        currentTargetId: 'user',
      );
      expect(resultUser, contains('真人用户'));

      // 当 currentTargetId 是 char-b 时，AI 关系应优先。
      final resultB = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a', 'char-b'],
        currentTargetId: 'char-b',
      );
      expect(resultB, contains('char-b'));
    });
  });

  // ─── Memory sorting ─────────────────────────────────────────────────────────

  group('Memory sorting', () {
    test('pinned memories come first', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));

      await db.permanentMemoryBox.put('pm:unpinned', PermanentMemory(
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '普通事实',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 90,
        confidence: 1.0,
        pinned: false,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊:测试',
      ));
      await db.permanentMemoryBox.put('pm:pinned', PermanentMemory(
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '重要事实',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 30,
        confidence: 0.5,
        pinned: true,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊:测试',
      ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'],
        currentTargetId: 'user',
        characterBudget: 1000,
      );

      // pinned 记忆应排在前面。
      final pinnedPos = result.indexOf('重要事实');
      final unpinnedPos = result.indexOf('普通事实');
      expect(pinnedPos, greaterThan(0));
      expect(pinnedPos, lessThan(unpinnedPos));
    });

    test('respects character budget', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));

      for (var i = 0; i < 5; i++) {
        await db.permanentMemoryBox.put('pm:$i', PermanentMemory(
          observerCharacterId: 'char-a',
          kind: MemoryKind.fact,
          content: '事实$i',
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          importance: 50,
          originType: MemoryOriginType.group,
          originNameSnapshot: '群聊:测试',
        ));
      }

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'],
        currentTargetId: 'user',
        characterBudget: 50, // very small budget
      );

      // 预算内只能放少量记忆。
      expect(result.length, lessThan(200));
    });
  });

  // ─── HumanizedChatOrchestrator global relationships ──────────────────────────

  group('HumanizedChatOrchestrator global relationships', () {
    test('relation lookup does not require groupId match', () {
      final alice = AICharacter(
        id: 'a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      );
      final bob = AICharacter(
        id: 'b', name: '小林', avatar: '💻', age: 28, role: '程序员',
        personalityTags: const [], systemPrompt: '你是小林', apiKey: 'k', apiProvider: 'deepseek',
      );

      // 关系在 group-1 建立，但查询时 groupId 是 group-2。
      final relation = RelationshipState(
        groupId: 'group-1', // 旧 groupId
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        familiarity: 80,
        affinity: 60,
        trust: 40,
        friction: 10,
        recentMood: RelationshipMood.warm,
      );

      // 使用全局关系列表（来自 ChatRoomLoader 的全局加载）。
      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-2',
            senderId: 'b',
            senderType: 'ai',
            content: '这个设计不错。',
          ),
        ],
        groupId: 'group-2', // 当前群
        groupTheme: '日常聊天',
        userMessage: null,
        mentionedIds: const [],
        memories: const [],
        relationships: [relation], // 全局关系列表
        isEligible: (_) => true,
        random: Random(1),
      );

      // Alice 应该因与 Bob 的良好关系而获得加分。
      expect(intents.any((i) => i.speakerId == 'a'), isTrue);
    });

    test('global relation is found without groupId filter', () {
      final alice = AICharacter(
        id: 'a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      );
      final bob = AICharacter(
        id: 'b', name: '小林', avatar: '💻', age: 28, role: '程序员',
        personalityTags: const [], systemPrompt: '你是小林', apiKey: 'k', apiProvider: 'deepseek',
      );

      // 关系在 group-1 建立，但查询时 groupId 是 group-2。
      final relation = RelationshipState(
        groupId: 'group-1', // 旧 groupId
        sourceCharacterId: 'a',
        targetId: 'b',
        targetType: RelationshipTargetType.ai,
        familiarity: 80,
        affinity: 60,
        trust: 40,
        friction: 10,
        recentMood: RelationshipMood.warm,
      );

      // 使用全局关系列表（来自 ChatRoomLoader 的全局加载）。
      final intents = HumanizedChatOrchestrator.selectReplyIntents(
        characters: [alice, bob],
        recentMessages: [
          Message(
            groupId: 'group-2',
            senderId: 'b',
            senderType: 'ai',
            content: '这个设计不错。',
          ),
        ],
        groupId: 'group-2', // 当前群
        groupTheme: '日常聊天',
        userMessage: null,
        mentionedIds: const [],
        memories: const [],
        relationships: [relation], // 全局关系列表
        isEligible: (_) => true,
        random: Random(1),
      );

      // Alice 应该因与 Bob 的良好关系而获得加分。
      expect(intents.any((i) => i.speakerId == 'a'), isTrue);
    });
  });

  // ─── Cross-group + cross-DM comprehensive ────────────────────────────────────

  group('Cross-context integration', () {
    test('memory formed in group is readable in DM prompt', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));

      // 群聊中形成的承诺记忆。
      await db.permanentMemoryBox.put('pm:commit', PermanentMemory(
        observerCharacterId: 'char-a',
        kind: MemoryKind.commitment,
        content: '用户承诺下次给阿月发自己的画作',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 75,
        explicitlyRequested: true,
        originType: MemoryOriginType.group,
        originConversationId: 'group-art',
        originNameSnapshot: '群聊:画画交流',
      ));

      final selector = MemoryContextSelector(db);

      // DM 场景查询。
      final dmResult = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'],
        currentTargetId: 'user',
        userMessage: '最近怎么样',
      );
      expect(dmResult, contains('画作'));
      expect(dmResult, contains('承诺'));

      // 另一个群场景查询。
      final groupResult = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a', 'char-b'],
        currentTargetId: 'user',
        userMessage: '阿月最近在干嘛',
      );
      expect(groupResult, contains('画作'));
    });
  });

  // ─── DM → group positive read ────────────────────────────────────────────────

  group('DM → group positive read', () {
    test('memory formed in DM is readable in group prompt', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));

      // 私聊中形成的事实记忆。
      await db.permanentMemoryBox.put('pm:dm-fact', PermanentMemory(
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '用户最喜欢吃日料',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 50,
        originType: MemoryOriginType.direct,
        originConversationId: 'dm:char-a',
        originNameSnapshot: '私聊:阿月',
      ));

      final selector = MemoryContextSelector(db);
      // 群聊场景查询：participantCharacterIds 包含多位角色。
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a', 'char-b', 'char-c'],
        currentTargetId: 'user',
      );

      expect(result, contains('日料'));
    });
  });

  // ─── Global relationship stable snapshot ─────────────────────────────────────

  group('Global relationship stable snapshot', () {
    test('two old snapshots + one global snapshot → global wins', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));
      await db.aiCharacterBox.put('char-b', AICharacter(
        id: 'char-b', name: '小林', avatar: '💻', age: 28, role: '程序员',
        personalityTags: const [], systemPrompt: '你是小林', apiKey: 'k', apiProvider: 'deepseek',
      ));
      await db.chatGroupBox.put('group-1', ChatGroup(
        id: 'group-1', name: '群1', theme: '测试', description: '',
        aiCharacterIds: const ['char-a', 'char-b'], ownerName: '',
      ));

      // 旧群 1 快照（较新）。
      await db.relationshipStateBox.put('rel:old1', RelationshipState(
        id: 'rel:char-a:ai:char-b',
        groupId: 'group-1',
        sourceCharacterId: 'char-a',
        targetId: 'char-b',
        targetType: RelationshipTargetType.ai,
        affinity: 30,
        familiarity: 40,
        updatedAt: DateTime.now().subtract(const Duration(days: 5)),
      ));
      // 旧群 2 快照（更旧）。
      await db.relationshipStateBox.put('rel:old2', RelationshipState(
        id: 'rel:char-a:ai:char-b:v2',
        groupId: 'group-2',
        sourceCharacterId: 'char-a',
        targetId: 'char-b',
        targetType: RelationshipTargetType.ai,
        affinity: 10,
        familiarity: 20,
        updatedAt: DateTime.now().subtract(const Duration(days: 10)),
      ));
      // 全局稳定快照（应该优先使用）。
      await db.relationshipStateBox.put('rel:global', RelationshipState(
        id: 'rel:char-a:ai:char-b:global',
        groupId: 'global',
        sourceCharacterId: 'char-a',
        targetId: 'char-b',
        targetType: RelationshipTargetType.ai,
        affinity: 80,
        familiarity: 90,
        updatedAt: DateTime.now().subtract(const Duration(days: 1)),
      ));

      // 通过 ChatRoomLoader 的稳定加载验证全局优先。
      final loader = ChatRoomLoader(
        db: db,
        resolveApiConfig: (c) => null,
      );
      final context = await loader.load('group-1');
      // 应该只返回全局快照（旧快照被过滤掉）。
      expect(context.relationships.length, 1);
      expect(context.relationships.first.affinity, 80);
      expect(context.relationships.first.groupId, 'global');
    });

    test('fallback to latest legacy snapshot when no global snapshot', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));
      await db.aiCharacterBox.put('char-b', AICharacter(
        id: 'char-b', name: '小林', avatar: '💻', age: 28, role: '程序员',
        personalityTags: const [], systemPrompt: '你是小林', apiKey: 'k', apiProvider: 'deepseek',
      ));
      await db.chatGroupBox.put('group-1', ChatGroup(
        id: 'group-1', name: '群1', theme: '测试', description: '',
        aiCharacterIds: const ['char-a', 'char-b'], ownerName: '',
      ));

      // 只有旧快照，没有全局快照。
      await db.relationshipStateBox.put('rel:old', RelationshipState(
        id: 'rel:char-a:ai:char-b',
        groupId: 'group-1',
        sourceCharacterId: 'char-a',
        targetId: 'char-b',
        targetType: RelationshipTargetType.ai,
        affinity: 50,
        familiarity: 60,
        updatedAt: DateTime.now().subtract(const Duration(days: 3)),
      ));

      final loader = ChatRoomLoader(
        db: db,
        resolveApiConfig: (c) => null,
      );
      final context = await loader.load('group-1');
      // 回退到最新的旧快照。
      expect(context.relationships.length, 1);
      expect(context.relationships.first.affinity, 50);
    });
  });

  // ─── Selector invalidation chain ─────────────────────────────────────────────

  group('Selector invalidation chain', () {
    test('superseded memory is excluded', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));

      // 旧记忆被新记忆 supersede。
      await db.permanentMemoryBox.put('pm:old', PermanentMemory(
        id: 'pm-old',
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '用户住在北京',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 60,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊:旧',
      ));
      await db.permanentMemoryBox.put('pm:new', PermanentMemory(
        id: 'pm-new',
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '用户搬去上海了',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 60,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊:新',
        supersedesIds: const ['pm-old'],
      ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'],
      );

      expect(result, contains('上海'));
      expect(result, isNot(contains('北京')));
    });

    test('strict budget: first memory cannot exceed budget', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
      ));

      // 第一条记忆就超过预算。
      await db.permanentMemoryBox.put('pm:big', PermanentMemory(
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '这是一条非常非常非常非常非常非常非常非常长的记忆内容超过了预算限制',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 60,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊:测试',
      ));
      await db.permanentMemoryBox.put('pm:small', PermanentMemory(
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '短的',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 60,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊:测试',
      ));

      final selector = MemoryContextSelector(db);
      // 预算极小，最短记忆也放不下 → 返回空（不强行塞入）。
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'],
        characterBudget: 5,
      );

      expect(result, '');
    });
  });

  // ─── DM prohibits legacy double injection ────────────────────────────────────

  group('DM memory injection', () {
    test('direct chat uses unified selector not legacySummary', () async {
      final db = DatabaseService();
      await db.aiCharacterBox.put('char-a', AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
        memorySummary: '这是旧版 legacy 记忆，不应该出现在 prompt 中',
      ));

      // 通过 unified selector 注入的记忆。
      await db.permanentMemoryBox.put('pm:unified', PermanentMemory(
        observerCharacterId: 'char-a',
        kind: MemoryKind.fact,
        content: '用户喜欢听爵士乐',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 50,
        originType: MemoryOriginType.group,
        originNameSnapshot: '群聊:音乐',
      ));

      final selector = MemoryContextSelector(db);
      final result = await selector.select(
        observerCharacterId: 'char-a',
        participantCharacterIds: const ['char-a'],
        currentTargetId: 'user',
      );

      // 应该包含 unified memory 的内容。
      expect(result, contains('爵士乐'));
      // 不应该包含 legacy memorySummary 的内容。
      expect(result, isNot(contains('旧版 legacy 记忆')));
    });
  });

  // ─── WorkModePolicy planning context ────────────────────────────────────────

  group('WorkModePolicy planning context', () {
    test('planningContext returns work-mode instructions', () async {
      // Verify that WorkModePolicy.planningContext returns expected content.
      final char = AICharacter(
        id: 'char-a', name: '阿月', avatar: '🌙', age: 25, role: '插画师',
        personalityTags: const [], systemPrompt: '你是阿月', apiKey: 'k', apiProvider: 'deepseek',
        skillIds: const ['skill-1'],
      );

      final context = WorkModePolicy.planningContext(char);
      expect(context, contains('工作模式'));
      expect(context, contains('插画师'));
      expect(context, contains('skill-1'));
      expect(context, contains('不得改走普通闲聊'));
    });
  });
}
