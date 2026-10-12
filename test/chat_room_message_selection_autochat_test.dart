import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_message_selection_fixture.dart';
import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 多选是模态的：勾选期间不冒出新气泡，系统返回键先退多选。
///
/// 两条都是同一个理由——删除不可撤销，用户瞄的那个位置必须一直是同一条消息。
/// 所以进入多选就停掉空闲自动聊天（它开口一次，整列就被顶动一次），返回键也
/// 只退多选而不是把整个会话页 pop 掉。
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

  testWidgets('多选期间空闲自动聊天不开口，返回键先退多选，退出后恢复调度',
      (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    const groupId = 'g-selection-autochat';
    await seedRoundRoom(tester, db, groupId);
    await seedRoomMessages(tester, db, groupId, const ['待删一', '待删二']);
    final api = ScriptedChatApi()..pickerResponse = '{"speakerId":"va"}';
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: groupId,
      api: api,
      db: db,
      directory: directory,
    );
    // 空闲自动聊天在假时钟上重新排队（首次加载那次的计时器落在真实时钟上）。
    await restartAutoChatScheduler(tester);

    // 进入多选前已经开口的轮次不算：这里只关心勾选期间有没有**新的**轮次。
    final roundsBeforeSelection = api.pickerCalls.length;

    await openRoomMoreMenu(tester);
    await tester.tap(find.text('批量删除'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 条'), findsOneWidget);

    // 推进远超自动聊天间隔（群间隔夹在 5~60 秒，初始延迟再加 0~9 秒抖动）：
    // 勾选期间一次都不该开口。
    for (var step = 0; step < 20; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(seconds: 5));
    }
    expect(
      api.pickerCalls.length,
      roundsBeforeSelection,
      reason: '多选期间仍有空闲自动聊天在选人，新气泡会顶动整列',
    );

    // 系统返回键：先退多选，房间还在。判据落在"多选栏消失"上——没有这条守卫时
    // 根路由收到返回只会 bubble，多选栏会一直留着。
    await Navigator.of(tester.element(find.byType(ChatRoomPage))).maybePop();
    await tester.pumpAndSettle();
    expect(find.text('全选'), findsNothing, reason: '返回键没有退出多选');
    expect(find.byType(ChatRoomPage), findsOneWidget, reason: '返回键关掉了会话页');

    // 退出多选 → 调度恢复（否则"不冒泡"会退化成永久静音）。
    for (var step = 0; step < 60 && api.pickerCalls.isEmpty; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(seconds: 2));
    }
    expect(api.pickerCalls, isNotEmpty, reason: '退出多选后空闲自动聊天没有恢复');

    await settleRoundTimers(tester);
  });
}
