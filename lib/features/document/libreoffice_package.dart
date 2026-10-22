import 'dart:ffi';

class LibreOfficeInstallException implements Exception {
  const LibreOfficeInstallException(this.message);
  final String message;
}

enum LibreOfficeInstallStage { downloading, verifying, installing }

class LibreOfficeInstallProgress {
  const LibreOfficeInstallProgress(this.stage,
      {this.received = 0, this.total = 0});
  final LibreOfficeInstallStage stage;
  final int received;
  final int total;
}

/// Only these official packages may be installed; callers cannot supply a URL.
class LibreOfficePackage {
  const LibreOfficePackage._(this.relativePath, this.fileName);
  // shortcut: release is pinned for predictable installers; update with supported LibreOffice releases.
  static const version = '26.8.1';
  static const host = 'download.documentfoundation.org';
  final String relativePath;
  final String fileName;
  Uri get uri =>
      Uri.https(host, '/libreoffice/stable/$version/$relativePath/$fileName');

  static LibreOfficePackage current() => forAbi(Abi.current());

  static LibreOfficePackage forAbi(Abi abi) {
    if (abi == Abi.macosArm64) {
      return const LibreOfficePackage._(
          'mac/aarch64', 'LibreOffice_${version}_MacOS_aarch64.dmg');
    }
    if (abi == Abi.macosX64) {
      return const LibreOfficePackage._(
          'mac/x86_64', 'LibreOffice_${version}_MacOS_x86-64.dmg');
    }
    if (abi == Abi.windowsArm64) {
      return const LibreOfficePackage._(
          'win/aarch64', 'LibreOffice_${version}_Win_aarch64.msi');
    }
    if (abi == Abi.windowsX64) {
      return const LibreOfficePackage._(
          'win/x86_64', 'LibreOffice_${version}_Win_x86-64.msi');
    }
    throw const LibreOfficeInstallException(
        '当前系统架构暂不支持自动安装，请从 LibreOffice 官网安装。');
  }

  String parseChecksum(String source) {
    final match = RegExp(r'^([a-fA-F0-9]{64})\s+\*?([^\r\n]+)\s*$')
        .firstMatch(source.trim());
    if (match == null || match.group(2)!.trim() != fileName) {
      throw const LibreOfficeInstallException('官方安装包校验信息无效，已停止下载。');
    }
    return match.group(1)!.toLowerCase();
  }
}
