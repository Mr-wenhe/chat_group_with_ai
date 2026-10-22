import 'dart:io';

import 'package:path/path.dart' as p;

import 'libreoffice_package.dart';

/// System tools perform installation; no password collection or security bypass.
class LibreOfficeSystemInstall {
  Future<void> install(File package) async {
    if (Platform.isMacOS) return _installMac(package);
    if (Platform.isWindows) return _installWindows(package);
    throw const LibreOfficeInstallException('当前平台不支持自动安装 LibreOffice。');
  }

  Future<void> _installMac(File package) async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw const LibreOfficeInstallException('无法确定当前用户的 Applications 目录。');
    }
    final applications =
        await Directory(p.join(home, 'Applications')).create(recursive: true);
    final destination = p.join(applications.path, 'LibreOffice.app');
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const LibreOfficeInstallException(
          '用户 Applications 目录已有 LibreOffice，请检查已有安装，未覆盖任何文件。');
    }
    final staging = await applications.createTemp('.chat-group-libreoffice-');
    final mount = Directory(p.join(package.parent.path, 'mount'));
    var mounted = false;
    try {
      await mount.create();
      await _requireSuccess('/usr/bin/hdiutil', [
        'attach',
        '-readonly',
        '-nobrowse',
        '-noautoopen',
        '-mountpoint',
        mount.path,
        package.path
      ]);
      mounted = true;
      final source = p.join(mount.path, 'LibreOffice.app');
      await _requireSuccess(
          '/usr/bin/codesign', ['--verify', '--deep', '--strict', source]);
      await _requireSuccess(
          '/usr/sbin/spctl', ['--assess', '--type', 'execute', source]);
      final staged = p.join(staging.path, 'LibreOffice.app');
      await _requireSuccess('/usr/bin/ditto', [source, staged]);
      if (!await File(p.join(staged, 'Contents', 'MacOS', 'soffice'))
          .exists()) {
        throw const LibreOfficeInstallException('安装包缺少 LibreOffice 程序，已停止安装。');
      }
      // Same-filesystem rename publishes a complete app; existing apps are never replaced.
      if (await FileSystemEntity.type(destination, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const LibreOfficeInstallException(
            'LibreOffice 安装目录已被占用，未覆盖已有文件。');
      }
      await Directory(staged).rename(destination);
    } finally {
      if (mounted) {
        await Process.run('/usr/bin/hdiutil', ['detach', mount.path]);
      }
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<void> _installWindows(File package) async {
    final root = Platform.environment['SystemRoot'];
    if (root == null) {
      throw const LibreOfficeInstallException('无法找到 Windows 系统安装程序。');
    }
    final system32 = p.join(root, 'System32');
    final signature = await Process.run(
        p.join(system32, 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'''$s = Get-AuthenticodeSignature -LiteralPath $env:CHAT_GROUP_LIBREOFFICE_INSTALLER; if ($s.Status -ne 'Valid' -or $null -eq $s.SignerCertificate -or $s.SignerCertificate.Subject -notmatch '(?:^|,\s*)(?:CN|O)=The Document Foundation(?:,|$)') { exit 1 }''',
        ],
        environment: {'CHAT_GROUP_LIBREOFFICE_INSTALLER': package.path},
        runInShell: false);
    if (signature.exitCode != 0) {
      throw const LibreOfficeInstallException(
          'LibreOffice 安装包未通过系统签名检查，已停止安装。');
    }
    final result = await Process.run(
        p.join(system32, 'msiexec.exe'),
        [
          '/i',
          package.path,
          '/passive',
          '/norestart',
          'REBOOT=ReallySuppress',
          'REGISTER_ALL_MSO_TYPES=0',
        ],
        runInShell: false);
    if (result.exitCode == 1602) {
      throw const LibreOfficeInstallException('已取消系统安装。');
    }
    if (result.exitCode == 1618) {
      throw const LibreOfficeInstallException('Windows 正在安装其他程序，请等待结束后重试。');
    }
    if (result.exitCode != 0 && result.exitCode != 3010) {
      throw const LibreOfficeInstallException('系统安装未完成，请检查管理员授权、磁盘空间及系统安装窗口。');
    }
  }

  Future<void> _requireSuccess(
      String executable, List<String> arguments) async {
    final result = await Process.run(executable, arguments, runInShell: false);
    if (result.exitCode != 0) {
      throw const LibreOfficeInstallException(
          '系统校验或安装未通过。请检查系统提示和磁盘空间后重试；未跳过安全检查。');
    }
  }
}
