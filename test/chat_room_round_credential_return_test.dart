import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 选人已经完成、角色凭据还在等待时离开本群再回来：这一轮必须作废。
///
/// 离开会取消正在飞的选择请求，但那时选择早已结束——这一轮停在角色凭据解析上，
/// 回来后"用户是否在看这个群"又变成真，只有回合代际号还记得中途离开过。
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

  testWidgets('角色凭据等待期间离开本群再回来，旧回合不再续跑', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-cred-return');
    final api = ScriptedChatApi()..pickerResponse = '{"speakerId":"va"}';
    final resolver = HeldCredentialResolver(heldConfigId: 'cfg-a');
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-cred-return',
      api: api,
      db: db,
      directory: directory,
      credentialResolver: resolver,
    );
    await restartAutoChatScheduler(tester);
    await waitForPicker(tester, api);
    await waitForHeldCredential(tester, resolver);

    hostKey.currentState!.pushCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    hostKey.currentState!.popCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    resolver.release();
    await drainRound(tester, rounds: 30);

    expect(
      api.replyCalls,
      isEmpty,
      reason: '回到本群后，离开前那一轮仍然发出了角色请求',
    );

    // 收尾前再离开一次：回到本群时调度器已经重启，会在推进假时间的过程中开新回合，
    // 最后那一个正好停在选人请求自己的 15 秒时限上。
    hostKey.currentState!.pushCover();
    await tester.pump();
    await settleRoundTimers(tester);
  });
}
