part of 'chat_room_page.dart';

extension _ChatRoomInputSupport on _ChatRoomPageState {
  /// 是否运行在桌面端（决定回车发送、拖放文件等交互）。
  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// 输入区键盘事件：@ 弹窗打开时走导航；桌面端回车发送、Shift+回车换行。
  KeyEventResult _handleKeyEvent(KeyEvent event) {
    // 单独放行 Shift 抬起/按下，否则会干扰 Shift+Enter 的组合判断。
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
            event.logicalKey == LogicalKeyboardKey.shiftRight)) {
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // @ 弹窗键盘导航优先（↑↓ 选择、回车插入、Esc 关闭）
    if (_showMentionPopup) return _handleMentionKeyEvent(event);
    final key = event.logicalKey;
    // Ctrl/Cmd+V：自行处理剪贴板（可能含图片），不走 TextField 默认粘贴。
    if (key == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      unawaited(_pasteClipboardAttachments(showEmptyHint: false));
      // 阻止 Flutter 默认粘贴行为，避免手动插入与 TextField 原生粘贴重复。
      return KeyEventResult.handled;
    }
    // 桌面端：Enter 发送、Shift+Enter 换行
    if (_isDesktop) {
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
        if (!isShiftPressed) {
          if (_canSend) {
            // 语音输入中回车 = 先结束聆听落定文本，再发送。
            unawaited(_sendAfterVoiceInput());
          }
          return KeyEventResult.handled; // 阻止插入换行
        }
        // Shift+Enter：放行，让 TextField 插入换行
      }
    }
    return KeyEventResult.ignored;
  }

  /// 构建底部输入区（引用条、附件预览、拖放区、表情、发送/停止按钮）。
  ///
  /// 具体 UI 在 [ChatRoomComposer]，此处只做状态与回调的接线。
  Widget _buildInputArea() {
    return ChatRoomComposer(
      textController: _textController,
      focusNode: _inputFocusNode,
      inputFieldKey: _inputFieldKey,
      quotedMessage: _quotedMessage,
      quotedSenderName: _quotedMessage == null
          ? ''
          : _senderNameById(_quotedMessage!.senderId),
      attachments: _pendingAttachments,
      isDraggingFiles: _isDraggingFiles,
      isStreaming: _isStreaming,
      canSend: _canSend,
      isDirectChat: _isDirectChat,
      isDesktop: _isDesktop,
      onKeyEvent: _handleKeyEvent,
      onTextChanged: _handleTextChanged,
      onDragStateChanged: (dragging) {
        if (_canTouchUi) _setUiState(() => _isDraggingFiles = dragging);
      },
      onDroppedPaths: (paths) => unawaited(_handleDroppedFiles(paths)),
      onShowAttachmentMenu: _showAttachmentMenu,
      onPasteAttachments: () => _pasteClipboardAttachments(showEmptyHint: true),
      onShowEmojiPanel: _showEmojiPanel,
      onCancelQuote: _cancelQuote,
      onRemoveAttachment: _removeAttachment,
      onStopStreaming: _stopStreaming,
      // 语音输入：仅原生平台显示麦克风；发送前若仍在聆听先落定文本。
      showVoiceInput: !kIsWeb,
      voiceInputUsable: _asrUsable,
      voiceInputActive: _voiceInputActive,
      onToggleVoiceInput: () => unawaited(_toggleVoiceInput()),
      onSend: () => unawaited(_sendAfterVoiceInput()),
    );
  }

  /// 弹出附件选择底部菜单：图片（多选）/ 视频（单选）/ 文件（多选）。
  void _showAttachmentMenu() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text('发送附件',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
            const SizedBox(height: 14),
            SheetButton(ctx, cs, Icons.image_rounded, '图片（可多选）', () {
              Navigator.pop(ctx);
              _pickImages();
            }),
            const SizedBox(height: 8),
            SheetButton(ctx, cs, Icons.videocam_rounded, '视频（单选）', () {
              Navigator.pop(ctx);
              _pickVideo();
            }),
            const SizedBox(height: 8),
            SheetButton(ctx, cs, Icons.insert_drive_file_rounded, '文件（可多选）',
                () {
              Navigator.pop(ctx);
              _pickFiles();
            }),
            const SizedBox(height: 8),
            SheetButton(ctx, cs, Icons.content_paste_rounded, '粘贴截图或文件', () {
              Navigator.pop(ctx);
              _pasteClipboardAttachments(showEmptyHint: true);
            }),
          ],
        ),
      ),
    );
  }

  /// 弹出常用表情面板，点选后在光标处内联插入。
  void _showEmojiPanel() {
    const emojis = [
      '😀',
      '😂',
      '🥹',
      '😍',
      '😎',
      '🤔',
      '👍',
      '👏',
      '🙏',
      '🔥',
      '✨',
      '🎉',
      '💡',
      '✅',
      '🧪',
      '🚀',
    ];
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: emojis.map((emoji) {
            return InkWell(
              onTap: () {
                Navigator.pop(ctx);
                _insertTextAtCursor(emoji, inline: true);
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.5)),
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 24)),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  /// 从相册多选图片，复制到媒体目录并加入待发送列表。
  ///
  /// 受 [defaultMaxVisionImages]（4 张）约束：多选超出时截断并提示，
  /// 单张超过体积上限则跳过该张而不中断其余图片。
  /// Web 端只能拿到字节流，原生端直接按路径复制文件。
}
