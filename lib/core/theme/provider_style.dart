import 'package:flutter/material.dart';

import 'package:chat_group/core/models/api_provider.dart';

/// 统一管理各 LLM 提供商的配色与标签，避免在各页面重复定义导致不一致。
///
/// 之前 `_providerColor` 被复制进 5 个文件且取值互相矛盾
/// （如 qwen 在角色列表是 0xFF6A1B9A，在设置页却是 0xFF7C3AED），
/// 这里收敛为单一事实来源。
class ProviderStyle {
  static const Map<String, Color> _colors = {
    'deepseek': Color(0xFF5B8DEF),
    'qwen': Color(0xFF9B7BFF),
    'zhipu': Color(0xFF2DD4BF),
    'moonshot': Color(0xFFF472B6),
    'baidu': Color(0xFF6E7BFF),
    'xfyun': Color(0xFF0066FF),
    'sensenova': Color(0xFF00A88F),
    'custom': Color(0xFFF59E0B),
  };

  static const Color _fallback = Color(0xFF7C8CFF);

  /// 提供商主题色（暗色高级感下选取更明快、彼此可区分的色相）。
  static Color color(String provider) => _colors[provider] ?? _fallback;

  /// 提供商标签：优先使用枚举内置 label，避免硬编码中文。
  static String label(String provider) {
    for (final p in ApiProvider.values) {
      if (p.name == provider) return p.label;
    }
    return provider;
  }
}

/// 便捷函数，页面 import 后可直接调用。
Color providerColor(String provider) => ProviderStyle.color(provider);
String providerLabel(String provider) => ProviderStyle.label(provider);
