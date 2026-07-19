import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:flutter/foundation.dart';

/// 读文件字节的函数签名，便于在单测中注入假数据（不依赖真实文件）。
typedef FileBytesReader = Uint8List Function(String path);
typedef AsyncFileBytesReader = Future<Uint8List> Function(String path);

const int defaultMaxVisionImages = 4;
const int defaultMaxInlineImageBytes = 5 * 1024 * 1024;

/// 根据用户消息与 provider 的视觉能力，生成发送给 AI 的 content。
///
/// 返回类型为 dynamic，原因：
/// - 无媒体时返回纯文本 [String]；
/// - 含图片且支持视觉时返回 OpenAI 兼容的 content parts [List]：
///   ```dart
///   [
///     {"type": "text", "text": "<文案>"},
///     {"type": "image_url", "image_url": {"url": "data:<mime>;base64,..."}}
///   ]
///   ```
///
/// 规则：
/// - 无媒体 → 返回 [Message.content]。
/// - 有图片且 [supportsVision] → 图片读取为 base64 `data:<mime>;base64,...` 嵌入，图文混排。
/// - 有图片但 `!supportsVision` → 返回字符串 `"<文案>\n[用户发送了 N 张图片]"`。
/// - 有视频 → 文案后追加 `"[用户发送了一段视频]"`（视频不送视觉模型）。
/// - 有普通文件 → 文案后追加文件名提示（普通文件不内联发送给模型）。
/// - 图片 + 视频/文件混合 → 图片按 [supportsVision] 处理，其余追加文字提示。
///
/// [fileReader] 默认从本地文件同步读取字节；单测时注入假的字节以避免真实 IO。
dynamic buildUserMessageContent(
  Message message, {
  required bool supportsVision,
  FileBytesReader? fileReader,
  int maxVisionImages = defaultMaxVisionImages,
  int maxInlineImageBytes = defaultMaxInlineImageBytes,
  Map<String, String> preparedImageDataUris = const {},
}) {
  final media = message.media ?? const <MediaAttachment>[];
  if (media.isEmpty) {
    return message.content;
  }

  final readBytes = fileReader ?? _defaultFileReader;
  final images = media.where((m) => m.type == 'image').toList();
  final videos = media.where((m) => m.type == 'video').toList();
  final files =
      media.where((m) => m.type != 'image' && m.type != 'video').toList();
  final text = message.content;

  // 视频不送视觉模型，统一追加文字提示。
  final videoHint = videos.isEmpty ? '' : '[用户发送了一段视频]';
  final fileHint = _fileHint(files);

  // 无图片：直接拼接文案与非视觉附件提示。
  if (images.isEmpty) {
    return [text, videoHint, fileHint].where((s) => s.isNotEmpty).join('\n');
  }

  if (supportsVision) {
    // 图片按多模态内容处理：文案 + 每张图片作为 image_url part。
    final parts = <Map<String, dynamic>>[];
    if (text.isNotEmpty) {
      parts.add({'type': 'text', 'text': text});
    }
    var readableImageCount = 0;
    var unreadableImageCount = 0;
    var skippedImageCount = 0;
    for (final image in images) {
      if (readableImageCount >= maxVisionImages) {
        skippedImageCount++;
        continue;
      }
      if ((image.fileSize ?? 0) > maxInlineImageBytes) {
        skippedImageCount++;
        continue;
      }
      final preparedDataUri = preparedImageDataUris[image.localPath];
      Uint8List? bytes;
      if (preparedDataUri == null) {
        try {
          bytes = readBytes(image.localPath);
        } catch (_) {
          unreadableImageCount++;
          continue;
        }
        if (bytes.lengthInBytes > maxInlineImageBytes) {
          skippedImageCount++;
          continue;
        }
      }
      readableImageCount++;
      final mime = image.mimeType ?? 'image/jpeg';
      parts.add({
        'type': 'image_url',
        'image_url': {
          'url': preparedDataUri ?? 'data:$mime;base64,${base64Encode(bytes!)}',
        },
      });
    }
    if (unreadableImageCount > 0) {
      parts.add({
        'type': 'text',
        'text': _unreadableImageHint(unreadableImageCount),
      });
    }
    if (skippedImageCount > 0) {
      parts.add({
        'type': 'text',
        'text': _skippedImageHint(skippedImageCount),
      });
    }
    if (videoHint.isNotEmpty) {
      parts.add({'type': 'text', 'text': videoHint});
    }
    if (fileHint.isNotEmpty) {
      parts.add({'type': 'text', 'text': fileHint});
    }
    if (readableImageCount == 0) {
      return [
        text,
        _unreadableImageHint(unreadableImageCount),
        _skippedImageHint(skippedImageCount),
        videoHint,
        fileHint,
      ].where((s) => s.isNotEmpty).join('\n');
    }
    return parts;
  } else {
    // 不支持视觉：图片降级为文字提示。
    final imageHint = '[用户发送了 ${images.length} 张图片]';
    return [text, imageHint, videoHint, fileHint]
        .where((s) => s.isNotEmpty)
        .join('\n');
  }
}

