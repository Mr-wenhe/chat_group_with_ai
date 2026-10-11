import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 被全屏页面盖住期间，排队中的用户输入必须留着，回到本群才处理。
///
/// 取走了却不回复，用户看到的就是"消息发出去了，却一直没有回应"；而返回页面
/// 的恢复逻辑再也找不回已经被消费的那一项。
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

  testWidgets('被全屏页面盖住期间不消费排队用户输入，回来后再回复', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-queue');
    final api = ScriptedChatApi()..pickerResponse = '{"speakerId":"va"}';
    final pending = api.holdNextPicker();
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-queue',
      api: api,
      db: db,
      directory: directory,
    );
    await restartAutoChatScheduler(tester);
    await waitForPicker(tester, api);

    // 关掉自动发言，让队列里的普通聊天成为唯一待处理的请求。
    await toggleAutoChatOff(tester);
    await tester.enterText(find.byType(TextField), '我想聊聊今晚吃什么');
    final composer =
        tester.widget<ChatRoomComposer>(find.byType(ChatRoomComposer));
    await tester.runAsync(() async {
      composer.onSend();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });

    hostKey.currentState!.pushCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    pending.complete({'success': true, 'message': '{"speakerId":null}'});
    await drainRound(tester, rounds: 60);
    expect(api.replyCalls, isEmpty, reason: '被盖住时不该在后台发起角色请求');

    hostKey.currentState!.popCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await waitForReply(tester, api);
    expect(
      api.replyCalls,
      isNotEmpty,
      reason: '被遮挡时排队输入被取走，回到群聊后不再回复',
    );

    // 本轮会产生真实回复，每条后面跟着一段"打字延迟"；收尾前把计时器走完。
    await settleRoundTimers(tester);
  });
}
