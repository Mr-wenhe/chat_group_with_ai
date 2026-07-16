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

  test('未知模型保守降级，自定义声明后使用声明值', () {
    final unknown = registry.resolve(
      provider: ApiProvider.custom,
      modelId: 'private-model',
    );
    expect(unknown.isKnown, isFalse);
    expect(unknown.supportsStreaming, isFalse);
    expect(unknown.supportsVision, isFalse);
    expect(unknown.supportsTools, isFalse);
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
      registry.resolve(provider: ApiProvider.qwen, modelId: 'qwen-max').supportsVision,
      isFalse,
    );
    expect(
      registry
          .resolve(provider: ApiProvider.zhipu, modelId: 'glm-4-flash')
          .supportsVision,
      isFalse,
    );
  });
}
