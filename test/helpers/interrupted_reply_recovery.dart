import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/features/chat_group/chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_composer.dart';
import 'package:chat_group/features/chat_group/pending_chat_reply_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_room_round_fixture.dart';
import 'lifecycle_hive.dart';

void interruptedReplyRecoveryTests({required bool isDirectChat}) {
  final conversationId = isDirectChat ? 'dm:va' : 'g-recovery';
  late Directory directory;
  late DatabaseService db;
  setUpAll(() async {
    installTtsChannelMock();
    directory = await openLifecycleHive();
    db = DatabaseService();
    await openGovernanceLedgerBox();
  });
  tearDownAll(() => tearDownRoundFixture(directory));

  testWidgets('${isDirectChat ? '私聊' : '群聊'}切页中断后返回自动回复，销毁重进也恢复，手动停止不恢复',
      (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await tester.runAsync(() async {
      await db.apiConfigBox.put('cfg-a', roundTestConfig('cfg-a'));
      await db.aiCharacterBox
          .put('va', testCharacter('va', apiConfigId: 'cfg-a'));
      await db.appSettingsBox
          .put('ai_governance_budget_v1', const {'autoChatEnabled': false});
    });
    if (!isDirectChat) {
      await tester.runAsync(() async {
        await db.chatGroupBox.put(
            conversationId,
            ChatGroup(
                id: conversationId,
                name: '恢复测试群',
                theme: '聊天',
                aiCharacterIds: ['va']));
        // Keep this recovery test out of the unrelated summary API path.
        await db.groupMemoryBox.put(
            '${conversationId}_${ChatOrchestrator.memoryPeriodKey(DateTime.now())}',
            GroupMemory(groupId: conversationId, topicSummary: '已有群摘要'));
      });
    }
    final api = ScriptedChatApi()
      ..holdReplies = true
      ..pickerResponse = '{"speakerId":"va"}';
    var hostKey = GlobalKey<RoundRoomHostState>();
    Future<void> openRoom() => pumpRoundRoom(tester,
        hostKey: hostKey,
        groupId: conversationId,
        api: api,
        db: db,
        directory: directory);
    Future<void> send(String text) async {
      api.replyStreaming = false;
      await tester.enterText(find.byType(TextField), text);
      final composer =
          tester.widget<ChatRoomComposer>(find.byType(ChatRoomComposer));
      await tester.runAsync(() async {
        composer.onSend();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      for (var step = 0; step < 80 && !api.replyStreaming; step++) {
        await drainRound(tester, rounds: 1);
      }
      expect(api.replyStreaming, isTrue);
    }

    Future<void> expectReplies(int count) async {
      for (var step = 0; step < 100; step++) {
        final replies = db.messageBox.values
            .where((m) => m.groupId == conversationId && m.senderType == 'ai');
        if (replies.length == count) return;
        await drainRound(tester, rounds: 1);
      }
      expect(
          db.messageBox.values.where(
              (m) => m.groupId == conversationId && m.senderType == 'ai'),
          hasLength(count));
    }

    await openRoom();
    await send('你认识张若晴吗');
    hostKey.currentState!.pushCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    api.holdReplies = false;
    api.releaseHeldReply();
    await drainRound(tester);
    expect(api.replyCalls, hasLength(1), reason: '页面不可见时不得自动重试');
    hostKey.currentState!.popCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await expectReplies(1);
    expect(api.replyCalls, hasLength(2), reason: '无需追发消息即可恢复');
    await settleRoundTimers(tester);

    api.holdReplies = true;
    await send('第二个问题');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    api.holdReplies = false;
    api.releaseHeldReply();
    await drainRound(tester);
    hostKey = GlobalKey<RoundRoomHostState>();
    await openRoom();
    await expectReplies(2);
    expect(api.replyCalls, hasLength(4));
    await settleRoundTimers(tester);

    api.holdReplies = true;
    await send('这个问题我手动停止');
    tester
        .widget<ChatRoomComposer>(find.byType(ChatRoomComposer))
        .onStopStreaming();
    api.holdReplies = false;
    api.releaseHeldReply();
    await drainRound(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    hostKey = GlobalKey<RoundRoomHostState>();
    await openRoom();
    await settleRoundTimers(tester);
    expect(api.replyCalls, hasLength(5), reason: '手动停止不能被重新进入撤销');
    await expectReplies(2);

    api.holdReplies = true;
    await send('先回复这个问题');
    await tester.enterText(find.byType(TextField), '这是排队的下一个问题');
    await tester.runAsync(() async {
      tester.widget<ChatRoomComposer>(find.byType(ChatRoomComposer)).onSend();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    hostKey.currentState!.pushCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    api.holdReplies = false;
    api.releaseHeldReply();
    await drainRound(tester);
    hostKey.currentState!.popCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await settleRoundTimers(tester);
    for (var step = 0; step < 100; step++) {
      if (PendingChatReplyStore(db.appSettingsBox, conversationId)
          .messageIds
          .isEmpty) {
        break;
      }
      await drainRound(tester, rounds: 1);
    }
    expect(api.replyCalls.length, 8,
        reason:
            '先恢复中断消息，再处理排队消息，各一次；输入序列：${api.replyCalls.map((call) => call.lastWhere((m) => m['role'] == 'user')['content']).toList()}；待办：${PendingChatReplyStore(db.appSettingsBox, conversationId).messageIds}');
    expect(PendingChatReplyStore(db.appSettingsBox, conversationId).messageIds,
        isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
