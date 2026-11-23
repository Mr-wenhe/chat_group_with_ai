/// 五子棋 AI 落子的输出预算：按模型能力（上下文窗口 / 最大输出）计算。
///
/// 复用 App 已有的模型能力注册表与上下文预算公式——与聊天回复同一套口径，
/// 避免游戏里另起一套「拍脑袋」的数字。推理模型在 1024 下会把整份预算花在
/// 思考上、正文为空（现场 finishReason=length / reasoningTokens=completionTokens）；
/// 这里按窗口给足预算，配合 JSON-first prompt 让模型先写坐标。
library;

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';

/// 按 (provider, model) 解析本次落子可用的输出 token 预算。
typedef GomokuBudgetResolver = int Function(ApiProvider provider, String model);

/// 默认兜底预算：拿不到模型能力时的保守值（够写一个坐标 JSON）。
const int kGomokuFallbackMaxTokens = 1024;

/// 落子输出预算的上限：五子棋答案只要一个坐标 + 一句想法，
/// 即使模型窗口很大也不该为一步棋申请过多输出（成本/延迟都划不来）。
const int kGomokuMaxOutputCeiling = 4096;

/// 基于治理侧能力注册表实现 [GomokuBudgetResolver]。
///
/// [customCapability] 读取用户在设置里手写的模型能力（可为 null）；
/// 其余走内置快照。[registry] 可注入便于单测。
class RegistryGomokuBudgetResolver {
  final ModelCapabilityRegistry _registry;
  final CustomModelCapability? Function(String provider, String model)
      _customCapability;

  RegistryGomokuBudgetResolver({
    ModelCapabilityRegistry? registry,
    CustomModelCapability? Function(String provider, String model)?
        customCapability,
  })  : _registry = registry ?? ModelCapabilityRegistry(),
        _customCapability = customCapability ?? ((_, __) => null);

  /// 按模型能力算出落子预算。
  ///
  /// 与聊天私聊回复同一公式：预算不超过窗口的一半（给输入留空间），
  /// 也不超过 [kGomokuMaxOutputCeiling]；小窗口模型自动收到较小的预算。
  int resolve(ApiProvider provider, String model) {
    final capability = _registry.resolve(
      provider: provider,
      modelId: model,
      custom: _customCapability(provider.name, model),
    );
    final budget = ContextWindowManager.replyOutputBudget(
      contextWindow: capability.contextWindow,
      maxOutput: capability.maxOutput,
      replyCeiling: kGomokuMaxOutputCeiling,
    );
    return budget > 0 ? budget : kGomokuFallbackMaxTokens;
  }
}
