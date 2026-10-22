import 'package:chat_group/core/widgets/required_fields_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cs = ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4));

  group('requiredFieldsMessage', () {
    test('无缺失项时不给文案', () {
      expect(requiredFieldsMessage(const []), isNull);
    });

    test('按传入顺序点名每一项', () {
      expect(
        requiredFieldsMessage(const ['名字', '性别', 'API 配置']),
        '请先填写：名字、性别、API 配置',
      );
    });
  });

  group('RequiredFieldsBanner', () {
    /// 把提示条挂进一个带 `AppBar.bottom` 的页面。
    ///
    /// 高度必须走 [RequiredFieldsBanner.appBarBottom] 这条真实路径：`PreferredSize`
    /// 是固定值，直接给 widget 塞一个自由高度就验不到"正文被裁掉"这个失败模式。
    Future<void> pumpBanner(
      WidgetTester tester,
      List<String> missing, {
      double textScale = 1,
      Size logicalSize = const Size(800, 600),
    }) async {
      tester.view.physicalSize = logicalSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              appBar: AppBar(
                title: const Text('创建 AI 角色'),
                bottom: RequiredFieldsBanner.appBarBottom(
                  context: context,
                  missingFields: missing,
                  cs: cs,
                ),
              ),
              body: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('点名缺什么', (tester) async {
      await pumpBanner(tester, const ['名字', '性别']);

      expect(find.text('请先填写：名字、性别'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      // 命中测试能过 = 真的画在屏幕上，而不只是存在于 widget 树里。
      expect(find.byType(RequiredFieldsBanner).hitTestable(), findsOneWidget);
    });

    testWidgets('无缺失项时不占任何高度', (tester) async {
      await pumpBanner(tester, const []);

      expect(find.textContaining('请先填写：'), findsNothing);
      expect(tester.getSize(find.byType(RequiredFieldsBanner)).height, 0);
    });

    testWidgets('正文不被 PreferredSize 的固定高度裁掉', (tester) async {
      await pumpBanner(tester, const ['群聊名称', '主题', '选择角色']);

      expect(tester.takeException(), isNull);
      final text = find.text('请先填写：群聊名称、主题、选择角色');
      expect(text, findsOneWidget);
      final bannerHeight =
          tester.getSize(find.byType(RequiredFieldsBanner)).height;
      // 正文（含上下 padding）必须整体落在提示条内，而不是被顶出去。
      expect(tester.getSize(text).height, lessThan(bannerHeight));
      expect(tester.getTopLeft(text).dy, greaterThan(0));
    });

    testWidgets('放大到 1.6 倍字体仍不溢出', (tester) async {
      await pumpBanner(tester, const ['群聊名称', '主题', '选择角色'], textScale: 1.6);

      expect(tester.takeException(), isNull);
      final text = find.text('请先填写：群聊名称、主题、选择角色');
      expect(
        tester.getSize(text).height,
        lessThan(tester.getSize(find.byType(RequiredFieldsBanner)).height),
      );
    });

    testWidgets('窄屏 + 放大字体换行时，高度按真实行数长出来', (tester) async {
      // 320 逻辑像素宽配 1.6 倍字体时这行文案必然折成两行。按"一行"算高度的
      // 写法会把它挤爆 PreferredSize，正文被裁掉且 debug 下报 overflow。
      await pumpBanner(tester, const ['群聊名称', '主题', '选择角色'],
          textScale: 1.6, logicalSize: const Size(320, 640));

      expect(tester.takeException(), isNull);
      final text = find.text('请先填写：群聊名称、主题、选择角色');
      final banner = find.byType(RequiredFieldsBanner);
      expect(
          tester.getSize(text).height, lessThan(tester.getSize(banner).height));
      expect(
        tester.getBottomLeft(text).dy,
        lessThanOrEqualTo(tester.getBottomLeft(banner).dy),
      );
    });
  });
}
