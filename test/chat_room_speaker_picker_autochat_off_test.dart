import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 选人还在等待时关掉空闲自动发言：这一轮必须立刻失效。
///
/// 关掉开关只停掉了调度器，没有让"正在等选人的这一轮"失效；迟到的选择结果
/// 若仍被采纳，就会在用户已经关掉自动发言之后继续发言、继续消耗 API。
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

  testWidgets('选人等待期间关闭自动发言，不再发起角色请求', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-off');
    final api = ScriptedChatApi();
    final pending = api.holdNextPicker();
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-off',
      api: api,
      db: db,
      directory: directory,
    );
    await restartAutoChatScheduler(tester);
    await waitForPicker(tester, api);

    await toggleAutoChatOff(tester);
    pending.complete({'success': true, 'message': '{"speakerId":"va"}'});
    await drainRound(tester, rounds: 30);

    expect(
      api.replyCalls,
      isEmpty,
      reason: '自动发言关闭后仍然启动了角色流式调用',
    );
  });
}
