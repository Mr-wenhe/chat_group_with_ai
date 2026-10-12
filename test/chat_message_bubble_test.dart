import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/message_action_item.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_bubble.dart';
import 'package:chat_group/features/chat_group/widgets/message_action_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Message message({String? replyTo}) => Message(
        id: 'message-1',
        groupId: 'g1',
        senderId: 'ai-1',
        senderType: Message.senderTypeAi,
        content: '这是一条回复',
        replyToMessageId: replyTo,
      );

  Widget bubble({
    Message? withMessage,
    Message? quoted,
    String? quotedSenderName,
    VoidCallback? onQuotedTap,
    VoidCallback? onLongPress,
    MessageActionItemBuilder? messageActions,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          child: ChatMessageBubble(
            message: withMessage ?? message(),
            characters: const [],
            cs: const ColorScheme.light(),
            senderColor: (_) => Colors.blue,
            ownerName: '我',
            quotedMessage: quoted,
            quotedSenderName: quotedSenderName,
            onQuotedTap: onQuotedTap,
            onLongPress: onLongPress,
            messageActions: messageActions,
          ),
        ),
      ),
    );
  }

  /// 右键菜单是桌面行为，钉在 macOS 上跑才有意义（原生工具栏那边渲染的是
  /// 单个「Copy」）。平台覆写只能在测试体内复位，见 `addTearDown` 的校验时机。
  void desktopTest(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('引用的消息已不存在时显示占位而不是空白', (tester) async {
    await tester.pumpWidget(bubble(
      withMessage: message(replyTo: 'deleted-message'),
      quoted: null,
    ));

    expect(find.text('原消息已删除'), findsOneWidget);
  });

  testWidgets('引用的消息还在时照常显示原正文，不显示占位', (tester) async {
    var tapped = false;
    await tester.pumpWidget(bubble(
      withMessage: message(replyTo: 'quoted-1'),
      quoted: Message(
        id: 'quoted-1',
        groupId: 'g1',
        senderId: 'ai-2',
        senderType: Message.senderTypeAi,
        content: '被引用的原话',
      ),
      quotedSenderName: '程序媛',
      onQuotedTap: () => tapped = true,
    ));

    expect(find.text('原消息已删除'), findsNothing);
    expect(find.text('被引用的原话'), findsOneWidget);

    await tester.tap(find.text('被引用的原话'));
    expect(tapped, isTrue);
  });

  testWidgets('没有引用指针时不出现占位', (tester) async {
    await tester.pumpWidget(bubble(quoted: null));

    expect(find.text('原消息已删除'), findsNothing);
  });

  desktopTest('右键消息文字只弹出操作菜单，不再同时弹底部弹窗', (tester) async {
    var longPressed = false;
    await tester.pumpWidget(bubble(
      onLongPress: () => longPressed = true,
      messageActions: (_, __) => [
        MessageActionItem(
          icon: Icons.delete_outline_rounded,
          label: '删除这条消息',
          destructive: true,
          onSelected: () {},
        ),
      ],
    ));

    await tester.tap(
      find.text('这是一条回复'),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(find.byType(MessageActionContextMenu), findsOneWidget);
    expect(find.text('删除这条消息'), findsOneWidget);
    // 外层 GestureDetector 的 onSecondaryTap 若也响应，右键会同时开出两层菜单。
    expect(longPressed, isFalse);
  });
}
