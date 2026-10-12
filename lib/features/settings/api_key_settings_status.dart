/// 「API KEY 设置」页的状态摘要。
///
/// 全部是纯函数：输入取自各凭据存储的**只读**快照，输出一行给用户看的文案。
/// 这里既不读安全存储的明文，也不改任何配置 —— 它只回答「配没配、缺什么」，
/// 让用户在一屏内看清哪一类还没配好，再去对应的既有页面填写。
library;

import 'package:chat_group/core/audio/voice_catalog.dart';
import 'package:chat_group/core/audio/voice_service_config.dart';
import 'package:chat_group/core/images/image_service_config.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/features/web_search/models/search_provider_config.dart';

/// 凭据类别 id。「AI 接话选人器」不在 [ApiKeyOverview.countedCategories] 里，
/// 因为它不持有密钥，只引用已有配置的 id。
class ApiKeyCategory {
  const ApiKeyCategory._();

  static const String chat = 'chat';
  static const String speakerPicker = 'speakerPicker';
  static const String voice = 'voice';
  static const String image = 'image';
  static const String search = 'search';
}

/// 页面上一个条目的展示状态。
class ApiKeyStatusEntry {
  const ApiKeyStatusEntry({
    required this.id,
    required this.configured,
    required this.summary,
  });

  /// 类别 id，取值见 [ApiKeyCategory]。
  final String id;

  /// 是否已具备可用前提。只有真正持有密钥的类别才参与顶部计数。
  final bool configured;

  /// 一行副标题文案。
  final String summary;
}

/// 顶部进度：只统计**真正持有密钥**的类别。
///
/// 「AI 接话选人器」不持有 Key（它只引用已有配置的 id），计入分母会把
/// 「四类密钥都配好了」显示成 4/5，读起来像还缺一把密钥，于是它单独展示、
/// 不参与计数。
class ApiKeyOverview {
  const ApiKeyOverview(this.entries);

  final List<ApiKeyStatusEntry> entries;

  /// 参与计数的类别，顺序即页面上「对话 / 能力扩展 / 联网」的呈现顺序。
  static const List<String> countedCategories = <String>[
    ApiKeyCategory.chat,
    ApiKeyCategory.voice,
    ApiKeyCategory.image,
    ApiKeyCategory.search,
  ];

  int get total => countedCategories.length;

  int get configuredCount => entries
      .where(
          (entry) => countedCategories.contains(entry.id) && entry.configured)
      .length;

  bool get allConfigured => configuredCount == total;

  String get progressLabel => '密钥已配置 $configuredCount / $total 项';
}

/// 聊天与角色发言用的 API 配置。
///
/// 只要有一条绑定了 Key，角色就能发言 —— 因此按「至少一条可用」判定，
/// 而不是要求全部绑定。
ApiKeyStatusEntry chatStatus(List<ApiConfig> configs) {
  if (configs.isEmpty) {
    return const ApiKeyStatusEntry(
      id: ApiKeyCategory.chat,
      configured: false,
      summary: '尚未配置 · 角色无法回复消息',
    );
  }
  final bound = configs.where((config) => config.hasCredential).length;
  if (bound == 0) {
    return ApiKeyStatusEntry(
      id: ApiKeyCategory.chat,
      configured: false,
      summary: '${configs.length} 个配置 · 均未绑定 Key',
    );
  }
  if (bound == configs.length) {
    return ApiKeyStatusEntry(
      id: ApiKeyCategory.chat,
      configured: true,
      summary: '${configs.length} 个配置 · 全部已绑定 Key',
    );
  }
  return ApiKeyStatusEntry(
    id: ApiKeyCategory.chat,
    configured: true,
    summary: '${configs.length} 个配置 · $bound 个已绑定 Key',
  );
}

