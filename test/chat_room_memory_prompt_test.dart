import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/chat_group/chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

class FixedApiCredentialResolver implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'sk-test';
}

class PromptTestDatabaseService extends DatabaseService {
  @override
  Future<MessagePage> loadLatestMessages(String groupId, {int limit = 80}) {
    return Future.value(
      const MessagePage(messages: [], hasOlder: false, totalCount: 0),
    );
  }

  @override
  Future<List<Message>> messagesForGroup(String groupId) {
    return Future.value(const <Message>[]);
  }

  @override
  Future<void> markGroupChatRead(String groupId, {DateTime? readAt}) async {}

  @override
  Future<void> markDirectChatRead(
    String conversationId, {
    DateTime? readAt,
  }) async {}
}

void main() {
  late Directory tempDir;
  late DatabaseService db;

  setUp(() async {
    tempDir = await openLifecycleHive();
    db = PromptTestDatabaseService();
  });

  tearDown(() async {
    db.resetLifecycleCaches();
    await closeLifecycleHive(tempDir);
  });

  testWidgets('普通群聊页面发送入口使用统一记忆而不注入 legacy 内容', (tester) async {
    final character = _character();
    await tester.runAsync(() async {
      await _seedCommonMemory(db, character);
      await db.aiCharacterBox.put(character.id, character);
      await db.chatGroupBox.put(
        'group-prompt',
        ChatGroup(
          id: 'group-prompt',
          name: '普通群聊测试',
          theme: '日常聊天',
          ownerName: '旧群主名_不得出现',
          aiCharacterIds: [character.id],
        ),
      );
      await db.groupMemoryBox.put(
        'group-prompt_${ChatOrchestrator.memoryPeriodKey(DateTime.now())}',
        GroupMemory(
          groupId: 'group-prompt',
          topicSummary: 'GROUP_MEMORY_必须出现',
        ),
      );
      await db.characterMemoryBox.put(
        'group-legacy',
        CharacterMemory(
          groupId: 'group-prompt',
          characterId: character.id,
          facts: const ['CHARACTER_MEMORY_GROUP_不得出现'],
        ),
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatRoomPage(
            groupId: 'group-prompt',
            credentialResolver: FixedApiCredentialResolver(),
          ),
        ),
      ),
    );
    await _pumpPageFrames(tester);
    final dynamic pageState = tester.state(find.byType(ChatRoomPage));
    final messages = await pageState.buildPromptMessages(
      character: character,
      context: const <Message>[],
      userMessage: '你好',
    );
    final prompt = _allMessages(messages);
    expect(prompt, contains('人物卡名称_入口测试'));
    expect(prompt, contains('PERMANENT_GROUP_必须出现'));
    expect(prompt, contains('最近情绪warm'));
    expect(prompt, contains('GROUP_MEMORY_必须出现'));
    expect(prompt, isNot(contains('LEGACY_SUMMARY_不得出现')));
    expect(prompt, isNot(contains('CHARACTER_MEMORY_GROUP_不得出现')));
    expect(prompt, isNot(contains('旧群主名_不得出现')));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('普通私聊页面发送入口使用统一记忆而不注入当前 DM legacy 内容', (tester) async {
    final character = _character();
    await tester.runAsync(() async {
      await _seedCommonMemory(db, character);
      await db.aiCharacterBox.put(character.id, character);
      await db.characterMemoryBox.put(
        'direct-legacy',
        CharacterMemory(
          groupId: 'dm:${character.id}',
          characterId: character.id,
          facts: const ['CHARACTER_MEMORY_DM_不得出现'],
        ),
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatRoomPage(
            groupId: 'dm:${character.id}',
            credentialResolver: FixedApiCredentialResolver(),
          ),
        ),
      ),
    );
    await _pumpPageFrames(tester);
    final dynamic pageState = tester.state(find.byType(ChatRoomPage));
    final messages = await pageState.buildPromptMessages(
      character: character,
      context: const <Message>[],
      userMessage: '你最近好吗',
    );
    final prompt = _allMessages(messages);
    expect(prompt, contains('人物卡名称_入口测试'));
    expect(prompt, contains('PERMANENT_DM_必须出现'));
    expect(prompt, contains('最近情绪warm'));
    expect(prompt, isNot(contains('LEGACY_SUMMARY_不得出现')));
    expect(prompt, isNot(contains('CHARACTER_MEMORY_DM_不得出现')));
    expect(prompt, isNot(contains('群聊中的其他角色')));
    expect(prompt, isNot(contains('高活跃度群聊')));

    await tester.pumpWidget(const SizedBox());
  });
}

AICharacter _character() => AICharacter(
      id: 'char-1',
      name: '入口角色',
      avatar: '角',
      age: 26,
      role: '朋友',
      personalityTags: const [],
      systemPrompt: '你是入口角色',
      apiKey: '',
      apiProvider: 'deepseek',
      apiConfigId: 'cfg-1',
    )..memorySummary = 'LEGACY_SUMMARY_不得出现';

Future<void> _seedCommonMemory(
    DatabaseService db, AICharacter character) async {
  await db.apiConfigBox.put(
    'cfg-1',
    ApiConfig(
      id: 'cfg-1',
      name: '测试配置',
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      credentialId: 'credential.api-config.cfg-1',
      hasCredential: true,
    ),
  );
  await db.userProfileBox.put(
    'me',
    UserProfile(
      displayName: '人物卡名称_入口测试',
      preferredAddress: '测试用户',
      avatar: '',
      bio: '入口测试人物卡',
    ),
  );
  await db.permanentMemoryBox.put(
    'pm-${character.id}',
    PermanentMemory(
      observerCharacterId: character.id,
      kind: MemoryKind.fact,
      content: 'PERMANENT_DM_必须出现',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      importance: 95,
      originType: MemoryOriginType.direct,
      originConversationId: 'dm:${character.id}',
      originNameSnapshot: '入口测试私聊',
    ),
  );
  await db.permanentMemoryBox.put(
    'pm-group-${character.id}',
    PermanentMemory(
      observerCharacterId: character.id,
      kind: MemoryKind.fact,
      content: 'PERMANENT_GROUP_必须出现',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      importance: 90,
      originType: MemoryOriginType.group,
      originConversationId: 'group-prompt',
      originNameSnapshot: '入口测试群',
    ),
  );
  await db.relationshipStateBox.put(
    'rel-${character.id}',
    RelationshipState(
      id: 'rel:${character.id}:user:global',
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
  await db.appSettingsBox.put(
    'ai_governance_budget_v1',
    const {'autoChatEnabled': false},
  );
}

String _allMessages(List<Map<String, dynamic>> messages) =>
    messages.map((message) => message['content']?.toString() ?? '').join('\n');

Future<void> _pumpPageFrames(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
