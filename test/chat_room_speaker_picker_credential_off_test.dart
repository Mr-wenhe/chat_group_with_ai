import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 选择器自己的凭据还在等待时关掉自动发言：这一步必须立刻收手。
///
/// 外层在选人返回之后才丢掉结果，拦不住**已经发出去**的那次选择请求——用户等的
/// 是同一份等待时间，账本里也照样多一次调用。有效性判据必须传进真正发请求的
/// 那一步，并在凭据解析之后、发送之前复检。
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

  testWidgets('选择器凭据等待期间关闭自动发言，不应再发选择器请求', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-picker-cred-off');
    final api = ScriptedChatApi()..pickerResponse = '{"speakerId":"va"}';
    final resolver = HeldCredentialResolver(heldConfigId: 'cfg-picker');
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-picker-cred-off',
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

    await toggleAutoChatOff(tester);
    resolver.release();
    await drainRound(tester, rounds: 30);

    final stalePickerCount = api.pickerCalls.length;
    expect(stalePickerCount, 0, reason: '关闭自动发言后旧选择器请求仍然发出');

    hostKey.currentState!.pushCover();
    await tester.pump();
    await settleRoundTimers(tester);
  });
}
