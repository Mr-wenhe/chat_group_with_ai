import 'package:path/path.dart' as p;

enum AttachmentPreviewFormat {
  markdown,
  text,
  code,
  html,
  pdf,
  office,
  spreadsheet,
  image,
  audio,
  video,
  unsupported
}

/// Shared by the card and viewer, independent of the attachment's parse status.
AttachmentPreviewFormat attachmentPreviewFormat(String name,
    {String? mimeType, String? mediaType}) {
  final ext = p.extension(name).toLowerCase();
  if (const {'.md', '.markdown', '.mdown'}.contains(ext)) {
    return AttachmentPreviewFormat.markdown;
  }
  if (const {'.html', '.htm'}.contains(ext)) {
    return AttachmentPreviewFormat.html;
  }
  if (ext == '.pdf') return AttachmentPreviewFormat.pdf;
  if (const {'.doc', '.docx', '.ppt', '.pptx', '.odt', '.odp', '.rtf'}
      .contains(ext)) {
    return AttachmentPreviewFormat.office;
  }
  if (const {'.xls', '.xlsx', '.ods', '.csv', '.tsv'}.contains(ext)) {
    return AttachmentPreviewFormat.spreadsheet;
  }
  if (const {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico', '.svg'}
      .contains(ext)) {
    return AttachmentPreviewFormat.image;
  }
  if (const {'.mp3', '.wav', '.m4a', '.aac', '.ogg', '.flac', '.opus', '.aiff'}
      .contains(ext)) {
    return AttachmentPreviewFormat.audio;
  }
  if (const {'.mp4', '.m4v', '.mov', '.webm', '.avi', '.mkv', '.wmv'}
      .contains(ext)) {
    return AttachmentPreviewFormat.video;
  }
  if (const {'.txt', '.log', '.text'}.contains(ext)) {
    return AttachmentPreviewFormat.text;
  }
  if (codeLanguage(name) != null) return AttachmentPreviewFormat.code;
  if (mediaType == 'image' || mimeType?.startsWith('image/') == true) {
    return AttachmentPreviewFormat.image;
  }
  if (mediaType == 'video' || mimeType?.startsWith('video/') == true) {
    return AttachmentPreviewFormat.video;
  }
  if (mimeType?.startsWith('audio/') == true) {
    return AttachmentPreviewFormat.audio;
  }
  return AttachmentPreviewFormat.unsupported;
}

String? codeLanguage(String name) => const {
      '.dart': 'dart',
      '.py': 'python',
      '.js': 'javascript',
      '.jsx': 'javascript',
      '.ts': 'typescript',
      '.tsx': 'typescript',
      '.json': 'json',
      '.yaml': 'yaml',
      '.yml': 'yaml',
      '.xml': 'xml',
      '.css': 'css',
      '.scss': 'scss',
      '.sh': 'bash',
      '.bash': 'bash',
      '.zsh': 'bash',
      '.ps1': 'powershell',
      '.bat': 'dos',
      '.c': 'c',
      '.h': 'cpp',
      '.cpp': 'cpp',
      '.cc': 'cpp',
      '.cs': 'cs',
      '.java': 'java',
      '.kt': 'kotlin',
      '.swift': 'swift',
      '.go': 'go',
      '.rs': 'rust',
      '.rb': 'ruby',
      '.php': 'php',
      '.sql': 'sql',
      '.toml': 'ini',
      '.ini': 'ini',
      '.conf': 'ini',
      '.vue': 'xml',
      '.svelte': 'xml',
    }[p.extension(name).toLowerCase()];
