import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
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

  /// 名称与 API Key 两个输入框没有 Key，按标签文字定位：标签 Text 渲染在
  /// TextFormField 自己的子树里。
  Finder fieldWithLabel(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(TextFormField),
      );

  bool switchValue(WidgetTester tester, String label) => tester
      .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, label))
      .value;

  testWidgets('新建时选 Oray：预填地址与 Anthropic 协议，模型仍留空', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('DeepSeek'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Oray').last);
    await tester.pumpAndSettle();

    expect(fieldText(tester, 'api-config-base-url'),
        'https://ai-api.orayer.com/v1');
    // Oray 只有 Anthropic 原生协议；若沿用全站默认的 OpenAI 兼容，请求会打到
    // /v1/chat/completions 而不是 /v1/messages。
    expect(find.text(ApiProtocol.anthropicMessages.label), findsOneWidget);
    // 模型不预填：聚合站的模型名由上游命名空间决定，靠手输或「获取模型」。
    expect(fieldText(tester, 'model-field'), '');
    expect(find.byKey(const Key('fetch-models-button')), findsOneWidget);
  });

  testWidgets('已保存的 Oray 配置：按存下来的协议与地址回填', (tester) async {
    await pumpPage(
      tester,
      config: ApiConfig(
        name: 'Oray',
        provider: 'oray',
        apiProtocol: ApiProtocol.anthropicMessages.name,
        modelName: 'deepseek/deepseek-flash',
        customBaseUrl: 'https://ai-api.orayer.com/v1',
      ),
    );

    expect(fieldText(tester, 'api-config-base-url'),
        'https://ai-api.orayer.com/v1');
    expect(find.text(ApiProtocol.anthropicMessages.label), findsOneWidget);
    expect(fieldText(tester, 'model-field'), 'deepseek/deepseek-flash');
  });

  testWidgets('新建内置配置：地址可见可改、模型留空、未知模型不做能力承诺', (tester) async {
    await pumpPage(tester);

    // 内置提供商也要能看到并修改地址，否则内置 + 协议子路径永远配不出来。
    expect(
        fieldText(tester, 'api-config-base-url'), 'https://api.deepseek.com');
    // 模型不再预填一个可能已失效的内置默认值。
    expect(fieldText(tester, 'model-field'), '');
    expect(find.text('deepseek-chat'), findsNothing);
    expect(find.byKey(const Key('fetch-models-button')), findsOneWidget);
  });

  testWidgets('模型名一律手输：内置提供商也是输入框而不是下拉', (tester) async {
    await pumpPage(tester);

    expect(tester.widget(find.byKey(const Key('model-field'))),
        isA<TextFormField>());

    // 不在任何内置候选清单里的自造别名照样填得进去——下拉做不到这一点。
    await tester.enterText(
        find.byKey(const Key('model-field')), 'my-own-alias');
    await tester.pump();

    expect(fieldText(tester, 'model-field'), 'my-own-alias');
  });

  testWidgets('手输模型名后失焦，能力字段回填该模型的生效值', (tester) async {
    await pumpPage(tester);

    await tester.enterText(
        find.byKey(const Key('model-field')), 'deepseek-chat');
    await tester.pump();
    // 回填只在失焦时发生：跟着按键回填会把用户正在输入的名字抹掉。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    // 内置快照里 deepseek-chat 是 100 万上下文。
    expect(fieldText(tester, 'capability-context-window'), '1000000');
    expect(fieldText(tester, 'capability-max-output'), '8192');
  });

  testWidgets('手输模型名不失焦直接创建，声明按新模型落盘而不是上一个模型的值', (tester) async {
    await pumpPage(tester);

    // 先把字段带到 deepseek-chat 的生效值上（内置快照里是 100 万上下文）。
    await tester.enterText(
        find.byKey(const Key('model-field')), 'deepseek-chat');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(fieldText(tester, 'capability-context-window'), '1000000');

    // 换成未登记模型，但**不失焦**：移动端点击按钮不会让输入框失焦，
    // "_onModelFocusChanged" 于是不触发，字段里留的还是上一个模型的值。
    await tester.enterText(find.byKey(const Key('model-field')), 'my-llm');
    await tester.pump();

    await tester.enterText(fieldWithLabel('配置名称 *'), '自建端点');
    await tester.enterText(fieldWithLabel('API Key *'), 'sk-test');
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.text('创建').first);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 300));
    // AppToast 的 3 秒定时器会一直产生 frame，收尾时主动收掉。
    AppToast.dismiss();

    final declared = AiGovernanceStore.forDatabase(db)
        .customCapability('deepseek', 'my-llm');
    // 保存前对齐过：声明写的是新模型的兜底值，不是上一个模型残留的 100 万上下文。
    expect(declared, isNotNull);
    expect(declared!.contextWindow, 8192);
    expect(declared.supportsStreaming, isTrue);
    expect(declared.supportsTools, isTrue);
  });

  testWidgets('新建配置不预选模型，未选模型时能力字段用未登记模型的兜底值', (tester) async {
    await pumpPage(tester);

    // 不预选内置默认值是刻意的：那份清单会过时（deepseek-chat 已不在 DeepSeek
    // 的模型列表里），预填等于让用户保存一个跑不通的模型。既然还没有模型，就只
    // 显示未登记模型的兜底值——流式/工具放行，否则任何新模型都跑不了工作模式；
    // 视觉与尺寸仍保守。
    expect(find.text('deepseek-chat'), findsNothing);
    expect(fieldText(tester, 'capability-context-window'), '8192');
    expect(fieldText(tester, 'capability-max-output'), '2048');
    expect(switchValue(tester, '流式'), isTrue);
    expect(switchValue(tester, '视觉'), isFalse);
    expect(switchValue(tester, '工具'), isTrue);
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
