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
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
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
  List<Message> historyMessages = const [];

  @override
  Future<MessagePage> loadLatestMessages(String groupId, {int limit = 80}) {
    final start =
        historyMessages.length > limit ? historyMessages.length - limit : 0;
    return Future.value(
      MessagePage(
        messages: historyMessages.sublist(start),
        hasOlder: start > 0,
        totalCount: historyMessages.length,
      ),
    );
  }

  @override
  Future<List<Message>> messagesForGroup(String groupId) {
    return Future.value(historyMessages);
  }

  @override
  Future<Set<String>> messageIdsForConversation(String groupId) {
    return Future.value(
      historyMessages
          .where((message) => message.groupId == groupId)
          .map((message) => message.id)
          .toSet(),
    );
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
  late PromptTestDatabaseService db;

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
      intent: const ReplyIntent(
        speakerId: 'char-1',
        action: ReplyAction.answer,
        targetId: 'user',
        lengthHint: ReplyLengthHint.short,
        toneHint: '自然',
        reason: 'test-humanized-entry',
      ),
    );
    final prompt = _allMessages(messages);
    expect(prompt.split(character.rolePlaySystemPrompt).length - 1, 1);
    expect(prompt.split(character.promptIdentity).length - 1, 1);
    expect(prompt, contains(character.promptIdentity));
    expect(prompt, contains('角色性别为${character.gender.label}'));
    expect(prompt, contains(character.systemPrompt));
    expect(prompt, contains('本轮动作：answer'));
    expect(prompt, contains('人物卡名称_入口测试'));
    expect(prompt, contains('PERMANENT_GROUP_必须出现'));
    expect(prompt, contains('最近情绪warm'));
    expect(prompt, contains('GROUP_MEMORY_必须出现'));
    expect(prompt, isNot(contains('LEGACY_SUMMARY_不得出现')));
    expect(prompt, isNot(contains('CHARACTER_MEMORY_GROUP_不得出现')));
    expect(prompt, isNot(contains('旧群主名_不得出现')));

    final autoMessages = await pageState.buildPromptMessages(
      character: character,
      context: const <Message>[],
      isAutoChat: true,
    );
    final autoPrompt = _allMessages(autoMessages);
    expect(autoPrompt.split(character.rolePlaySystemPrompt).length - 1, 1);
    expect(autoPrompt.split(character.promptIdentity).length - 1, 1);
    expect(autoPrompt, contains(character.promptIdentity));
    expect(autoPrompt, contains('角色性别为${character.gender.label}'));
    expect(autoPrompt, contains(character.systemPrompt));

    final hiddenMessages = await pageState.buildPromptMessages(
      character: character,
      context: [
        Message(
          groupId: 'group-prompt',
          senderId: 'user',
          senderType: 'user',
          content: 'PROMPT_LEAK_不可见',
          visibleToCharacterIds: const ['another-character'],
        ),
      ],
    );
    expect(_allMessages(hiddenMessages), isNot(contains('PROMPT_LEAK_不可见')));
    expect(_allMessages(hiddenMessages), isNot(contains('GROUP_MEMORY_必须出现')));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('分页之外的受限群消息不会注入共享群摘要', (tester) async {
    final character = _character();
    await tester.runAsync(() async {
      await db.aiCharacterBox.put(character.id, character);
      await db.chatGroupBox.put(
        'group-paginated-privacy',
        ChatGroup(
          id: 'group-paginated-privacy',
          name: '分页隐私测试群',
          theme: '日常聊天',
          aiCharacterIds: const ['char-1', 'private-character'],
        ),
      );
      db.historyMessages = [
        Message(
          id: 'restricted-old',
          groupId: 'group-paginated-privacy',
          senderId: 'user',
          senderType: 'user',
          content: '分页之外的私密内容',
          visibleToCharacterIds: const ['private-character'],
        ),
        for (var index = 0; index < 80; index++)
          Message(
            id: 'visible-$index',
            groupId: 'group-paginated-privacy',
            senderId: 'user',
            senderType: 'user',
            content: '公开消息$index',
            visibleToCharacterIds: const ['char-1', 'private-character'],
          ),
      ];
      await db.groupMemoryBox.put(
        'group-paginated-privacy_${ChatOrchestrator.memoryPeriodKey(DateTime.now())}',
        GroupMemory(
          groupId: 'group-paginated-privacy',
          topicSummary: 'PAGINATED_GROUP_MEMORY_不得注入',
        ),
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatRoomPage(
            groupId: 'group-paginated-privacy',
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
    expect(
        _allMessages(messages), isNot(contains('PAGINATED_GROUP_MEMORY_不得注入')));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('群聊 legacy 消息没有权限快照时不注入角色 Prompt', (tester) async {
    final character = _character();
    await tester.runAsync(() async {
      await db.aiCharacterBox.put(character.id, character);
      await db.chatGroupBox.put(
        'group-legacy-privacy',
        ChatGroup(
          id: 'group-legacy-privacy',
          name: '旧消息隐私测试群',
          theme: '日常聊天',
          aiCharacterIds: [character.id],
        ),
      );
      db.historyMessages = [
        Message(
          id: 'legacy-group-message',
          groupId: 'group-legacy-privacy',
          senderId: 'user',
          senderType: 'user',
          content: 'LEGACY_GROUP_MESSAGE_不得注入',
        ),
      ];
      await db.groupMemoryBox.put(
        'group-legacy-privacy_${ChatOrchestrator.memoryPeriodKey(DateTime.now())}',
        GroupMemory(
          groupId: 'group-legacy-privacy',
          topicSummary: 'LEGACY_GROUP_MEMORY_不得注入',
        ),
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatRoomPage(
            groupId: 'group-legacy-privacy',
            credentialResolver: FixedApiCredentialResolver(),
          ),
        ),
      ),
    );
    await _pumpPageFrames(tester);

    final dynamic pageState = tester.state(find.byType(ChatRoomPage));
    final messages = await pageState.buildPromptMessages(
      character: character,
      context: db.historyMessages,
      userMessage: '你好',
    );
    final prompt = _allMessages(messages);
    expect(prompt, isNot(contains('LEGACY_GROUP_MESSAGE_不得注入')));
    expect(prompt, isNot(contains('LEGACY_GROUP_MEMORY_不得注入')));

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
    expect(prompt.split(character.rolePlaySystemPrompt).length - 1, 1);
    expect(prompt.split(character.promptIdentity).length - 1, 1);
    expect(prompt, contains(character.promptIdentity));
    expect(prompt, contains('角色性别为${character.gender.label}'));
    expect(prompt, contains(character.systemPrompt));
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