/// Prepares image bytes and Base64 away from the chat page's synchronous UI
/// path, then reuses the established content-shaping rules above.
Future<dynamic> prepareUserMessageContent(
  Message message, {
  required bool supportsVision,
  AsyncFileBytesReader? fileReader,
  int maxVisionImages = defaultMaxVisionImages,
  int maxInlineImageBytes = defaultMaxInlineImageBytes,
  String? documentQuery,
  DocumentTextReader? documentTextReader,
  DocumentProcessingToken? documentCancelToken,
  bool includeDocumentContext = true,
}) async {
  final documentContext = includeDocumentContext
      ? await DocumentUnderstandingService.buildPromptContext(
          query: documentQuery ?? message.content,
          attachments: message.media ?? const [],
          readText: documentTextReader,
          cancelToken: documentCancelToken,
        )
      : '';
  final preparedMessage = documentContext.isEmpty
      ? message
      : Message(
          id: message.id,
          groupId: message.groupId,
          senderId: message.senderId,
          senderType: message.senderType,
          content: '${message.content}\n\n$documentContext',
          timestamp: message.timestamp,
          replyToMessageId: message.replyToMessageId,
          isMention: message.isMention,
          mentionedAiIds: message.mentionedAiIds,
          media: message.media,
        );
  if (!supportsVision || message.media == null) {
    return buildUserMessageContent(
      preparedMessage,
      supportsVision: supportsVision,
      maxVisionImages: maxVisionImages,
      maxInlineImageBytes: maxInlineImageBytes,
    );
  }
  final readBytes = fileReader ?? _defaultAsyncFileReader;
  final prepared = <String, String>{};
  for (final image in message.media!.where((item) => item.type == 'image')) {
    if (prepared.length >= maxVisionImages ||
        (image.fileSize ?? 0) > maxInlineImageBytes) {
      continue;
    }
    try {
      final data = decodeAttachmentDataUri(image.localPath);
      if (data != null) {
        prepared[image.localPath] = image.localPath;
        continue;
      }
      final bytes = await readBytes(image.localPath);
      if (bytes.lengthInBytes > maxInlineImageBytes) continue;
      final encoded = await compute(_encodeBase64, bytes);
      prepared[image.localPath] =
          'data:${image.mimeType ?? 'image/jpeg'};base64,$encoded';
    } catch (_) {
      // The established builder adds the same unreadable-image hint.
    }
  }
  return buildUserMessageContent(
    preparedMessage,
    supportsVision: supportsVision,
    fileReader: (path) {
      final data = decodeAttachmentDataUri(path);
      if (data != null) return data.bytes;
      throw FileSystemException('Image was not prepared', path);
    },
    maxVisionImages: maxVisionImages,
    maxInlineImageBytes: maxInlineImageBytes,
    preparedImageDataUris: prepared,
  );
}

String _encodeBase64(Uint8List bytes) => base64Encode(bytes);

Future<Uint8List> _defaultAsyncFileReader(String path) async {
  final data = decodeAttachmentDataUri(path);
  if (data != null) return data.bytes;
  return File(path).readAsBytes();
}

/// Legacy synchronous entry point only supports already-inline data URIs.
Uint8List _defaultFileReader(String path) {
  final data = decodeAttachmentDataUri(path);
  if (data != null) return data.bytes;
  throw FileSystemException(
      'Use prepareUserMessageContent for local files', path);
}

String _unreadableImageHint(int count) {
  if (count <= 0) return '';
  return '[用户发送了 $count 张图片，但本地文件暂时不可读取]';
}

String _skippedImageHint(int count) {
  if (count <= 0) return '';
  return '[用户还发送了 $count 张图片，但因为数量或体积限制没有内联发送]';
}

String _fileHint(List<MediaAttachment> files) {
  if (files.isEmpty) return '';
  if (files.length == 1) {
    final file = files.first;
    final name = file.fileName ?? _basename(file.localPath);
    final size =
        file.fileSize == null ? '' : '，${_formatBytes(file.fileSize!)}';
    return '[用户发送了文件：$name$size]';
  }
  final names = files
      .take(6)
      .map((file) => file.fileName ?? _basename(file.localPath))
      .join('、');
  final suffix = files.length > 6 ? ' 等' : '';
  return '[用户发送了 ${files.length} 个文件：$names$suffix]';
}

String _basename(String path) {
  final segments = path.split(RegExp(r'[/\\]'));
  return segments.isEmpty ? path : segments.last;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
}
