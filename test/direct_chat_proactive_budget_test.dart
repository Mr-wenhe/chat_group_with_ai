import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/direct_chat/direct_chat_proactive_service.dart';
import 'package:chat_group/features/direct_chat/direct_chat_inbox.dart';
import 'package:chat_group/features/chat_group/group_chat_proactive_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/capturing_chat_api_service.dart';
import 'helpers/lifecycle_hive.dart';

/// 用内存版 ChatApiService 验证主动消息入口和「主动 DM 走统一每小时发言预算」。
class FakeChatApiService extends CapturingChatApiService {
  FakeChatApiService() : super(responseText: '主动私聊内容');
}

class FakeApiCredentialResolver implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async =>
      config.id == 'cfg-1' ? 'sk-test' : null;
}

void main() {
  late Directory tempDir;
  late DatabaseService db;
  late FakeChatApiService chatApi;

  setUp(() async {
    tempDir = await openLifecycleHive();
    db = DatabaseService();
    chatApi = FakeChatApiService();
  });

  tearDown(() async {
    db.resetLifecycleCaches();
    await closeLifecycleHive(tempDir);
  });

  AICharacter seedCharacter({required bool atHourlyLimit}) {
    final config = ApiConfig(
      id: 'cfg-1',
      name: 'cfg',
      provider: 'deepseek',
      apiKey: 'sk-test',
      credentialId: 'credential.api-config.cfg-1',
      hasCredential: true,
    );
    db.apiConfigBox.put(config.id, config);
    final character = AICharacter(
      id: 'char-1',
      name: '小夏',
      avatar: '',
      age: 20,
      role: '朋友',
      personalityTags: const [],
      systemPrompt: '你是小夏',
      apiKey: '',
      apiProvider: 'deepseek',
      apiConfigId: 'cfg-1',
      hourlyReplyLimit: 5,
      hourlyReplyCount: atHourlyLimit ? 5 : 0,
      lastReplyTimestamp: atHourlyLimit ? DateTime.now() : null,
      isActive: true,
    );
    db.aiCharacterBox.put(character.id, character);
    return character;
  }

  test('达到每小时上限时跳过主动 DM（不调用模型、不伪造发送）', () async {
    seedCharacter(atHourlyLimit: true);
    final service = DirectChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    final result = await service.tryCreateProactiveMessage();

    // 跳过：不生成消息、不调用模型、不记用。
    expect(result, isNull);
    expect(chatApi.sendCount, 0);
    expect(db.aiCharacterBox.get('char-1')!.hourlyReplyCount, 5);
  });

  test('未达上限时正常发送并记用（与聊天共用同一套每小时预算）', () async {
    seedCharacter(atHourlyLimit: false);
    final service = DirectChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    final result = await service.tryCreateProactiveMessage();

    expect(result, isNotNull);
    expect(result!.message.content, '主动私聊内容');
    expect(chatApi.sendCount, 1);
    // 统一记用：发送后每小时计数 +1，并记录时间戳。
    expect(db.aiCharacterBox.get('char-1')!.hourlyReplyCount, 1);
    expect(db.aiCharacterBox.get('char-1')!.lastReplyTimestamp, isNotNull);
  });

  test('主动私聊不应注入角色未加入群聊的用户消息', () async {
    seedCharacter(atHourlyLimit: false);
    await db.chatGroupBox.put(
      'outside-group',
      ChatGroup(
        id: 'outside-group',
        name: '外部群',
        theme: '测试',
        aiCharacterIds: const ['another-character'],
      ),
    );
    await db.messageBox.put(
      'outside-message',
      Message(
        id: 'outside-message',
        groupId: 'outside-group',
        senderId: 'user',
        senderType: 'user',
        content: '外部群的私密内容',
        visibleToCharacterIds: const ['another-character'],
      ),
    );

    final service = DirectChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    expect(await service.tryCreateProactiveMessage(), isNotNull);
    final requestText = chatApi.messageCalls.single
        .expand((message) => [message['content']?.toString() ?? ''])
        .join('\n');
    expect(requestText, isNot(contains('外部群的私密内容')));
  });

  test('不可见的群消息不应触发该角色的群聊主动私聊', () async {
    seedCharacter(atHourlyLimit: false);
    await db.chatGroupBox.put(
      'hidden-trigger-group',
      ChatGroup(
        id: 'hidden-trigger-group',
        name: '隐藏触发群',
        theme: '测试',
        aiCharacterIds: const ['char-1', 'another-character'],
      ),
    );
    await db.messageBox.put(
      'hidden-trigger-message',
      Message(
        id: 'hidden-trigger-message',
        groupId: 'hidden-trigger-group',
        senderId: 'user',
        senderType: 'user',
        content: '只给另一个角色看的内容',
        visibleToCharacterIds: const ['another-character'],
      ),
    );

    final service = DirectChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    final result = await service.tryCreateProactiveMessage();

    expect(result, isNotNull);
    expect(result!.source, DirectChatSource.direct);
    final requestText = chatApi.messageCalls.single
        .expand((message) => [message['content']?.toString() ?? ''])
        .join('\n');
    expect(requestText, isNot(contains('从群聊话题延伸')));
  });

  test('主动私聊群来源只注入角色可见的群消息', () async {
    seedCharacter(atHourlyLimit: false);
    await db.chatGroupBox.put(
      'visible-source-group',
      ChatGroup(
        id: 'visible-source-group',
        name: '来源群',
        theme: '测试',
        aiCharacterIds: const ['char-1', 'another-character'],
      ),
    );
    await db.messageBox.putAll({
      'visible-source-message': Message(
        id: 'visible-source-message',
        groupId: 'visible-source-group',
        senderId: 'user',
        senderType: 'user',
        content: 'GROUP_VISIBLE_FOR_CHAR',
        visibleToCharacterIds: const ['char-1'],
      ),
      'hidden-source-message': Message(
        id: 'hidden-source-message',
        groupId: 'visible-source-group',
        senderId: 'user',
        senderType: 'user',
        content: 'GROUP_SECRET_FOR_OTHER',
        visibleToCharacterIds: const ['another-character'],
      ),
      'legacy-source-message': Message(
        id: 'legacy-source-message',
        groupId: 'visible-source-group',
        senderId: 'user',
        senderType: 'user',
        content: 'GROUP_LEGACY_WITHOUT_PROOF',
      ),
    });

    final service = DirectChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    final result = await service.tryCreateProactiveMessage();

    expect(result, isNotNull);
    expect(result!.source, DirectChatSource.group);
    final requestText = chatApi.messageCalls.single
        .expand((message) => [message['content']?.toString() ?? ''])
        .join('\n');
    expect(requestText, contains('GROUP_VISIBLE_FOR_CHAR'));
    expect(requestText, isNot(contains('GROUP_SECRET_FOR_OTHER')));
    expect(requestText, isNot(contains('GROUP_LEGACY_WITHOUT_PROOF')));
  });

  test('主动群聊不注入角色不可见或无权限快照的消息', () async {
    seedCharacter(atHourlyLimit: false);
    await db.chatGroupBox.put(
      'group-proactive-visibility',
      ChatGroup(
        id: 'group-proactive-visibility',
        name: '主动群聊隐私群',
        theme: '测试',
        aiCharacterIds: const ['char-1', 'another-character'],
      ),
    );
    await db.messageBox.putAll({
      'group-visible-message': Message(
        id: 'group-visible-message',
        groupId: 'group-proactive-visibility',
        senderId: 'user',
        senderType: 'user',
        content: 'GROUP_PROACTIVE_VISIBLE',
        visibleToCharacterIds: const ['char-1'],
      ),
      'group-hidden-message': Message(
        id: 'group-hidden-message',
        groupId: 'group-proactive-visibility',
        senderId: 'user',
        senderType: 'user',
        content: 'GROUP_PROACTIVE_SECRET',
        visibleToCharacterIds: const ['another-character'],
      ),
      'group-legacy-message': Message(
        id: 'group-legacy-message',
        groupId: 'group-proactive-visibility',
        senderId: 'user',
        senderType: 'user',
        content: 'GROUP_PROACTIVE_LEGACY',
      ),
    });

    final service = GroupChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    final result = await service.tryCreateProactiveMessage();

    expect(result, isNotNull);
    final requestText = chatApi.messageCalls.single
        .expand((message) => [message['content']?.toString() ?? ''])
        .join('\n');
    expect(requestText, contains('GROUP_PROACTIVE_VISIBLE'));
    expect(requestText, isNot(contains('GROUP_PROACTIVE_SECRET')));
    expect(requestText, isNot(contains('GROUP_PROACTIVE_LEGACY')));
  });

  test('主动私聊公开入口把统一记忆送到 fake API 的 system messages', () async {
    final character = seedCharacter(atHourlyLimit: false);
    character.memorySummary = 'LEGACY_SUMMARY_不得出现';
    await db.aiCharacterBox.put(character.id, character);
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
      'pm-direct-entry',
      PermanentMemory(
        observerCharacterId: character.id,
        kind: MemoryKind.fact,
        content: 'PERMANENT_DM_必须出现',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 90,
        originType: MemoryOriginType.direct,
        originConversationId: 'dm:${character.id}',
        originNameSnapshot: '入口测试私聊',
      ),
    );
    await db.relationshipStateBox.put(
      'rel-direct-entry',
      RelationshipState(
        id: 'rel:char-1:user:global',
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

    final service = DirectChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    expect(await service.tryCreateProactiveMessage(), isNotNull);
    expect(chatApi.sendCount, 1);
    expect(chatApi.messageCalls, hasLength(1));
    final systemContent = chatApi.messageCalls.single
        .where((message) => message['role'] == 'system')
        .map((message) => message['content'].toString())
        .join('\n');
    expect(systemContent.split(character.rolePlaySystemPrompt).length - 1, 1);
    expect(systemContent.split(character.promptIdentity).length - 1, 1);
    expect(systemContent, contains(character.promptIdentity));
    expect(systemContent, contains('角色性别为${character.gender.label}'));
    expect(systemContent, contains(character.systemPrompt));
    expect(systemContent, contains('人物卡名称_入口测试'));
    expect(systemContent, contains('PERMANENT_DM_必须出现'));
    expect(systemContent, contains('最近情绪warm'));
    expect(systemContent, isNot(contains('LEGACY_SUMMARY_不得出现')));
  });

  test('主动群聊公开入口把统一记忆送到 fake API 且使用人物卡名称', () async {
    final character = seedCharacter(atHourlyLimit: false);
    character.memorySummary = 'LEGACY_SUMMARY_不得出现';
    await db.aiCharacterBox.put(character.id, character);
    await db.userProfileBox.put(
      'me',
      UserProfile(
        displayName: '人物卡名称_入口测试',
        preferredAddress: '测试用户',
        avatar: '',
        bio: '入口测试人物卡',
      ),
    );
    await db.chatGroupBox.put(
      'group-entry',
      ChatGroup(
        id: 'group-entry',
        name: '入口测试群',
        theme: '测试主题',
        ownerName: '旧群主名_不得出现',
        aiCharacterIds: [character.id],
      ),
    );
    await db.permanentMemoryBox.put(
      'pm-group-entry',
      PermanentMemory(
        observerCharacterId: character.id,
        kind: MemoryKind.fact,
        content: 'PERMANENT_GROUP_必须出现',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        importance: 90,
        originType: MemoryOriginType.group,
        originConversationId: 'group-entry',
        originNameSnapshot: '入口测试群',
      ),
    );
    await db.relationshipStateBox.put(
      'rel-group-entry',
      RelationshipState(
        id: 'rel:char-1:user:global',
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

    final service = GroupChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    expect(
      await service.tryCreateProactiveMessage(preferredGroupId: 'group-entry'),
      isNotNull,
    );
    expect(chatApi.sendCount, 1);
    expect(chatApi.messageCalls, hasLength(1));
    final systemContent = chatApi.messageCalls.single
        .where((message) => message['role'] == 'system')
        .map((message) => message['content'].toString())
        .join('\n');
    expect(systemContent.split(character.rolePlaySystemPrompt).length - 1, 1);
    expect(systemContent.split(character.promptIdentity).length - 1, 1);
    expect(systemContent, contains(character.promptIdentity));
    expect(systemContent, contains('角色性别为${character.gender.label}'));
    expect(systemContent, contains(character.systemPrompt));
    expect(systemContent, contains('人物卡名称_入口测试'));
    expect(systemContent, isNot(contains('旧群主名_不得出现')));
    expect(systemContent, contains('PERMANENT_GROUP_必须出现'));
    expect(systemContent, contains('最近情绪warm'));
    expect(systemContent, isNot(contains('LEGACY_SUMMARY_不得出现')));
  });

  test('群聊主动消息遵守每小时上限并成功后记用', () async {
    seedCharacter(atHourlyLimit: true);
    await db.chatGroupBox.put(
      'group-1',
      ChatGroup(
        id: 'group-1',
        name: '测试群',
        theme: '测试主题',
        aiCharacterIds: const ['char-1'],
      ),
    );
    final blockedService = GroupChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    expect(await blockedService.tryCreateProactiveMessage(), isNull);
    expect(chatApi.sendCount, 0);

    final character = db.aiCharacterBox.get('char-1')!;
    character.hourlyReplyCount = 0;
    character.lastReplyTimestamp = null;
    await db.aiCharacterBox.put(character.id, character);
    final service = GroupChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    expect(await service.tryCreateProactiveMessage(), isNotNull);
    expect(chatApi.sendCount, 1);
    expect(db.aiCharacterBox.get('char-1')!.hourlyReplyCount, 1);
  });

  test('角色回复额度并发写入不会丢失增量', () async {
    seedCharacter(atHourlyLimit: false);
    await Future.wait([
      db.recordCharacterReplyUsage('char-1'),
      db.recordCharacterReplyUsage('char-1'),
    ]);

    expect(db.aiCharacterBox.get('char-1')!.hourlyReplyCount, 2);
  });

  test('没有关联安全配置时，不回退使用角色遗留 Key', () async {
    final character = AICharacter(
      id: 'legacy-character',
      name: '旧角色',
      avatar: '',
      age: 20,
      role: '朋友',
      personalityTags: const [],
      systemPrompt: '你是旧角色',
      apiKey: 'legacy-key-must-not-be-used',
      apiProvider: 'deepseek',
      apiConfigId: '',
      isActive: true,
    );
    await db.aiCharacterBox.put(character.id, character);
    final service = DirectChatProactiveService(
      db: db,
      chatApi: chatApi,
      credentialResolver: FakeApiCredentialResolver(),
    );

    final result = await service.tryCreateProactiveMessage();

    expect(result, isNull);
    expect(chatApi.sendCount, 0);
  });
}
