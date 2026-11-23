import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_message_selection_fixture.dart';
import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 真后台必须断开在飞回复，窗口遮挡不算离开。
///
/// 这两条判据分别对应两个不同的入口，混成一个就会出错：
/// - `hidden`（桌面端窗口被遮挡/最小化）按 2026-11-17 的决定继续生成；
/// - `paused`（移动端真后台）必须立刻停，否则等于在没有通知设计的情况下
///   后台跑模型（CLAUDE.md 红线）。
///
/// 回归点在于触发时机：Android 退到后台的序列是 `inactive → hidden → paused`。
/// `hidden` 已经把"可见性合流值"压成 false，`paused` 到来时闸门判定"没有变化"
/// 就直接返回，取消与停调度都不会执行——真后台取消**永远**轮不到。
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

  testWidgets('hidden 之后再 paused 必须断开在飞回复', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    const groupId = 'g-true-background';
    await seedRoundRoom(tester, db, groupId);
    await seedRoomMessages(tester, db, groupId, const ['在吗']);
    final api = ScriptedChatApi()..pickerResponse = '{"speakerId":"va"}';
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: groupId,
      api: api,
      db: db,
      directory: directory,
    );
    await restartAutoChatScheduler(tester);
    api.holdReplies = true;

    // 推进假时钟直到自动聊天真的发出一轮回复并吐出第一段。
    for (var step = 0; step < 80 && !api.replyStreaming; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(seconds: 2));
    }
    expect(api.replyStreaming, isTrue, reason: '自动聊天没有发出回复');
    final token = api.replyCancelToken;
    expect(token, isNotNull, reason: '回复请求没有带取消令牌');

    // 窗口被遮挡：用户还在看群（2026-11-17 决定），不该打断。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(token!.isCancelled, isFalse,
        reason: '窗口遮挡不应取消已发出的回复');

    // 真后台：必须真的 abort 传输层。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(token.isCancelled, isTrue,
        reason: '真后台没有取消在飞回复：闸门因 hidden 已把合流值压成 false 而早返回');

    api.releaseHeldReply();
    await settleRoundTimers(tester);
  });
}
