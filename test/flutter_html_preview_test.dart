import 'package:chat_group/features/document/flutter_html_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内嵌 HTML 预览改由 Flutter 渲染后的回归用例。
///
/// 背景：macOS 上 WKWebView 作为 Flutter 平台视图时收不到鼠标指针事件
/// （滚轮、拖选、点击全部失效），因此预览不再使用内嵌浏览器；这组用例
/// 钉住三件事：离线安全边界、能渲染正文、能真的滚动。
void main() {
  group('sanitizeHtmlForPreview', () {
    test('reading mode keeps nested text and drops incompatible CSS', () {
      final sanitized =
          sanitizeHtmlForPreview('<style>.card{width:100%;display:flex}</style>'
              '<div style="color:white"><h1>陆博文</h1><p>物理教授</p></div>');
      expect(sanitized, contains('<h1>陆博文</h1>'));
      expect(sanitized, contains('<p>物理教授</p>'));
      expect(sanitized, isNot(contains('style')));
    });
    test('removes executable and externally loading tags', () {
      final sanitized = sanitizeHtmlForPreview('''
<html><head>
  <base href="https://evil.example/">
  <link rel="stylesheet" href="https://evil.example/a.css">
  <meta http-equiv="refresh" content="0;url=https://evil.example/">
</head><body>
  <script>alert(1)</script>
  <iframe src="https://evil.example/"></iframe>
  <object data="x.swf"></object>
  <embed src="y.swf">
  <noscript>fallback</noscript>
  <p>正文</p>
</body></html>''');

      for (final tag in [
        '<script',
        '<iframe',
        '<object',
        '<embed',
        '<link',
        '<base',
        '<noscript',
        'http-equiv="refresh"'
      ]) {
        expect(sanitized.contains(tag), isFalse, reason: '不应保留 $tag');
      }
      expect(sanitized, contains('正文'));
    });

    test('drops remote images but keeps data URIs', () {
      final sanitized = sanitizeHtmlForPreview('''
<body>
  <img src="https://tracker.example/pixel.png" alt="远程图">
  <img src="data:image/png;base64,AAAA" alt="内嵌图">
</body>''');

      expect(sanitized.contains('tracker.example'), isFalse);
      expect(sanitized, contains('[图片未加载：离线预览]'));
      expect(sanitized, contains('data:image/png;base64,AAAA'));
    });

    test('strips link targets and remote CSS urls', () {
      final sanitized = sanitizeHtmlForPreview('''
<html><head><style>
  body { background-image: url(https://evil.example/bg.png); }
</style></head>
<body>
  <a href="https://evil.example/">链接</a>
  <p style="background:url(https://evil.example/x.png)">段落</p>
</body></html>''');

      expect(sanitized.contains('evil.example'), isFalse);
      expect(sanitized, contains('链接'));
      expect(sanitized, contains('段落'));
      expect(sanitized.contains('url('), isFalse);
    });

    test('truncates oversized documents', () {
      final sanitized =
          sanitizeHtmlForPreview('<p>${'x' * 500}</p>', maxCharacters: 50);
      expect(sanitized.length, lessThan(500));
    });
  });

  group('FlutterHtmlPreview', () {
    testWidgets('Calc white headers retain cell, row and table backgrounds',
        (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: FlutterHtmlPreview(html: '''
<table bgcolor="#548235"><tr bgcolor="#4472c4">
<td bgcolor="#305496"><b><font color="#ffffff">日期</font></b></td>
<td><font color="#ffffff">项目名称</font></td></tr>
<tr><td><font color="#ffffff">汇总</font></td><td>100</td></tr></table>'''))));
      await tester.pump();
      for (final entry in {
        '日期': const Color(0xFF305496),
        '项目名称': const Color(0xFF4472C4),
        '汇总': const Color(0xFF548235),
      }.entries) {
        final text = find.byWidgetPredicate((widget) =>
            widget is RichText && widget.text.toPlainText() == entry.key);
        expect(text, findsOneWidget);
        final background = find.ancestor(
            of: text,
            matching: find.byWidgetPredicate((widget) =>
                widget is ColoredBox && widget.color == entry.value));
        expect(background, findsOneWidget, reason: '${entry.key} 不应白字白底');
      }
      expect(tester.takeException(), isNull);
    });
    testWidgets('rejects unbounded table dimensions before allocating cells',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: FlutterHtmlPreview(
                  html:
                      '<table><tr><td colspan="10000">X</td></tr></table>'))));
      await tester.pump();
      expect(find.textContaining('表格超过预览上限'), findsOneWidget);
      expect(find.byType(Table), findsNothing);
    });
    testWidgets('rowspan keeps following values in their original column',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: FlutterHtmlPreview(
                  html:
                      '<table><tr><td rowspan="2">Group</td><td>A</td></tr><tr><td>B</td></tr></table>'))));
      await tester.pump();
      expect(tester.getTopLeft(find.text('B')).dx,
          closeTo(tester.getTopLeft(find.text('A')).dx, 1));
    });
    testWidgets(
        'renders inline images outside tables without a custom-builder crash',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: FlutterHtmlPreview(
                  html:
                      '<img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=">'))));
      await tester.pump();
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('renders inline spreadsheet images inside table cells',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: FlutterHtmlPreview(
                  html:
                      '<table><tr><td><img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="></td></tr></table>'))));
      await tester.pump();
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets(
        'deep table nesting falls back instead of recursively building forever',
        (tester) async {
      var html = 'deep';
      for (var depth = 0; depth < 6; depth++) {
        html = '<table><tr><td>$html</td></tr></table>';
      }
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: FlutterHtmlPreview(html: html))));
      await tester.pump();
      expect(find.textContaining('表格嵌套超过预览上限'), findsOneWidget);
    });
    testWidgets('nested tables retain their content', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: FlutterHtmlPreview(
                  html:
                      '<table><tr><td><table><tr><td>INNER</td></tr></table></td></tr></table>'))));
      await tester.pump();
      expect(find.text('INNER'), findsOneWidget);
    });
    testWidgets('wide tables can scroll to the last column', (tester) async {
      final cells = List.generate(40, (i) => '<td>Column $i</td>').join();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body:
                  FlutterHtmlPreview(html: '<table><tr>$cells</tr></table>'))));
      await tester.pump();
      final scroll = find.byWidgetPredicate((w) =>
          w is SingleChildScrollView && w.scrollDirection == Axis.horizontal);
      expect(scroll, findsOneWidget);
      final before = tester.getTopLeft(find.text('Column 39')).dx;
      await tester.drag(scroll, const Offset(-500, 0));
      await tester.pump();
      expect(tester.getTopLeft(find.text('Column 39')).dx, lessThan(before));
    });
    testWidgets('renders table cells instead of dropping the whole table',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: FlutterHtmlPreview(
                  html: '<html><body><table>'
                      '<tr><th>模块</th><th>状态</th></tr>'
                      '<tr><td>单元格甲</td><td>单元格乙</td></tr>'
                      '</table></body></html>'))));
      await tester.pumpAndSettle();

      expect(find.text('模块'), findsOneWidget);
      expect(find.text('单元格甲'), findsOneWidget);
      expect(find.text('单元格乙'), findsOneWidget);
    });

    testWidgets('merged cells keep every row the same width', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: FlutterHtmlPreview(
                  html: '<html><body><table>'
                      '<tr><td colspan="2">合并标题</td></tr>'
                      '<tr><td>左</td><td>右</td></tr>'
                      '</table></body></html>'))));
      await tester.pumpAndSettle();

      expect(find.text('合并标题'), findsOneWidget);
      expect(find.text('左'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders body text inside a selectable area', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: FlutterHtmlPreview(
                  html: '<html><body><h1>标题甲</h1><p>正文乙</p></body></html>'))));
      await tester.pumpAndSettle();

      expect(
          find.byWidgetPredicate((widget) =>
              widget is RichText && widget.text.toPlainText().contains('标题甲')),
          findsWidgets);
      expect(find.byType(SelectionArea), findsOneWidget);
    });

    testWidgets('long documents scroll with wheel-sized drags', (tester) async {
      final body = List.generate(60, (index) => '<p>段落 $index</p>').join();
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: FlutterHtmlPreview(
                  html: '<html><body>$body</body></html>'))));
      await tester.pumpAndSettle();

      final before = tester.getTopLeft(find.byType(Html)).dy;
      await tester.drag(
          find.byType(SingleChildScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      final after = tester.getTopLeft(find.byType(Html)).dy;

      expect(after, lessThan(before), reason: '滚动后正文应当上移');
    });

    testWidgets('zoom buttons change scale without throwing', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: FlutterHtmlPreview(
                  html: '<html><body><p>缩放测试</p></body></html>'))));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('放大'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('缩小'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
