enum ApiProvider {
  deepseek('DeepSeek', 'https://api.deepseek.com'),
  qwen('通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1'),
  zhipu('智谱AI', 'https://open.bigmodel.cn/api/paas/v4'),
  moonshot('Moonshot', 'https://api.moonshot.cn/v1'),
  baidu('百度文心', 'https://qianfan.baidubce.com/v2'),
  custom('自定义', '');

  final String label;
  final String baseUrl;

  const ApiProvider(this.label, this.baseUrl);

  String get apiPath => '/chat/completions';

  static const Map<String, List<String>> providerModels = {
    'deepseek': ['deepseek-chat', 'deepseek-reasoner'],
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
    'custom': [],
  };

  static const Map<String, String> defaultModels = {
    'deepseek': 'deepseek-chat',
    'qwen': 'qwen-plus',
    'zhipu': 'glm-4-plus',
    'moonshot': 'moonshot-v1-32k',
    'baidu': 'ernie-4.0-turbo-8k',
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
