part of 'workspace_file_service.dart';

/// Errors reported by the read-only workspace file service.
enum WorkspaceFileErrorKind {
  invalidRequest,
  notFile,
  notDirectory,
  nonText,
  timeout,
  io,
}

/// A user-safe error. The optional path is kept for callers, but is not
/// included in [toString] so raw workspace paths do not leak into logs.
class WorkspaceFileException implements Exception {
  final WorkspaceFileErrorKind kind;
  final String reason;
  final String? path;

  const WorkspaceFileException(this.kind, this.reason, {this.path});

  @override
  String toString() => 'WorkspaceFileException: $reason';
}

/// Cooperative cancellation token for bounded file operations.
class WorkspaceReadCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Limits applied to every workspace read operation.
class WorkspaceReadLimits {
  static const defaultMaxDirectoryEntries = 2000;
  static const defaultMaxFiles = 200;
  static const defaultMaxReadBytes = 512 * 1024;
  static const defaultMaxSearchBytes = 4 * 1024 * 1024;
  static const defaultMaxOutputCharacters = 12000;
  static const defaultMaxDepth = 8;
  static const defaultMaxDuration = Duration(seconds: 30);

  final int maxDirectoryEntries;
  final int maxFiles;
  final int maxReadBytes;
  final int maxSearchBytes;
  final int maxOutputCharacters;
  final Duration maxDuration;
  final int maxDepth;

  const WorkspaceReadLimits({
    this.maxDirectoryEntries = defaultMaxDirectoryEntries,
    this.maxFiles = defaultMaxFiles,
    this.maxReadBytes = defaultMaxReadBytes,
    this.maxSearchBytes = defaultMaxSearchBytes,
    this.maxOutputCharacters = defaultMaxOutputCharacters,
    this.maxDuration = defaultMaxDuration,
    this.maxDepth = defaultMaxDepth,
  })  : assert(maxDirectoryEntries > 0),
        assert(maxFiles > 0),
        assert(maxReadBytes > 0),
        assert(maxSearchBytes > 0),
        assert(maxOutputCharacters > 0),
        assert(maxDepth >= 0);

  int get maxSearchFiles => maxFiles;
}

enum WorkspaceFileEventKind { sensitiveRead }

class WorkspaceFileEvent {
  final WorkspaceFileEventKind kind;
  final String operation;
  final String path;
  final String detail;
  final DateTime timestamp;

  WorkspaceFileEvent({
    required this.kind,
    required this.operation,
    required this.path,
    required this.detail,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().toUtc();
}

typedef WorkspaceFileEventSink = void Function(WorkspaceFileEvent event);

class WorkspaceDirectoryEntry {
  final String name;
  final String path;
  final FileSystemEntityType type;

  const WorkspaceDirectoryEntry({
    required this.name,
    required this.path,
    required this.type,
  });

  bool get isFile => type == FileSystemEntityType.file;
  bool get isDirectory => type == FileSystemEntityType.directory;
  bool get isLink => type == FileSystemEntityType.link;
}

class WorkspaceDirectoryPage {
  final List<WorkspaceDirectoryEntry> entries;
  final int page;
  final int pageSize;
  final bool recursive;
  final bool hasMore;
  final bool truncated;
  final bool cancelled;
  final int filesExamined;
  final int bytesRead;
  final int outputCharacters;
  final Duration elapsed;

  const WorkspaceDirectoryPage({
    required this.entries,
    required this.page,
    required this.pageSize,
    required this.recursive,
    required this.hasMore,
    required this.truncated,
    required this.cancelled,
    required this.filesExamined,
    required this.bytesRead,
    required this.outputCharacters,
    required this.elapsed,
  });
}

class WorkspaceStat {
  final String path;
  final FileSystemEntityType type;
  final int size;
  final DateTime modified;
  final DateTime accessed;
  final bool wasSymbolicLink;
  final int filesExamined;
  final int bytesRead;
  final int outputCharacters;
  final Duration elapsed;

  const WorkspaceStat({
    required this.path,
    required this.type,
    required this.size,
    required this.modified,
    required this.accessed,
    required this.wasSymbolicLink,
    required this.filesExamined,
    required this.bytesRead,
    required this.outputCharacters,
    required this.elapsed,
  });

  bool get isFile => type == FileSystemEntityType.file;
  bool get isDirectory => type == FileSystemEntityType.directory;
  bool get isLink => type == FileSystemEntityType.link;
}

class WorkspaceTextReadResult {
  final String path;
  final String text;
  final int startByte;
  final int bytesRead;
  final int filesExamined;
  final int outputCharacters;
  final bool truncated;
  final bool cancelled;
  final bool sensitive;
  final Duration elapsed;

  const WorkspaceTextReadResult({
    required this.path,
    required this.text,
    required this.startByte,
    required this.bytesRead,
    this.filesExamined = 0,
    required this.outputCharacters,
    required this.truncated,
    required this.cancelled,
    required this.sensitive,
    required this.elapsed,
  });
}

class WorkspaceSearchMatch {
  final String path;
  final int line;
  final int column;
  final String snippet;
  final bool sensitive;

  const WorkspaceSearchMatch({
    required this.path,
    required this.line,
    required this.column,
    required this.snippet,
    this.sensitive = false,
  });

  int get lineNumber => line;
}

class WorkspaceSearchResult {
  final String query;
  final List<WorkspaceSearchMatch> matches;
  final bool recursive;
  final bool truncated;
  final bool cancelled;
  final int filesExamined;
  final int bytesRead;
  final int outputCharacters;
  final int nonTextFiles;
  final Duration elapsed;

  const WorkspaceSearchResult({
    required this.query,
    required this.matches,
    required this.recursive,
    required this.truncated,
    required this.cancelled,
    required this.filesExamined,
    required this.bytesRead,
    required this.outputCharacters,
    required this.nonTextFiles,
    required this.elapsed,
  });
}
