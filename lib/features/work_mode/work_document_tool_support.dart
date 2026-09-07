part of 'work_document_tool.dart';

const Set<String> _imageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'heic',
  'heif',
  'avif',
  'svg',
  'tif',
  'tiff',
};
const Set<String> _audioExtensions = {
  'aac',
  'flac',
  'm4a',
  'mp3',
  'ogg',
  'wav',
  'opus',
  'wma',
  'aiff',
};
const Set<String> _videoExtensions = {
  'avi',
  'm4v',
  'mkv',
  'mov',
  'mp4',
  'mpeg',
  'mpg',
  'webm',
  'wmv',
  '3gp',
};

WorkToolResult _unsupportedDocument(String fileName) => WorkToolResult.failed(
      message: '暂不支持读取 $fileName。当前版本支持文本、代码、PDF、DOCX 和 XLSX。',
      failureCode: 'unsupportedMedia',
      data: {
        'fileName': fileName,
        'unsupportedMedia': true,
        'mediaKind': 'document',
      },
    );

WorkToolResult _unsupportedMedia(String fileName, _MediaKind kind) {
  final label = kind == _MediaKind.audio ? '音频' : '视频';
  return WorkToolResult.failed(
    message: '当前版本不支持$label分析：$fileName。无需安装转码服务。',
    failureCode: 'unsupportedMedia',
    data: {
      'fileName': fileName,
      'unsupportedMedia': true,
      'mediaKind': kind.name,
    },
  );
}

String _documentMessage(String fileName, List<DocumentChunk> chunks) {
  final labels =
      chunks.map((chunk) => chunk.source.label).toSet().take(6).join('；');
  final suffix = labels.isEmpty ? '' : '（$labels）';
  return '已读取 $fileName，已提供 ${chunks.length} 个相关片段$suffix。';
}

Map<String, dynamic> _sourceData(DocumentChunk chunk) {
  final source = chunk.source;
  return {
    'fileName': source.fileName,
    if (source.paragraph != null) 'paragraph': source.paragraph,
    if (source.lineStart != null) 'lineStart': source.lineStart,
    if (source.lineEnd != null) 'lineEnd': source.lineEnd,
    if (source.page != null) 'page': source.page,
    if (source.sheet != null) 'sheet': source.sheet,
  };
}

_MediaKind _mediaKind(String fileName, String? mimeType) {
  final mime = mimeType?.toLowerCase() ?? '';
  if (mime.startsWith('image/')) return _MediaKind.image;
  if (mime.startsWith('audio/')) return _MediaKind.audio;
  if (mime.startsWith('video/')) return _MediaKind.video;
  final extension = _extension(fileName);
  if (_imageExtensions.contains(extension)) return _MediaKind.image;
  if (_audioExtensions.contains(extension)) return _MediaKind.audio;
  if (_videoExtensions.contains(extension)) return _MediaKind.video;
  return _MediaKind.document;
}

String? _mimeType(String fileName) => switch (_extension(fileName)) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      'avif' => 'image/avif',
      'svg' => 'image/svg+xml',
      'tif' || 'tiff' => 'image/tiff',
      'pdf' => 'application/pdf',
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xlsx' =>
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'json' => 'application/json',
      'csv' => 'text/csv',
      'html' || 'htm' => 'text/html',
      'xml' => 'application/xml',
      'js' || 'jsx' || 'ts' || 'tsx' => 'text/javascript',
      'py' => 'text/x-python',
      'dart' => 'text/x-dart',
      _ => null,
    };

String _pathReason(WorkspacePathErrorKind kind) => switch (kind) {
      WorkspacePathErrorKind.notAuthorized => '路径不在授权目录内。',
      WorkspacePathErrorKind.symlinkEscape => '路径通过符号链接越过授权目录。',
      WorkspacePathErrorKind.invalidPath => '路径格式无效。',
      WorkspacePathErrorKind.notFound => '文件不存在。',
      WorkspacePathErrorKind.brokenSymlink => '符号链接目标不可用。',
      WorkspacePathErrorKind.inaccessible => '路径无法访问。',
      WorkspacePathErrorKind.timeout => '路径校验超时。',
    };

String _formatHint(String fileName) {
  final extension = _extension(fileName);
  return extension.isEmpty ? '' : '（$extension）';
}

String _extension(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final value = normalized.split('/').last.trim();
  return value.isEmpty ? '文件' : value;
}

enum _MediaKind { document, image, audio, video }
