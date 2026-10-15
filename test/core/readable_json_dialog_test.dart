import 'dart:io';

import 'package:chat_group/core/widgets/readable_json_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('readable_json_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester, String path,
      {bool prettifyJson = true}) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showReadableJsonDialog(
                context,
                title: '方案与验收详情',
                path: path,
                prettifyJson: prettifyJson,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  String shownText(WidgetTester tester) =>
      tester.widget<SelectableText>(find.byType(SelectableText)).data!;

  testWidgets('合法 JSON 缩进美化后显示', (tester) async {
    final file = File('${dir.path}/detail.json')
      ..writeAsStringSync('{"scope":"做一个飞行棋","acceptances":[1,2]}');

    await open(tester, file.path);

    final text = shownText(tester);
    expect(text, contains('"scope": "做一个飞行棋"'));
    expect(text, contains('\n  "acceptances"'));
    // 原文件是紧凑单行，能出现换行就说明确实美化过。
    expect(text.contains('\n'), isTrue);
  });

  testWidgets('不是合法 JSON 时按原文显示并说明', (tester) async {
    final file = File('${dir.path}/detail.json')..writeAsStringSync('{不是 JSON');

    await open(tester, file.path);

    expect(shownText(tester), '{不是 JSON');
    expect(find.textContaining('不是合法 JSON'), findsOneWidget);
  });

  testWidgets('超出显示上限时截断并说明仍可复制全文', (tester) async {
    final long = 'x' * 200000;
    final file = File('${dir.path}/detail.json')
      ..writeAsStringSync('{"plan":"$long"}');

    await open(tester, file.path);

    expect(shownText(tester).length, maxReadableJsonCharacters);
    expect(find.textContaining('仅显示前 10 万字符'), findsOneWidget);
  });

  testWidgets('文件超过读取上限时说明只读了开头，按钮也不再承诺全文',
      (tester) async {
    final file = File('${dir.path}/detail.json')
      ..writeAsStringSync('y' * (maxReadableJsonBytes + 4096));

    await open(tester, file.path);

    expect(find.textContaining('仅读取前 256 KB'), findsOneWidget);
    // 上限之外的内容根本没读进内存，能复制的也只有读到的那一段。
    expect(find.text('复制已读取部分'), findsOneWidget);
    expect(find.text('复制全文'), findsNothing);
    expect(find.textContaining('可复制全文'), findsNothing);
  });

  testWidgets('文件不存在时给出错误态而不是空视图', (tester) async {
    await open(tester, '${dir.path}/missing.json');

    expect(find.textContaining('读取失败'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('纯文本模式按原文显示且不提示 JSON 说明', (tester) async {
    final file = File('${dir.path}/plan.md')..writeAsStringSync('# 方案\n\n- 第一步');

    await open(tester, file.path, prettifyJson: false);

    expect(shownText(tester), '# 方案\n\n- 第一步');
    expect(find.textContaining('不是合法 JSON'), findsNothing);
  });
}
