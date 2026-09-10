part of 'chat_room_page.dart';

extension _ChatRoomInputAttachmentSupport on _ChatRoomPageState {
  Future<void> _pickImages() async {
    try {
      final currentImageCount =
          _pendingAttachments.where((att) => att.type == 'image').length;
      final remainingSlots = defaultMaxVisionImages - currentImageCount;
      if (remainingSlots <= 0) {
        if (mounted) {
          AppToast.show(context, '一次最多发送 4 张图片',
              icon: Icons.info_outline_rounded);
        }
        return;
      }

      final files = await _imagePicker.pickMultiImage(
        // 压缩到 1600px / 85% 质量：足够视觉模型识别，又能显著降低上传体积。
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (files.isEmpty) return;
      final selectedFiles = files.take(remainingSlots).toList();
      if (files.length > selectedFiles.length && mounted) {
        AppToast.show(context, '已限制为一次最多 4 张图片',
            icon: Icons.info_outline_rounded);
      }
      for (final file in selectedFiles) {
        final size = await file.length();
        if (!_canAddAttachment(size)) {
          _showAttachmentLimit(file.name);
          continue;
        }
        late final MediaAttachment att;
        if (kIsWeb) {
          final bytes = await file.readAsBytes();
          att = await _db.copyBytesToMedia(
            bytes,
            'image',
            fileName: file.name,
            mimeType: file.mimeType,
          );
        } else {
          att = await _db.copyToMedia(
            File(file.path),
            'image',
            fileName: file.name,
          );
        }
        if (mounted) _setUiState(() => _pendingAttachments.add(att));
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '选择图片失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  /// 从相册选择单个视频，复制到媒体目录并加入待发送列表。
  ///
  /// 视频体积大，仅支持单选。
  Future<void> _pickVideo() async {
    try {
      final file = await _imagePicker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      if (!_canAddAttachment(await file.length())) {
        _showAttachmentLimit(file.name);
        return;
      }
      late final MediaAttachment att;
      if (kIsWeb) {
        final bytes = await file.readAsBytes();
        att = await _db.copyBytesToMedia(
          bytes,
          'video',
          fileName: file.name,
          mimeType: file.mimeType,
        );
      } else {
        att = await _db.copyToMedia(
          File(file.path),
          'video',
          fileName: file.name,
        );
      }
      if (mounted) _setUiState(() => _pendingAttachments.add(att));
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '选择视频失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  /// 选择任意类型文件（可多选）作为附件。
  ///
  /// 不同平台拿到的载荷不同（Web 为字节、原生为路径），
  /// 由 [resolvePickedAttachmentPayload] 归一后再分支处理。
  /// 一个都没成功时提示"没有可读取的文件"。
  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;
      var added = 0;
      for (final picked in result.files) {
        final payload = resolvePickedAttachmentPayload(picked, isWeb: kIsWeb);
        if (payload == null) continue;
        late final MediaAttachment att;
        if (payload is PickedAttachmentBytes) {
          if (!_canAddAttachment(payload.bytes.lengthInBytes)) {
            _showAttachmentLimit(payload.fileName);
            continue;
          }
          att = await _db.copyBytesToMedia(
            payload.bytes,
            _attachmentTypeForPath(payload.fileName),
            fileName: payload.fileName,
          );
        } else if (payload is PickedAttachmentPath) {
          final source = File(payload.path);
          if (!await source.exists()) continue;
          if (!_canAddAttachment(await source.length())) {
            _showAttachmentLimit(payload.fileName);
            continue;
          }
          att = await _db.copyToMedia(
            source,
            _attachmentTypeForPath(payload.path),
            fileName: payload.fileName,
          );
        } else {
          continue;
        }
        if (mounted) _setUiState(() => _pendingAttachments.add(att));
        added++;
      }
      if (mounted && added == 0) {
        AppToast.show(context, '没有可读取的文件', icon: Icons.info_outline_rounded);
      }
    } catch (e) {
      if (mounted) {
        AppToast.show(context, '选择文件失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  /// 处理桌面端拖放进来的路径。
  ///
  /// 文件按附件处理；文件夹无法作为附件，改为把绝对路径插入输入框
  /// （便于让 agentic 工具去读该目录）。
  Future<void> _handleDroppedFiles(Iterable<String> paths) async {
    if (paths.isEmpty) return;
    var addedFiles = 0;
    final droppedDirectories = <String>[];
    try {
      for (final droppedPath in paths) {
        final path = droppedPath.trim();
        if (path.isEmpty) continue;
        final directory = Directory(path);
        if (await directory.exists()) {
          droppedDirectories.add(directory.absolute.path);
          continue;
        }
        final source = File(path);
        if (!await source.exists()) continue;
        if (!_canAddAttachment(await source.length())) {
          _showAttachmentLimit(fileNameFromPath(path));
          continue;
        }
        final att = await _db.copyToMedia(
          source,
          _attachmentTypeForPath(path),
          fileName: fileNameFromPath(path),
        );
        addedFiles++;
        if (_canTouchUi) {
          _setUiState(() => _pendingAttachments.add(att));
        }
      }

      if (droppedDirectories.isNotEmpty) {
        _insertTextAtCursor(droppedDirectories.join('\n'));
      }
      if (!mounted) return;
      if (!_canTouchUi) return;
      final parts = <String>[
        if (addedFiles > 0) '$addedFiles 个文件',
        if (droppedDirectories.isNotEmpty)
          '${droppedDirectories.length} 个文件夹路径',
      ];
      if (parts.isNotEmpty) {
        AppToast.show(context, '已添加 ${parts.join('、')}',
            icon: Icons.attach_file_rounded);
      }
    } catch (e) {
      if (_canTouchUi && mounted) {
        AppToast.show(context, '拖放失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  /// 在光标处插入文本（替换当前选区）。
  ///
  /// [inline] 为 true 时紧贴插入（表情、粘贴文本）；否则在已有内容后另起一行
  /// （拖入的文件夹路径等，独占一行更清晰）。
  void _insertTextAtCursor(String text, {bool inline = false}) {
    if (text.trim().isEmpty) return;
    final current = _textController.text;
    final selection = _textController.selection;
    final insertion = inline || current.trim().isEmpty ? text : '\n$text';
    // 选区偏移为 -1 表示未聚焦，退化为在末尾插入。
    final start = selection.start < 0 ? current.length : selection.start;
    final end = selection.end < 0 ? current.length : selection.end;
    final next = current.replaceRange(start, end, insertion);
    final cursor = start + insertion.length;
    _textController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  /// 把剪贴板内容转成附件或文本插入输入框。
  ///
  /// 按优先级依次尝试：文件路径 → 图片位图 → 纯文本。
  /// 每种尝试都各自 try/catch：某个平台不支持某种剪贴板类型是常态，
  /// 不应因此中断后续回退路径。[_isPastingAttachments] 防止重复触发。
  /// [includeText] 只控制纯文本回退；快捷键仍可检测文件和截图，纯文本
  /// 则交给 TextField 原生粘贴，避免两条路径同时插入。
  Future<void> _pasteClipboardAttachments({
    bool showEmptyHint = false,
    bool includeText = true,
  }) async {
    if (_isPastingAttachments) return;
    _isPastingAttachments = true;
    try {
      final attachments = <MediaAttachment>[];

      // 优先级 1：剪贴板中的文件路径。Android 的 content:// URI 无法直接读，跳过。
      try {
        final files = await Pasteboard.files();
        for (final path in files) {
          if (path.trim().isEmpty || path.startsWith('content://')) continue;
          final source = File(path);
          if (!await source.exists()) continue;
          if (!_canAddAttachment(await source.length())) {
            _showAttachmentLimit(fileNameFromPath(path));
            continue;
          }
          attachments.add(await _db.copyToMedia(
            source,
            _attachmentTypeForPath(path),
          ));
        }
      } catch (_) {}

      if (attachments.isEmpty) {
        // 优先级 2：剪贴板位图（如系统截图），落盘成带时间戳的 png。
        try {
          final image = await Pasteboard.image;
          if (image != null && image.isNotEmpty) {
            if (!_canAddAttachment(image.length)) {
              _showAttachmentLimit('剪贴板图片');
              return;
            }
            attachments.add(await _db.copyBytesToMedia(
              Uint8List.fromList(image),
              'image',
              fileName:
                  'clipboard_${DateTime.now().millisecondsSinceEpoch}.png',
              mimeType: 'image/png',
            ));
          }
        } catch (_) {}
      }

      if (attachments.isEmpty && includeText) {
        // 优先级 3：纯文本，直接插入输入框。
        String? clipboardText;
        try {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          clipboardText = clipboardTextFallback(data?.text);
        } catch (_) {}

        if (clipboardText != null) {
          if (!mounted || !_canTouchUi) return;
          _setUiState(() {
            _insertTextAtCursor(clipboardText!, inline: true);
          });
          _handleTextChanged(_textController.text);
          _inputFocusNode.requestFocus();
          if (showEmptyHint) {
            AppToast.show(context, '已粘贴剪贴板文本',
                icon: Icons.content_paste_rounded);
          }
          return;
        }
      }

      if (!mounted) return;
      if (attachments.isEmpty) {
        if (showEmptyHint) {
          AppToast.show(context, '剪贴板里没有可粘贴的文本、文件或截图',
              icon: Icons.info_outline_rounded);
        }
        return;
      }
      _setUiState(() => _pendingAttachments.addAll(attachments));
      AppToast.show(context, '已粘贴 ${attachments.length} 个附件',
          icon: Icons.content_paste_rounded);
    } catch (e) {
      if (mounted && showEmptyHint) {
        AppToast.show(context, '粘贴失败：$e', icon: Icons.error_outline_rounded);
      }
    } finally {
      _isPastingAttachments = false;
    }
  }

  /// 根据文件扩展名判定附件类型：`image` / `video` / 其余归为 `file`。
  String _attachmentTypeForPath(String path) {
    final ext = extensionOfPath(path);
    const imageExts = {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'bmp',
    };
    const videoExts = {
      'mp4',
      'mov',
      'avi',
      'mkv',
      'webm',
      'm4v',
    };
    if (imageExts.contains(ext)) return 'image';
    if (videoExts.contains(ext)) return 'video';
    return 'file';
  }

  /// 判断再加一个 [newBytes] 字节的附件是否仍在体积限制内。
  ///
  /// 限制同时作用于单文件与单条消息总量（各 10 MB）。
  bool _canAddAttachment(int newBytes) {
    final existingBytes = _pendingAttachments.fold<int>(
      0,
      (sum, attachment) => sum + (attachment.fileSize ?? 0),
    );
    return canAddAttachment(
      existingBytes: existingBytes,
      newBytes: newBytes,
    );
  }

  /// 提示某个文件因超过体积限制而被跳过。
  void _showAttachmentLimit(String fileName) {
    if (!mounted) return;
    AppToast.show(
      context,
      '$fileName 超过单文件或单条消息 10 MB 限制',
      icon: Icons.info_outline_rounded,
    );
  }

  /// 从待发送列表移除某附件。
  void _removeAttachment(MediaAttachment att) {
    if (!mounted) return;
    final removed = _pendingAttachments
        .where((a) => a.id == att.id)
        .toList(growable: false);
    _setUiState(() => _pendingAttachments.removeWhere((a) => a.id == att.id));
    if (removed.isNotEmpty) unawaited(_cleanupMediaPaths(removed));
  }

  /// 删除这些附件在媒体目录里的副本文件。
  ///
  /// 附件被移除或页面关闭时调用，避免未发送的临时文件长期堆积。
  Future<void> _cleanupMediaPaths(Iterable<MediaAttachment> attachments) async {
    await DataLifecycleService(db: _db).cleanupMediaPaths(
      attachments.map((attachment) => attachment.localPath),
    );
  }
}
