import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/chat_group/chat_reply_prompt_guard.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/chat_group/group_shared_context.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

class FixedApiCredentialResolver implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'sk-test';
}

/// 固定分页结果的数据库替身：不读真实 `data/*.hive`，也不依赖磁盘顺序。
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
  Future<List<Message>> messagesForGroup(String groupId) =>
      Future.value(historyMessages);

  @override
  Future<Set<String>> messageIdsForConversation(String groupId) => Future.value(
        historyMessages
            .where((message) => message.groupId == groupId)
            .map((message) => message.id)
            .toSet(),
      );

  @override
  Future<void> markGroupChatRead(String groupId, {DateTime? readAt}) async {}

  @override
  Future<void> markDirectChatRead(
    String conversationId, {
    DateTime? readAt,
  }) async {}
}

void main() {
  late Directory directory;
  late PromptTestDatabaseService db;
  const ttsChannel = MethodChannel('flutter_tts');

  setUpAll(() async {
    // 房间 dispose 时会停掉 TTS；测试替身环境没有平台实现，不打桩会在清理阶段
    // 抛 MissingPluginException，把本来通过的用例判失败。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async => 1);
    directory = await openLifecycleHive();
    db = PromptTestDatabaseService();
  });

  setUp(() async {
    await db.aiCharacterBox.clear();
    await db.chatGroupBox.clear();
    await db.apiConfigBox.clear();
    await db.appSettingsBox.clear();
    db.historyMessages = const [];
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
    // 刻意不调用 `Hive.close()`：这条用例让页面真正跑起来，途中发起的 Hive 写
    // 有一部分留在测试的假时钟上，`close()` 会一直等它们而永久挂起（仓库已知的
    // 假区 Hive 行为）。临时目录直接删掉即可。
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  AICharacter character() => AICharacter(
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
      );

  Future<void> seedCharacter(WidgetTester tester, AICharacter member) async {
    await tester.runAsync(() async {
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
      await db.aiCharacterBox.put(member.id, member);
    });
  }

  Future<void> pumpRoom(WidgetTester tester, String groupId) async {
    // 先卸载上一棵树：同一个位置再 pump 一个 ChatRoomPage 会**复用旧 State**，
    // 于是 `_group` 还是上一个会话的快照，测出来的就不是这一次的请求上下文。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: ChatRoomPage(
            key: ValueKey(groupId),
            groupId: groupId,
            credentialResolver: FixedApiCredentialResolver(),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 交替推进假时钟并放行真实 I/O，再销毁页面。
  ///
  /// 只 `pump` 会让页面发起的 Hive 写永远悬着，最终卡住 teardown。
  Future<void> disposeRoom(WidgetTester tester) async {
    for (var round = 0; round < 12; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    for (var round = 0; round < 12; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  String allMessages(List<Map<String, dynamic>> messages) => messages
      .map((message) => message['content']?.toString() ?? '')
      .join('\n');

  testWidgets('群固定共同设定在普通与空闲回复里各只注入一次', (tester) async {
    addTearDown(() => disposeRoom(tester));
    final member = character();
    await seedCharacter(tester, member);
    await tester.runAsync(() async {
      await db.chatGroupBox.put(
        'group-shared',
        ChatGroup(
          id: 'group-shared',
          name: '共同设定群',
          theme: '日常聊天',
          description: '共同背景_甲是乙的姐姐',
          announcement: '群约定_工作日晚上聊轻松话题',
          aiCharacterIds: [member.id],
        ),
      );
    });
    await pumpRoom(tester, 'group-shared');
    final dynamic pageState = tester.state(find.byType(ChatRoomPage));

    final prompt = allMessages(await pageState.buildPromptMessages(
      character: member,
      context: const <Message>[],
      userMessage: '你好',
      intent: const ReplyIntent(
        speakerId: 'char-1',
        action: ReplyAction.answer,
        targetId: 'user',
        lengthHint: ReplyLengthHint.short,
        toneHint: '自然',
        reason: 'shared-context-test',
      ),
    ));
    // 每份文本与区块头都只出现一次：区块集中，不在人格成长规则里重复。
    expect(prompt.split(GroupSharedContext.marker).length - 1, 1);
    expect(prompt.split('共同背景_甲是乙的姐姐').length - 1, 1);
    expect(prompt.split('群约定_工作日晚上聊轻松话题').length - 1, 1);
    expect(prompt, isNot(contains('群说明')));
    expect(prompt.split(member.rolePlaySystemPrompt).length - 1, 1);

    final autoPrompt = allMessages(await pageState.buildPromptMessages(
      character: member,
      context: const <Message>[],
      isAutoChat: true,
    ));
    expect(autoPrompt.split(GroupSharedContext.marker).length - 1, 1);
    expect(autoPrompt.split('共同背景_甲是乙的姐姐').length - 1, 1);
    expect(autoPrompt.split('群约定_工作日晚上聊轻松话题').length - 1, 1);
  });

  testWidgets('A 群设定不进私聊，清空字段后也不再残留', (tester) async {
    addTearDown(() => disposeRoom(tester));
    final member = character();
    await seedCharacter(tester, member);
    await tester.runAsync(() async {
      await db.chatGroupBox.put(
        'group-shared-source',
        ChatGroup(
          id: 'group-shared-source',
          name: '来源群',
          theme: '日常聊天',
          description: '来源群背景_不得外泄',
          announcement: '来源群约定_不得外泄',
          aiCharacterIds: [member.id],
        ),
      );
    });

    // 私聊：本群设定不进私聊，共享区块整块不出现。
    await pumpRoom(tester, 'dm:${member.id}');
    final dynamic directState = tester.state(find.byType(ChatRoomPage));
    final directPrompt = allMessages(await directState.buildPromptMessages(
      character: member,
      context: const <Message>[],
      userMessage: '你好',
    ));
    expect(directPrompt, isNot(contains(GroupSharedContext.marker)));
    expect(directPrompt, isNot(contains('来源群背景_不得外泄')));

    // 另一个群同样看不到来源群的设定。
    await tester.runAsync(() async {
      await db.chatGroupBox.put(
        'group-other',
        ChatGroup(
          id: 'group-other',
          name: '另一个群',
          theme: '日常聊天',
          aiCharacterIds: [member.id],
        ),
      );
    });
    await pumpRoom(tester, 'group-other');
    final dynamic otherState = tester.state(find.byType(ChatRoomPage));
    final otherPrompt = allMessages(await otherState.buildPromptMessages(
      character: member,
      context: const <Message>[],
      userMessage: '你好',
    ));
    expect(otherPrompt, isNot(contains(GroupSharedContext.marker)));
    expect(otherPrompt, isNot(contains('来源群背景_不得外泄')));

    // 清空字段后重新进入：请求里不再残留旧设定。
    await tester.runAsync(() async {
      final stored = db.chatGroupBox.get('group-shared-source')!;
      stored.description = '';
      stored.announcement = '';
      await stored.save();
    });
    await pumpRoom(tester, 'group-shared-source');
    final dynamic clearedState = tester.state(find.byType(ChatRoomPage));
    final clearedPrompt = allMessages(await clearedState.buildPromptMessages(
      character: member,
      context: const <Message>[],
      userMessage: '你好',
    ));
    expect(clearedPrompt, isNot(contains(GroupSharedContext.marker)));
    expect(clearedPrompt, isNot(contains('来源群背景_不得外泄')));
  });

  testWidgets('构建器交出本轮真人输入的形态，供必需内容守卫保护', (tester) async {
    addTearDown(() => disposeRoom(tester));
    final member = character();
    await seedCharacter(tester, member);
    await tester.runAsync(() async {
      await db.chatGroupBox.put(
        'group-human-turn',
        ChatGroup(
          id: 'group-human-turn',
          name: '多人接话群',
          theme: '日常聊天',
          aiCharacterIds: [member.id],
        ),
      );
    });
    await pumpRoom(tester, 'group-human-turn');
    final dynamic pageState = tester.state(find.byType(ChatRoomPage));

    // 第二位角色发言前的真实排列：真人这一轮的要求后面跟着上一位 AI 的发言。
    final human = Message(
      id: 'm-human',
      groupId: 'group-human-turn',
      senderId: 'user',
      senderType: Message.senderTypeUser,
      content: '本轮真人要求_今晚只讨论家人',
      timestamp: DateTime(2026, 1, 1, 10),
      visibleToCharacterIds: [member.id],
    );
    final peer = Message(
      id: 'm-peer',
      groupId: 'group-human-turn',
      senderId: 'char-2',
      senderType: Message.senderTypeAi,
      content: '今天我们聊聊旅行吧',
      timestamp: DateTime(2026, 1, 1, 10, 1),
      visibleToCharacterIds: [member.id],
    );

    Object? captured;
    final messages = await pageState.buildPromptMessages(
      character: member,
      context: [human, peer],
      userMessage: human.content,
      currentUserMessage: human,
      onCurrentUserTurn: (rendered) => captured = rendered,
    );

    expect(
      captured,
      human.content,
      reason: '构建器必须交出真人那一条，而不是末尾的 AI 发言',
    );
    expect(messages.last['content'], isNot(human.content));

    final guard = ChatReplyPromptGuard.collect(
      messages,
      sharedContext: '',
      personaPrompt: member.rolePlaySystemPrompt,
      currentUserTurn: captured,
    );
    // 把真人那条从请求里拿掉之后必须判为不可发送，哪怕末尾那条 AI 发言还在。
    final withoutHuman = messages
        .where((message) => message['content'] != human.content)
        .toList(growable: false);
    expect(guard.missingFrom(withoutHuman), '本轮真人输入');
  });
}
