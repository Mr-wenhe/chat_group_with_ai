import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 删除单条消息只该让这条气泡消失：它已经产生的群记忆要留着，引用它的消息也要
/// 能说明"原消息已删除"，而不是凭空少一截引用条。
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

  testWidgets('长按删除只移除这条气泡，群记忆与引用指针都保留', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    // 生产方法收尾会弹 AppToast，其 3 秒 Timer 必须显式清掉。
    addTearDown(AppToast.dismiss);
    await seedRoundRoom(tester, db, 'g-delete');
    await tester.runAsync(() async {
      await db.messageBox.putAll({
        'msg-quoted': Message(
          id: 'msg-quoted',
          groupId: 'g-delete',
          senderId: 'user',
          senderType: Message.senderTypeUser,
          content: '被引用的原话',
          timestamp: DateTime(2026, 1, 1),
        ),
        'msg-reply': Message(
          id: 'msg-reply',
          groupId: 'g-delete',
          senderId: 'va',
          senderType: Message.senderTypeAi,
          content: '回复上面那句',
          timestamp: DateTime(2026, 1, 1, 0, 1),
          replyToMessageId: 'msg-quoted',
        ),
      });
      await db.groupMemoryBox.put(
        'mem-1',
        GroupMemory(groupId: 'g-delete', topicSummary: '删除前生成的摘要'),
      );
    });

    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'g-delete',
      api: ScriptedChatApi(),
      db: db,
      directory: directory,
    );
    await restartAutoChatScheduler(tester);
    await toggleAutoChatOff(tester);

    // 被引用的那条自己是一个气泡，另外还被回复的引用条展示一次。
    expect(find.text('被引用的原话'), findsNWidgets(2));

    // 用鼠标按住：触屏长按会被 SelectableText 的选择手势抢走（既有行为，
    // 本次不动），桌面鼠标长按才是用户实际打开弹窗的那条路径。
    final press = await tester.startGesture(
      tester.getCenter(find.text('被引用的原话').first),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await press.up();
    await tester.pumpAndSettle();
    expect(find.text('删除这条消息'), findsOneWidget);

    await tester.tap(find.text('删除这条消息'));
    await tester.pumpAndSettle();
    expect(find.text('删除这条消息？'), findsOneWidget);
    expect(find.textContaining('记忆、心情都会保留'), findsOneWidget);

    await tester.tap(find.text('删除'));
    // 落库是真实异步 I/O，必须让出事件循环才可能完成。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(find.text('被引用的原话'), findsNothing);
    // 引用条没有消失，改成了占位。
    expect(find.text('原消息已删除'), findsOneWidget);

    await tester.runAsync(() async {
      expect(db.messageBox.get('msg-quoted'), isNull);
      expect(
        db.messageBox.get('msg-reply')!.replyToMessageId,
        'msg-quoted',
        reason: '引用指针要留着，否则渲染层无从判断该显示占位',
      );
      expect(
        db.groupMemoryBox.get('mem-1'),
        isNotNull,
        reason: '删一条消息不该把整个群的记忆一起失效',
      );
    });

    await settleRoundTimers(tester);
  });
}
