/// Pure utility functions for attachment display and file path handling.
///
/// Consolidates the duplicate implementations that previously existed in both
/// top-level functions and `_ChatRoomPageState` methods of
/// `chat_room_page.dart`.
library;

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// File path helpers
// ---------------------------------------------------------------------------

/// Returns the file name portion of a path (last segment after `/` or `\`).
String fileNameFromPath(String path) {
  final segments = path.split(RegExp(r'[/\\]'));
  return segments.isEmpty ? path : segments.last;
}

/// Returns the lower-cased file extension (without the dot) from a path.
///
/// Returns an empty string when the path has no extension or the dot is the
/// last character.
String extensionOfPath(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

// ---------------------------------------------------------------------------
// File icon mapping
// ---------------------------------------------------------------------------

/// Maps a [MediaAttachment] to an appropriate [IconData] based on its
/// file extension.
IconData fileIconFor(MediaAttachment att) {
  final ext = extensionOfPath(att.fileName ?? att.localPath);
  return fileIconForExtension(ext);
}

/// Maps a file extension string to an appropriate [IconData].
IconData fileIconForExtension(String ext) {
  return switch (ext) {
    'pdf' => Icons.picture_as_pdf_rounded,
    'zip' || 'rar' || '7z' => Icons.folder_zip_rounded,
    'doc' || 'docx' => Icons.description_rounded,
    'xls' || 'xlsx' || 'csv' => Icons.table_chart_rounded,
    'ppt' || 'pptx' => Icons.slideshow_rounded,
    'txt' ||
    'md' ||
    'json' ||
    'yaml' ||
    'yml' ||
    'dart' =>
      Icons.article_rounded,
    _ => Icons.insert_drive_file_rounded,
  };
}

// ---------------------------------------------------------------------------
// File size formatting
// ---------------------------------------------------------------------------

/// Formats a byte count into a human-readable string (e.g. "1.5 KB", "2 MB").
///
/// Returns `'文件'` when [bytes] is `null`.
String formatAttachmentSize(int? bytes) {
  if (bytes == null) return '文件';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
}
