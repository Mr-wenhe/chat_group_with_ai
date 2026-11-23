// 五子棋预算 resolver 单测：按模型能力算输出预算，与聊天回复同一口径。
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/game/gomoku/gomoku_budget_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final resolver = RegistryGomokuBudgetResolver();

  group('按内置模型能力算预算', () {
    test('大窗口推理模型按上限给足（deepseek-reasoner → 4096）', () {
      final budget = resolver.resolve(ApiProvider.deepseek, 'deepseek-reasoner');
      expect(budget, kGomokuMaxOutputCeiling);
      expect(budget, greaterThan(kGomokuFallbackMaxTokens),
          reason: '推理模型需要比兜底 1024 更多的预算，否则思考吃光正文为空');
    });

    test('小窗口模型的预算不超过窗口一半', () {
      // moonshot-v1-8k：窗口 8192，预算应 <= 4096 且 <= 输出上限。
      final budget = resolver.resolve(ApiProvider.moonshot, 'moonshot-v1-8k');
      expect(budget, lessThanOrEqualTo(4096));
      expect(budget, greaterThan(0));
    });

    test('未登记模型走保守兜底', () {
      final budget = resolver.resolve(ApiProvider.custom, 'some-unknown-model');
      expect(budget, greaterThan(0));
      expect(budget, lessThanOrEqualTo(kGomokuMaxOutputCeiling));
    });
  });

  group('用户自定义能力', () {
    test('未登记模型用手写能力算预算', () {
      final r = RegistryGomokuBudgetResolver(
        customCapability: (_, __) => const CustomModelCapability(
          contextWindow: 8192,
          maxOutput: 512,
        ),
      );
      // 未登记模型没有内置快照，直接用手写值：min(ceiling 4096, window/2 4096)
      // = 4096，再被 maxOutput 512 clamp → 512。
      final budget = r.resolve(ApiProvider.custom, 'my-private-model');
      expect(budget, 512);
    });

    test('已登记模型取手写与内置能力的较大者（注册表语义）', () {
      final r = RegistryGomokuBudgetResolver(
        customCapability: (_, __) => const CustomModelCapability(
          contextWindow: 8192,
          maxOutput: 512,
        ),
      );
      // deepseek-reasoner 内置 output=8192 > 手写 512，注册表保留较大者，
      // 因此预算仍是上限 4096——这是注册表既有语义，不是 bug。
      final budget = r.resolve(ApiProvider.deepseek, 'deepseek-reasoner');
      expect(budget, kGomokuMaxOutputCeiling);
    });
  });
}
