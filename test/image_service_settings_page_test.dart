import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/images/image_service_config.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/settings/image_service_settings_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;
  late ProviderContainer providerContainer;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
    providerContainer = ProviderContainer(
      overrides: [databaseServiceProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    providerContainer.dispose();
    // 保存等生产方法会弹 AppToast；其 3 秒 Timer 会让 test 的 await 永不 resolve。
    AppToast.dismiss();
    await closeLifecycleHive(hiveDirectory, db);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 页面用 ListView，只构建视口内的子项：默认 800×600 测试窗口里
    // 「生成预览」卡与「保存配置」按钮压根不在树上，断言/点击会直接找不到。
    // 加大窗口让整页一次可见，比 scrollUntilVisible 少一轮交互也更稳。
    tester.view.physicalSize = const Size(1000, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: providerContainer,
      child: const MaterialApp(home: ImageServiceSettingsPage()),
    ));
    // _syncKeyPresence 是 initState 里的一次性异步读；给它一轮真实调度即可，
    // 不 pumpAndSettle —— 进度条类动画会让 settle 永不结束。
    await tester.pump();
  }

  testWidgets('选中智谱预设带出 /api/paas/v4 前缀与建议模型', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('image-provider-dropdown')));
    await tester.pump();
    await tester.tap(find.textContaining('智谱').last);
    await tester.pump();

    final address = tester.widget<TextFormField>(find
        .widgetWithText(TextFormField, '服务地址')
        .first); // 只取字段本身，避免误命中 hint 文本
    expect(address.controller!.text, 'https://open.bigmodel.cn/api/paas/v4');
    expect(find.byKey(const ValueKey('image-model-suggest-cogview-4-flash')),
        findsOneWidget);
  });

  testWidgets('点击模型建议 chip 填入模型名', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('image-provider-dropdown')));
    await tester.pump();
    await tester.tap(find.textContaining('智谱').last);
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey('image-model-suggest-cogview-4-flash')));
    await tester.pump();

    final model = find.widgetWithText(TextFormField, '模型名');
    expect(tester.widget<TextFormField>(model).controller!.text,
        'cogview-4-flash');
  });

  testWidgets('手改服务地址后回落到自定义，不静默改写用户输入', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, '服务地址'),
      'https://my-proxy.internal/openai/v1',
    );
    await tester.pump();

    // DropdownButtonFormField 不暴露 value，改断言收起后下拉显示的选中项。
    expect(find.text('自定义'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, '服务地址'))
          .controller!
          .text,
      'https://my-proxy.internal/openai/v1',
    );
  });

  testWidgets('生成预览卡出现在出图参数之后', (tester) async {
    await pumpPage(tester);

    // 「生成预览」既是卡标题也是按钮文案，因此按至少一处出现断言。
    expect(find.text('生成预览'), findsAtLeastNWidgets(1));
    expect(find.byKey(const ValueKey('image-preview-generate')), findsOneWidget);
    expect(find.byKey(const ValueKey('image-preview-box')), findsOneWidget);
  });

  test('保存的配置 Map 不含明文 Key，字段完整落盘', () async {
    // **不在 widget 测试里点「保存配置」**：`_saveMeta` 会弹 `AppToast`，
    // 其 3 秒 Timer 会让 `_verifyInvariants` 报 pending 并把后续用例拖到超时
    // （CLAUDE.md「AppToast timer 隔离」明令禁止调用含 AppToast 的生产方法）。
    // 因此这里在数据层断言落盘结果 —— UI 已由上面几例覆盖。
    await db.saveImageServiceConfig(const ImageServiceConfig(
      baseUrl: 'https://api.openai.com/v1',
      model: 'dall-e-3',
      size: '1024x1792',
      quality: 'hd',
      apiKeyBound: true,
    ));

    final saved = db.imageServiceConfig;
    expect(saved.baseUrl, 'https://api.openai.com/v1');
    expect(saved.model, 'dall-e-3');
    expect(saved.size, '1024x1792');
    expect(saved.quality, 'hd');
    expect(saved.isConfigured, isTrue);

    // 凭据红线：配置 Map 里只允许布尔位，绝不落明文 Key。
    final raw = db.appSettingsBox.get(imageServiceSettingsKey) as Map;
    expect(raw.containsKey('apiKey'), isFalse);
    expect(raw['apiKeyBound'], isA<bool>());
  });

  testWidgets('未绑定 Key 时预览按钮禁用并提示先绑定', (tester) async {
    await pumpPage(tester);

    expect(find.textContaining('先绑定 API Key'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('image-preview-generate')),
    );
    expect(button.onPressed, isNull);
  });
}
