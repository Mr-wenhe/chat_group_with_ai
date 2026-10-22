import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'attachment_pdf_preview.dart';
import 'attachment_media_preview.dart';

import 'attachment_preview_format.dart';
import 'flutter_html_preview.dart';
import 'office_preview_session.dart';
import 'offline_preview_browser.dart';
import 'libreoffice_install_dialog.dart';

Future<void> showAttachmentPreview(
        BuildContext context, MediaAttachment attachment) =>
    showDialog<void>(
        context: context,
        builder: (_) => AttachmentPreviewDialog(attachment: attachment));

/// Read-only viewer shared by user uploads and work-mode deliverables in every room.
class AttachmentPreviewDialog extends StatefulWidget {
  const AttachmentPreviewDialog(
      {super.key, required this.attachment, this.office});
  final MediaAttachment attachment;
  final OfficePreviewSession? office;
  @override
  State<AttachmentPreviewDialog> createState() =>
      _AttachmentPreviewDialogState();
}

class _AttachmentPreviewDialogState extends State<AttachmentPreviewDialog> {
  late final _office = widget.office ?? OfficePreviewSession();
  late final String _name =
      widget.attachment.fileName ?? p.basename(widget.attachment.localPath);
  late final AttachmentPreviewFormat _format = attachmentPreviewFormat(_name,
      mimeType: widget.attachment.mimeType, mediaType: widget.attachment.type);
  File? _source;
  File? _pdfFile;
  Directory? _inlineDirectory;
  String? _text;
  String? _html;
  String? _error;
  bool _needsOfficeInstall = false;
  List<PreviewSheet> _sheets = [];
  int _sheet = 0;
  double _textScale = 1;
  bool _ready = false;
  bool _closed = false;
  bool _readingMode = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final path = widget.attachment.localPath;
      if (isAttachmentDataUri(path)) {
        if (path.length > OfficePreviewSession.maxInputBytes * 1.4) {
          throw const AttachmentPreviewException('附件超过 100 MB 预览上限。');
        }
        final data = uiAttachmentDataUriCache.decode(path);
        if (data == null) {
          throw const AttachmentPreviewException('附件数据损坏，无法预览。');
        }
        final directory =
            await Directory.systemTemp.createTemp('chat-group-inline-preview-');
        _inlineDirectory = directory;
        _source =
            await File(p.join(directory.path, 'source${p.extension(_name)}'))
                .writeAsBytes(data.bytes);
      } else {
        _source = File(path);
      }
      final source = _source!;
      if (!await source.exists()) {
        throw const AttachmentPreviewException('附件文件不存在，请重新发送或恢复原文件。');
      }
      if (await source.length() > OfficePreviewSession.maxInputBytes) {
        throw const AttachmentPreviewException('附件超过 100 MB 预览上限，请用系统应用打开。');
      }
      if (_closed) return;
      await _prepare(source);
      if (mounted) setState(() => _ready = true);
    } on AttachmentPreviewException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _needsOfficeInstall = error.code == 'officeMissing';
        });
      }
    } on Object {
      if (mounted) setState(() => _error = '无法读取或预览此附件，请检查文件权限和文件内容。');
    } finally {
      if (_closed) await _cleanup();
    }
  }

  Future<void> _prepare(File source) async {
    switch (_format) {
      case AttachmentPreviewFormat.office:
        _pdfFile = await _office.convert(source, spreadsheet: false);
      case AttachmentPreviewFormat.spreadsheet:
        final file = await _office.convert(source, spreadsheet: true);
        _sheets = await loadPreviewSheets(file);
      case AttachmentPreviewFormat.pdf:
        _pdfFile = source;
      case AttachmentPreviewFormat.markdown:
      case AttachmentPreviewFormat.text:
      case AttachmentPreviewFormat.code:
        _text = await readPreviewText(source, limit: 1024 * 1024);
      case AttachmentPreviewFormat.html:
        _html = await readPreviewText(source);
      case AttachmentPreviewFormat.image:
        if (p.extension(_name).toLowerCase() == '.svg' ||
            widget.attachment.mimeType == 'image/svg+xml') {
          _html = await readPreviewText(source);
        }
      case AttachmentPreviewFormat.audio:
      case AttachmentPreviewFormat.video:
        _html = attachmentMediaHtml(
            await readPreviewBytes(source,
                limit: OfficePreviewSession.maxInputBytes),
            name: _name,
            audio: _format == AttachmentPreviewFormat.audio);
      case AttachmentPreviewFormat.unsupported:
        throw const AttachmentPreviewException('此类型暂不支持内嵌预览，可用系统应用打开或另存为。');
    }
  }

  Future<void> _installOffice() async {
    final installed = await showLibreOfficeInstallDialog(context);
    if (!mounted || installed != true || _source == null) return;
    setState(() {
      _error = null;
      _needsOfficeInstall = false;
      _ready = false;
    });
    try {
      await _prepare(_source!);
      if (mounted) setState(() => _ready = true);
    } on AttachmentPreviewException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _needsOfficeInstall = error.code == 'officeMissing';
        });
      }
    } on Object {
      if (mounted) setState(() => _error = '安装后仍无法预览此附件，请用系统应用打开。');
    }
  }

  Widget _errorContent() => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SelectableText(_error!),
            if (_needsOfficeInstall) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                  onPressed: _installOffice,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('下载并安装 LibreOffice')),
            ],
          ])));

  /// SVG 走 [OfflinePreviewBrowser]（flutter_html 不渲染 SVG 文档），
  /// 其余 HTML 文档走 [FlutterHtmlPreview] 才能滚动和选择文本。
  bool get _isSvgAttachment =>
      p.extension(_name).toLowerCase() == '.svg' ||
      widget.attachment.mimeType == 'image/svg+xml';

  Future<void> _cleanup() async {
    await _office.close();
    final directory = _inlineDirectory;
    if (directory != null && await directory.exists()) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        /* Viewer may still be releasing its file handle. */
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(_cleanup());
    super.dispose();
  }

  Future<void> _openExternal() async {
    try {
      final result =
          await OpenFilex.open(_source?.path ?? widget.attachment.localPath);
      if (result.type != ResultType.done && mounted) {
        setState(() => _error = '系统未能打开此文件，请检查默认应用关联。');
      }
    } on Object {
      if (mounted) setState(() => _error = '系统未能打开此文件，请检查默认应用关联。');
    }
  }

  Future<void> _saveAs() async {
    try {
      final source = _source;
      if (source == null || !await source.exists()) return;
      final destination = await FilePicker.platform
          .saveFile(dialogTitle: '附件另存为', fileName: p.basename(_name));
      if (destination == null ||
          p.equals(p.absolute(destination), p.absolute(source.path))) {
        return;
      }
      if (await File(destination).exists() &&
          p.equals(await File(destination).resolveSymbolicLinks(),
              await source.resolveSymbolicLinks())) {
        return;
      }
      await source.copy(destination);
    } on Object {
      if (mounted) setState(() => _error = '另存为失败，请检查目标文件夹权限。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: size.width * .9,
        height: size.height * .88,
        child: Column(children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(children: [
                Expanded(
                    child: Text(_name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge)),
                IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close)),
              ])),
          if (_ready && (_text != null || _sheets.isNotEmpty)) _toolbar(),
          const Divider(height: 1),
          Expanded(
              child: _error != null
                  ? _errorContent()
                  : !_ready
                      ? const Center(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 16),
                              Text('正在本地准备预览，你无需操作。')
                            ]))
                      : _content()),
          const Divider(height: 1),
          _actions(),
        ]),
      ),
    );
  }

  Widget _actions() => Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(spacing: 8, children: [
        if (_text != null)
          TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: _text!)),
              icon: const Icon(Icons.copy),
              label: const Text('复制全文')),
        TextButton.icon(
            onPressed: _openExternal,
            icon: const Icon(Icons.open_in_new),
            label: const Text('用系统应用打开')),
        TextButton.icon(
            onPressed: _source == null ? null : _saveAs,
            icon: const Icon(Icons.save_alt),
            label: const Text('另存为')),
      ]));

  Widget _toolbar() => SizedBox(
      height: 48,
      child: Row(children: [
        if (_sheets.isNotEmpty)
          Expanded(
              child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (var i = 0; i < _sheets.length; i++)
                      Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: ChoiceChip(
                              label: Text(_sheets[i].name),
                              selected: _sheet == i,
                              onSelected: (_) => setState(() => _sheet = i))),
                  ])))
        else
          const Spacer(),
        if (_text != null) ...[
          IconButton(
              tooltip: '缩小文字',
              onPressed: () =>
                  setState(() => _textScale = (_textScale - .1).clamp(.7, 2.5)),
              icon: const Icon(Icons.zoom_out)),
          IconButton(
              tooltip: '放大文字',
              onPressed: () =>
                  setState(() => _textScale = (_textScale + .1).clamp(.7, 2.5)),
              icon: const Icon(Icons.zoom_in)),
        ],
      ]));

  Widget _content() {
    if (_pdfFile != null) {
      return AttachmentPdfPreview(file: _pdfFile!);
    }
    if (_sheets.isNotEmpty) {
      // 表格使用 Flutter 渲染：内嵌 WebView 平台视图在 desktop
      // 上收不到鼠标事件，滚轮和拖选都会失效。
      return FlutterHtmlPreview(
          key: ValueKey(_sheet), html: _sheets[_sheet].html);
    }
    if (_html != null) {
      if (_isSvgAttachment || !_readingMode) {
        return Column(children: [
          if (_format == AttachmentPreviewFormat.html)
            TextButton(
                onPressed: () => setState(() => _readingMode = true),
                child: const Text('阅读模式（可滚动、选择文字）')),
          Expanded(
              child: OfflinePreviewBrowser(
                  html: _html!,
                  mediaControls: _format == AttachmentPreviewFormat.video ||
                      _format == AttachmentPreviewFormat.audio)),
        ]);
      }
      return Column(children: [
        TextButton(
            onPressed: () => setState(() => _readingMode = false),
            child: const Text('查看原网页排版')),
        Expanded(child: FlutterHtmlPreview(html: _html!)),
      ]);
    }
    if (_format == AttachmentPreviewFormat.image) {
      return InteractiveViewer(
          minScale: .1,
          maxScale: 8,
          child: Center(
              child: Image.file(_source!,
                  errorBuilder: (_, __, ___) =>
                      const Text('图片损坏或格式不受支持，请用系统应用打开。'))));
    }
    return MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(_textScale)),
        child: _textContent());
  }

  Widget _textContent() {
    if (_format == AttachmentPreviewFormat.markdown) {
      return Markdown(
          data: _text!,
          selectable: true,
          // Previewing a document must not fetch remote/tracking images or traverse local paths.
          imageBuilder: (_, __, ___) => const Text('[图片未加载：离线预览]'),
          onTapLink: (_, __, ___) {},
          padding: const EdgeInsets.all(24));
    }
    if (_format == AttachmentPreviewFormat.code) {
      return ColoredBox(
          color: githubTheme['root']?.backgroundColor ?? Colors.white,
          child: Align(
              alignment: Alignment.topLeft,
              child: SingleChildScrollView(
                  child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: HighlightView(_text!,
                          language: codeLanguage(_name),
                          theme: githubTheme,
                          padding: const EdgeInsets.all(24),
                          textStyle: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 14 * _textScale))))));
    }
    return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: SelectableText(_text!,
            style: const TextStyle(fontFamily: 'monospace')));
  }
}
