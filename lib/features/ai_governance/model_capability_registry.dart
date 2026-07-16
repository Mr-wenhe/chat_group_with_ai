import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';

/// 模型能力注册表（built-in 快照）。
///
/// 这是随应用发布的厂商文档快照，版本 [_version] = `builtin-2026-07-16`
/// （[_snapshotDate] = 2026-07-16）。当前为静态硬编码，未来若有在线更新
/// 机制再扩展；更新时请同步 bump 版本与日期，并在 [resolve] 中保留用户声明
/// 的 [CustomModelCapability] 优先级（见 [ModelCapabilityRegistry.resolve]）。
class ModelCapabilityRegistry {
  static final DateTime _snapshotDate = DateTime.utc(2026, 7, 16);
  static const String _version = 'builtin-2026-07-16';

  ModelCapability resolve({
    required ApiProvider provider,
    required String modelId,
    CustomModelCapability? custom,
  }) {
    final normalized = modelId.trim().toLowerCase();
    if (custom != null) {
      return ModelCapability(
        provider: provider.name,
        modelId: modelId,
        isKnown: true,
        supportsStreaming: custom.supportsStreaming,
        supportsVision: custom.supportsVision,
        supportsTools: custom.supportsTools,
        contextWindow: custom.contextWindow,
        maxOutput: custom.maxOutput,
        price: null,
        source: '用户声明',
        version: 'custom-local',
        updatedAt: _snapshotDate,
      );
    }
    final spec = _specs['${provider.name}/$normalized'];
    if (spec != null) return spec(modelId);
    return ModelCapability(
      provider: provider.name,
      modelId: modelId,
      isKnown: false,
      supportsStreaming: false,
      supportsVision: false,
      supportsTools: false,
      contextWindow: 8192,
      maxOutput: 2048,
      price: null,
      source: '未知模型：保守降级',
      version: _version,
      updatedAt: _snapshotDate,
    );
  }

  static ModelCapability Function(String) _text({
    required String provider,
    required int context,
    int output = 8192,
    bool tools = true,
    ModelPrice? price,
    String source = '随应用发布的厂商文档快照',
  }) {
    return (modelId) => ModelCapability(
          provider: provider,
          modelId: modelId,
          isKnown: true,
          supportsStreaming: true,
          supportsVision: false,
          supportsTools: tools,
          contextWindow: context,
          maxOutput: output,
          price: price,
          source: source,
          version: _version,
          updatedAt: _snapshotDate,
        );
  }

  static ModelCapability Function(String) _vision({
    required String provider,
    required int context,
    int output = 8192,
    bool tools = true,
  }) {
    final text = _text(
      provider: provider,
      context: context,
      output: output,
      tools: tools,
    );
    return (modelId) {
      final base = text(modelId);
      return ModelCapability(
        provider: base.provider,
        modelId: base.modelId,
        isKnown: true,
        supportsStreaming: true,
        supportsVision: true,
        supportsTools: base.supportsTools,
        contextWindow: base.contextWindow,
        maxOutput: base.maxOutput,
        price: base.price,
        source: base.source,
        version: base.version,
        updatedAt: base.updatedAt,
      );
    };
  }

  static const _deepSeekChatPrice = ModelPrice(
    currency: 'USD',
    inputMicrosPerMillion: 270000,
    cachedInputMicrosPerMillion: 70000,
    outputMicrosPerMillion: 1100000,
    version: 'deepseek-usd-2026-06',
  );
  static const _deepSeekReasonerPrice = ModelPrice(
    currency: 'USD',
    inputMicrosPerMillion: 550000,
    cachedInputMicrosPerMillion: 140000,
    outputMicrosPerMillion: 2190000,
    version: 'deepseek-usd-2026-06',
  );

  static final Map<String, ModelCapability Function(String)> _specs = {
    'deepseek/deepseek-chat': _text(
      provider: 'deepseek',
      context: 65536,
      price: _deepSeekChatPrice,
      source: 'DeepSeek API Docs 价格与模型快照',
    ),
    'deepseek/deepseek-reasoner': _text(
      provider: 'deepseek',
      context: 65536,
      output: 8192,
      price: _deepSeekReasonerPrice,
      source: 'DeepSeek API Docs 价格与模型快照',
    ),
    for (final model in [
      'deepseek-vl',
      'deepseek-vl-1.3b',
      'deepseek-vl-7b',
      'deepseek-vl2',
      'deepseek-vl2-small',
      'deepseek-vl2-tiny',
    ])
      'deepseek/$model': _vision(provider: 'deepseek', context: 65536),
    for (final model in ['qwen-turbo', 'qwen-plus', 'qwen-max'])
      'qwen/$model': _text(provider: 'qwen', context: 131072),
    'qwen/qwen-long': _text(provider: 'qwen', context: 1000000),
    for (final model in [
      'qwen-vl-max',
      'qwen-vl-plus',
      'qwen-vl-max-2024-08-09',
      'qwen-vl-max-latest',
      'qwen2.5-vl-max',
      'qwen2.5-vl-7b-instruct',
      'qwen2.5-vl-32b-instruct',
      'qwen2.5-vl-72b-instruct',
      'qwen-vl-ocr',
      'qwen-vl-ocr-latest',
    ])
      'qwen/$model': _vision(provider: 'qwen', context: 131072),
    for (final model in ['glm-4-plus', 'glm-4-air', 'glm-4-flash'])
      'zhipu/$model': _text(provider: 'zhipu', context: 131072),
    for (final model in ['glm-4v-plus', 'glm-4v', 'glm-4v-flash'])
      'zhipu/$model': _vision(provider: 'zhipu', context: 8192),
    'moonshot/moonshot-v1-8k': _text(provider: 'moonshot', context: 8192),
    'moonshot/moonshot-v1-32k': _text(provider: 'moonshot', context: 32768),
    'moonshot/moonshot-v1-128k': _text(provider: 'moonshot', context: 131072),
    for (final model in [
      'moonshot-v1-8k-vision',
      'moonshot-v1-32k-vision',
      'moonshot-v1-128k-vision',
      'kimi-vl-a3b-thinking',
      'kimi-vl-a3b',
    ])
      'moonshot/$model': _vision(provider: 'moonshot', context: 32768),
    'baidu/ernie-4.0-8k': _text(provider: 'baidu', context: 8192),
    'baidu/ernie-4.0-turbo-8k': _text(provider: 'baidu', context: 8192),
    'baidu/ernie-3.5-8k': _text(provider: 'baidu', context: 8192),
    'baidu/ernie-speed-128k': _text(provider: 'baidu', context: 131072),
    'baidu/ernie-lite-8k': _text(provider: 'baidu', context: 8192),
    'xfyun/spark-lite': _text(provider: 'xfyun', context: 8192),
    'xfyun/spark-plus': _text(provider: 'xfyun', context: 32768),
    'xfyun/spark-pro': _text(provider: 'xfyun', context: 131072),
    'xfyun/spark-ultra': _text(provider: 'xfyun', context: 131072),
  };
}
