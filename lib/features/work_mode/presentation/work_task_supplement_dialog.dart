import 'dart:async';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:chat_group/features/chat_group/picked_attachment_payload.dart';
import 'package:chat_group/features/chat_group/widgets/attachment_preview_strip.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

class WorkTaskSupplementDialog extends StatefulWidget {
  final DatabaseService database;
  final Future<void> Function(String, List<MediaAttachment>) onSubmit;
  const WorkTaskSupplementDialog(
      {super.key, required this.database, required this.onSubmit});

  @override
  State<WorkTaskSupplementDialog> createState() =>
      _WorkTaskSupplementDialogState();
}

class _WorkTaskSupplementDialogState extends State<WorkTaskSupplementDialog> {
  final _text = TextEditingController();
  final _attachments = <MediaAttachment>[];
  bool _busy = false;
  bool _submitted = false;
  String? _error;

  @override
  void dispose() {
    if (!_submitted) unawaited(_cleanup(_attachments));
    _text.dispose();
    super.dispose();
  }

  Future<void> _cleanup(Iterable<MediaAttachment> attachments) async {
    try {
      await DataLifecycleService(db: widget.database).cleanupMediaPaths(
          attachments.map((attachment) => attachment.localPath));
    } on Object {
      // A failed cleanup retains copies; never delete originals or referenced files.
    }
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) setState(() => _error = sanitizeWorkTaskError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _checkSize(int bytes, String type) {
    if (!canAddAttachment(
        existingBytes:
            _attachments.fold(0, (sum, item) => sum + (item.fileSize ?? 0)),
        newBytes: bytes)) {
      throw StateError('单文件和本条需求附件总量均不能超过 10 MB。');
    }
    if (type == 'image' &&
        _attachments.where((a) => a.type == 'image').length >= 4) {
      throw StateError('一次最多添加 4 张图片。');
    }
  }

  Future<void> _addFile(String path) async {
    final file = File(path);
    final type = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'}
            .contains(extensionOfPath(path))
        ? 'image'
        : 'file';
    _checkSize(await file.length(), type);
    final attachment = await widget.database.copyToMedia(file, type);
    if (mounted) setState(() => _attachments.add(attachment));
  }

  Future<void> _pick() => _perform(() async {
        final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
        for (final file in picked?.files ?? <PlatformFile>[]) {
          if (file.path == null) throw StateError('无法读取所选文件，请重新选择。');
          await _addFile(file.path!);
        }
      });

  Future<void> _paste() => _perform(() async {
        var added = false;
        // Clipboard plugins can reject an unsupported format independently.
        List<String> paths = [];
        try {
          paths = await Pasteboard.files();
        } on Object {/* Try bitmap/text. */}
        for (final path in paths) {
          if (await File(path).exists()) {
            await _addFile(path);
            added = true;
          }
        }
        if (added) return;
        Uint8List? bitmap;
        try {
          bitmap = await Pasteboard.image;
        } on Object {/* Try text. */}
        if (bitmap != null && bitmap.isNotEmpty) {
          _checkSize(bitmap.length, 'image');
          final attachment = await widget.database.copyBytesToMedia(
              bitmap, 'image',
              fileName:
                  'clipboard_${DateTime.now().millisecondsSinceEpoch}.png',
              mimeType: 'image/png');
          if (mounted) setState(() => _attachments.add(attachment));
          return;
        }
        final text = clipboardTextFallback(
            (await Clipboard.getData(Clipboard.kTextPlain))?.text);
        if (text == null) throw StateError('剪贴板中没有可粘贴的文件、图片或文字。');
        final selection = _text.selection;
        final start = selection.isValid ? selection.start : _text.text.length;
        final end = selection.isValid ? selection.end : start;
        _text.value = TextEditingValue(
            text: _text.text.replaceRange(start, end, text),
            selection: TextSelection.collapsed(offset: start + text.length));
      });

  Future<void> _submit() => _perform(() async {
        final text = _text.text.trim();
        if (text.isEmpty && _attachments.isEmpty) {
          throw StateError('请输入补充需求或添加附件。');
        }
        await widget.onSubmit(text.isEmpty ? '请结合附件补充当前任务需求。' : text,
            List.unmodifiable(_attachments));
        _submitted = true;
        if (mounted) Navigator.pop(context);
      });

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_busy,
        child: AlertDialog(
          title: const Text('补充需求'),
          content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('当前动作结束后停在安全检查点。提交或关闭此窗口均不会自动恢复；确认更新后的需求再继续。'),
                  const SizedBox(height: 12),
                  CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.keyV,
                            meta: true): _paste,
                        const SingleActivator(LogicalKeyboardKey.keyV,
                            control: true): _paste,
                      },
                      child: TextField(
                        key: const Key('work-supplement-input'),
                        controller: _text,
                        enabled: !_busy,
                        minLines: 3,
                        maxLines: 8,
                        decoration: const InputDecoration(
                            hintText: '补充需求，可粘贴文件或图片',
                            border: OutlineInputBorder()),
                        contextMenuBuilder: (context, state) =>
                            AdaptiveTextSelectionToolbar.buttonItems(
                                anchors: state.contextMenuAnchors,
                                buttonItems: state.contextMenuButtonItems
                                    .map((item) => item.type ==
                                            ContextMenuButtonType.paste
                                        ? ContextMenuButtonItem(
                                            type: ContextMenuButtonType.paste,
                                            onPressed: () {
                                              state.hideToolbar();
                                              _paste();
                                            })
                                        : item)
                                    .toList()),
                      )),
                  AttachmentPreviewStrip(
                      attachments: _attachments,
                      onRemove: (item) {
                        if (!_busy) {
                          setState(() => _attachments.remove(item));
                          unawaited(_cleanup([item]));
                        }
                      }),
                  Wrap(spacing: 8, children: [
                    TextButton.icon(
                        onPressed: _busy ? null : _pick,
                        icon: const Icon(Icons.attach_file),
                        label: const Text('添加文件或图片')),
                    TextButton.icon(
                        onPressed: _busy ? null : _paste,
                        icon: const Icon(Icons.content_paste),
                        label: const Text('粘贴')),
                  ]),
                  if (_error != null)
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                ],
              ))),
          actions: [
            TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('保持暂停')),
            FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? '处理中…' : '提交补充并保持暂停')),
          ],
        ),
      );
}
