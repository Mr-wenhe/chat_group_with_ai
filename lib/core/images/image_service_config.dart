/// 全局图像服务配置（OpenAI Images 兼容文生图，用于 IP 形象）。
///
/// 这是「设置 → 图像服务」里唯一的一份全局配置，**不复用**角色的 `ApiConfig`
/// （那是聊天补全服务，模型未必有生图能力）：
/// - API Key 存安全存储（[CredentialRepository]），本模型只记录「是否已绑定」
///   布尔位，绝不落明文；
/// - 其余字段存 `app_settings` box 的单个 Map（见 [DatabaseService] 扩展）。
///
/// 与语音服务（`volcVoiceCredentialId`）同构：固定凭据 id + 单 Map 配置。
library;

import 'package:chat_group/core/images/image_provider_presets.dart';

/// 图像 API Key 在安全存储中的固定凭据 id（经 CredentialRepository 存取）。
const String imageServiceCredentialId = 'image.openai-compatible';

/// `app_settings` box 中本配置的存储 key。
const String imageServiceSettingsKey = 'image_generation_service';

/// 一次生成的图片张数。IP 形象一次只出一张，不做候选。
const int kImageGenerationCount = 1;

const String kDefaultImageSize = '1024x1024';

/// 出图分辨率的**地板**：任何一条边低于此值一律不发。
///
/// 实测（2026-09）：`512x512` 下构图彻底崩塌 —— 头和头发涨出画框、脸被挤到
/// 画面外，出来就是一片发丝。三个角色 11 张图无一例外，而 prompt 里脸部词量是
/// 头发的六倍、开头就是「一个人」，且模型确实画得出人（有图能看到孩子的眉眼被
/// 压在画面最下缘）——它不是没读懂 prompt，是**装不下**。
///
/// 生图模型的构图能力与训练分辨率强绑定：低于训练网格，它还有能力画纹理（发丝
/// 画得极好），却没有能力安排构图，于是只渲染它最擅长的那一块并把它放大到占满
/// 画布。glm-image 的合法区间是 1024–2048，`512x512` 在地板之下。
///
/// 地板设在**解析层**而不只是删掉一个下拉项：已存的脏配置、手填值、日后新加进
/// 下拉的选项都走同一道闸门。`512x512` 曾作为选项提供过，用户一选就中招。
const int kImageMinSizePixels = 1024;

/// 可选出图尺寸。**各家模型的合法枚举不同**，选错的表现是 400 而非配置错误：
/// - OpenAI dall-e-3：`1024x1024` / `1024x1792` / `1792x1024`
/// - 智谱 glm-image：`1280x1280`（默认）/ `1056x1568` / `1568x1056` 等 32 对齐值；
///   自定义需 1024–2048px 且 32 的整数倍
/// - 通义万相 / 火山方舟另有枚举，见各自文档
/// 因此由服务商预设带出建议值（见 [ImageProviderPreset.recommendedSize]）。
///
/// **每一项都必须不低于 [kImageMinSizePixels]**，新增前先确认该家接受它。
const List<String> kImageSizeOptions = <String>[
  '1024x1024',
  '1024x1792',
  '1792x1024',
  '1280x1280',
  '1056x1568',
  '1568x1056',
];

/// 把任意来源的尺寸收成「一定发得出去、也一定画得出构图」的值。
///
/// 只守**地板与 `宽x高` 形状**，不校验各家枚举：枚举因型号而异且会变，而
/// 「某条边小于 [kImageMinSizePixels]」是所有型号上都只会产出废图的错误。
/// 合法但不在下拉里的自定义值（如 `1472x1088`）原样保留，不强行改写。
///
/// [baseUrl] 用于查服务商预设的建议尺寸：非法值优先落到该家的建议值而不是
/// 一律 [kDefaultImageSize] —— 智谱 glm-image 的原生默认是 `1280x1280`。
String normalizeImageSize(String raw, {String baseUrl = ''}) {
  final size = raw.trim();
  if (_isGeneratableSize(size)) return size;
  final preset =
      imageProviderPresetById(imageProviderPresetIdForPrefix(baseUrl));
  final recommended = preset?.recommendedSize ?? '';
  return _isGeneratableSize(recommended) ? recommended : kDefaultImageSize;
}

/// `宽x高` 且两条边都不低于 [kImageMinSizePixels]。
bool _isGeneratableSize(String size) {
  final match = RegExp(r'^(\d+)x(\d+)$').firstMatch(size);
  if (match == null) return false;
  return int.parse(match.group(1)!) >= kImageMinSizePixels &&
      int.parse(match.group(2)!) >= kImageMinSizePixels;
}

