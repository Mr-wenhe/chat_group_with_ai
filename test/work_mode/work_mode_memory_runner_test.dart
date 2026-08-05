import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/work_mode/work_mode_memory_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';

void main() {
  late Directory tempDir;
  late DatabaseService db;

  setUp(() async {
    tempDir = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(tempDir));

  test('work mode production boundary injects memory before runtime callback',
      () async {
    final character = AICharacter(
      id: 'char-work',
      name: '工作角色',
      avatar: 'W',
      age: 30,
      role: '执行者',
      personalityTags: const [],
      systemPrompt: '你是工作角色',
      apiKey: '',
      apiProvider: 'deepseek',
    )..memorySummary = 'LEGACY_SUMMARY_不得出现';
    await db.aiCharacterBox.put(character.id, character);
    await db.userProfileBox.put(
      'me',
      UserProfile(
        displayName: '人物卡名称_入口测试',
        preferredAddress: '测试用户',
        avatar: '',
        bio: '工作模式人物卡',
      ),
    );
    await db.permanentMemoryBox.put(
      'pm-work-entry',
      PermanentMemory(
        observerCharacterId: character.id,
        kind: MemoryKind.commitment,
        content: 'PERMANENT_WORK_必须出现',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 95,
        originType: MemoryOriginType.group,
        originConversationId: 'group-work',
        originNameSnapshot: '工作模式测试',
      ),
    );
    await db.relationshipStateBox.put(
      'rel-work-entry',
      RelationshipState(
        id: 'rel:char-work:user:global',
        groupId: 'global',
        sourceCharacterId: character.id,
        targetId: 'user',
        targetType: RelationshipTargetType.user,
        affinity: 80,
        trust: 60,
        friction: 10,
        familiarity: 70,
        recentMood: RelationshipMood.warm,
      ),
    );

    final originalHistory = <Map<String, dynamic>>[
      {'role': 'system', 'content': 'CHECKPOINT_ALREADY_DONE'},
      {'role': 'user', 'content': '帮我继续完成任务'},
    ];
    List<Map<String, dynamic>>? runtimeHistory;
    var runtimeCalls = 0;

    final result = await runWithUnifiedMemory<String>(
      selector: MemoryContextSelector(db),
      conversationHistory: originalHistory,
      observerCharacterId: character.id,
      participantCharacterIds: const ['char-work'],
      userMessage: '帮我继续完成任务',
      run: (preparedHistory) async {
        runtimeCalls++;
        runtimeHistory = preparedHistory
            .map((message) => Map<String, dynamic>.from(message))
            .toList(growable: false);
        return preparedHistory.first['content'].toString();
      },
    );

    expect(runtimeCalls, 1);
    expect(runtimeHistory, isNotNull);
    expect(runtimeHistory!.first['role'], 'system');
    expect(runtimeHistory!.first['content'], contains('PERMANENT_WORK_必须出现'));
    expect(runtimeHistory!.first['content'], contains('人物卡名称_入口测试'));
    expect(runtimeHistory!.first['content'], contains('最近情绪warm'));
    expect(runtimeHistory!.first['content'],
        isNot(contains('LEGACY_SUMMARY_不得出现')));
    expect(
      runtimeHistory!.any(
        (message) => message['content'] == 'CHECKPOINT_ALREADY_DONE',
      ),
      isTrue,
    );
    expect(result, contains('PERMANENT_WORK_必须出现'));
  });
}
