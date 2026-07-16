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
}
