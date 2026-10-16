/// 授权码载荷（配置包）的结构与字段级校验。
///
/// **本文件必须保持纯 Dart**（只允许 `dart:*` 与纯 Dart 的 lib 内依赖），
/// 因为生成工具 `scripts/generate_api_bundle.dart` 与 App 共用它。
/// 特别注意：端点校验（`SearchEndpointValidator`）依赖 `flutter/foundation`，
/// 因此**不在这里做**——枚举与端点的语义校验统一放在 Flutter 侧的
/// `api_bundle_import_service.dart`。本文件只负责「结构对不对、字段长短合不合法」。
library;

import 'api_bundle_codec.dart';

/// 载荷里的字段上限。
///
/// 与 `SearchProviderConfig` 的同名上限刻意保持一致（`maxIdLength` /
/// `maxNameLength` / `maxBaseUrlLength` / `maxCredentialLength`）：两边口径不同
/// 会出现「包能解开、却存不进去」的中间态，而那种失败发生在写入阶段，比在预览
/// 阶段拦下难排查得多。
class ApiBundleLimits {
  const ApiBundleLimits._();

  static const int maxLabelLength = 120;
  static const int maxIssuedAtLength = 40;
  static const int maxIdLength = 128;
  static const int maxNameLength = 80;
  static const int maxBaseUrlLength = 2048;
  static const int maxModelLength = 200;
  static const int maxResourceIdLength = 200;
  static const int maxCredentialLength = 512;

  /// 单个服务类别允许的条目数。超出即视为载荷异常，而不是「用户配了很多」。
  static const int maxEntriesPerSection = 32;
}

/// 结构层就已判定不可用的条目。
///
/// 它**不是**致命错误：一条坏的搜索配置不该挡住四类服务里其余的配置。它会被
/// 渲染成预览页上的一条「跳过」行，带原因，用户看得见也说得清。
class ApiBundleIssue {
  const ApiBundleIssue({
    required this.section,
    required this.title,
    required this.reason,
  });

  /// 中文服务名，直接用于展示（「聊天」/「语音」/「图像」/「搜索」）。
  final String section;

  /// 尽力还原的条目标题；解析不出时是 `section` 加序号。
  final String title;

  final String reason;
}

class ApiBundleChatEntry {
  const ApiBundleChatEntry({
    required this.id,
    required this.name,
    required this.provider,
    required this.model,
    required this.baseUrl,
    required this.protocol,
    required this.apiKey,
    required this.setDefault,
  });

  /// 空串表示「没有指定 id」，由匹配规则决定新增还是覆盖。
  final String id;
  final String name;
  final String provider;

  /// 空串表示「用该 provider 的默认模型」，由导入服务补齐。
  final String model;
  final String baseUrl;

  /// 空串表示「用默认协议」。
  final String protocol;
  final String apiKey;
  final bool setDefault;
}

class ApiBundleVoiceEntry {
  const ApiBundleVoiceEntry({
    required this.apiKey,
    required this.ttsResourceId,
    required this.asrResourceId,
    required this.defaultVoiceId,
  });

  final String apiKey;
  final String ttsResourceId;
  final String asrResourceId;

  /// 空串表示不覆盖现有默认音色。
  final String defaultVoiceId;
}

class ApiBundleImageEntry {
  const ApiBundleImageEntry({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    required this.size,
    required this.quality,
    required this.disableWatermark,
  });

  final String apiKey;
  final String baseUrl;
  final String model;

  /// 空串表示沿用现有尺寸。
  final String size;
  final String quality;
  final bool disableWatermark;
}

class ApiBundleSearchEntry {
  const ApiBundleSearchEntry({
    required this.id,
    required this.name,
    required this.provider,
    required this.baseUrl,
    required this.apiKey,
    required this.enabled,
    required this.isDefault,
  });

  final String id;
  final String name;
  final String provider;
  final String baseUrl;

  /// 该 provider 不需要凭据时可以是空串。
  final String apiKey;
  final bool enabled;
  final bool isDefault;
}

/// 一份配置包。
class ApiBundle {
  const ApiBundle({
    required this.label,
    required this.issuedAt,
    required this.chat,
    required this.voice,
    required this.image,
    required this.search,
    required this.issues,
  });

  /// 载荷 schema 版本。与信封前缀 `BBK1` 是两道独立闸门：前者管 JSON 形状，
  /// 后者管字节排布。
  static const int supportedVersion = 1;

  final String label;
  final String issuedAt;
  final List<ApiBundleChatEntry> chat;
  final ApiBundleVoiceEntry? voice;
  final ApiBundleImageEntry? image;
  final List<ApiBundleSearchEntry> search;

  /// 结构层被拒的条目。见 [ApiBundleIssue]。
  final List<ApiBundleIssue> issues;

  /// 四类都没东西可配（全是结构层被拒的条目，或载荷本来就没写服务）。
  bool get hasNoEntries =>
      chat.isEmpty && voice == null && image == null && search.isEmpty;

