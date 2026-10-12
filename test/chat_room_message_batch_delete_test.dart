import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_message_selection_fixture.dart';
import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 批量删除：长按进入多选、勾选、确认，落库只删勾中的那几条。
///
/// 只放一条用例：它真的触发了一次删除，见 `chat_room_message_selection_fixture.dart`
/// 顶部关于假区 Hive 写的说明。
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

  testWidgets('长按进入多选后只删除被勾选的消息', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    addTearDown(AppToast.dismiss);
    const groupId = 'g-batch-delete';
    await seedRoundRoom(tester, db, groupId);
    await seedRoomMessages(tester, db, groupId, const ['勾选一', '勾选二', '别删我']);

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

    await enterSelectionFromLongPress(tester, find.text('勾选一'));
    // 长按的那条进来就预选：用户的动作本身已经表明他瞄的是这一条。
    expect(find.text('已选 1 条'), findsOneWidget);

    await tester.tap(selectionCheckboxFor('勾选二'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除 2 条消息？'), findsOneWidget);
    await tapDialogButton(tester, '删除');

    await pumpUntilDone(
      tester,
      () => find.textContaining('已选').evaluate().isEmpty,
      reason: '删除完成后必须退出多选，否则顶部栏会停在一个已经没有意义的模式上',
    );

    await tester.runAsync(() async {
      expect(db.messageBox.get('勾选一'), isNull);
      expect(db.messageBox.get('勾选二'), isNull);
      expect(db.messageBox.get('别删我'), isNotNull);
    });
    expect(find.text('勾选一'), findsNothing);
    expect(find.text('别删我'), findsOneWidget);

    await settleRoundTimers(tester);
  });
}
