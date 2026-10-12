import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 选人已经完成、角色凭据还在等待时关掉空闲自动发言：这一轮必须立刻失效。
///
/// 关掉开关只停了调度器与调度计时器；正在跑的那一轮既不在流里，也没有选择器请求
/// 可取消——它停在凭据解析这个 await 上，只有"这一轮还算不算数"的复检能拦住它。
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

  testWidgets('角色凭据等待期间关闭自动发言，不再发起角色请求', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-cred-off');
    final api = ScriptedChatApi()..pickerResponse = '{"speakerId":"va"}';
    final resolver = HeldCredentialResolver(heldConfigId: 'cfg-a');
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-cred-off',
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
    resolver.release();
    await drainRound(tester, rounds: 30);

    expect(
      api.replyCalls,
      isEmpty,
      reason: '自动发言关闭后，等在半路上的角色请求仍然发出去了',
    );
    await settleRoundTimers(tester);
  });
}
