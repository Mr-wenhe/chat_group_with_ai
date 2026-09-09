/// 全局语音服务配置（火山引擎流式 TTS / ASR）。
///
/// 这是「设置 → API 配置 → 语音服务」里唯一的一份全局配置：
/// - API Key 存安全存储（[CredentialRepository] 前缀 `credential.api-config.`），
///   本模型只记录「是否已绑定」布尔位，绝不落明文；
/// - 其余字段存 `app_settings` box 的单个 Map（见 [DatabaseService] 的读写）。
///
/// 音色与角色的关系：`defaultVoiceId` 是兜底音色 —— 某个角色没单独指定
/// 音色（[AICharacter.voiceId] 为空）时用它来 TTS。
library;

import 'voice_catalog.dart';

/// TTS 资源的常见取值（火山 seed-tts 大模型语音合成）。
const String volcTtsDefaultResourceId = 'seed-tts-1.0';

/// ASR 资源的常见取值（SAUC 时长计费版流式语音识别）。
const String volcAsrDefaultResourceId = 'volc.bigasr.sauc.duration';

/// 语音 Key 在安全存储中的固定凭据 id（经 CredentialRepository 存取）。
const String volcVoiceCredentialId = 'voice.volcengine';

/// `app_settings` box 中本配置的存储 key。
const String voiceServiceSettingsKey = 'volc_voice_service';

/// 一份全局语音服务配置（不可变）。
class VoiceServiceConfig {
  const VoiceServiceConfig({
    this.ttsResourceId = volcTtsDefaultResourceId,
    this.asrResourceId = volcAsrDefaultResourceId,
    this.defaultVoiceId,
    this.apiKeyBound = false,
  });

  /// 空配置（未在设置页保存过任何内容时的初值）。
  static const VoiceServiceConfig empty = VoiceServiceConfig();

  /// 语音合成资源 ID（TTS）。
  final String ttsResourceId;

  /// 语音识别资源 ID（ASR）。
  final String asrResourceId;

  /// 兜底音色 id；为 null 表示未配置默认音色。
  final String? defaultVoiceId;

  /// 是否已在安全存储绑定 API Key（模型内仅存该布尔位，不存密钥）。
  final bool apiKeyBound;

  /// 是否至少满足可用的基本前提：绑定了 Key 且有 TTS 资源。
  bool get isConfigured => apiKeyBound && ttsResourceId.trim().isNotEmpty;

  VoiceServiceConfig copyWith({
    String? ttsResourceId,
    String? asrResourceId,
    String? Function()? defaultVoiceId,
    bool? apiKeyBound,
  }) {
    return VoiceServiceConfig(
      ttsResourceId: ttsResourceId ?? this.ttsResourceId,
      asrResourceId: asrResourceId ?? this.asrResourceId,
      defaultVoiceId:
          defaultVoiceId != null ? defaultVoiceId() : this.defaultVoiceId,
      apiKeyBound: apiKeyBound ?? this.apiKeyBound,
    );
  }

  /// 解析可用的音色 id：优先 [voiceId]，其次全局 [defaultVoiceId]。
  static String? resolveVoiceId(String? voiceId, VoiceServiceConfig config) {
    final candidate = (voiceId != null && voiceId.trim().isNotEmpty)
        ? voiceId
        : config.defaultVoiceId;
    if (candidate == null || candidate.trim().isEmpty) return null;
    return voicePresetById(candidate) != null ? candidate : null;
  }

  Map<String, dynamic> toMap() => {
        'ttsResourceId': ttsResourceId,
        'asrResourceId': asrResourceId,
        if (defaultVoiceId != null && defaultVoiceId!.isNotEmpty)
          'defaultVoiceId': defaultVoiceId,
        'apiKeyBound': apiKeyBound,
      };

  factory VoiceServiceConfig.fromMap(Object? raw) {
    final map =
        raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    final tts = map['ttsResourceId']?.toString().trim() ?? '';
    final asr = map['asrResourceId']?.toString().trim() ?? '';
    final voice = map['defaultVoiceId']?.toString().trim();
    return VoiceServiceConfig(
      ttsResourceId: tts.isEmpty ? volcTtsDefaultResourceId : tts,
      asrResourceId: asr.isEmpty ? volcAsrDefaultResourceId : asr,
      defaultVoiceId: (voice != null && voice.isNotEmpty) ? voice : null,
      apiKeyBound: map['apiKeyBound'] == true,
    );
  }
}
