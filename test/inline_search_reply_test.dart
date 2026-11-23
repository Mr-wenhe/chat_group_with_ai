import 'package:chat_group/features/chat_group/message_action_item.dart';
import 'package:chat_group/features/chat_group/widgets/message_selectable_text.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/presentation/inline_search_reply.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a known entry alone does not claim a successful network read',
      (tester) async {
    final entry = WebSearchSnapshot(
        searchedAt: DateTime.utc(2026),
        provider: 'autonomous-web',
        results: [
          WebSearchResult(
              sourceId: 's1',
              title: '官方入口（内部读取说明）',
              snippet: '',
              url: Uri.parse('https://example.com/'),
              provider: '官方公开入口')
        ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: InlineSearchReply(
                content: '尚未读取榜单',
                snapshot: entry.toMap(),
                style: const TextStyle(),
                mentionNames: const []))));
    expect(find.text('已找到入口 · 1 个来源'), findsOneWidget);
    expect(find.textContaining('已联网'), findsNothing);
    await tester.tap(find.text('已找到入口 · 1 个来源'));
    await tester.pump();
    expect(find.text('[W1] 官方入口'), findsOneWidget);
    expect(find.textContaining('内部读取说明'), findsNothing);
  });
  final snapshot = WebSearchSnapshot(
      searchedAt: DateTime.utc(2026),
      provider: 'autonomous-web',
      results: [
        WebSearchResult(
            sourceId: 's1',
            title: '官方文档',
            snippet: '',
            url: Uri.parse('https://example.com/doc'),
            provider: 'public-web')
      ]).toMap();
  Widget app(
          {bool selectionMode = false,
          ValueChanged<Uri>? open,
          VoidCallback? tap,
          List<MessageActionItem> Function()? actions}) =>
      MaterialApp(
          home: Scaffold(
              body: InlineSearchReply(
                  content:
                      '**官方文档**\nhttps://example.com/doc [W1]\n@程序媛 [假链接](https://127.0.0.1/)',
                  snapshot: snapshot,
                  style: const TextStyle(fontSize: 15),
                  mentionNames: const ['程序媛'],
                  onOpenSource: open,
                  selectionMode: selectionMode,
                  onTap: tap,
                  messageActions: actions)));

  testWidgets(
      'only registered safe links are clickable and titles replace raw markup',
      (tester) async {
    Uri? opened;
    await tester.pumpWidget(app(open: (uri) => opened = uri));
    final text = tester.widget<SelectableText>(find.byType(SelectableText));
    final spans = text.textSpan!.children!.whereType<TextSpan>().toList();
    expect(spans.any((s) => s.text == '**官方文档**'), isFalse);
    final title = spans.singleWhere((s) => s.text == '官方文档');
    expect(title.recognizer, isA<TapGestureRecognizer>());
    await tester.tapAt(
        tester.getTopLeft(find.byType(SelectableText)) + const Offset(20, 8));
    await tester.pump();
    expect(opened.toString(), 'https://example.com/doc');
    expect(spans.singleWhere((s) => s.text == '假链接').recognizer, isNull);
    expect(spans.singleWhere((s) => s.text == '@程序媛').style?.fontWeight,
        FontWeight.w500);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection mode disables link opening and keeps row selection',
      (tester) async {
    var selected = false;
    await tester.pumpWidget(app(
        selectionMode: true,
        open: (_) => fail('must not open links during selection'),
        tap: () => selected = true));
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.byType(MessageSelectableText));
    expect(selected, isTrue);
    expect(
        tester
            .widget<TextButton>(find.byWidgetPredicate((w) => w is TextButton))
            .onPressed,
        isNull);
  });

  testWidgets('source-backed replies retain the message context menu',
      (tester) async {
    var copied = false;
    await tester.pumpWidget(app(
        actions: () => [
              MessageActionItem(
                  icon: Icons.copy,
                  label: '复制本条',
                  onSelected: () => copied = true)
            ]));
    await tester.tap(find.byType(MessageSelectableText),
        buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.tap(find.text('复制本条'));
    await tester.pump();
    expect(copied, isTrue);
  });
}
