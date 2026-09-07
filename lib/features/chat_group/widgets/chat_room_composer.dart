import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/widgets/attachment_preview_strip.dart';
import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

class ChatRoomComposer extends StatelessWidget {
  final TextEditingController textController;
  final FocusNode focusNode;
  final GlobalKey inputFieldKey;
  final Message? quotedMessage;
  final String quotedSenderName;
  final List<MediaAttachment> attachments;
  final bool isDraggingFiles;
  final bool isStreaming;
  final bool canSend;
  final bool isDirectChat;
  final bool isDesktop;
  final KeyEventResult Function(KeyEvent event) onKeyEvent;
  final ValueChanged<String> onTextChanged;
  final ValueChanged<bool> onDragStateChanged;
  final ValueChanged<Iterable<String>> onDroppedPaths;
  final VoidCallback onShowAttachmentMenu;
  final VoidCallback onPasteAttachments;
  final VoidCallback onShowEmojiPanel;
  final VoidCallback onCancelQuote;
  final ValueChanged<MediaAttachment> onRemoveAttachment;
  final VoidCallback onStopStreaming;
  final VoidCallback onSend;

  const ChatRoomComposer({
    super.key,
    required this.textController,
    required this.focusNode,
    required this.inputFieldKey,
    required this.quotedMessage,
    required this.quotedSenderName,
    required this.attachments,
    required this.isDraggingFiles,
    required this.isStreaming,
    required this.canSend,
    required this.isDirectChat,
    required this.isDesktop,
    required this.onKeyEvent,
    required this.onTextChanged,
    required this.onDragStateChanged,
    required this.onDroppedPaths,
    required this.onShowAttachmentMenu,
    required this.onPasteAttachments,
    required this.onShowEmojiPanel,
    required this.onCancelQuote,
    required this.onRemoveAttachment,
    required this.onStopStreaming,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => onDragStateChanged(true),
      onDragExited: (_) => onDragStateChanged(false),
      onDragDone: (detail) {
        onDragStateChanged(false);
        onDroppedPaths(detail.files.map((file) => file.path));
      },
      child: Focus(
        onKeyEvent: (_, event) => onKeyEvent(event),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (quotedMessage != null)
              _QuoteBar(
                message: quotedMessage!,
                senderName: quotedSenderName,
                onCancel: onCancelQuote,
              ),
            if (attachments.isNotEmpty)
              AttachmentPreviewStrip(
                attachments: attachments,
                onRemove: onRemoveAttachment,
              ),
            Container(
              padding: EdgeInsets.only(
                left: 8,
                right: 8,
                top: 8,
                bottom: MediaQuery.paddingOf(context).bottom + 8,
              ),
              decoration: BoxDecoration(
                color: WeComChatTokens.inputSurface(context),
                border: Border(
                  top: BorderSide(
                    color: isDraggingFiles
                        ? colorScheme.primary
                        : WeComChatTokens.divider(context),
                    width: isDraggingFiles ? 2 : 1,
                  ),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file_rounded, size: 24),
                    color: colorScheme.onSurfaceVariant,
                    onPressed: onShowAttachmentMenu,
                    tooltip: '添加附件',
                  ),
                  IconButton(
                    icon: const Icon(Icons.content_paste_rounded, size: 22),
                    color: colorScheme.onSurfaceVariant,
                    onPressed: onPasteAttachments,
                    tooltip: '粘贴截图或文件',
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_reaction_outlined, size: 22),
                    color: colorScheme.onSurfaceVariant,
                    onPressed: onShowEmojiPanel,
                    tooltip: '插入表情',
                  ),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: 44,
                        maxHeight: 120,
                      ),
                      child: TextField(
                        key: inputFieldKey,
                        controller: textController,
                        focusNode: focusNode,
                        // Desktop automation and keyboard users need a real
                        // native focus target as soon as the room mounts;
                        // mobile keeps the keyboard opt-in by design.
                        autofocus: isDesktop,
                        decoration: InputDecoration(
                          hintText: _hintText,
                          suffixIcon: quotedMessage == null
                              ? null
                              : IconButton(
                                  icon: Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  onPressed: onCancelQuote,
                                  tooltip: '取消引用',
                                ),
                          border: _inputBorder,
                          enabledBorder: _inputBorder,
                          focusedBorder: _inputBorder,
                          filled: true,
                          fillColor: WeComChatTokens.inputField(context),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 11,
                          ),
                          isDense: true,
                        ),
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        maxLines: null,
                        onChanged: onTextChanged,
                        contextMenuBuilder: (context, editableTextState) {
                          return AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: editableTextState.contextMenuAnchors,
                            buttonItems:
                                editableTextState.contextMenuButtonItems,
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isStreaming) ...[
                    IconButton(
                      icon: const Icon(Icons.stop_rounded, size: 24),
                      color: colorScheme.error,
                      onPressed: onStopStreaming,
                      tooltip: '停止生成',
                    ),
                    const SizedBox(width: 4),
                  ],
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: textController,
                    builder: (context, value, _) {
                      // Keep the parent page stable while typing; the
                      // controller is the smallest reactive boundary for the
                      // send affordance.
                      final canSendNow = canSend ||
                          value.text.trim().isNotEmpty ||
                          attachments.isNotEmpty;
                      return IconButton(
                        icon: const Icon(Icons.send_rounded, size: 22),
                        style: IconButton.styleFrom(
                          backgroundColor: canSendNow
                              ? WeComChatTokens.lightSelfBubble
                              : WeComChatTokens.divider(context),
                          foregroundColor: canSendNow
                              ? WeComChatTokens.lightText
                              : colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        onPressed: canSendNow ? onSend : null,
                        tooltip: '发送',
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _hintText {
    if (quotedMessage != null) return '回复 $quotedSenderName...';
    if (isDirectChat) return '输入私聊消息…';
    if (isDesktop) return '输入消息，回车发送，Shift+回车换行，@ 提到角色…';
    return '输入消息，@ 提到角色…';
  }

  static final _inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(4),
    borderSide: BorderSide.none,
  );
}

class _QuoteBar extends StatelessWidget {
  final Message message;
  final String senderName;
  final VoidCallback onCancel;

  const _QuoteBar({
    required this.message,
    required this.senderName,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final snippet = message.content.length > 60
        ? '${message.content.substring(0, 60)}...'
        : message.content;
    return Container(
      margin: const EdgeInsets.only(left: 16, right: 16, top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.format_quote_rounded,
              size: 14, color: colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  senderName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
                Text(
                  snippet,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.close_rounded,
              size: 16,
              color: colorScheme.onSurfaceVariant,
            ),
            onPressed: onCancel,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}
