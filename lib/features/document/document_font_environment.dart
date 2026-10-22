import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// macOS 无界面转换须显式加载系统字体，避免中文被替换成西文字体的空字形。
Map<String, String>? documentFontEnvironment({Directory? fallbackDirectory}) {
  if (!Platform.isMacOS) return null;
  final inherited = Platform.environment['FONTCONFIG_FILE']?.trim();
  // shortcut: Flutter 测试字体配置路径变化时需更新此判据。
  if (inherited != null &&
      inherited.isNotEmpty &&
      !inherited.contains('/flutter_test_fonts.')) {
    return null;
  }
  for (final path in const [
    '/opt/homebrew/etc/fonts/fonts.conf',
    '/usr/local/etc/fonts/fonts.conf',
    '/etc/fonts/fonts.conf',
  ]) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.file) {
      return {'FONTCONFIG_FILE': path, 'FONTCONFIG_PATH': p.dirname(path)};
    }
  }
  if (fallbackDirectory == null) return null;
  // 没有 Homebrew 也可预览；配置和缓存仅存在本次转换的临时目录。
  final config = File(p.join(fallbackDirectory.path, 'fonts.conf'));
  final cache =
      const HtmlEscape().convert(p.join(fallbackDirectory.path, 'font-cache'));
  config.writeAsStringSync('''<?xml version="1.0"?>
<fontconfig>
  <dir>/System/Library/Fonts</dir>
  <dir>/Library/Fonts</dir>
  <dir>~/Library/Fonts</dir>
  <dir>/System/Library/AssetsV2/com_apple_MobileAsset_Font7</dir>
  <cachedir>$cache</cachedir>
  <alias><family>sans-serif</family><prefer><family>PingFang SC</family></prefer></alias>
  <alias><family>serif</family><prefer><family>Songti SC</family></prefer></alias>
</fontconfig>''');
  return {
    'FONTCONFIG_FILE': config.path,
    'FONTCONFIG_PATH': fallbackDirectory.path,
  };
}
