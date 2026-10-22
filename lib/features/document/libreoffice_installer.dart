import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'libreoffice_download.dart';
import 'libreoffice_package.dart';
import 'libreoffice_system_install.dart';
import 'office_preview_session.dart';

export 'libreoffice_package.dart';

class LibreOfficeInstaller {
  LibreOfficeInstaller(
      {LibreOfficeDownload? download,
      LibreOfficeSystemInstall? system,
      String? Function()? findOffice,
      LibreOfficePackage? package})
      : _download = download ?? LibreOfficeDownload(),
        _system = system ?? LibreOfficeSystemInstall(),
        _findOffice = findOffice ?? OfficePreviewSession.findOfficeExecutable,
        _package = package;
  final LibreOfficeDownload _download;
  final LibreOfficeSystemInstall _system;
  final String? Function() _findOffice;
  final LibreOfficePackage? _package;
  static bool _running = false;

  /// Installs only after the official checksum and system signature checks pass.
  Future<void> install(
      {required CancelToken cancel,
      required void Function(LibreOfficeInstallProgress) onProgress}) async {
    if (_running) {
      throw const LibreOfficeInstallException(
          '已有 LibreOffice 下载或安装正在进行，请返回原安装窗口。');
    }
    if (_findOffice() != null) return;
    _running = true;
    Directory? directory;
    final deadline = Timer(LibreOfficeDownload.overallTimeout,
        () => cancel.cancel('download deadline'));
    try {
      final package = _package ?? LibreOfficePackage.current();
      onProgress(const LibreOfficeInstallProgress(
          LibreOfficeInstallStage.downloading));
      final expected = await _download.checksum(package, cancel);
      if (cancel.isCancelled) throw cancel.cancelError!;
      directory = await Directory.systemTemp
          .createTemp('chat-group-libreoffice-install-');
      final file = File('${directory.path}/${package.fileName}');
      await _download.download(
          package,
          file,
          cancel,
          (received, total) => onProgress(LibreOfficeInstallProgress(
              LibreOfficeInstallStage.downloading,
              received: received,
              total: total)));
      if (cancel.isCancelled) throw cancel.cancelError!;
      onProgress(
          const LibreOfficeInstallProgress(LibreOfficeInstallStage.verifying));
      final actual = (await sha256.bind(file.openRead()).first).toString();
      if (actual != expected) {
        throw const LibreOfficeInstallException(
            '安装包 SHA-256 校验失败，已停止安装，请重新下载。');
      }
      if (cancel.isCancelled) throw cancel.cancelError!;
      deadline.cancel();
      onProgress(
          const LibreOfficeInstallProgress(LibreOfficeInstallStage.installing));
      // Installation is handed to system tools; do not kill an MSI halfway through.
      await _system.install(file);
      if (_findOffice() == null) {
        throw const LibreOfficeInstallException(
            '安装程序已结束，但尚未检测到 LibreOffice。若系统提示重启，请重启后再打开附件。');
      }
    } on LibreOfficeInstallException {
      rethrow;
    } on DioException catch (error) {
      throw LibreOfficeInstallException(CancelToken.isCancel(error)
          ? '下载已取消或超时，未启动安装。'
          : '安装包下载失败，请检查网络后重试。');
    } on Object {
      throw const LibreOfficeInstallException('下载或安装失败，请检查网络、系统提示和磁盘空间后重试。');
    } finally {
      deadline.cancel();
      if (directory != null) {
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          /* System installer may still hold its source file. */
        }
      }
      _running = false;
    }
  }
}
