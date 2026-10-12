import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_message_selection_fixture.dart';
import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 「清空聊天记录」只删消息，记忆与任务保留——它和「清空对话」是两个不同的承诺，
/// 菜单措辞与确认框说明都必须让人分得清。
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

  testWidgets('清空聊天记录只删消息，记忆与任务保留', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    addTearDown(AppToast.dismiss);
    const groupId = 'g-clear-messages';
    await seedRoundRoom(tester, db, groupId);
    await seedRoomMessages(tester, db, groupId, const ['清空一', '清空二']);
    await tester.runAsync(() async {
      await db.groupMemoryBox.put(
        'clear-room-memory',
        GroupMemory(groupId: groupId, topicSummary: '要留下的摘要'),
      );
      await db.agentTaskBox.put(
        'clear-room-task',
        AgentTask(
          id: 'clear-room-task',
          groupId: groupId,
          characterId: 'va',
          userRequest: '要留下的任务',
        ),
      );
    });

    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: groupId,
      api: ScriptedChatApi(),
      db: db,
      directory: directory,
    );
    await restartAutoChatScheduler(tester);
    await toggleAutoChatOff(tester);

    await openRoomMoreMenu(tester);
    // 两个入口必须能从措辞上分清：一个连记忆和任务一起删，一个只删消息。
    expect(find.text('清空对话（含记忆与任务）'), findsOneWidget);
    await tester.tap(find.text('清空聊天记录（保留记忆与任务）'));
    await tester.pumpAndSettle();

    expect(find.text('清空聊天记录？'), findsOneWidget);
    expect(find.textContaining('2 条消息'), findsOneWidget);
    expect(find.textContaining('保留：'), findsOneWidget);
    await tapDialogButton(tester, '清空消息');

    await pumpUntilDone(
      tester,
      () => find.text('清空一').evaluate().isEmpty,
      reason: '清空后列表不该还留着已删除的气泡',
    );

    await tester.runAsync(() async {
      expect(db.messageBox.get('清空一'), isNull);
      expect(db.messageBox.get('清空二'), isNull);
      expect(
        db.groupMemoryBox.get('clear-room-memory'),
        isNotNull,
        reason: '清空聊天记录要保留场合记忆',
      );
      expect(
        db.agentTaskBox.get('clear-room-task'),
        isNotNull,
        reason: '任务面板还挂着这条任务，不能一起删',
      );
    });

    await settleRoundTimers(tester);
  });
}