/// 可选质量档。**空字符串表示「不发送 quality 字段」** —— 通义/智谱等兼容
/// 实现会拒绝未知字段，默认不发以最大化兼容；dall-e-3 用户可自填 standard/hd。
const List<String> kImageQualityOptions = <String>['', 'standard', 'hd'];

/// 一份全局图像服务配置（不可变）。
class ImageServiceConfig {
  const ImageServiceConfig({
    this.baseUrl = '',
    this.model = '',
    this.size = kDefaultImageSize,
    this.quality = '',
    this.disableWatermark = false,
    this.apiKeyBound = false,
  });

  /// 空配置（未在设置页保存过任何内容时的初值）。
  static const ImageServiceConfig empty = ImageServiceConfig();

  /// 含版本段的完整 API 前缀，端点为 `{baseUrl}/images/generations`。
  ///
  /// 例：OpenAI `https://api.openai.com/v1`、智谱 `https://open.bigmodel.cn/api/paas/v4`、
  /// 火山 `https://ark.cn-beijing.volces.com/api/v3`。只有域名没有路径时会自动补
  /// `/v1`，见 [generationsEndpoint]。设置页由服务商预设一键带出（见
  /// `image_provider_presets.dart`）。
  final String baseUrl;

  /// 生图模型名，如 `dall-e-3` / `cogview-4-flash` / `wanx-v1`。
  final String model;

  /// 出图尺寸，取值见 [kImageSizeOptions]。
  final String size;

  /// 质量档，取值见 [kImageQualityOptions]；空串表示不发送该字段。
  final String quality;

  /// 是否在请求里显式关闭厂商水印（智谱 `watermark_enabled: false`）。
  ///
  /// 默认 false = **不发送该字段**：OpenAI 等实现不认它，发了可能被拒；而智谱
  /// `glm-image` 的默认值是 `true`，出图带显式 AI 水印，当头像很影响观感。
  /// 智谱侧关水印需先到「个人中心 → 安全管理 → 去水印管理」签署免责声明，
  /// 否则请求会被拒 —— 因此做成显式开关，而不是无条件发送。
  final bool disableWatermark;

  /// 是否已在安全存储绑定 API Key（模型内仅存该布尔位，不存密钥）。
  final bool apiKeyBound;

  /// 是否至少满足可用的基本前提：绑定了 Key 且 baseUrl / 模型非空。
  bool get isConfigured =>
      apiKeyBound && baseUrl.trim().isNotEmpty && model.trim().isNotEmpty;

  ImageServiceConfig copyWith({
    String? baseUrl,
    String? model,
    String? size,
    String? quality,
    bool? disableWatermark,
    bool? apiKeyBound,
  }) {
    return ImageServiceConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      size: size ?? this.size,
      quality: quality ?? this.quality,
      disableWatermark: disableWatermark ?? this.disableWatermark,
      apiKeyBound: apiKeyBound ?? this.apiKeyBound,
    );
  }

  Map<String, dynamic> toMap() => {
        'baseUrl': baseUrl,
        'model': model,
        'size': size,
        'quality': quality,
        'disableWatermark': disableWatermark,
        'apiKeyBound': apiKeyBound,
      };

  factory ImageServiceConfig.fromMap(Object? raw) {
    final map =
        raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    // 尾部 `/` 统一去掉，避免拼出 `//images/generations`。
    // 注意 `String.trimRight()` 只去空白，必须用正则剥斜杠。
    final baseUrl =
        map['baseUrl']?.toString().trim().replaceAll(RegExp(r'/+$'), '') ?? '';
    return ImageServiceConfig(
      baseUrl: baseUrl,
      model: map['model']?.toString().trim() ?? '',
      // 尺寸在这里就收口：已存的非法值（如曾作为选项提供过的 512x512）读回即
      // 自愈成该服务商的建议值。不靠用户进一次设置页才发现出图是废的 —— 大多数
      // 人只会反复重新生成，然后归因到 prompt 上（实测就是如此）。
      size: normalizeImageSize(map['size']?.toString() ?? '', baseUrl: baseUrl),
      quality: map['quality']?.toString().trim() ?? '',
      // 旧配置缺该键时读作 false（不发送），保持既有行为不变。
      disableWatermark: map['disableWatermark'] == true,
      apiKeyBound: map['apiKeyBound'] == true,
    );
  }
}