  int get totalEntries =>
      chat.length +
      (voice == null ? 0 : 1) +
      (image == null ? 0 : 1) +
      search.length;

  /// 解析载荷。只对**整包级别**的问题抛异常（版本不认识、形状不对）；
  /// 条目级问题记进 [issues]，不抛。
  static ApiBundle parse(Map<String, dynamic> json) {
    final version = _asInt(json['v']);
    if (version == null) {
      throw const ApiBundleFormatError('配置包缺少版本号');
    }
    if (version != supportedVersion) {
      throw ApiBundleFormatError('配置包版本 $version 不受支持（当前支持 $supportedVersion）');
    }

    final issues = <ApiBundleIssue>[];
    return ApiBundle(
      label: _readText(json['label'], maxLength: ApiBundleLimits.maxLabelLength),
      issuedAt:
          _readText(json['issuedAt'], maxLength: ApiBundleLimits.maxIssuedAtLength),
      chat: _parseChat(json['chat'], issues),
      voice: _parseVoice(json['voice'], issues),
      image: _parseImage(json['image'], issues),
      search: _parseSearch(json['search'], issues),
      issues: issues,
    );
  }

  static List<ApiBundleChatEntry> _parseChat(Object? raw, List<ApiBundleIssue> issues) {
    const section = '聊天';
    final list = _asList(raw);
    if (list.length > ApiBundleLimits.maxEntriesPerSection) {
      issues.add(const ApiBundleIssue(
        section: section,
        title: '聊天配置',
        reason: '条目数超过上限 ${ApiBundleLimits.maxEntriesPerSection}',
      ));
      return const <ApiBundleChatEntry>[];
    }
    final result = <ApiBundleChatEntry>[];
    for (var i = 0; i < list.length; i++) {
      final map = _asMap(list[i]);
      final title = '第 ${i + 1} 条';
      if (map == null) {
        issues.add(ApiBundleIssue(section: section, title: title, reason: '不是配置对象'));
        continue;
      }
      final provider = _requireText(map['provider'],
          maxLength: ApiBundleLimits.maxNameLength,
          section: section,
          title: title,
          label: 'provider',
          issues: issues);
      final apiKey = _requireText(map['apiKey'],
          maxLength: ApiBundleLimits.maxCredentialLength,
          section: section,
          title: title,
          label: 'apiKey',
          issues: issues);
      final baseUrl = _optionalText(map['customBaseUrl'],
          maxLength: ApiBundleLimits.maxBaseUrlLength,
          section: section,
          title: title,
          label: 'customBaseUrl',
          issues: issues);
      final id = _optionalText(map['id'],
          maxLength: ApiBundleLimits.maxIdLength,
          section: section,
          title: title,
          label: 'id',
          issues: issues);
      final model = _optionalText(map['modelName'],
          maxLength: ApiBundleLimits.maxModelLength,
          section: section,
          title: title,
          label: 'modelName',
          issues: issues);
      final protocol = _optionalText(map['apiProtocol'],
          maxLength: ApiBundleLimits.maxNameLength,
          section: section,
          title: title,
          label: 'apiProtocol',
          issues: issues);
      if (provider == null || apiKey == null || baseUrl == null || id == null ||
          model == null || protocol == null) {
        continue;
      }
      final name = _readText(map['name'], maxLength: ApiBundleLimits.maxNameLength);
      result.add(ApiBundleChatEntry(
        id: id,
        name: name.isEmpty ? provider : name,
        provider: provider,
        model: model,
        baseUrl: baseUrl,
        protocol: protocol,
        apiKey: apiKey,
        setDefault: map['makeDefault'] == true,
      ));
    }
    return result;
  }

  static ApiBundleVoiceEntry? _parseVoice(Object? raw, List<ApiBundleIssue> issues) {
    const section = '语音';
    if (raw == null) return null;
    final map = _asMap(raw);
    if (map == null) {
      issues.add(const ApiBundleIssue(section: section, title: '语音服务', reason: '不是配置对象'));
      return null;
    }
    final apiKey = _requireText(map['apiKey'],
        maxLength: ApiBundleLimits.maxCredentialLength,
        section: section,
        title: '语音服务',
        label: 'apiKey',
        issues: issues);
    if (apiKey == null) return null;
    return ApiBundleVoiceEntry(
      apiKey: apiKey,
      ttsResourceId: _readText(map['ttsResourceId'],
          maxLength: ApiBundleLimits.maxResourceIdLength),
      asrResourceId: _readText(map['asrResourceId'],
          maxLength: ApiBundleLimits.maxResourceIdLength),
      defaultVoiceId: _readText(map['defaultVoiceId'],
          maxLength: ApiBundleLimits.maxResourceIdLength),
    );
  }

