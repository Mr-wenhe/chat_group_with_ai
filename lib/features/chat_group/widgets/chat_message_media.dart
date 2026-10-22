part of 'chat_message_bubble.dart';

/// 气泡内的媒体渲染：图片缩略图网格、视频播放器、文件卡片，堆在文字之上。
///
/// 从 `chat_message_bubble.dart` 拆出来：那一支既有气泡排版（头像 / 引用 /
/// 昵称 / 已读回执 / 进度气泡）又有媒体打开与分享动作，两类关注点混在一个文件
/// 里已经越过行数红线。本类只认 [message] 的 media 列表，不碰气泡排版 ——
/// 打开 / 全屏预览 / 长按动作这些系统交互也随之归位到一处。
///
/// 六个成员是从原 `ChatMessageBubble` 逐行搬过来的实例方法（本文件是同一
/// library 的 part，私有成员互相可见），没有改逻辑。
class ChatMessageMedia extends StatelessWidget {
  const ChatMessageMedia({
    super.key,
    required this.message,
    required this.isUser,
    required this.cs,
    this.isDirectChat = false,
    this.entityLabels,
  });

  final Message message;

  /// 自己的消息：媒体按右对齐排版，卡片配色也跟着翻转。
  final bool isUser;

  final ColorScheme cs;
  final bool isDirectChat;
  final EntityLabels? entityLabels;

  @override
  Widget build(BuildContext context) =>
      _buildMediaContent(context, message, cs, isUser, isDirectChat);

