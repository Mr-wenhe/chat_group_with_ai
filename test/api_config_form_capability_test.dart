import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/settings/api_config_form_page.dart';
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
    await closeLifecycleHive(hiveDirectory, db);
  });

  /// 页面用 ListView，只构建视口内的子项：默认 800×600 测试窗口里能力区块
  /// 压根不在树上，断言会直接找不到。加大窗口让整页一次可见。
  Future<void> pumpPage(WidgetTester tester, {ApiConfig? config}) async {
    tester.view.physicalSize = const Size(1000, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: providerContainer,
      child: MaterialApp(home: ApiConfigFormPage(config: config)),
    ));
    await tester.pump();
  }

  Future<void> saveDeclaration(
    WidgetTester tester,
    CustomModelCapability capability,
  ) async {
    // Hive 写操作必须在 runAsync 里跑，否则 testWidgets 的假时钟会让它挂住。
    await tester.runAsync(() async {
      await AiGovernanceStore.forDatabase(db)
          .saveCustomCapability('deepseek', 'deepseek-chat', capability);
    });
  }

  String fieldText(WidgetTester tester, String key) =>
      tester.widget<TextFormField>(find.byKey(Key(key))).controller!.text;

  bool switchValue(WidgetTester tester, String label) => tester
      .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, label))
      .value;

  testWidgets('新建配置时能力字段回填生效值，而不是裸默认值', (tester) async {
    await pumpPage(tester);

    // 默认 DeepSeek / deepseek-chat：内置快照是 100 万上下文且支持流式与工具。
    // 裸默认值（全关 + 8192/2048）会把它显示成降级态，正是要避免的误导。
    expect(fieldText(tester, 'capability-context-window'), '1000000');
    expect(fieldText(tester, 'capability-max-output'), '8192');
    expect(switchValue(tester, '流式'), isTrue);
    expect(switchValue(tester, '工具'), isTrue);
    expect(switchValue(tester, '视觉'), isFalse);
  });

  testWidgets('已声明的配置回填合并后的生效值', (tester) async {
    await saveDeclaration(
      tester,
      const CustomModelCapability(supportsTools: false, contextWindow: 500000),
    );

    await pumpPage(
      tester,
      config: ApiConfig(name: '我的 DeepSeek', provider: 'deepseek'),
    );

    // 工具关来自用户声明；上下文取「声明 500000 与内置 1000000 的较大者」。
    expect(switchValue(tester, '工具'), isFalse);
    expect(fieldText(tester, 'capability-context-window'), '1000000');
  });

  testWidgets('最大输出大于上下文时报错，而不是静默丢弃', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
      find.byKey(const Key('capability-max-output')),
      '9999999',
    );
    await tester.pump();

    // 走真实入口（FormState.validate）而不点「测试连接」，避免发网络请求。
    expect(tester.state<FormState>(find.byType(Form)).validate(), isFalse);
    await tester.pump();

    expect(find.text('最大输出不能大于上下文 Token'), findsOneWidget);
  });

  testWidgets('未声明时没有「恢复内置默认」按钮', (tester) async {
    await pumpPage(tester);

    expect(find.text('恢复内置默认'), findsNothing);
  });

  testWidgets('已有声明时出现「恢复内置默认」按钮', (tester) async {
    await saveDeclaration(
        tester, const CustomModelCapability(supportsTools: false));

    await pumpPage(
      tester,
      config: ApiConfig(name: '我的 DeepSeek', provider: 'deepseek'),
    );

    expect(find.text('恢复内置默认'), findsOneWidget);
  });

  test('clearCustomCapability 只清掉目标模型的声明', () async {
    final store = AiGovernanceStore.forDatabase(db);
    const declared = CustomModelCapability(supportsTools: true);
    await store.saveCustomCapability('deepseek', 'deepseek-chat', declared);
    await store.saveCustomCapability('zhipu', 'glm-4-plus', declared);

    await store.clearCustomCapability('deepseek', 'deepseek-chat');

    expect(store.customCapability('deepseek', 'deepseek-chat'), isNull);
    expect(store.customCapability('zhipu', 'glm-4-plus'), isNotNull);
  });
}
