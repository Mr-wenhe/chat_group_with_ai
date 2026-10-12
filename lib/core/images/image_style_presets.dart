/// IP 形象的画风预设：一句英文风格片段，直接拼进生图 prompt。
///
/// 为什么要预设：写死的 `Anime-inspired semi-realistic` 会让所有角色长成
/// 「差不多的动漫半身像」，画风与角色气质脱钩。风格是 IP 形象的稳定属性，
/// 因此选择持久化在 `AICharacter.ipImageStyle`，重新生成时保持一致。
library;

/// 「自动」项的 id：不指定画风，交给模型按人设自行决定。
const String kImageStyleAutoId = 'auto';

class ImageStylePreset {
  const ImageStylePreset({
    required this.id,
    required this.label,
    required this.promptClause,
  });

  final String id;

  /// 角色表单下拉里的显示名。
  final String label;

  /// 拼进 prompt 的英文风格片段（不含句号，由拼装处统一分隔）。
  ///
  /// 只写**画风**，不写构图/光影/安全后缀 —— 那些由 [buildIpPortraitPrompt] 的
  /// 固定框统一提供，避免每条预设各写一份后漏掉安全词。
  final String promptClause;
}

/// 内置画风预设。顺序即下拉展示顺序，「自动」永远在最前。
const List<ImageStylePreset> kImageStylePresets = <ImageStylePreset>[
  ImageStylePreset(
    id: kImageStyleAutoId,
    label: '自动（按人设决定）',
    promptClause: 'Anime-inspired semi-realistic style',
  ),
  ImageStylePreset(
    id: 'anime',
    label: '日系动漫',
    promptClause: 'Japanese anime style, cel shading, clean confident line art',
  ),
  ImageStylePreset(
    id: 'semiReal',
    label: '半写实',
    promptClause:
        'Anime-inspired semi-realistic style, painterly rendering, soft edges',
  ),
  ImageStylePreset(
    id: 'chibi',
    label: 'Q 版',
    promptClause:
        'Chibi style, oversized head, large expressive eyes, simplified features',
  ),
  ImageStylePreset(
    id: 'watercolor',
    label: '水彩',
    promptClause:
        'Soft watercolor illustration, gentle colour bleeding, subtle paper texture',
  ),
  ImageStylePreset(
    id: 'ink',
    label: '水墨',
    promptClause:
        'Chinese ink-wash painting style, sumi-e brush strokes, restrained palette',
  ),
  ImageStylePreset(
    id: 'cyberpunk',
    label: '赛博朋克',
    promptClause:
        'Cyberpunk illustration, neon rim lighting, futuristic tech accents',
  ),
  ImageStylePreset(
    id: 'realistic',
    label: '写实人像',
    promptClause:
        'Photorealistic portrait, detailed skin and fabric texture, natural depth of field',
  ),
];

/// 按 id 解析画风预设；未知/空值一律回落到「自动」。
///
/// 命名带 `resolve` 是因为它**不会返回 null**：风格只是画风偏好，存了脏 id
/// 或日后删掉了某个预设都不该让整次生成失败，因此把回落内置而不是抛错。
ImageStylePreset resolveImageStylePreset(String id) {
  for (final preset in kImageStylePresets) {
    if (preset.id == id) return preset;
  }
  return kImageStylePresets.first;
}