  /// Media rendering inside the bubble: image grid + video player, stacked above text.
  Widget _buildMediaContent(BuildContext context, Message message,
      ColorScheme cs, bool isUser, bool isDirectChat) {
    final media = message.media ?? [];
    if (media.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        alignment: isUser ? WrapAlignment.end : WrapAlignment.start,
        children: media.map((att) {
          if (att.type == 'image') {
            return _buildImageThumb(context, att, cs);
          }
          if (att.type == 'video' && !Platform.isMacOS && !Platform.isWindows) {
            return VideoBubble(localPath: att.localPath, isUser: isUser);
          }
          return _buildFileAttachment(context, att, cs, isUser, isDirectChat);
        }).toList(),
      ),
    );
  }

  /// Image thumbnail — tap to open fullscreen preview with InteractiveViewer.
  Widget _buildImageThumb(
      BuildContext context, MediaAttachment att, ColorScheme cs) {
    final data = uiAttachmentDataUriCache.decode(att.localPath);
    return GestureDetector(
      onTap: () => unawaited(Platform.isMacOS || Platform.isWindows
          ? _openAttachment(context, att)
          : _openImageFullscreen(context, att.localPath)),
      onLongPress: () => _showAttachmentActions(context, att),
      onSecondaryTap: () => _showAttachmentActions(context, att),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: data == null
            ? Image.file(
                File(att.localPath),
                width: 140,
                height: 140,
                fit: BoxFit.cover,
              )
            : Image.memory(
                data.bytes,
                width: 140,
                height: 140,
                fit: BoxFit.cover,
              ),
      ),
    );
  }

  /// Fullscreen image preview: black background + InteractiveViewer for pinch-zoom.
  Future<void> _openImageFullscreen(BuildContext context, String path) async {
    if (uiAttachmentDataUriCache.decode(path) == null) {
      final inspected = await inspectAttachmentPath(path);
      if (!inspected.success) {
        if (context.mounted) {
          AppToast.show(context, inspected.message,
              icon: Icons.error_outline_rounded);
        }
        return;
      }
    }
    if (!context.mounted) return;
    final data = uiAttachmentDataUriCache.decode(path);
    await showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(0),
        child: Stack(
          children: [
            InteractiveViewer(
              child: data == null
                  ? Image.file(File(path))
                  : Image.memory(data.bytes),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: '关闭',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 文件类附件的卡片。工作模式写给自己的详情留档（方案与验收详情、调查来源
  /// 与结果、完整公开正文、工作项交接）也走这里，只换掉措辞与点击动作。
  ///
  /// 留档不能沿用通用外观：「待解析」是给用户文档用的状态，对内部留档没有
  /// 意义，正是"这文件是什么"的困惑来源；点击也不该把一份 JSON 甩给系统
  /// 打开，应用内可读视图才能让正文真正看得见。
  Widget _buildFileAttachment(
    BuildContext context,
    MediaAttachment att,
    ColorScheme cs,
    bool isUser,
    bool isDirectChat,
  ) {
    final textColor = WeComChatTokens.text(context);
    final subtleColor = textColor.withValues(alpha: 0.62);
    final fillColor = isUser
        ? WeComChatTokens.lightText.withValues(alpha: 0.07)
        : WeComChatTokens.chatBackground(context).withValues(alpha: 0.7);
    final isDetail = isWorkModeDetailAttachment(att);
    return InkWell(
      onTap: () {
        Future<void> preview() => isDetail
            ? showReadableJsonDialog(
                context,
                title: att.fileName ?? fileNameFromPath(att.localPath),
                path: att.localPath,
                structuredWorkPlan: !isDirectChat,
                showRawSource: !isDirectChat,
                entityLabels: !isDirectChat ? entityLabels : null,
              )
            : _openAttachment(context, att);
        unawaited(isDirectChat ||
                (!isDetail && (Platform.isMacOS || Platform.isWindows))
            ? preview()
            : WorkTaskOverlayHost.withPanelHiddenForPreview(context, preview));
      },
      onLongPress: () => _showAttachmentActions(context, att),
      onSecondaryTap: () => _showAttachmentActions(context, att),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(8),
          // 内部留档用一层弱描边和用户附件区分：它不占用户的空间，
          // 也不该被读成"别人发来的文件"。
          border: isDetail
              ? Border.all(color: subtleColor.withValues(alpha: 0.32))
              : null,
        ),
        child: Row(
          children: [
            Icon(isDetail ? Icons.receipt_long_outlined : fileIconFor(att),
                size: isDetail ? 26 : 30, color: subtleColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    att.fileName ?? fileNameFromPath(att.localPath),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isDetail
                        ? '内部记录 · ${formatAttachmentSize(att.fileSize)}'
                        : '${formatAttachmentSize(att.fileSize)} · '
                            '${(Platform.isMacOS || Platform.isWindows) && attachmentPreviewFormat(att.fileName ?? att.localPath) != AttachmentPreviewFormat.unsupported ? '点击预览' : DocumentUnderstandingService.statusLabel(att)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: subtleColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
                isDetail
                    ? Icons.visibility_outlined
                    : Icons.open_in_new_rounded,
                size: 18,
                color: subtleColor),
          ],
        ),
      ),
    );
  }

  Future<void> _openAttachment(
      BuildContext context, MediaAttachment att) async {
    if (Platform.isMacOS || Platform.isWindows) {
      await WorkTaskOverlayHost.withPanelHiddenForPreview(
          context, () => showAttachmentPreview(context, att));
      return;
    }
    try {
      if (isAttachmentDataUri(att.localPath)) {
        final opened = await openDataAttachment(
          att.localPath,
          att.fileName ?? fileNameFromPath(att.localPath),
        );
        if (!opened && context.mounted) {
          AppToast.show(context, '浏览器未能打开附件',
              icon: Icons.error_outline_rounded);
        }
        return;
      }
      final inspected = await inspectAttachmentPath(att.localPath);
      if (!inspected.success) {
        if (context.mounted) {
          AppToast.show(context, inspected.message,
              icon: Icons.error_outline_rounded);
        }
        return;
      }
      final extension = extensionOfPath(att.fileName ?? att.localPath);
      final isGroupHtmlSource =
          !isDirectChat && const {'html', 'htm'}.contains(extension);
      // 纯文本（md / txt / json 等）改用应用内只读视图：交给系统默认程序会
      // 依赖文件关联，关联缺失时 `cmd /c start` 仍返回成功，用户看到的是
      // "点击没反应"。应用内视图既可靠，也让正文立刻可见。
      if (isPlainTextAttachment(att) || isGroupHtmlSource) {
        if (!context.mounted) return;
        await showReadableJsonDialog(
          context,
          title: att.fileName ?? fileNameFromPath(att.localPath),
          path: inspected.absolutePath ?? att.localPath,
          prettifyJson: !isDirectChat && extension == 'json',
          renderMarkdown:
              !isDirectChat && const {'md', 'markdown'}.contains(extension),
          showRawSource: !isDirectChat && extension == 'json',
        );
        return;
      }
      final result = await OpenFilex.open(att.localPath, type: att.mimeType);
      if (result.type.name != 'done' && context.mounted) {
        AppToast.show(context, '打开失败：${result.message}',
            icon: Icons.error_outline_rounded);
      }
    } on Object {
      if (context.mounted) {
        AppToast.show(context, '打开失败，请检查文件权限及默认应用。',
            icon: Icons.error_outline_rounded);
      }
    }
  }

  Future<void> _showAttachmentActions(
      BuildContext context, MediaAttachment att) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: const Text('打开文件'),
              onTap: () => Navigator.of(sheetContext).pop('open'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_rounded),
              title: const Text('在 Finder/资源管理器中显示'),
              onTap: () => Navigator.of(sheetContext).pop('reveal'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制绝对路径'),
              onTap: () => Navigator.of(sheetContext).pop('copy'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'open':
        await _openAttachment(context, att);
      case 'reveal':
        final result = await revealAttachmentPath(att.localPath);
        if (context.mounted && !result.success) {
          AppToast.show(context, result.message,
              icon: Icons.error_outline_rounded);
        }
      case 'copy':
        final result = await inspectAttachmentPath(att.localPath);
        if (!context.mounted) return;
        if (!result.success || result.absolutePath == null) {
          AppToast.show(context, result.message,
              icon: Icons.error_outline_rounded);
          return;
        }
        try {
          await Clipboard.setData(ClipboardData(text: result.absolutePath!));
          if (context.mounted) {
            AppToast.show(context, '已复制附件绝对路径', icon: Icons.check_rounded);
          }
        } on Object {
          if (context.mounted) {
            AppToast.show(context, '系统未能复制附件路径，请稍后重试。',
                icon: Icons.error_outline_rounded);
          }
        }
    }
  }
}
