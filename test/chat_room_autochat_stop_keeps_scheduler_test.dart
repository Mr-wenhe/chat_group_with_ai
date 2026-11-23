// 「停止一条自动消息不会关掉空闲自动聊天」的回归用例。
//
// 一个文件只放一条会真正跑起回合的 widget 用例：回合里的用量记账会在假时钟区
// 发起 Hive 写，同一进程里再跑第二条会让 box 的写队列卡住（仓库已知行为）。
//
// 用群聊夹具而不是私聊：`_stopStreaming` 对「自动回合」的处理是同一段代码，而
// 私聊没有自动聊天开关、固定 45 秒间隔，并发批跑时等不到第一轮就会超时。群聊
// 可以把间隔压到 5 秒，稳定驱动到"正在流式输出"，断言仍是同一个用户可见结果：
// 停止之后必须有下一轮自动聊天。
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

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

  /// 交替推进假时钟并放行真实 I/O（回合里的 Hive 写只有真实事件循环能完成）。
  Future<void> advance(WidgetTester tester, Duration total) async {
    var elapsed = Duration.zero;
    while (elapsed < total) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(seconds: 2));
      elapsed += const Duration(seconds: 2);
    }
  }

  testWidgets('停止一条自动消息后，空闲自动聊天仍按间隔发起', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await seedRoundRoom(tester, db, 'g-autochat-stop', intervalSeconds: 5);

    final api = ScriptedChatApi()
      ..holdReplies = true
      ..pickerResponse = '{"speakerId":"va"}';
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-autochat-stop',
      api: api,
      db: db,
      directory: directory,
    );

    // 首次加载创建的启动计时器可能落在真实时钟上；关掉再打开自动聊天，让调度器
    // 在假时钟区重新开始（见夹具里的说明）。
    await restartAutoChatScheduler(tester);

    /// 先推进假时钟让调度器真的触发，再用真实时间轮询后续的异步工作。
    ///
    /// 回合启动（凭据、提示词、Hive 写入）是真实异步，并发跑整批时会被拉长；
    /// 固定轮数的假时间推进在重负载下不够，这里把"调度触发"和"异步落地"分开等。
    Future<bool> waitFor(bool Function() ready, {int seconds = 12}) async {
      for (var step = 0; step < seconds * 20; step++) {
        if (ready()) return true;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      return ready();
    }

    await advance(tester, const Duration(seconds: 20));
    expect(await waitFor(() => api.pickerCalls.isNotEmpty), isTrue,
        reason: '调度器应当发起第一轮选人');
    expect(await waitFor(() => api.replyStreaming), isTrue,
        reason: '第一轮自动聊天应当进入流式输出');
    final pickersBeforeStop = api.pickerCalls.length;

    // 停掉这一条自动消息（不是关掉自动聊天）。
    tester
        .widget<ChatRoomComposer>(find.byType(ChatRoomComposer))
        .onStopStreaming();
    api.holdReplies = false;
    api.releaseHeldReply();
    await drainRound(tester);

    // 调度器若被整体停掉，这段时间内不会再发起选人。
    await advance(tester, const Duration(seconds: 20));
    expect(
        await waitFor(() => api.pickerCalls.length > pickersBeforeStop), isTrue,
        reason: '停止自动消息不得关掉调度器，之后必须继续发起自动聊天');

    // 回合里的「打字延迟」、调度计时器与被停掉的流都还挂着：用例体结束前按假时间
    // 走完，并显式销毁页面（flutter_test 在用例体结束时就会检查挂起计时器，早于
    // tearDown，所以这里必须自己清理）。
    await settleRoundTimers(tester);
    await disposeRoundRoom(tester);
    // 销毁过程中可能还有一次「打字延迟」被安排出去（Future.delayed 无法 dispose），
    // 再走一轮假时间把它们放掉。
    await settleRoundTimers(tester);
  });
}
