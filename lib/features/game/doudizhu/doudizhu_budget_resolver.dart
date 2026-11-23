import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';

typedef DoudizhuBudgetResolver = int Function(
  ApiProvider provider,
  String model,
);
typedef DoudizhuInputBudgetResolver = int Function(
  ApiProvider provider,
  String model,
);

const int doudizhuFallbackMaxTokens = 1024;
const int doudizhuMaxOutputCeiling = 4096;

class RegistryDoudizhuBudgetResolver {
  RegistryDoudizhuBudgetResolver({
    ModelCapabilityRegistry? registry,
    CustomModelCapability? Function(String provider, String model)?
        customCapability,
  })  : _registry = registry ?? ModelCapabilityRegistry(),
        _customCapability = customCapability ?? ((_, __) => null);

  final ModelCapabilityRegistry _registry;
  final CustomModelCapability? Function(String provider, String model)
      _customCapability;

  int resolve(ApiProvider provider, String model) {
    final capability = _capability(provider, model);
    final output = ContextWindowManager.replyOutputBudget(
      contextWindow: capability.contextWindow,
      maxOutput: capability.maxOutput,
      replyCeiling: doudizhuMaxOutputCeiling,
    );
    return output > 0 ? output : doudizhuFallbackMaxTokens;
  }

  int resolveInputTokens(ApiProvider provider, String model) {
    final capability = _capability(provider, model);
    final output = ContextWindowManager.replyOutputBudget(
      contextWindow: capability.contextWindow,
      maxOutput: capability.maxOutput,
      replyCeiling: doudizhuMaxOutputCeiling,
    );
    return ContextWindowManager.inputBudget(
      contextWindow: capability.contextWindow,
      maxOutput: output,
    );
  }

  ModelCapability _capability(ApiProvider provider, String model) =>
      _registry.resolve(
        provider: provider,
        modelId: model,
        custom: _customCapability(provider.name, model),
      );
}
