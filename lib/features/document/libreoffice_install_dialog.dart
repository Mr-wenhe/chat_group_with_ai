import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'libreoffice_installer.dart';

Future<bool?> showLibreOfficeInstallDialog(BuildContext context) =>
    showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const LibreOfficeInstallDialog());

class LibreOfficeInstallDialog extends StatefulWidget {
  const LibreOfficeInstallDialog({super.key, this.installer});
  final LibreOfficeInstaller? installer;
  @override
  State<LibreOfficeInstallDialog> createState() =>
      _LibreOfficeInstallDialogState();
}

class _LibreOfficeInstallDialogState extends State<LibreOfficeInstallDialog> {
  late final _installer = widget.installer ?? LibreOfficeInstaller();
  CancelToken? _cancel;
  LibreOfficeInstallProgress _progress =
      const LibreOfficeInstallProgress(LibreOfficeInstallStage.downloading);
  String? _error;
  bool get _installing =>
      _error == null && _progress.stage == LibreOfficeInstallStage.installing;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    final cancel = CancelToken();
    _cancel = cancel;
    try {
      await _installer.install(
          cancel: cancel,
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          });
      if (mounted) Navigator.of(context).pop(true);
    } on LibreOfficeInstallException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) setState(() => _error = '下载或安装失败，请检查网络及系统安装窗口后重试。');
    }
  }

  @override
  void dispose() {
    if (!_installing) _cancel?.cancel();
    super.dispose();
  }

  String get _status => switch (_progress.stage) {
        LibreOfficeInstallStage.downloading => _progress.received == 0
            ? '正在获取官方安装包，你无需操作。'
            : '正在下载 LibreOffice：${_mb(_progress.received)} MB${_progress.total > 0 ? ' / ${_mb(_progress.total)} MB' : ''}',
        LibreOfficeInstallStage.verifying => '正在校验安装包，你无需操作。',
        LibreOfficeInstallStage.installing =>
          '正在自动安装 LibreOffice。若系统请求密码或授权，请在系统窗口确认。',
      };

  String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_installing,
      child: AlertDialog(
        title: const Text('下载并安装 LibreOffice'),
        content: SizedBox(
            width: 440,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_error ?? _status),
                  if (_error == null) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                        value: _progress.stage ==
                                    LibreOfficeInstallStage.downloading &&
                                _progress.total > 0
                            ? (_progress.received / _progress.total).clamp(0, 1)
                            : null),
                  ],
                ])),
        actions: [
          if (_error != null)
            TextButton(
                onPressed: () {
                  if (_error == null) return;
                  setState(() {
                    _error = null;
                    _progress = const LibreOfficeInstallProgress(
                        LibreOfficeInstallStage.downloading);
                  });
                  unawaited(_run());
                },
                child: const Text('重试下载并安装')),
          TextButton(
              onPressed: _installing
                  ? null
                  : () {
                      _cancel?.cancel();
                      Navigator.of(context).pop(false);
                    },
              child: Text(_error != null ? '关闭' : '取消下载')),
        ],
      ));
}
