import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_message_selection_fixture.dart';
import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 从右上角「更多」菜单进入多选：全选只覆盖当前已加载的消息，取消能退回正常会话。
///
/// 这条用例不改动任何消息，仍然单独占一个文件——同文件里只要有一条真删过
/// Hive 记录的用例，它后面那条就会卡住（见 fixture 顶部说明）。
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

  testWidgets('更多菜单的批量删除入口支持全选与取消', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    addTearDown(AppToast.dismiss);
    const groupId = 'g-batch-select-all';
    await seedRoundRoom(tester, db, groupId);
    await seedRoomMessages(tester, db, groupId, const ['全选一', '全选二', '全选三']);

    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: groupId,
      api: ScriptedChatApi(),
      db: db,
      directory: directory,
    );
    await restartAutoChatScheduler(tester);
    await toggleAutoChatOff(tester);

    await openRoomMoreMenu(tester);
    await tester.tap(find.text('批量删除'));
    await tester.pumpAndSettle();

    expect(find.text('已选 0 条'), findsOneWidget);

    // 点气泡正文即勾选：多选时正文已交出选择手势，点击整行都能切换勾选。
    await tester.tap(find.text('全选二'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3 条'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('全选'), findsNothing);
    expect(find.text('已选 3 条'), findsNothing);

    await settleRoundTimers(tester);
  });
}
