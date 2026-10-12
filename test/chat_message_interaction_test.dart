import 'package:chat_group/features/chat_group/message_action_item.dart';
import 'package:chat_group/features/chat_group/widgets/message_action_menu.dart';
import 'package:chat_group/features/chat_group/widgets/message_selectable_text.dart';
import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:flutter/cupertino.dart' show CupertinoDesktopTextSelectionToolbar;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<MessageActionItem> actions(List<String> selected) => [
        MessageActionItem(
          icon: Icons.copy_rounded,
          label: '复制',
          onSelected: () => selected.add('复制'),
        ),
        MessageActionItem(
          icon: Icons.format_quote_rounded,
          label: '引用回复',
          onSelected: () => selected.add('引用回复'),
        ),
      ];

  Widget app({
    List<MessageActionItem> Function()? messageActions,
    VoidCallback? onLongPress,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: MessageSelectableText(
            content: 'hello world',
            style: const TextStyle(fontSize: 15),
            messageActions: messageActions,
            onLongPress: onLongPress,
          ),
        ),
      ),
    );
  }

  /// 右键菜单是桌面行为：在 macOS 上原生工具栏渲染的是单个「Copy」，
  /// 正是要替换掉的那个框，所以这几条用例必须钉在 macOS 上跑。
  ///
  /// 平台覆写只能在测试体内复位：`addTearDown` 跑在框架的
  /// `debugAssertAllFoundationVarsUnset` 校验之后，用它会被判成"测试改了调试变量"。
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

  testWidgets('renders selectable text and uses no TextField (no focus ring)',
      (tester) async {
    await tester.pumpWidget(app());

    expect(find.text('hello world'), findsOneWidget);
    // 改用 SelectableText 后不应再存在 TextField，避免 macOS 桌面端聚焦光环。
    expect(find.byType(TextField), findsNothing);
  });

  desktopTest('右键文字弹出消息操作菜单，而不是原生的 Copy 工具栏',
      (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(app(messageActions: () => actions(selected)));

    await tester.tap(
      find.byType(MessageSelectableText),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(find.byType(MessageActionContextMenu), findsOneWidget);
    expect(find.text('引用回复'), findsOneWidget);
    // 原生工具栏只有「Copy」一项；它一旦出现就说明两层菜单又叠在了一起。
    expect(find.byType(CupertinoDesktopTextSelectionToolbar), findsNothing);
    expect(find.text('Copy'), findsNothing);

    await tester.tap(find.text('引用回复'));
    await tester.pump();
    expect(selected, ['引用回复']);
  });

  desktopTest('点击菜单项后浮层收起', (tester) async {
    await tester.pumpWidget(app(messageActions: () => actions(<String>[])));

    await tester.tap(
      find.byType(MessageSelectableText),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(find.text('引用回复'), findsOneWidget);

    await tester.tap(find.text('引用回复'));
    await tester.pump();
    expect(find.byType(MessageActionContextMenu), findsNothing);
  });

  desktopTest('触屏长按仍交给外层底部弹窗，不弹桌面菜单', (tester) async {
    var longPressed = false;
    await tester.pumpWidget(app(
      messageActions: () => actions(<String>[]),
      onLongPress: () => longPressed = true,
    ));

    await tester.longPress(find.byType(MessageSelectableText));
    await tester.pump();

    expect(longPressed, isTrue);
    expect(find.byType(MessageActionContextMenu), findsNothing);
  });

  desktopTest('未提供操作清单时保持平台原生的选择工具栏', (tester) async {
    await tester.pumpWidget(app());

    await tester.tap(
      find.byType(MessageSelectableText),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(find.byType(CupertinoDesktopTextSelectionToolbar), findsOneWidget);
    expect(find.byType(MessageActionContextMenu), findsNothing);
  });

  testWidgets('renders selectable rich text for WeCom mention highlighting',
      (tester) async {
    const style = TextStyle(fontSize: 15, color: Colors.black);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageSelectableText(
            content: '请 @Alice 看一下',
            style: style,
            spans: buildWeComMentionSpans(
              '请 @Alice 看一下',
              mentionNames: const ['Alice'],
              baseStyle: style,
            ),
          ),
        ),
      ),
    );

    final selectable =
        tester.widget<SelectableText>(find.byType(SelectableText));
    expect(selectable.textSpan?.toPlainText(), '请 @Alice 看一下');
    final mention = selectable.textSpan!.children!
        .cast<TextSpan>()
        .where((span) => span.text == '@Alice')
        .single;
    expect(mention.style?.color, WeComChatTokens.mention);
    expect(find.byType(TextField), findsNothing);
  });
}
