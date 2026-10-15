import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:chat_group/features/settings/widgets/model_capability_fields.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final registry = ModelCapabilityRegistry();

  ModelCapability effectiveOf(
    ApiProvider provider,
    String model, [
    CustomModelCapability? custom,
  ]) =>
      registry.resolve(provider: provider, modelId: model, custom: custom);

  group('ModelCapabilityController', () {
    test('按生效值回填，而不是裸默认值', () {
      final capability = effectiveOf(ApiProvider.deepseek, 'deepseek-chat');
      final controller = ModelCapabilityController(capability);
      addTearDown(controller.dispose);

      // 裸默认值是「全关 + 8192/2048」，会把支持工具的 deepseek-chat 显示成降级态。
      expect(controller.contextController.text, '${capability.contextWindow}');
      expect(controller.outputController.text, '${capability.maxOutput}');
      expect(controller.supportsStreaming, capability.supportsStreaming);
      expect(controller.supportsVision, capability.supportsVision);
      expect(controller.supportsTools, capability.supportsTools);
      expect(controller.supportsTools, isTrue);
    });

    test('seed 重置整块字段，切模型后不残留上一个模型的值', () {
      final controller = ModelCapabilityController(
        effectiveOf(ApiProvider.deepseek, 'deepseek-chat'),
      );
      addTearDown(controller.dispose);
      controller.supportsTools = false;
      controller.contextController.text = '123';

      controller.seed(effectiveOf(ApiProvider.zhipu, 'glm-4-flash'));

      expect(controller.contextController.text, '131072');
      expect(controller.supportsTools, isTrue);
    });

    test('最大输出大于上下文或非正数时没有可写入的声明', () {
      final controller = ModelCapabilityController(
        effectiveOf(ApiProvider.deepseek, 'deepseek-chat'),
      );
      addTearDown(controller.dispose);

      controller.outputController.text = '99999999';
      expect(controller.declared, isNull);

      controller.outputController.text = '0';
      expect(controller.declared, isNull);

      controller.contextController.text = '';
      controller.outputController.text = '4096';
      expect(controller.declared, isNull);

      controller.contextController.text = '1000000';
      expect(controller.declared?.maxOutput, 4096);
    });
  });

  group('modelCapabilityPersistAction', () {
    ModelCapabilityPersistAction actionFor({
      required bool restoreBuiltin,
      required CustomModelCapability? declared,
      required ApiProvider provider,
      required String modelId,
      CustomModelCapability? stored,
    }) =>
        modelCapabilityPersistAction(
          restoreBuiltin: restoreBuiltin,
          declared: declared,
          stored: stored,
          registry: registry,
          provider: provider,
          modelId: modelId,
          effective: effectiveOf(provider, modelId, stored),
        );

    test('恢复内置默认优先于一切', () {
      expect(
        actionFor(
          restoreBuiltin: true,
          declared: const CustomModelCapability(supportsStreaming: true),
          provider: ApiProvider.deepseek,
          modelId: 'deepseek-chat',
        ),
        ModelCapabilityPersistAction.clear,
      );
    });

    test('草稿非法时不写', () {
      expect(
        actionFor(
          restoreBuiltin: false,
          declared: null,
          provider: ApiProvider.deepseek,
          modelId: 'deepseek-chat',
        ),
        ModelCapabilityPersistAction.keep,
      );
    });

    test('已登记模型：字段与生效值一致时不写', () {
      final effective = effectiveOf(ApiProvider.deepseek, 'deepseek-chat');
      expect(
        actionFor(
          restoreBuiltin: false,
          declared: CustomModelCapability(
            supportsStreaming: effective.supportsStreaming,
            supportsVision: effective.supportsVision,
            supportsTools: effective.supportsTools,
            contextWindow: effective.contextWindow,
            maxOutput: effective.maxOutput,
          ),
          provider: ApiProvider.deepseek,
          modelId: 'deepseek-chat',
        ),
        ModelCapabilityPersistAction.keep,
      );
    });

    test('未登记模型：草稿与兜底值一致也要落盘', () {
      // 兜底值只是默认、不是任何人做过的决定。不写就等于用户看着流式/工具开着、
      // 落盘却一份声明都没有——这正是「新建配置后两个开关没同步进配置」的成因。
      expect(
        actionFor(
          restoreBuiltin: false,
          declared: const CustomModelCapability(
            supportsStreaming: true,
            supportsTools: true,
            contextWindow: 8192,
            maxOutput: 2048,
          ),
          provider: ApiProvider.custom,
          modelId: 'my-llm',
        ),
        ModelCapabilityPersistAction.save,
      );
    });

    test('未登记模型已有声明时，草稿没改动就不重写', () {
      const stored = CustomModelCapability(
        supportsStreaming: true,
        supportsTools: true,
        contextWindow: 8192,
        maxOutput: 2048,
      );
      expect(
        actionFor(
          restoreBuiltin: false,
          declared: stored,
          stored: stored,
          provider: ApiProvider.custom,
          modelId: 'my-llm',
        ),
        ModelCapabilityPersistAction.keep,
      );
    });

    test('改动生效值就写', () {
      // 未登记模型的兜底是 8192/2048，声明一个更大的窗口会真的改变生效值。
      expect(
        actionFor(
          restoreBuiltin: false,
          declared: const CustomModelCapability(
            supportsStreaming: true,
            supportsTools: true,
            contextWindow: 32000,
            maxOutput: 4000,
          ),
          provider: ApiProvider.custom,
          modelId: 'my-llm',
        ),
        ModelCapabilityPersistAction.save,
      );
    });

    test('调低内置快照里的值不写：解析取较大值，写进去也不会生效', () {
      final effective = effectiveOf(ApiProvider.deepseek, 'deepseek-chat');
      expect(effective.contextWindow, 1000000);

      expect(
        actionFor(
          restoreBuiltin: false,
          declared: const CustomModelCapability(
            supportsStreaming: true,
            supportsTools: true,
            contextWindow: 500000,
            maxOutput: 8192,
          ),
          provider: ApiProvider.deepseek,
          modelId: 'deepseek-chat',
        ),
        ModelCapabilityPersistAction.keep,
      );
    });

    test('调高内置快照里的值就写', () {
      expect(
        actionFor(
          restoreBuiltin: false,
          declared: const CustomModelCapability(
            supportsStreaming: true,
            supportsTools: true,
            contextWindow: 2000000,
            maxOutput: 8192,
          ),
          provider: ApiProvider.deepseek,
          modelId: 'deepseek-chat',
        ),
        ModelCapabilityPersistAction.save,
      );
    });

    test('关掉流式会写：这是会把工作模式挡在外面的改动', () {
      expect(
        actionFor(
          restoreBuiltin: false,
          declared: const CustomModelCapability(
            supportsTools: true,
            contextWindow: 1000000,
            maxOutput: 8192,
          ),
          provider: ApiProvider.deepseek,
          modelId: 'deepseek-chat',
        ),
        ModelCapabilityPersistAction.save,
      );
    });
  });
}
