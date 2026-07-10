import 'dart:io';

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';

typedef AgentAttachmentTextReader = Future<String> Function(String path);

class AgentAttachmentContext {
  static const int maxInlineFileBytes = 256 * 1024;
  static const int maxInlineCharsPerFile = 12000;

  static Future<String> enhanceCurrentRequest({
    required String userRequest,
    required List<MediaAttachment>? media,
    AgentAttachmentTextReader? readText,
  }) async {
    final context = await _attachmentContext(
      media ?? const [],
      readText: readText,
    );
    if (context.isEmpty) return userRequest;
    return '$userRequest\n\n$context';
  }

  static Future<List<Map<String, dynamic>>> buildHistory({
    required List<Message> messages,
    required String currentUserRequest,
    int maxMessages = 12,
    AgentAttachmentTextReader? readText,
  }) async {
    final source = List<Message>.from(messages);
    final normalizedRequest = currentUserRequest.trim();
    var removedCurrent = false;
    for (var index = source.length - 1; index >= 0; index--) {
      final message = source[index];
      if (message.senderType == 'user' &&
          message.content.trim() == normalizedRequest) {
        source.removeAt(index);
        removedCurrent = true;
        break;
      }
    }
    if (!removedCurrent &&
        source.isNotEmpty &&
        source.last.senderType == 'user') {
      source.removeLast();
    }
    final trimmed = source.length > maxMessages
        ? source.sublist(source.length - maxMessages)
        : source;
    final result = <Map<String, dynamic>>[];
    for (final message in trimmed) {
      final attachmentContext = await _attachmentContext(
        message.media ?? const [],
        readText: readText,
      );
      final content = [message.content.trim(), attachmentContext]
          .where((value) => value.isNotEmpty)
          .join('\n\n');
      if (content.isEmpty) continue;
      if (message.senderType == 'user') {
        result.add({'role': 'user', 'content': content});
      } else if (message.senderType == 'ai') {
        result.add({'role': 'assistant', 'content': content});
      }
    }
    return result;
  }

  static Future<String> _attachmentContext(
    List<MediaAttachment> media, {
    AgentAttachmentTextReader? readText,
  }) async {
    if (media.isEmpty) return '';
    final reader = readText ?? (path) => File(path).readAsString();
    final lines = <String>['【持续可用的附件上下文】'];
    for (final attachment in media.take(8)) {
      final name = attachment.fileName ?? _basename(attachment.localPath);
      lines.add('- $name；类型=${attachment.type}；本地路径=${attachment.localPath}');
      if (!_isTextAttachment(attachment) ||
          (attachment.fileSize ?? 0) > maxInlineFileBytes) {
        continue;
      }
      try {
        final raw = await reader(attachment.localPath);
        final clipped = raw.length <= maxInlineCharsPerFile
            ? raw
            : '${raw.substring(0, maxInlineCharsPerFile)}\n…（附件内容已截断）';
        lines.add('【$name 内容】\n$clipped');
      } catch (_) {
        lines.add('【$name 内容暂时无法读取；仍请记住文件名和路径】');
      }
    }
    return lines.join('\n');
  }

  static bool _isTextAttachment(MediaAttachment attachment) {
    final mime = attachment.mimeType?.toLowerCase() ?? '';
    if (mime.startsWith('text/')) return true;
    final extension = _basename(attachment.fileName ?? attachment.localPath)
        .split('.')
        .last
        .toLowerCase();
    return const {
      'txt', 'md', 'markdown', 'json', 'yaml', 'yml', 'csv', 'dart',
      'html', 'css', 'js', 'ts', 'py', 'sh', 'c', 'cc', 'cpp', 'h', 'hpp',
      'xml', 'toml', 'ini', 'log',
    }.contains(extension);
  }

  static String _basename(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? path : parts.last;
  }
}
