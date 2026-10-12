import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 选择器自己的凭据还在等待时切到工作模式：这一步必须立刻收手。
///
/// 工作模式让空闲自动发言整体停摆，与用户关掉开关是同一件事，因此推进的是空闲
/// 自动发言自己的代际号。只置位"工作模式开着"的标记是不够的：那个标记既管不到
/// 选择器这一步（它不属于任何一位角色的回复），也没法表达"这一轮已经被取消过"。
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

  testWidgets('选择器凭据等待期间切到工作模式，不应再发选择器请求', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-picker-cred-workmode');
    final api = ScriptedChatApi()..pickerResponse = '{"speakerId":"va"}';
    final resolver = HeldCredentialResolver(heldConfigId: 'cfg-picker');
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-picker-cred-workmode',
      api: api,
      db: db,
      directory: directory,
      credentialResolver: resolver,
    );
    await restartAutoChatScheduler(tester);
    for (var step = 0; step < 80 && !resolver.reached; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(resolver.reached, isTrue, reason: '回合没有走到选择器凭据解析那一步');
    expect(api.pickerCalls, isEmpty);

    await tester.tap(find.byKey(const Key('work-mode-toggle')));
    await tester.pump();
    await drainRound(tester, rounds: 10);
    resolver.release();
    await drainRound(tester, rounds: 30);

    expect(
      api.pickerCalls,
      isEmpty,
      reason: '切到工作模式后，等在半路上的旧选择器请求仍然发出',
    );
    await settleRoundTimers(tester);
  });
}
