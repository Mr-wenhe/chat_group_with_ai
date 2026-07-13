import 'dart:io';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/chat_group/attachment_opener.dart';
import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:chat_group/features/chat_group/widgets/blinking_cursor.dart';
import 'package:chat_group/features/chat_group/widgets/message_selectable_text.dart';
import 'package:chat_group/features/chat_group/widgets/video_bubble.dart';
import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

/// A single chat message bubble — user or AI.
///
/// Displays avatar, sender name, quoted reference, media attachments,
/// text content with mention highlighting, read receipts, and a streaming
/// cursor. All state is passed via constructor parameters (pure data/callback),
/// with no dependency on `_ChatRoomPageState`.
class ChatMessageBubble extends StatelessWidget {
  final Message message;
  final AICharacter? sender;
  final List<AICharacter> characters;
  final ColorScheme cs;
  final bool isStreaming;
  final bool isRegenerating;
  final bool isHighlightedMention;
  final VoidCallback? onLongPress;
  final VoidCallback? onSenderTap;
  final VoidCallback? onMentionSender;
  final Color Function(AICharacter) senderColor;
  final Message? quotedMessage;
  final String? quotedSenderName;
  final String ownerName;
  final String? readReceiptText;

  const ChatMessageBubble({
    super.key,
    required this.message,
    this.sender,
    required this.characters,
    required this.cs,
    this.isStreaming = false,
    this.isRegenerating = false,
    this.isHighlightedMention = false,
    this.onLongPress,
    this.onSenderTap,
    this.onMentionSender,
    required this.senderColor,
    this.quotedMessage,
    this.quotedSenderName,
    required this.ownerName,
    this.readReceiptText,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.senderType == 'user';

    return GestureDetector(
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          mainAxisAlignment:
              isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser && sender != null) ...[
              InkWell(
                onTap: onSenderTap,
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: senderColor(sender!).withOpacity(0.14),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                      sender!.avatar.isNotEmpty
                          ? sender!.avatar
                          : sender!.name[0],
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: senderColor(sender!))),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Column(
                crossAxisAlignment:
                    isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (!isUser && sender != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 4),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: onSenderTap,
                            onSecondaryTap: onMentionSender,
                            onLongPress: onMentionSender,
                            child: Text(sender!.name,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: senderColor(sender!))),
                          ),
                          if (isRegenerating)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.5, color: cs.primary)),
                            ),
                        ],
                      ),
                    ),
                  WeComBubbleSurface(
                    isUser: isUser,
                    isHighlighted: isHighlightedMention,
                    child: Column(
                      crossAxisAlignment: isUser
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (message.replyToMessageId != null)
                          _buildQuotedRef(
                            context,
                            quotedMessage ?? message,
                            quotedSenderName,
                            isUser,
                          ),
                        _buildMediaContent(context, message, cs, isUser),
                        _buildContent(context, message),
                      ],
                    ),
                  ),
                  if (readReceiptText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3, right: 2),
                      child: Text(
                        readReceiptText!,
                        style: TextStyle(
                          fontSize: 10,
                          color: WeComChatTokens.nickname(context),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (isUser) const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildQuotedRef(
    BuildContext context,
    Message? quoted,
    String? senderName,
    bool isUser,
  ) {
    if (quoted == null) return const SizedBox.shrink();
    final snippet = quoted.content.length > 50
        ? '${quoted.content.substring(0, 50)}...'
        : quoted.content;
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: isUser
            ? WeComChatTokens.lightText.withOpacity(0.08)
            : WeComChatTokens.lightChatBackground.withOpacity(0.8),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        children: [
          Container(
            width: 2,
            height: 28,
            color: WeComChatTokens.mention,
          ),
          const SizedBox(width: 7),
          if (senderName != null)
            Text(senderName,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: WeComChatTokens.mention)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(snippet,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: WeComChatTokens.text(context).withOpacity(0.68),
                )),
          ),
        ],
      ),
    );
  }

  /// Media rendering inside the bubble: image grid + video player, stacked above text.
  Widget _buildMediaContent(
      BuildContext context, Message message, ColorScheme cs, bool isUser) {
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
          if (att.type == 'video') {
            return VideoBubble(localPath: att.localPath, isUser: isUser);
          }
          return _buildFileAttachment(context, att, cs, isUser);
        }).toList(),
      ),
    );
  }

  /// Image thumbnail — tap to open fullscreen preview with InteractiveViewer.
  Widget _buildImageThumb(
      BuildContext context, MediaAttachment att, ColorScheme cs) {
    final data = uiAttachmentDataUriCache.decode(att.localPath);
    return GestureDetector(
      onTap: () => _openImageFullscreen(context, att.localPath),
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
  void _openImageFullscreen(BuildContext context, String path) {
    final data = uiAttachmentDataUriCache.decode(path);
    showDialog(
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

  Widget _buildFileAttachment(
    BuildContext context,
    MediaAttachment att,
    ColorScheme cs,
    bool isUser,
  ) {
    final textColor = WeComChatTokens.text(context);
    final subtleColor = textColor.withOpacity(0.62);
    final fillColor = isUser
        ? WeComChatTokens.lightText.withOpacity(0.07)
        : WeComChatTokens.chatBackground(context).withOpacity(0.7);
    return InkWell(
      onTap: () => _openAttachment(context, att),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(fileIconFor(att), size: 30, color: subtleColor),
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
                    formatAttachmentSize(att.fileSize),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: subtleColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.open_in_new_rounded, size: 18, color: subtleColor),
          ],
        ),
      ),
    );
  }

  Future<void> _openAttachment(
      BuildContext context, MediaAttachment att) async {
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
      final result = await OpenFilex.open(att.localPath, type: att.mimeType);
      if (result.type.name != 'done' && context.mounted) {
        AppToast.show(context, '打开失败：${result.message}',
            icon: Icons.error_outline_rounded);
      }
    } catch (e) {
      if (context.mounted) {
        AppToast.show(context, '打开失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  Widget _buildContent(BuildContext context, Message message) {
    final textColor = WeComChatTokens.text(context);
    final content = message.content.replaceAll('\\n', '\n');
    final mentionNames = <String>{
      ownerName,
      ...characters.map((character) => character.name),
    };
    final textStyle = TextStyle(fontSize: 15, color: textColor, height: 1.45);

    final base = MessageSelectableText(
      content: content,
      style: textStyle,
      spans: buildWeComMentionSpans(
        content,
        mentionNames: mentionNames,
        baseStyle: textStyle,
      ),
    );

    // Append a blinking cursor at the end during streaming for typewriter effect.
    if (isStreaming) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(child: base),
          const SizedBox(width: 2),
          BlinkingCursor(color: textColor),
        ],
      );
    }
    return base;
  }
}
