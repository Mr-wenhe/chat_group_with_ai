import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_message_selection_fixture.dart';
import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 多选里工作模式的进度气泡勾不上：它由任务生命周期持续改写，删掉会让任务面板
/// 失去落点。判据与单条删除共用，这里从界面侧钉住它。
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

  testWidgets('多选里工作模式进度气泡勾不上', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    addTearDown(AppToast.dismiss);
    const groupId = 'g-batch-progress';
    const progressId = '${WorkModeTaskLifecycle.progressMessageIdPrefix}task-1';
    await seedRoundRoom(tester, db, groupId);
    await seedRoomMessages(tester, db, groupId, const ['能选-1', '能选-2', progressId]);

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

    // 进度气泡仍渲染勾选框位（否则整行位移会跳），但按规则勾不上。
    await tester.tap(selectionCheckboxFor(progressId));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 条'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(
      find.text('已选 2 条'),
      findsOneWidget,
      reason: '全选也不能把进度气泡算进去，它由任务生命周期持续改写',
    );

    await settleRoundTimers(tester);
  });
}
