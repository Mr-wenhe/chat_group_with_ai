import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/settings/model_catalog_picker.dart';
import 'package:chat_group/features/settings/widgets/model_capability_fields.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Base URL 起手值：存了的优先，否则用提供商预设', () {
    expect(
      initialBaseUrl(config: null, provider: ApiProvider.deepseek),
      'https://api.deepseek.com',
    );
    expect(
      initialBaseUrl(
        config: _config(baseUrl: 'https://api.deepseek.com/anthropic'),
        provider: ApiProvider.deepseek,
      ),
      'https://api.deepseek.com/anthropic',
    );
    // 新建自定义配置没有可预设的地址。
    expect(initialBaseUrl(config: null, provider: ApiProvider.custom), '');
  });

  test('拉到的清单排在最前，内置候选补在后，当前模型始终在列', () {
    final fetched = [
      const ProviderModelInfo(id: 'deepseek-flash', contextWindow: 1048576),
      const ProviderModelInfo(id: 'deepseek-v4-pro'),
    ];
    final choices = modelChoices(
      fetched: fetched,
      provider: ApiProvider.deepseek,
      currentModel: 'deepseek-flash',
    );

    expect(choices.first.id, 'deepseek-flash');
    expect(choices.first.contextWindow, 1048576);
    // 真实清单在前，内置候选（含可用别名）补在后且不重复。
    expect(
      choices.map((m) => m.id).toList(),
      [
        'deepseek-flash',
        'deepseek-v4-pro',
        'deepseek-chat',
        'deepseek-reasoner',
        'deepseek-v4-flash',
      ],
    );

    // 当前模型既不在真实清单也不在内置候选里（旧配置的失效模型）也要留着，
    // 否则用户打开选择面板看不到自己配的那个，会以为配置丢了。
    final stale = modelChoices(
      fetched: fetched,
      provider: ApiProvider.deepseek,
      currentModel: 'legacy-model',
    );
    expect(stale.first.id, 'legacy-model');
    expect(stale.where((m) => m.id == 'deepseek-flash'), hasLength(1));
  });

  test('没拉到清单时回落到内置候选', () {
    final choices = modelChoices(
      fetched: null,
      provider: ApiProvider.sensenova,
      currentModel: '',
    );
    expect(choices.map((m) => m.id), ApiProvider.providerModels['sensenova']);
  });

  test('能力回填只写上游给出了的字段', () {
    final controller = _capabilityController();
    applyFetchedCapability(
      controller,
      const ProviderModelInfo(
        id: 'deepseek-flash',
        contextWindow: 1048576,
        maxOutputTokens: 393216,
      ),
    );

    expect(controller.contextController.text, '1048576');
    expect(controller.outputController.text, '393216');
    // 上游没给模态，就不要替它猜：开关保持原样。
    expect(controller.supportsVision, isFalse);
  });

  test('上游只说模态时也只改模态', () {
    final controller =
        _capabilityController(contextWindow: 4096, maxOutput: 1024);
    applyFetchedCapability(
      controller,
      const ProviderModelInfo(id: 'm', supportsVision: true),
    );

    expect(controller.supportsVision, isTrue);
    expect(controller.contextController.text, '4096');
    expect(controller.outputController.text, '1024');
  });

  test('输出上限大于窗口时不写，避免把字段写成非法组合', () {
    final controller =
        _capabilityController(contextWindow: 8192, maxOutput: 2048);
    applyFetchedCapability(
      controller,
      const ProviderModelInfo(
        id: 'm',
        contextWindow: 1000,
        maxOutputTokens: 5000,
      ),
    );

    expect(controller.contextController.text, '1000');
    // 1000 窗口配 5000 输出是非法组合（declared 会整份判无效），宁可只写窗口。
    expect(controller.outputController.text, '2048');
  });
}

ModelCapabilityController _capabilityController({
  int contextWindow = 8192,
  int maxOutput = 2048,
}) =>
    ModelCapabilityController(ModelCapability(
      provider: 'custom',
      modelId: 'seed',
      isKnown: false,
      supportsStreaming: false,
      supportsVision: false,
      supportsTools: false,
      contextWindow: contextWindow,
      maxOutput: maxOutput,
      price: null,
      source: 'test',
      version: 'test',
      updatedAt: DateTime.utc(2026, 10, 15),
    ));

ApiConfig _config({required String baseUrl}) => ApiConfig(
      name: 'deepseek v4.1',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-flash',
      customBaseUrl: baseUrl,
    );
