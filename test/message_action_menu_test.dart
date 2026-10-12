import 'package:chat_group/features/chat_group/message_action_item.dart';
import 'package:chat_group/features/chat_group/widgets/message_action_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<MessageActionItem> items(List<String> tapped) => [
        MessageActionItem(
          icon: Icons.copy_rounded,
          label: '复制',
          onSelected: () => tapped.add('复制'),
        ),
        MessageActionItem(
          icon: Icons.format_quote_rounded,
          label: '引用回复',
          onSelected: () => tapped.add('引用回复'),
        ),
        MessageActionItem(
          icon: Icons.delete_outline_rounded,
          label: '删除这条消息',
          destructive: true,
          onSelected: () => tapped.add('删除这条消息'),
        ),
      ];

  testWidgets('底部弹窗列出全部操作项，点选先关闭弹窗再执行', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet(
                  context: context,
                  backgroundColor: Colors.transparent,
                  builder: (_) => MessageActionSheet(
                    title: '程序媛 的消息',
                    items: items(tapped),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('程序媛 的消息'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('删除这条消息'), findsOneWidget);

    await tester.tap(find.text('引用回复'));
    await tester.pumpAndSettle();

    expect(tapped, ['引用回复']);
    // 弹窗必须先走掉，否则动作执行后它还压在页面上。
    expect(find.text('引用回复'), findsNothing);
  });

  testWidgets('右键菜单竖向列出全部操作项，点选先收浮层再执行', (tester) async {
    final tapped = <String>[];
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageActionContextMenu(
            anchor: const Offset(80, 120),
            items: items(tapped),
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );

    expect(find.text('复制'), findsOneWidget);
    expect(find.text('引用回复'), findsOneWidget);
    expect(find.text('删除这条消息'), findsOneWidget);
    // 竖向排列：三项的 x 中心一致，y 依次增大。
    final copy = tester.getCenter(find.text('复制'));
    final quote = tester.getCenter(find.text('引用回复'));
    final remove = tester.getCenter(find.text('删除这条消息'));
    expect(copy.dx, quote.dx);
    expect(quote.dx, remove.dx);
    expect(copy.dy, lessThan(quote.dy));
    expect(quote.dy, lessThan(remove.dy));

    await tester.tap(find.text('删除这条消息'));
    await tester.pump();

    expect(dismissed, isTrue);
    expect(tapped, ['删除这条消息']);
  });

  testWidgets('右键菜单项数很多时限制高度并可滚动', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageActionContextMenu(
            anchor: const Offset(40, 40),
            items: [
              for (var index = 0; index < 20; index++)
                MessageActionItem(
                  icon: Icons.circle_outlined,
                  label: '操作$index',
                  onSelected: () => tapped.add('$index'),
                ),
            ],
            onDismiss: () {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    // 20 项的自然高度远超视口；高度被收住才说明没有撑破布局。
    final height = tester.getSize(find.byType(SingleChildScrollView)).height;
    expect(height, greaterThan(0));
    expect(height, lessThan(600));
  });
}
