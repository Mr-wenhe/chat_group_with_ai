import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 选择器自己的凭据还在等待时离开本群再回来：这一步必须作废。
///
/// 与外层丢掉迟到结果不同，这里要挡的是**请求本身**：离开再回来之后"用户是否在
/// 看这个群"已经恢复为真，只有回合代际号还记得中途离开过，因此判据必须能在
/// 选择器真正发请求之前读到它。
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

  testWidgets('选择器凭据等待期间离开再回来，不应发起旧选择请求', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-picker-cred-return');
    final api = ScriptedChatApi()..pickerResponse = '{"speakerId":"va"}';
    final resolver = HeldCredentialResolver(heldConfigId: 'cfg-picker');
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-picker-cred-return',
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

    hostKey.currentState!.pushCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    hostKey.currentState!.popCover();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    resolver.release();
    await drainRound(tester, rounds: 30);

    final stalePickerCount = api.pickerCalls.length;
    expect(stalePickerCount, 0, reason: '回到本群后旧选择器请求仍然发出');

    hostKey.currentState!.pushCover();
    await tester.pump();
    await settleRoundTimers(tester);
  });
}