/// AI 接话选人器的当前选择。
///
/// 它不保存密钥，[configured] 只表示"引用可用"；页面上据此提示，不参与计数。
/// 引用失效（配置被删除、导入备份后指向不存在的 id、存储值损坏）一律按
/// "未选择"呈现，与实际行为一致：解析不到配置时不调用模型选人。
ApiKeyStatusEntry speakerPickerStatus({
  required String? selectedConfigId,
  required ApiConfig? selectedConfig,
}) {
  if (selectedConfigId == null) {
    return const ApiKeyStatusEntry(
      id: ApiKeyCategory.speakerPicker,
      configured: false,
      summary: '未选择 · 使用本地规则选人，不额外调用模型',
    );
  }
  if (selectedConfig == null) {
    return const ApiKeyStatusEntry(
      id: ApiKeyCategory.speakerPicker,
      configured: false,
      summary: '引用的配置已不存在 · 已回落本地规则，请重新选择',
    );
  }
  if (!selectedConfig.hasCredential) {
    return ApiKeyStatusEntry(
      id: ApiKeyCategory.speakerPicker,
      configured: false,
      summary: '${selectedConfig.name} · 缺少凭据，暂时回落本地规则',
    );
  }
  return ApiKeyStatusEntry(
    id: ApiKeyCategory.speakerPicker,
    configured: true,
    summary: '${selectedConfig.name} · ${selectedConfig.modelName}',
  );
}

/// 火山引擎语音服务（TTS / ASR）。
ApiKeyStatusEntry voiceStatus(VoiceServiceConfig config) {
  if (!config.apiKeyBound) {
    return const ApiKeyStatusEntry(
      id: ApiKeyCategory.voice,
      configured: false,
      summary: '未配置 · 语音播报与语音输入均不可用',
    );
  }
  if (config.ttsResourceId.trim().isEmpty) {
    return const ApiKeyStatusEntry(
      id: ApiKeyCategory.voice,
      configured: false,
      summary: '已绑定 Key · 缺少 TTS 资源 ID，无法合成语音',
    );
  }
  // 音色 id 可能来自已被移除的目录项；解析不到就按"未设默认音色"处理，
  // 与 `VoiceServiceConfig.resolveVoiceId` 的口径一致。
  final preset = voicePresetById(config.defaultVoiceId ?? '');
  if (preset == null) {
    return const ApiKeyStatusEntry(
      id: ApiKeyCategory.voice,
      configured: true,
      summary: '已绑定 Key · 未设默认音色（需逐角色选）',
    );
  }
  return ApiKeyStatusEntry(
    id: ApiKeyCategory.voice,
    configured: true,
    summary: '已绑定 Key · 默认音色 ${preset.name}',
  );
}

/// 图像服务（IP 形象生成）。
ApiKeyStatusEntry imageStatus(ImageServiceConfig config) {
  if (!config.apiKeyBound) {
    return const ApiKeyStatusEntry(
      id: ApiKeyCategory.image,
      configured: false,
      summary: '未配置 · 无法生成 IP 形象',
    );
  }
  if (config.baseUrl.trim().isEmpty || config.model.trim().isEmpty) {
    return const ApiKeyStatusEntry(
      id: ApiKeyCategory.image,
      configured: false,
      summary: '已绑定 Key · 缺少 baseUrl 或模型，无法出图',
    );
  }
  return ApiKeyStatusEntry(
    id: ApiKeyCategory.image,
    configured: true,
    summary: '已绑定 Key · ${config.model}',
  );
}

/// 联网搜索凭据：自建 Provider 与智谱原生搜索。
///
/// 两者任一条可用即算配置完成 —— 默认关闭的前提下，用户可能只用其中一种。
ApiKeyStatusEntry searchStatus(
  List<SearchProviderConfig> providers, {
  required bool zhipuNativeConfigured,
}) {
  if (providers.isEmpty && !zhipuNativeConfigured) {
    return const ApiKeyStatusEntry(
      id: ApiKeyCategory.search,
      configured: false,
      summary: '尚未配置 · 联网搜索不可用',
    );
  }
  final bound = providers.where((config) => config.hasCredential).length;
  final needsAttention =
      providers.where((config) => config.requiresAttention).length;
  // 「需要重新验证凭据」比「已绑定几条」更该被看见：恢复备份后绑定会失效，
  // 只报数量会让用户以为可以用。
  if (needsAttention > 0) {
    return ApiKeyStatusEntry(
      id: ApiKeyCategory.search,
      configured: bound > 0 || zhipuNativeConfigured,
      summary: '${providers.length} 个 Provider · $needsAttention 个需要重新验证凭据',
    );
  }
  if (providers.isEmpty) {
    return const ApiKeyStatusEntry(
      id: ApiKeyCategory.search,
      configured: true,
      summary: '仅智谱原生搜索 · 已绑定 Key',
    );
  }
  return ApiKeyStatusEntry(
    id: ApiKeyCategory.search,
    configured: bound > 0 || zhipuNativeConfigured,
    summary: '${providers.length} 个 Provider · $bound 个已绑定 Key',
  );
}
