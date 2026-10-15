import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(AppToast.dismiss);

  Future<void> showToast(WidgetTester tester, String message) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => GestureDetector(
          key: const Key('toast-trigger'),
          behavior: HitTestBehavior.opaque,
          onTap: () => AppToast.show(context, message),
          child: const SizedBox.expand(),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('toast-trigger')));
    await tester.pump();
  }

  // 胶囊的行数直接决定高度，所以「高度不变」就是「没有多出一行」。
  double toastHeight(WidgetTester tester) =>
      tester.getSize(find.byType(InkWell)).height;

  // 3 秒自动消失的 Timer 必须在用例体内取消，否则测试框架会报 pending timer。
  Future<void> dismissToast(WidgetTester tester) async {
    AppToast.dismiss();
    await tester.pump();
  }

  testWidgets('回复带换行不会多渲染一个空行、把胶囊撑高', (tester) async {
    await showToast(tester, 'SenseNova 测试成功！');
    final singleLine = toastHeight(tester);

    await showToast(tester, 'SenseNova 测试成功！\n');
    expect(find.text('SenseNova 测试成功！'), findsOneWidget);
    expect(toastHeight(tester), singleLine);
    await dismissToast(tester);
  });

  testWidgets('连续空白折叠成一个空格，正文保持可读', (tester) async {
    await showToast(tester, 'deepseek 测试成功！ OK');
    final singleLine = toastHeight(tester);

    await showToast(tester, '  deepseek 测试成功！\n\n  OK  ');
    expect(find.text('deepseek 测试成功！ OK'), findsOneWidget);
    expect(toastHeight(tester), singleLine);
    await dismissToast(tester);
  });
}
