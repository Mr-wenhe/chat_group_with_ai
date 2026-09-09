enum ApiProvider {
  deepseek('DeepSeek', 'https://api.deepseek.com'),
  qwen('通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1'),
  zhipu('智谱AI', 'https://open.bigmodel.cn/api/paas/v4'),
  moonshot('Moonshot', 'https://api.moonshot.cn/v1'),
  baidu('百度文心', 'https://qianfan.baidubce.com/v2'),
  xfyun('讯飞星火', 'https://spark-api-open.xf-yun.com/v1'),
  sensenova('商汤 SenseNova', 'https://token.sensenova.cn/v1'),
  custom('自定义', '');

  final String label;
  final String baseUrl;

  const ApiProvider(this.label, this.baseUrl);

  String get apiPath => '/chat/completions';

  /// Selection hints for built-in providers. Custom endpoint model IDs are
  /// entered by the user and are intentionally not constrained by this map.
  static const Map<String, List<String>> providerModels = {
    'deepseek': [
      'deepseek-chat',
      'deepseek-reasoner',
      'deepseek-v4-pro',
      'deepseek-v4-flash',
    ],
    'qwen': [
      'qwen-turbo',
      'qwen-plus',
      'qwen-max',
      'qwen-long',
      'qwen-vl-max',
    ],
    'zhipu': ['glm-4-plus', 'glm-4-air', 'glm-4-flash', 'glm-4v-plus'],
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
      'sensenova-6.7-flash-lite',
    ],
    'custom': [],
  };

  /// Defaults used only when a built-in provider has no stored model yet.
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
