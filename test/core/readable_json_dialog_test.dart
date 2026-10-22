import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/widgets/readable_json_dialog.dart';
import 'package:chat_group/core/text/entity_labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
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
      {bool prettifyJson = true,
      bool structuredWorkPlan = false,
      bool renderMarkdown = false,
      bool showRawSource = false,
      EntityLabels? entityLabels}) async {
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
                structuredWorkPlan: structuredWorkPlan,
                renderMarkdown: renderMarkdown,
                showRawSource: showRawSource,
                entityLabels: entityLabels,
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

  String allShownText(WidgetTester tester) => tester
      .widgetList<SelectableText>(find.byType(SelectableText))
      .map((widget) => widget.data ?? '')
      .join('\n');

  testWidgets('合法 JSON 缩进美化后显示', (tester) async {
    final file = File('${dir.path}/detail.json')
      ..writeAsStringSync('{"scope":"做一个飞行棋","acceptances":[1,2]}');

    await open(tester, file.path, showRawSource: true);

    final text = shownText(tester);
    expect(text, contains('"scope": "做一个飞行棋"'));
    expect(text, contains('\n  "acceptances"'));
    // 原文件是紧凑单行，能出现换行就说明确实美化过。
    expect(text.contains('\n'), isTrue);
    expect(find.text('复制原文'), findsOneWidget);
    await tester.tap(find.text('技术详情（原始 JSON）'));
    await tester.pumpAndSettle();
    expect(allShownText(tester),
        contains('{"scope":"做一个飞行棋","acceptances":[1,2]}'));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.text('复制原文'));
    await tester.pump();
    expect(copied, '{"scope":"做一个飞行棋","acceptances":[1,2]}');
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

  testWidgets('文件超过读取上限时说明只读了开头，按钮也不再承诺全文', (tester) async {
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
    final file = File('${dir.path}/plan.md')
      ..writeAsStringSync('# 方案\n\n- 第一步');

    await open(tester, file.path, prettifyJson: false);

    expect(shownText(tester), '# 方案\n\n- 第一步');
    expect(find.textContaining('不是合法 JSON'), findsNothing);
  });

  testWidgets('群聊 Markdown 预览显示标题、列表、表格、代码和链接', (tester) async {
    final file = File('${dir.path}/rules.md')..writeAsStringSync('''# 飞行棋规则

- 四人轮流

| 动作 | 规则 |
| --- | --- |
| 掷骰 | 点数决定移动 |

```js
rollDice()
```

参见 [规则说明](https://example.test/rules)''');

    await open(tester, file.path, prettifyJson: false, renderMarkdown: true);

    final text = allShownText(tester);
    expect(find.textContaining('飞行棋规则'), findsOneWidget);
    expect(find.textContaining('四人轮流'), findsOneWidget);
    expect(text, contains('动作'));
    expect(text, contains('点数决定移动'));
    expect(text, contains('rollDice()'));
    expect(find.textContaining('规则说明 (https://example.test/rules)'),
        findsOneWidget);
    expect(find.text('技术详情（原始 Markdown）'), findsOneWidget);
  });

  testWidgets('已知工作方案 JSON 结构化显示，保留可展开原文', (tester) async {
    final file = File('${dir.path}/plan.json')..writeAsStringSync('''{
  "requestRevision": 3,
  "teamRevision": 2,
  "verificationRevision": 4,
  "scope": "制作单文件 HTML 飞行棋",
  "plan": "先实现四人轮流，再由测试成员操作验收。",
  "artifactContract": {
    "type": "html",
    "format": "html",
    "location": "/tmp/out",
    "revisionTarget": "飞行棋.html",
    "files": ["飞行棋.html"]
  },
  "workItems": [{"id":"制作","ownerId":"5c13c5d8-a11a-4db3-a09f-c6039320b949","status":"done"}],
  "issues": [{"id":"DEF-1","kind":"defect","status":"resolved","problem":"回合不会切换","resolution":"修复回合控制"}],
  "acceptances": [{"id":"AC-1","method":"实际掷骰并走棋","status":"pending"}]
}''');

    await open(tester, file.path,
        structuredWorkPlan: true,
        showRawSource: true,
        entityLabels: EntityLabels(resolvers: [
          (id) => id == '5c13c5d8-a11a-4db3-a09f-c6039320b949' ? '程序媛' : null
        ]));

    final text = allShownText(tester);
    expect(text, contains('制作单文件 HTML 飞行棋'));
    expect(find.text('目标'), findsOneWidget);
    expect(find.text('最终方案'), findsOneWidget);
    expect(text, contains('程序媛'));
    expect(text, isNot(contains('5c13c5d8-a11a-4db3-a09f-c6039320b949')));
    expect(find.text('问题与解决状态'), findsOneWidget);
    expect(text, contains('已解决'));
    await tester.scrollUntilVisible(
      find.text('验收标准'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('验收标准'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('需求版本：3'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.textContaining('需求版本：3'), findsOneWidget);
    expect(find.text('技术详情（原始 JSON）'), findsOneWidget);
  });

  testWidgets('普通 JSON 不会被误识别为工作方案', (tester) async {
    final file = File('${dir.path}/ordinary.json')
      ..writeAsStringSync('{"name":"棋子","count":4}');

    await open(tester, file.path,
        structuredWorkPlan: true,
        entityLabels: EntityLabels(resolvers: [
          (id) => id == '5c13c5d8-a11a-4db3-a09f-c6039320b949' ? '程序媛' : null
        ]));

    expect(shownText(tester), contains('"name": "棋子"'));
    expect(find.text('目标'), findsNothing);
    expect(find.text('技术详情（原始 JSON）'), findsNothing);
  });

  testWidgets('待采纳的嵌套提案明确标记为未采纳', (tester) async {
    final file = File('${dir.path}/pending-proposal.json')
      ..writeAsStringSync(jsonEncode({
        'proposal': {
          'scope': '制作单文件 HTML 飞行棋',
          'plan': '四人轮流，沿完整外圈后进入终点跑道。',
          'artifactContract': {
            'type': 'html',
            'format': 'html',
            'location': '/tmp/out'
          },
          'workItems': <Object>[],
          'acceptances': <Object>[],
        },
        'issues': [
          {
            'id': 'IDEA-1',
            'kind': 'idea',
            'status': 'open',
            'problem': '等待成员认可',
            'resolution': '等待全员审阅；尚未改变正式方案。',
          }
        ],
      }));

    await open(tester, file.path,
        structuredWorkPlan: true, showRawSource: true);

    expect(find.text('提案方案（尚未采纳）'), findsOneWidget);
    expect(find.text('最终方案'), findsNothing);
    expect(find.text('问题与解决状态'), findsOneWidget);
  });

  testWidgets('形似工作字段但缺少交付合同的 JSON 仍按普通 JSON 显示', (tester) async {
    final file = File('${dir.path}/ordinary-plan-like.json')
      ..writeAsStringSync('{"scope":"棋局范围","plan":"执行步骤","workItems":[]}');

    await open(tester, file.path, structuredWorkPlan: true);

    expect(shownText(tester), contains('"scope": "棋局范围"'));
    expect(find.text('目标'), findsNothing);
    expect(find.text('技术详情（原始 JSON）'), findsNothing);
  });

  testWidgets('TXT 预览保留空行和缩进', (tester) async {
    final file = File('${dir.path}/notes.txt')
      ..writeAsStringSync('第一行\n  缩进内容\n\n最后一行');

    await open(tester, file.path, prettifyJson: false);

    expect(shownText(tester), '第一行\n  缩进内容\n\n最后一行');
  });

  String longPlan() => jsonEncode({
        'scope': '滚动复现',
        'plan': '方案正文\n' * 20,
        'artifactContract': {'type': 'html'},
        'workItems': <Object>[],
        'issues': List.generate(
            40,
            (i) => {
                  'id': '问题 $i',
                  'problem': '问题描述\n' * 5,
                  'resolution': '解决方案的完整说明。' * 30,
                  'status': 'resolved',
                }),
        'acceptances': [
          {'id': '验收', 'method': '实际点击'}
        ],
      });

  for (final mode in ['方案', '纯文本', 'Markdown']) {
    testWidgets('macOS $mode 文档滚动条可用鼠标拖动', (tester) async {
      final file = File('${dir.path}/long-plan.json')
        ..writeAsStringSync(mode == '方案' ? longPlan() : '正文\n' * 1000);
      await open(tester, file.path,
          structuredWorkPlan: mode == '方案',
          prettifyJson: mode == '方案',
          renderMarkdown: mode == 'Markdown');
      final scrollable = find
          .descendant(
              of: find.byType(Scrollbar).first,
              matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final bounds = tester.getRect(scrollable);
      await tester.sendEventToBinding(PointerScrollEvent(
          position: bounds.center, scrollDelta: const Offset(0, 40)));
      await tester.pumpAndSettle();
      final before = position.pixels;
      final thumb = Offset(bounds.right - 5, bounds.top + 12);
      final mouse =
          await tester.startGesture(thumb, kind: PointerDeviceKind.mouse);
      await mouse.moveBy(const Offset(0, 100));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(position.pixels, greaterThan(before + 100));
    },
        timeout: const Timeout(Duration(seconds: 30)),
        variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets('长方案滚动时总高度稳定，小幅滚轮不跳页', (tester) async {
    final file = File('${dir.path}/long-plan.json')
      ..writeAsStringSync(longPlan());
    await open(tester, file.path, structuredWorkPlan: true);
    final scrollable = find
        .descendant(
            of: find.byType(Scrollbar).first, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final initialExtent = position.maxScrollExtent;
    for (final start in [0.0, initialExtent - 1000]) {
      position.jumpTo(start);
      await tester.pumpAndSettle();
      for (var i = 0; i < 12; i++) {
        final before = position.pixels;
        await tester.sendEventToBinding(PointerScrollEvent(
            position: tester.getRect(scrollable).center,
            scrollDelta: const Offset(0, 80)));
        await tester.pumpAndSettle();
        expect(position.pixels, closeTo(before + 80, 1));
        expect(position.maxScrollExtent, closeTo(initialExtent, 1));
      }
    }
  },
      timeout: const Timeout(Duration(seconds: 30)),
      variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
