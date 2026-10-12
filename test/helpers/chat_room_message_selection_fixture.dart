import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 多选 / 批量删除 / 清空聊天记录用例共用的小工具。
///
/// **一个文件只放一条真正跑起消息变更的 widget 用例**：由点击触发的删除会在假
/// 时钟区发起 Hive 写，同一个进程里再跑第二条会卡住 box 的写队列（仓库已知的
/// 假区 Hive 行为，见 `chat_room_round_fixture.dart` 顶部说明）。所以这些工具按
/// "一条用例一个文件"准备，而不是把几条用例凑进同一个文件。
Future<void> seedRoomMessages(
  WidgetTester tester,
  DatabaseService db,
  String groupId,
  List<String> ids,
) async {
  await tester.runAsync(() async {
    await db.messageBox.putAll({
      for (final id in ids)
        id: Message(
          id: id,
          groupId: groupId,
          senderId: 'user',
          senderType: Message.senderTypeUser,
          content: id,
          // 时间戳按 id 打散，避免同一时刻的消息在列表里顺序不定。
          timestamp: DateTime(2026, 1, 1, id.hashCode.abs() % 60),
        ),
    });
  });
}

/// 触屏长按会被 [SelectableText] 的选择手势抢走（既有行为），桌面鼠标才是
/// 用户实际打开消息菜单的那条路径。
Future<void> longPressMessageWithMouse(
  WidgetTester tester,
  Finder target,
) async {
  final press = await tester.startGesture(
    tester.getCenter(target),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump(const Duration(milliseconds: 700));
  await press.up();
  await tester.pumpAndSettle();
}

/// 长按一条消息并从操作菜单进入多选。
Future<void> enterSelectionFromLongPress(
  WidgetTester tester,
  Finder target,
) async {
  await longPressMessageWithMouse(tester, target);
  await tester.tap(find.text('多选删除'));
  await tester.pumpAndSettle();
}

Future<void> openRoomMoreMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('chat-room-more-actions')));
  await tester.pumpAndSettle();
}

Finder selectionCheckboxFor(String messageId) =>
    find.byKey(ValueKey('message-select-$messageId'));

/// 点确认对话框里的某个按钮。
///
/// 顶部栏与对话框里可能有同名按钮（都为「删除」），必须限定在对话框内。
Future<void> tapDialogButton(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(AlertDialog), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// 交替推进假时钟与真实 I/O，直到 [done] 成立。
///
/// 删除是真实异步 I/O：固定 `runAsync(200ms)` 之后就断言会跑在异步续体之前，
/// 于是"界面已经更新"的断言失败，而生产状态其实是对的（2026-10-12 实测：
/// 打点显示 `_messageSelectionActive` 已置 false，界面仍显示旧的顶部栏）。
/// 所以按条件等待，不按时间等待。
Future<void> pumpUntilDone(
  WidgetTester tester,
  bool Function() done, {
  int steps = 80,
  String? reason,
}) async {
  for (var step = 0; step < steps && !done(); step++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue, reason: reason ?? '条件在限定步数内没有成立');
}
