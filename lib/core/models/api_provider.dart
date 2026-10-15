import 'api_protocol.dart';

enum ApiProvider {
  deepseek('DeepSeek', 'https://api.deepseek.com'),
  qwen('通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1'),
  zhipu('智谱AI', 'https://open.bigmodel.cn/api/paas/v4'),
  moonshot('Moonshot', 'https://api.moonshot.cn/v1'),
  baidu('百度文心', 'https://qianfan.baidubce.com/v2'),
  xfyun('讯飞星火', 'https://spark-api-open.xf-yun.com/v1'),
  sensenova('商汤 SenseNova', 'https://token.sensenova.cn/v1'),

  /// Oray（聚合站）：只提供 Anthropic 原生协议，模型名带上游命名空间
  /// （`deepseek/deepseek-flash` 这类）。协议因此随提供商给默认值，而不是全站
  /// 统一按 OpenAI 兼容拼路径——否则选中它就会打到 `/v1/chat/completions`。
  oray(
    'Oray',
    'https://ai-api.orayer.com/v1',
    defaultProtocol: ApiProtocol.anthropicMessages,
  ),
  custom('自定义', '');

  final String label;
  final String baseUrl;

  /// 该提供商默认使用的上游协议。只有明确知道自己只支持某一种协议的提供商才
  /// 覆盖它，其余一律 OpenAI 兼容。表单切换提供商时据此预填。
  final ApiProtocol defaultProtocol;

  const ApiProvider(
    this.label,
    this.baseUrl, {
    this.defaultProtocol = ApiProtocol.defaultValue,
  });

  String get apiPath => '/chat/completions';

  /// Selection hints for built-in providers. Custom endpoint model IDs are
  /// entered by the user and are intentionally not constrained by this map.
  ///
  /// 这份清单是**候选**（拉不到 `/models` 时也能选），不再是表单的预填默认值。
  ///
  /// DeepSeek 与 SenseNova 的条目按 2026-10-15 对真实接口的实测修正过：`/models`
  /// 只列出 `deepseek-flash` 与 `deepseek-v4-pro`，但 `deepseek-chat` /
  /// `deepseek-reasoner` / `deepseek-v4-flash` 作为别名仍然可用（都返回 200），
  /// 所以都留着；SenseNova 的 `sensenova-6.7-flash-lite` 已 404，删掉。其余五家
  /// 没有可用凭据核实，保持原样，等有 Key 时再按实测更新。
  static const Map<String, List<String>> providerModels = {
    'deepseek': [
      'deepseek-flash',
      'deepseek-v4-pro',
      'deepseek-chat',
      'deepseek-reasoner',
      'deepseek-v4-flash',
    ],
    'qwen': [
      'qwen-turbo',
      'qwen-plus',
      'qwen-max',
      'qwen-long',
      'qwen-vl-max',
    ],
    'zhipu': [
      'glm-4.7',
      'glm4.7',
      'glm-4-plus',
      'glm-4-air',
      'glm-4-flash',
      'glm-4v-plus',
    ],
    'moonshot': ['moonshot-v1-8k', 'moonshot-v1-32k', 'moonshot-v1-128k'],
    'baidu': [
      'ernie-4.0-8k',
      'ernie-4.0-turbo-8k',
      'ernie-3.5-8k',
      'ernie-speed-128k',
      'ernie-lite-8k',
    ],
    'xfyun': ['spark-lite', 'spark-plus', 'spark-pro', 'spark-ultra'],
    'sensenova': [
      'sensenova-6.8-flash-lite',
      'sensenova-u1.5-lite',
      'deepseek-flash',
      'deepseek-v4-flash',
      'deepseek-v4.1-flash',
      'glm-5.2',
      'kimi-k3',
    ],
    'custom': [],
  };

  /// 兜底默认模型：只在**内置提供商 + 模型名为空**时使用（例如「测试连接」没有拿到
  /// 表单模型名）。表单不再用它预填——预填会让用户保存一个自己没选过的模型。
  /// DeepSeek 保持 `deepseek-chat`：实测仍可用，且是能力快照里有记录的那个
  /// （`deepseek-flash` 不在快照里，只能拿到 8192/2048 的兜底值）。
  /// Custom configurations never fall back to one of these values.
  static const Map<String, String> defaultModels = {
    'deepseek': 'deepseek-chat',
    'qwen': 'qwen-plus',
    'zhipu': 'glm-4-plus',
    'moonshot': 'moonshot-v1-32k',
    'baidu': 'ernie-4.0-turbo-8k',
    'xfyun': 'spark-lite',
    'sensenova': 'sensenova-6.8-flash-lite',
  };

  static String getBaseUrl(String providerName) {
    try {
      return ApiProvider.values
          .firstWhere((p) => p.name == providerName)
          .baseUrl;
    } catch (_) {
      return '';
    }
  }
}
