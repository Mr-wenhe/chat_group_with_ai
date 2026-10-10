import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 选人被治理网关硬拒绝（超预算 / 权限）时，这一轮必须结束。
///
/// 把硬拒绝和其他失败一并当成"选人器不可用"，会退回到本地编排器，在同一个
/// 预算下再发一次请求——已经明确发生的拒绝就这样被丢掉了。
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

  testWidgets('选人被硬预算阻止后不降级成本地选人', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    // 价格未知的模型不会被预算预检拦下，因此"是否兜底"只能看请求次数。
    await seedRoundRoom(
      tester,
      db,
      'g-budget',
      characterModel: 'deepseek-v4-flash',
    );
    await tester.runAsync(() async {
      await db.apiConfigBox.put('cfg-picker', roundTestConfig('cfg-picker'));
      await AiGovernanceStore.forDatabase(db).saveBudgetSettings(
        const BudgetSettings(dailyHardLimitMicros: 1, summaryEnabled: false),
      );
    });

    final api = ScriptedChatApi();
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-budget',
      api: api,
      db: db,
      directory: directory,
    );
    await restartAutoChatScheduler(tester);

    for (var step = 0; step < 40; step++) {
      final blocked = AiGovernanceStore.forDatabase(db)
          .diagnostics
          .any((item) => item.status == 'blocked');
      if (blocked) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(seconds: 2));
    }
    await drainRound(tester, rounds: 20);

    final blocked = AiGovernanceStore.forDatabase(db)
        .diagnostics
        .where((item) => item.status == 'blocked')
        .toList();
    // 只断言"有请求被拦下"是不够的：角色发言的网关调用同样会记一条 blocked，
    // 那样这条用例可能是空转的。选人器用的是 cfg-picker（deepseek-chat），
    // 角色用的是价格未知的 deepseek-v4-flash，用模型名把两者分开。
    expect(
      blocked.map((item) => item.model),
      contains('deepseek-chat'),
      reason: '必须是「选人器那次请求」被硬预算拦下，而不是角色发言',
    );
    expect(api.pickerCalls, isEmpty);
    expect(
      api.replyCalls,
      isEmpty,
      reason: '选择器被硬预算阻止后仍启动了未知价格角色请求',
    );
  });
}
