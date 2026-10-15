import 'dart:io';

import 'package:chat_group/core/bundle/api_bundle_codec.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/debug_credential_cache.dart';
import 'package:chat_group/features/settings/api_bundle_import_page.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

const String _chatKey = 'sk-page-SENTINEL-zz';
const String _secret = defaultBundleSecret;

String sealedBundle() => ApiBundleCodec.seal(<String, dynamic>{
      'v': 1,
      'label': '页面测试包',
      'chat': [
        {'name': '主力对话', 'provider': 'deepseek', 'apiKey': _chatKey},
      ],
    }, secret: _secret);

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;
  late ProviderContainer providerContainer;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
    await Hive.openBox<dynamic>(DebugCredentialCache.boxName);
    providerContainer = ProviderContainer(
      overrides: [databaseServiceProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    providerContainer.dispose();
    DebugCredentialCache.bind(null);
    CredentialRepository.clearCache();
    await closeLifecycleHive(hiveDirectory, db);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 页面是 ListView：默认视口里预览区压根不在树上。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: providerContainer,
      child: const MaterialApp(home: ApiBundleImportPage()),
    ));
    await tester.pump();
  }

  Future<void> enterAndPreview(WidgetTester tester, String code) async {
    await tester.enterText(find.byType(TextField), code);
    await tester.tap(find.text('解析并预览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('贴入乱码 → 就地报错，且不回显输入内容', (tester) async {
    await pumpPage(tester);
    await enterAndPreview(tester, '这不是授权码');

    expect(find.text('无法识别的授权码格式'), findsOneWidget);
    // 错误文案里不得出现用户贴进来的东西。输入框本身**保留**原文（用户还要改），
    // 所以要排除 EditableText，只看页面上的 Text。
    final visibleTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .toList(growable: false);
    expect(
      visibleTexts.any((text) => text.contains('这不是授权码')),
      isFalse,
    );
  });

  testWidgets('贴入被改坏的授权码 → 认证失败而不是格式错误', (tester) async {
    await pumpPage(tester);
    final code = sealedBundle();
    // 翻**中间**一位，不要动末位：base64 的末位字符里有一部分比特是被丢弃的
    // 填充位，改它解码出来的字节完全一样，认证照样通过，用例会随机地不成立。
    // 中间位必然改变密文或 MAC，信封结构仍然完整，因此走的正是认证失败这条路。
    final index = code.length ~/ 2;
    final original = code[index];
    final broken = code.replaceRange(
      index,
      index + 1,
      original == 'A' ? 'B' : 'A',
    );
    await enterAndPreview(tester, broken);

    expect(find.textContaining('授权码校验失败'), findsOneWidget);
  });

  testWidgets('合法授权码 → 列出将新增的条目与密钥指纹', (tester) async {
    await pumpPage(tester);
    await enterAndPreview(tester, sealedBundle());

    expect(find.text('页面测试包'), findsOneWidget);
    expect(find.textContaining('将新增 1 条、覆盖 0 条、跳过 0 条'), findsOneWidget);
    expect(find.textContaining('新增 · 聊天 · 主力对话'), findsOneWidget);
    expect(find.textContaining('密钥指纹'), findsOneWidget);
    // 预览里不得出现密钥本身。
    expect(find.textContaining(_chatKey, findRichText: true), findsNothing);
  });

  testWidgets('确认导入 → 展示结果，密钥落到凭据存储', (tester) async {
    // 导入**之前**就把 notifier 创建出来并缓存住那份空列表——这正是用户遇到的
    // 场景：他先打开过「API KEY 设置」页，那一页 watch 了 apiConfigsProvider。
    expect(providerContainer.read(apiConfigsProvider), isEmpty);

    await pumpPage(tester);
    await enterAndPreview(tester, sealedBundle());

    // 写入是真实 Hive / 凭据存储 I/O。假时钟下这些 Future 既跑不完也收不了尾，
    // 因此**连 tap 一起**放进 runAsync——只把等待放进去不够，因为发起写入的那次
    // 点击仍需在真实时区里执行（与 `ai_character_form_page_test.dart` 同一写法）。
    await tester.runAsync(() async {
      await tester.tap(find.text('确认导入'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('成功 1 条，失败 0 条'), findsOneWidget);
    expect(db.apiConfigBox.length, 1);
    expect(db.apiConfigBox.values.single.hasCredential, isTrue);

    // 导入是直接写 Hive 的，绕过了 notifier 自己的写方法。页面必须补一次刷新，
    // 否则返回「API KEY 设置」页时「聊天与角色发言」显示的仍是导入前的状态，
    // 而配置其实已经落盘——用户看到的就是「导入没生效」。
    expect(
      providerContainer.read(apiConfigsProvider).length,
      1,
      reason: '导入后没有刷新 apiConfigsProvider，界面会停留在导入前的旧列表',
    );

    // 密钥不得进 app_settings。
    final dump = db.appSettingsBox.values.map((v) => v.toString()).join('\n');
    expect(dump.contains(_chatKey), isFalse);
  });

  testWidgets('解析成功后输入框被清空，授权码不留在页面上', (tester) async {
    await pumpPage(tester);
    await enterAndPreview(tester, sealedBundle());

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
  });
}
