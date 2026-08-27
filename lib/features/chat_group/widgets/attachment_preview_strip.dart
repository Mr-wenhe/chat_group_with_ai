import 'dart:io';

import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:flutter/material.dart';

class AttachmentPreviewStrip extends StatelessWidget {
  final List<MediaAttachment> attachments;
  final ValueChanged<MediaAttachment> onRemove;

  const AttachmentPreviewStrip({
    super.key,
    required this.attachments,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: attachments.map((attachment) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              _AttachmentThumb(attachment: attachment),
              Positioned(
                top: -8,
                right: -8,
                child: IconButton(
                  onPressed: () => onRemove(attachment),
                  tooltip: '移除附件',
                  icon: Icon(
                    Icons.cancel,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: colorScheme.surface,
                    side: BorderSide(color: colorScheme.outlineVariant),
                    minimumSize: const Size(32, 32),
                    padding: const EdgeInsets.all(7),
                  ),
                ),
              ),
            ],
          );
        }).toList(growable: false),
      ),
    );
  }
}

class _AttachmentThumb extends StatelessWidget {
  final MediaAttachment attachment;

  const _AttachmentThumb({required this.attachment});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (attachment.type == 'image') {
      final data = uiAttachmentDataUriCache.decode(attachment.localPath);
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: data == null
            ? Image.file(
                File(attachment.localPath),
                width: 56,
                height: 56,
                fit: BoxFit.cover,
              )
            : Image.memory(
                data.bytes,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
                cacheWidth: 112,
                cacheHeight: 112,
                gaplessPlayback: true,
              ),
      );
    }

    final isFile = attachment.type == 'file';
    final icon = attachment.type == 'video'
        ? Icons.play_circle_outline_rounded
        : fileIconFor(attachment);
    return Container(
      width: isFile ? 150 : 56,
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisAlignment:
            isFile ? MainAxisAlignment.start : MainAxisAlignment.center,
        children: [
          Icon(icon, size: 28, color: colorScheme.onSurfaceVariant),
          if (isFile) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                attachment.fileName ?? fileNameFromPath(attachment.localPath),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
