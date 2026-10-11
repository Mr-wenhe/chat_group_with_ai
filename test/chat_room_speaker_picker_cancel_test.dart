import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 选人还在等待时离开本群再回来：迟到的结果不得被采纳。
///
/// 离开会取消正在飞的选择请求；回到本群后"用户是否在看这个群"又变成真，
/// 只有取消状态还记着这次结果已经不属于当前这一轮。
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

  testWidgets('选人等待期间离开本群再回来，不采纳已被取消的旧回合', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-return');
    final api = ScriptedChatApi();
    final pending = api.holdNextPicker();
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-return',
      api: api,
      db: db,
      directory: directory,
    );
    await restartAutoChatScheduler(tester);
    await waitForPicker(tester, api);

    hostKey.currentState!.pushCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(api.pickerCancelToken?.isCancelled, isTrue);
    hostKey.currentState!.popCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    pending.complete({'success': true, 'message': '{"speakerId":"va"}'});
    await drainRound(tester, rounds: 30);

    expect(
      api.replyCalls,
      isEmpty,
      reason: '回到本群后仍然采纳被取消的旧选择结果',
    );

    // 收尾前再离开一次：回到本群时调度器已经重启，会在推进假时间的过程中不停
    // 开新回合，最后那一个正好停在选人请求自己的 15 秒时限上。
    hostKey.currentState!.pushCover();
    await tester.pump();
    await settleRoundTimers(tester);
  });
}
