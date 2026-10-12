import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/settings/ai_speaker_picker_settings.dart';
import 'package:chat_group/features/settings/api_key_settings_page.dart';
import 'package:chat_group/features/settings/image_service_settings_page.dart';
import 'package:chat_group/features/settings/search_credential_settings_page.dart';
import 'package:chat_group/features/settings/voice_service_settings_page.dart';
import 'package:chat_group/features/web_search/presentation/web_search_settings_section.dart';
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
    AppToast.dismiss();
    await closeLifecycleHive(hiveDirectory, db);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 页面是 ListView，默认 800×600 视口里下方条目压根不在树上。
    tester.view.physicalSize = const Size(1000, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: providerContainer,
      child: const MaterialApp(home: ApiKeySettingsPage()),
    ));
    await tester.pump();
  }

  testWidgets('五类条目齐全，标题与状态都在', (tester) async {
    await pumpPage(tester);

    expect(find.text('API KEY 设置'), findsOneWidget);
    expect(find.text('聊天与角色发言'), findsOneWidget);
    expect(find.text('AI 接话选人器'), findsOneWidget);
    expect(find.text('语音服务 · 火山引擎'), findsOneWidget);
    expect(find.text('图像服务 · IP 形象生成'), findsOneWidget);
    expect(find.text('搜索服务'), findsOneWidget);

    // 每一类都还没配时，状态与顶部引导一致。
    expect(find.text('密钥已配置 0 / 4 项'), findsOneWidget);
    expect(find.text('还缺：聊天 / 语音 / 图像 / 搜索'), findsOneWidget);
    expect(find.text('尚未配置 · 角色无法回复消息'), findsOneWidget);
    expect(find.text('未选择 · 使用本地规则选人，不额外调用模型'), findsOneWidget);
  });

  testWidgets('配置一条绑定了 Key 的配置后进度与状态同步更新', (tester) async {
    late ApiConfig config;
    // testWidgets 跑在 FakeAsync 下，直接 await Hive 写会永不 resolve；
    // 必须放进 runAsync 走真实事件循环。
    await tester.runAsync(() async {
      config = ApiConfig(
        name: 'deepseek v4.1',
        provider: 'deepseek',
        modelName: 'deepseek-flash',
        hasCredential: true,
      );
      // 按配置自己的 id 落键：选人器是按 id 反查的，用 add 的整型自增键查不到。
      await db.apiConfigBox.put(config.id, config);
    });
    await pumpPage(tester);

    expect(find.text('密钥已配置 1 / 4 项'), findsOneWidget);
    expect(find.text('还缺：语音 / 图像 / 搜索'), findsOneWidget);
    expect(find.text('1 个配置 · 全部已绑定 Key'), findsOneWidget);
  });

  testWidgets('接话选人器不参与密钥计数', (tester) async {
    final config = ApiConfig(
      name: 'deepseek v4.1',
      provider: 'deepseek',
      modelName: 'deepseek-flash',
      hasCredential: true,
    );
    await tester.runAsync(() async {
      await db.apiConfigBox.put(config.id, config);
      // 选人器引用同一条配置：它的状态变成"可用"，但计数仍只由密钥类别决定。
      await AiSpeakerPickerSettings(db).select(config.id);
    });
    await pumpPage(tester);

    expect(find.text('deepseek v4.1 · deepseek-flash'), findsOneWidget);
    expect(find.text('可选'), findsOneWidget);
    expect(find.text('密钥已配置 1 / 4 项'), findsOneWidget);
  });

  testWidgets('手机窄屏下配置卡片不溢出', (tester) async {
    // 卡片右侧固定占着三个操作按钮，窄屏下留给名称与 Provider 徽章的宽度只剩
    // 一百像素出头。修复前这里会抛 RenderFlex overflowed by 200 pixels ——
    // 该缺陷是从设置页搬过来的，只在手机宽度上暴露。
    await tester.runAsync(() async {
      for (final id in ['a1', 'a2', 'a3']) {
        await db.apiConfigBox.put(
          id,
          ApiConfig(
            id: id,
            name: 'deepseek v4.1',
            provider: 'deepseek',
            modelName: 'deepseek-flash',
            hasCredential: true,
          ),
        );
      }
    });

    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: providerContainer,
      child: const MaterialApp(home: ApiKeySettingsPage()),
    ));
    await tester.pump();

    expect(find.text('语音服务 · 火山引擎'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击语音服务进入既有语音设置页', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('语音服务 · 火山引擎'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(VoiceServiceSettingsPage), findsOneWidget);
  });

  testWidgets('点击图像服务进入既有图像设置页', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('图像服务 · IP 形象生成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ImageServiceSettingsPage), findsOneWidget);
  });

  testWidgets('点击搜索服务进入搜索凭据页', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('搜索服务'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SearchCredentialSettingsPage), findsOneWidget);
    expect(find.byType(WebSearchSettingsSection), findsOneWidget);
  });
}