  static ApiBundleImageEntry? _parseImage(Object? raw, List<ApiBundleIssue> issues) {
    const section = '图像';
    if (raw == null) return null;
    final map = _asMap(raw);
    if (map == null) {
      issues.add(const ApiBundleIssue(section: section, title: '图像服务', reason: '不是配置对象'));
      return null;
    }
    final apiKey = _requireText(map['apiKey'],
        maxLength: ApiBundleLimits.maxCredentialLength,
        section: section,
        title: '图像服务',
        label: 'apiKey',
        issues: issues);
    final baseUrl = _requireText(map['baseUrl'],
        maxLength: ApiBundleLimits.maxBaseUrlLength,
        section: section,
        title: '图像服务',
        label: 'baseUrl',
        issues: issues);
    final model = _requireText(map['model'],
        maxLength: ApiBundleLimits.maxModelLength,
        section: section,
        title: '图像服务',
        label: 'model',
        issues: issues);
    if (apiKey == null || baseUrl == null || model == null) return null;
    return ApiBundleImageEntry(
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
      size: _readText(map['size'], maxLength: ApiBundleLimits.maxNameLength),
      quality: _readText(map['quality'], maxLength: ApiBundleLimits.maxNameLength),
      disableWatermark: map['disableWatermark'] == true,
    );
  }

  static List<ApiBundleSearchEntry> _parseSearch(
    Object? raw,
    List<ApiBundleIssue> issues,
  ) {
    const section = '搜索';
    final list = _asList(raw);
    if (list.length > ApiBundleLimits.maxEntriesPerSection) {
      issues.add(const ApiBundleIssue(
        section: section,
        title: '搜索配置',
        reason: '条目数超过上限 ${ApiBundleLimits.maxEntriesPerSection}',
      ));
      return const <ApiBundleSearchEntry>[];
    }
    final result = <ApiBundleSearchEntry>[];
    for (var i = 0; i < list.length; i++) {
      final map = _asMap(list[i]);
      final fallbackTitle = '第 ${i + 1} 条';
      if (map == null) {
        issues.add(ApiBundleIssue(
            section: section, title: fallbackTitle, reason: '不是配置对象'));
        continue;
      }
      final id = _requireText(map['id'],
          maxLength: ApiBundleLimits.maxIdLength,
          section: section,
          title: fallbackTitle,
          label: 'id',
          issues: issues);
      final name = _requireText(map['name'],
          maxLength: ApiBundleLimits.maxNameLength,
          section: section,
          title: fallbackTitle,
          label: 'name',
          issues: issues);
      final provider = _requireText(map['provider'],
          maxLength: ApiBundleLimits.maxNameLength,
          section: section,
          title: fallbackTitle,
          label: 'provider',
          issues: issues);
      final baseUrl = _optionalText(map['baseUrl'],
          maxLength: ApiBundleLimits.maxBaseUrlLength,
          section: section,
          title: fallbackTitle,
          label: 'baseUrl',
          issues: issues);
      final apiKey = _optionalText(map['apiKey'],
          maxLength: ApiBundleLimits.maxCredentialLength,
          section: section,
          title: fallbackTitle,
          label: 'apiKey',
          issues: issues);
      if (id == null || name == null || provider == null ||
          baseUrl == null || apiKey == null) {
        continue;
      }
      result.add(ApiBundleSearchEntry(
        id: id,
        name: name,
        provider: provider,
        baseUrl: baseUrl,
        apiKey: apiKey,
        enabled: map['enabled'] != false,
        isDefault: map['isDefault'] == true,
      ));
    }
    return result;
  }

  /// 超长时返回空串而不是截断：截断会把一个坏配置**伪装成**好配置，用户看不出
  /// 自己那串被削过；空串配合 [issues] 里的原因才是可诊断的。
  static String _readText(Object? value, {required int maxLength}) {
    final text = value?.toString().trim() ?? '';
    return text.length <= maxLength ? text : '';
  }

  static String? _requireText(
    Object? value, {
    required int maxLength,
    required String section,
    required String title,
    required String label,
    required List<ApiBundleIssue> issues,
  }) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) {
      issues.add(ApiBundleIssue(section: section, title: title, reason: '$label 不能为空'));
      return null;
    }
    if (text.length > maxLength) {
      issues.add(ApiBundleIssue(
        section: section,
        title: title,
        reason: '$label 过长（上限 $maxLength 字符）',
      ));
      return null;
    }
    return text;
  }

  /// 可选字段：缺省是合法的空串，但**过长仍然是错误**（见 [_readText] 的理由）。
  static String? _optionalText(
    Object? value, {
    required int maxLength,
    required String section,
    required String title,
    required String label,
    required List<ApiBundleIssue> issues,
  }) {
    final text = value?.toString().trim() ?? '';
    if (text.length > maxLength) {
      issues.add(ApiBundleIssue(
        section: section,
        title: title,
        reason: '$label 过长（上限 $maxLength 字符）',
      ));
      return null;
    }
    return text;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  static List<Object?> _asList(Object? value) =>
      value is List ? value.toList(growable: false) : const <Object?>[];

  static Map<dynamic, dynamic>? _asMap(Object? value) =>
      value is Map ? value : null;
}
