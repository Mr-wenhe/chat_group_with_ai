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

  testWidgets('normal reply completion clears the busy indicator',
      (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await tester.runAsync(() async {
      await db.apiConfigBox.put('cfg-a', roundTestConfig('cfg-a'));
      await db.appSettingsBox.put(
        'ai_governance_budget_v1',
        const {'autoChatEnabled': false},
      );
      await db.aiCharacterBox.put(
        'va',
        testCharacter('va', apiConfigId: 'cfg-a')..name = '状态角色',
      );
    });

    final api = ScriptedChatApi()..holdReplies = true;
    await pumpRoundRoom(
      tester,
      hostKey: GlobalKey<RoundRoomHostState>(),
      groupId: 'dm:va',
      api: api,
      db: db,
      directory: directory,
    );
    await tester.enterText(find.byType(TextField), '请回复');
    final composer =
        tester.widget<ChatRoomComposer>(find.byType(ChatRoomComposer));
    await tester.runAsync(() async {
      composer.onSend();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    await waitForReply(tester, api);
    for (var attempt = 0; attempt < 80 && !api.replyStreaming; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(api.replyStreaming, isTrue);
    expect(find.text('AI 正在生成...'), findsOneWidget);

    api.releaseHeldReply();
    for (var attempt = 0;
        attempt < 120 && find.text('测试回复').evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('测试回复'), findsOneWidget);
    for (var attempt = 0;
        attempt < 300 && find.text('AI 正在回复...').evaluate().isNotEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.text('AI 正在回复...'),
      findsNothing,
      reason: 'the run guard completes after the final message is persisted',
    );
    await settleRoundTimers(tester);
  });
}
