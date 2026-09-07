import 'dart:async';

enum DocumentParseStatus { pending, ready, unsupported, tooLarge, failed }

class DocumentSourceLocation {
  final String fileName;
  final int? paragraph;
  final int? lineStart;
  final int? lineEnd;
  final int? page;
  final String? sheet;

  const DocumentSourceLocation({
    required this.fileName,
    this.paragraph,
    this.lineStart,
    this.lineEnd,
    this.page,
    this.sheet,
  });

  String get label {
    if (page != null) return '$fileName · 第 $page 页';
    if (sheet != null) {
      final rows =
          lineStart == lineEnd ? '行 $lineStart' : '行 $lineStart-$lineEnd';
      return '$fileName · 工作表 $sheet · $rows';
    }
    if (lineStart != null) {
      return lineStart == lineEnd
          ? '$fileName · 行 $lineStart'
          : '$fileName · 行 $lineStart-$lineEnd';
    }
    return '$fileName · 段落 $paragraph';
  }
}

class DocumentChunk {
  final String text;
  final DocumentSourceLocation source;

  const DocumentChunk({required this.text, required this.source});
}

class DocumentParseResult {
  final DocumentParseStatus status;
  final List<DocumentChunk> chunks;
  final String? error;

  const DocumentParseResult(this.status, this.chunks, {this.error});
}

class DocumentProcessingToken {
  bool _cancelled = false;
  final Completer<void> _cancelledSignal = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledSignal.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledSignal.complete();
  }
}

// Text/code formats share the same bounded UTF-8 reader and paragraph/line
// chunker. Keeping this list here avoids a second parser just for work-mode
// source files.
const Set<String> documentTextFormats = {
  'txt',
  'md',
  'markdown',
  'json',
  'csv',
  'dart',
  'py',
  'js',
  'jsx',
  'ts',
  'tsx',
  'java',
  'kt',
  'kts',
  'go',
  'rs',
  'c',
  'cc',
  'cpp',
  'h',
  'hh',
  'hpp',
  'cs',
  'swift',
  'm',
  'mm',
  'sh',
  'bash',
  'zsh',
  'fish',
  'html',
  'htm',
  'css',
  'scss',
  'less',
  'sql',
  'yaml',
  'yml',
  'xml',
  'toml',
  'ini',
  'conf',
  'gradle',
  'graphql',
  'gql',
  'proto',
  'vue',
  'svelte',
  'rb',
  'php',
  'pl',
  'r',
  'log',
};
