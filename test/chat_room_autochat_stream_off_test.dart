import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 自动回复已经开始流式输出时关掉自动发言：这一条不许落库。
///
/// 关掉开关推进的是空闲自动发言自己的代际号，于是飞行中的这一轮从此刻起作废；
/// 同时停掉正在输出的流，用户不会看到"关了开关还在说话、说完又消失"。两者缺一：
/// 前者决定结果要不要提交，后者决定这一轮要不要立刻收手。
void main() {
  late Directory directory;
  late DatabaseService db;

  setUpAll(() async {
    installTtsChannelMock();
    directory = await openLifecycleHive();
    db = DatabaseService();
    await openGovernanceLedgerBox();
  });

  tearDownAll(() => tearDownRoundFixture(directory));

  testWidgets('流式输出进行中关掉自动发言，这条回复不再落库', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-autochat-stream-off');
    final api = ScriptedChatApi()
      ..pickerResponse = '{"speakerId":"va"}'
      ..holdReplies = true;
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-autochat-stream-off',
      api: api,
      db: db,
      directory: directory,
    );
    await restartAutoChatScheduler(tester);
    for (var step = 0; step < 60 && !api.replyStreaming; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(seconds: 2));
    }
    expect(api.replyStreaming, isTrue, reason: '回合没有真的开始流式输出');

    await toggleAutoChatOff(tester);
    api.releaseHeldReply();
    await drainRound(tester, rounds: 30);

    final persistedReplies = db.messageBox.values
        .where((message) => message.groupId == 'g-autochat-stream-off')
        .where((message) => message.senderType == 'ai')
        .toList();
    expect(
      persistedReplies,
      isEmpty,
      reason: '关掉自动发言后，已经开始的流式回复仍然落库了',
    );
    await settleRoundTimers(tester);
  });
}
