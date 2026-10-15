import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:chat_group/features/ai_governance/money_micros.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final registry = ModelCapabilityRegistry();

  test('同 provider 按 modelId 区分视觉能力', () {
    expect(
      registry
          .resolve(provider: ApiProvider.qwen, modelId: 'qwen-plus')
          .supportsVision,
      isFalse,
    );
    expect(
      registry
          .resolve(provider: ApiProvider.qwen, modelId: 'qwen-vl-max')
          .supportsVision,
      isTrue,
    );
    expect(
      registry
          .resolve(provider: ApiProvider.zhipu, modelId: 'glm-4-plus')
          .supportsVision,
      isFalse,
    );
    expect(
      registry
          .resolve(provider: ApiProvider.zhipu, modelId: 'glm-4v-plus')
          .supportsVision,
      isTrue,
    );
  });

  test('未登记模型放行流式与工具，视觉与尺寸仍保守，自定义声明后使用声明值', () {
    final unknown = registry.resolve(
      provider: ApiProvider.custom,
      modelId: 'private-model',
    );
    expect(unknown.isKnown, isFalse);
    // 这两个开关同时是工作模式的启动闸门：兜底全关会让任何没进快照的模型都跑不了
    // 工作模式，用户必须先到治理页手写一份声明。
    expect(unknown.supportsStreaming, isTrue);
    expect(unknown.supportsTools, isTrue);
    // 把图片发给未必支持的端点只会换来一次 400，不跟着放行。
    expect(unknown.supportsVision, isFalse);
    expect(unknown.contextWindow, 8192);
    expect(unknown.maxOutput, 2048);
    expect(unknown.price, isNull);

    final declared = registry.resolve(
      provider: ApiProvider.custom,
      modelId: 'private-model',
      custom: const CustomModelCapability(
        supportsStreaming: true,
        supportsVision: true,
        supportsTools: true,
        contextWindow: 32000,
        maxOutput: 4000,
      ),
    );
    expect(declared.isKnown, isTrue);
    expect(declared.supportsVision, isTrue);
    expect(declared.contextWindow, 32000);
    expect(declared.price, isNull);
  });

  test('价格计算使用整数微美元并保存版本', () {
    final capability = registry.resolve(
      provider: ApiProvider.deepseek,
      modelId: 'deepseek-chat',
    );
    expect(capability.price?.version, 'deepseek-usd-2026-06');
    expect(
      capability.price!.estimateMicros(
        inputTokens: 1000000,
        cachedInputTokens: 500000,
        outputTokens: 1000000,
      ),
      1270000,
    );
  });

  test('DeepSeek v4 models are selectable and support streaming requests', () {
    const models = ['deepseek-v4-pro', 'deepseek-v4-flash'];
    final selectableModels = ApiProvider.providerModels['deepseek']!;

    for (final model in models) {
      expect(selectableModels, contains(model));
      final capability = registry.resolve(
        provider: ApiProvider.deepseek,
        modelId: model,
      );
      expect(capability.isKnown, isTrue, reason: model);
      expect(capability.supportsStreaming, isTrue, reason: model);
    }
  });

  test('预算金额字符串确定性转换为微美元', () {
    expect(MoneyMicros.parseUsd('1'), 1000000);
    expect(MoneyMicros.parseUsd('0.000001'), 1);
    expect(MoneyMicros.parseUsd(''), isNull);
    expect(() => MoneyMicros.parseUsd('1.0000001'), throwsFormatException);
  });

  test('补全的常见视觉模型 ID 在注册表标记为支持视觉', () {
    final visionModels = <(String, String)>[
      ('qwen', 'qwen-vl-plus'),
      ('qwen', 'qwen-vl-max-2024-08-09'),
      ('qwen', 'qwen-vl-max-latest'),
      ('qwen', 'qwen2.5-vl-max'),
      ('zhipu', 'glm-4v'),
      ('zhipu', 'glm-4v-flash'),
      ('deepseek', 'deepseek-vl-7b'),
      ('deepseek', 'deepseek-vl2'),
      ('moonshot', 'moonshot-v1-8k-vision'),
      ('moonshot', 'kimi-vl-a3b-thinking'),
    ];
    for (final (providerName, modelId) in visionModels) {
      final provider = ApiProvider.values.firstWhere(
        (p) => p.name == providerName,
        orElse: () => ApiProvider.custom,
      );
      expect(
        registry.resolve(provider: provider, modelId: modelId).supportsVision,
        isTrue,
        reason: '$providerName/$modelId',
      );
    }
    // 纯文本模型仍保持不支持视觉，带图应被拦截（既有断言不受影响）。
    expect(
      registry
          .resolve(provider: ApiProvider.qwen, modelId: 'qwen-max')
          .supportsVision,
      isFalse,
    );
    expect(
      registry
          .resolve(provider: ApiProvider.zhipu, modelId: 'glm-4-flash')
          .supportsVision,
      isFalse,
    );
  });

  test('自定义能力与内置取较大值，避免旧配置被误拦截', () {
    final resolved = registry.resolve(
      provider: ApiProvider.deepseek,
      modelId: 'deepseek-chat',
      custom: const CustomModelCapability(
        supportsStreaming: true,
        supportsVision: false,
        supportsTools: false,
        contextWindow: 200000,
        maxOutput: 1024,
      ),
    );
    expect(resolved.contextWindow, 1000000);
    expect(resolved.supportsStreaming, isTrue);
    expect(resolved.supportsVision, isFalse);
    expect(resolved.source, contains('用户声明'));
  });

  test('纯未知模型的自定义能力不使用内置值', () {
    final resolved = registry.resolve(
      provider: ApiProvider.custom,
      modelId: 'my-private-model',
      custom: const CustomModelCapability(
        supportsStreaming: true,
        supportsVision: false,
        supportsTools: false,
        contextWindow: 32000,
        maxOutput: 4000,
      ),
    );
    expect(resolved.contextWindow, 32000);
    expect(resolved.supportsStreaming, isTrue);
    expect(resolved.price, isNull);
  });
}
