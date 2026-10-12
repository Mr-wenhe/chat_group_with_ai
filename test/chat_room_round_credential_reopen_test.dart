import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 选人已经完成、角色凭据还在等待时关掉自动发言**又打开**：旧回合必须仍是作废的。
///
/// 关掉开关只推进了"空闲自动发言"自己的代际号，重新打开只会启动携带新代际号的
/// 新回合。只看开关的当前布尔值是挡不住这一条的：重新打开之后它已经恢复为真，
/// 停在凭据解析上的旧回合会重新被判为有效，于是取消过的角色请求照常发出去。
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

  testWidgets('角色凭据等待期间关闭又重开自动发言，旧回合仍应作废', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-cred-reopen');
    final api = ScriptedChatApi()..pickerResponse = '{"speakerId":"va"}';
    final resolver = HeldCredentialResolver(heldConfigId: 'cfg-a');
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-cred-reopen',
      api: api,
      db: db,
      directory: directory,
      credentialResolver: resolver,
    );
    await restartAutoChatScheduler(tester);
    await waitForPicker(tester, api);
    // 选人已经定下了 'va'，这一轮此刻停在角色凭据解析上。
    await waitForHeldCredential(tester, resolver);

    await toggleAutoChatOff(tester);
    await tester.tap(find.byKey(const Key('auto-chat-toggle')));
    await tester.pump();
    resolver.release();
    await drainRound(tester, rounds: 30);

    final staleReplyCount = api.replyCalls.length;
    expect(staleReplyCount, 0, reason: '关闭后重开复活了旧自动轮次');

    // 收尾前再离开一次：回到本群时调度器已经重启，会在推进假时间的过程中开新回合，
    // 最后那一个正好停在选人请求自己的 15 秒时限上。
    hostKey.currentState!.pushCover();
    await tester.pump();
    await settleRoundTimers(tester);
  });
}
