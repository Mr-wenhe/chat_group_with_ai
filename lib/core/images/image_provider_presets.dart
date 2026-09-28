/// 生图服务商预设：一键带出服务地址前缀与常用模型建议。
///
/// 为什么要有预设：各家 OpenAI Images 兼容接口的**前缀不同**（OpenAI 是
/// `/v1`、智谱是 `/api/paas/v4`、火山是 `/api/v3`），让用户手填极易多填或
/// 漏填版本段，表现为 404 而非配置错误，极难自查。
///
/// [ImageProviderPreset.apiPrefix] 是**含版本段的完整前缀**，请求端点固定
/// 拼 `{apiPrefix}/images/generations`（见 `_generationsEndpoint`）。
library;

/// 预设列表里的「自定义」项 id。不在 [kImageProviderPresets] 内 ——
/// 它没有固定前缀，只是 UI 上给用户保留自由填空的入口。
const String kImageProviderPresetCustomId = 'custom';

/// 生图预览样张的固定 prompt。
///
/// 预览是**连通性/配置验证**，不是角色生成，因此用固定短 prompt：
/// 出图快、计费低，且不依赖任何角色字段。刻意不含人名与可变内容。
const String kImagePreviewPrompt =
    'A cute orange cat mascot, simple flat background, friendly smile, '
    'clean vector style, no text, no watermark';

class ImageProviderPreset {
  const ImageProviderPreset({
    required this.id,
    required this.label,
    required this.apiPrefix,
    this.sampleModels = const <String>[],
    this.modelHint = '',
    this.recommendedSize = '',
    this.recommendedQuality = '',
  });

  final String id;

  /// 设置页下拉里的显示名。
  final String label;

  /// 含版本段的完整 API 前缀（不含 `/images/generations`）。
  final String apiPrefix;

  /// 常用模型名，供模型输入框下的建议 chip 填充。
  ///
  /// **只收录能确认存在的型号**；不确定的厂商留空并用 [modelHint] 引导用户
  /// 按其控制台填写，宁可少给也不编造模型名（填错的表现同样是 404）。
  final List<String> sampleModels;

  /// 模型输入框的占位提示。
  final String modelHint;

  /// 选中本预设时一键带出的出图尺寸。
  ///
  /// **各家合法枚举不同，填错是 400 而不是配置错误**，因此预设直接带出该家
  /// 的合法值而不是让用户试。空串表示「不动用户已填的尺寸」（该厂商枚举不固定）。
  final String recommendedSize;

  /// 同 [recommendedSize]，对应质量档。智谱 `glm-image` 只支持 `hd`。
  final String recommendedQuality;
}

/// 内置服务商预设。
///
/// 顺序即下拉展示顺序：按「用户最可能用」排列，海外在前、国内在后。
const List<ImageProviderPreset> kImageProviderPresets = <ImageProviderPreset>[
  ImageProviderPreset(
    id: 'openai',
    label: 'OpenAI',
    apiPrefix: 'https://api.openai.com/v1',
    sampleModels: <String>['dall-e-3', 'gpt-image-1'],
    modelHint: 'dall-e-3',
    recommendedSize: '1024x1024',
    recommendedQuality: 'hd',
  ),
  ImageProviderPreset(
    id: 'zhipu',
    label: '智谱 BigModel',
    apiPrefix: 'https://open.bigmodel.cn/api/paas/v4',
    // `glm-image` 是智谱文档的当前主力型号；其余是 cogview 系列。
    sampleModels: <String>[
      'glm-image',
      'cogview-4-flash',
      'cogview-4-250304',
      'cogview-4',
      'cogview-3-flash',
    ],
    modelHint: 'glm-image',
    // glm-image 的合法枚举是 32 对齐值，默认 1280x1280；quality 只支持 hd。
    recommendedSize: '1280x1280',
    recommendedQuality: 'hd',
  ),
  ImageProviderPreset(
    id: 'dashscope',
    label: '通义 · DashScope 兼容模式',
    apiPrefix: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    modelHint: '填你已开通的万相模型名',
  ),
  ImageProviderPreset(
    id: 'ark',
    label: '火山方舟',
    apiPrefix: 'https://ark.cn-beijing.volces.com/api/v3',
    modelHint: '填 ARK 接入点 ID 或模型名',
  ),
];

/// 按 id 查预设；未知/自定义返回 null。
ImageProviderPreset? imageProviderPresetById(String id) {
  for (final preset in kImageProviderPresets) {
    if (preset.id == id) return preset;
  }
  return null;
}

/// 由已保存的服务地址反推服务商预设，用于下次进入设置页时还原下拉选中项。
///
/// 反推不出（用户改过地址、或用的是自定义）一律落到自定义项，
/// **绝不静默改写用户填的地址**。
String imageProviderPresetIdForPrefix(String apiPrefix) {
  final normalized = apiPrefix.trim().replaceAll(RegExp(r'/+$'), '');
  if (normalized.isEmpty) return kImageProviderPresetCustomId;
  for (final preset in kImageProviderPresets) {
    if (preset.apiPrefix == normalized) return preset.id;
  }
  return kImageProviderPresetCustomId;
}
