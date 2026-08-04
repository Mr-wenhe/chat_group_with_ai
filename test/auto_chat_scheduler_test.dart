import 'dart:async';

import 'package:chat_group/features/chat_group/auto_chat_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scheduler does not overlap rounds and stops after dispose', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    final scheduler = AutoChatScheduler(
      nextInterval: () => const Duration(milliseconds: 1),
      runRound: () async {
        calls++;
        if (!started.isCompleted) started.complete();
        await release.future;
      },
    );

    scheduler.start(initialDelay: Duration.zero);
    await started.future;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(calls, 1);

    release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(calls, greaterThan(1));
    scheduler.dispose();
    final stoppedAt = calls;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(calls, stoppedAt);
  });

  test('cooldown pauses rounds then resumes scheduling', () async {
    var calls = 0;
    final scheduler = AutoChatScheduler(
      nextInterval: () => const Duration(milliseconds: 1),
      runRound: () async => calls++,
    );
    scheduler.start(initialDelay: Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    scheduler.coolDown(const Duration(milliseconds: 5));
    final beforeCooldown = calls;
    await Future<void>.delayed(const Duration(milliseconds: 3));
    expect(calls, beforeCooldown);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(calls, greaterThan(beforeCooldown));
    scheduler.dispose();
  });

  test('coolDown during a round does not get overwritten by nextInterval',
      () async {
    var calls = 0;
    late AutoChatScheduler scheduler;
    scheduler = AutoChatScheduler(
      nextInterval: () => const Duration(milliseconds: 1),
      runRound: () async {
        calls++;
        if (calls == 1) {
          // 第一轮期间触发冷却，覆盖默认的 nextInterval
          scheduler.coolDown(const Duration(milliseconds: 30));
        }
      },
    );
    scheduler.start(initialDelay: Duration.zero);

    // 等待第一轮完成并进入冷却
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final atCooldown = calls;
    // 冷却期间不应有新轮次
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, atCooldown);
    // 冷却结束后应恢复调度
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(calls, greaterThan(atCooldown));
    scheduler.dispose();
  });
}
