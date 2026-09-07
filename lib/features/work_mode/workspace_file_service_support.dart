part of 'workspace_file_service.dart';

extension _WorkspaceFileServiceSupport on WorkspaceFileService {
  Future<_DirectoryScan> _collectDirectory(
    Directory root, {
    required bool recursive,
    required int limit,
    required _ReadBudget budget,
    required WorkspaceReadCancellation? cancellation,
  }) async {
    final queue = Queue<({Directory directory, int depth})>()
      ..add((directory: root, depth: 0));
    final entries = <WorkspaceDirectoryEntry>[];
    var filesExamined = 0;
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      final directory = current.directory;
      try {
        await for (final entity in directory.list(followLinks: false).timeout(
              budget.remaining,
            )) {
          budget.check();
          if (cancellation?.isCancelled == true) {
            return _directoryScan(
              entries,
              filesExamined,
              cancelled: true,
            );
          }
          if (_shouldSkipEntry(entity.path, skipSensitive: true)) continue;
          filesExamined++;
          if (entries.length >= limit) {
            return _directoryScan(
              entries,
              filesExamined,
              reachedLimit: true,
            );
          }
          final type = await _bounded(
            FileSystemEntity.type(entity.path, followLinks: false),
            budget,
          );
          final path = WorkspacePathPolicy.normalizePath(
            entity.path,
            isWindows: pathPolicy.isWindows,
          );
          entries.add(
            WorkspaceDirectoryEntry(
              name: _basename(path),
              path: path,
              type: type,
            ),
          );
          if (recursive &&
              type == FileSystemEntityType.directory &&
              current.depth < limits.maxDepth) {
            queue.add(
                (directory: Directory(entity.path), depth: current.depth + 1));
          }
        }
      } on TimeoutException {
        throw const WorkspaceFileException(
          WorkspaceFileErrorKind.timeout,
          '目录遍历超时。',
        );
      } on WorkspaceFileException {
        rethrow;
      } on Object {
        throw const WorkspaceFileException(
          WorkspaceFileErrorKind.io,
          '无法读取目录。',
        );
      }
    }
    return _directoryScan(entries, filesExamined);
  }

  _DirectoryScan _directoryScan(
    List<WorkspaceDirectoryEntry> entries,
    int filesExamined, {
    bool reachedLimit = false,
    bool cancelled = false,
  }) {
    entries.sort((left, right) => left.path.compareTo(right.path));
    return _DirectoryScan(
      entries,
      filesExamined,
      reachedLimit: reachedLimit,
      cancelled: cancelled,
    );
  }

  Future<_SearchScan> _collectSearchFiles(
    Directory root, {
    required bool recursive,
    required int limit,
    required _ReadBudget budget,
    required WorkspaceReadCancellation? cancellation,
    required bool skipSensitive,
  }) async {
    final queue = Queue<({Directory directory, int depth})>()
      ..add((directory: root, depth: 0));
    final files = <String>[];
    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      final directory = current.directory;
      try {
        await for (final entity in directory.list(followLinks: false).timeout(
              budget.remaining,
            )) {
          budget.check();
          if (cancellation?.isCancelled == true) {
            return _SearchScan(files, reachedLimit: false, cancelled: true);
          }
          // Directory searches skip sensitive names by default. A caller must
          // explicitly opt in before any secret-bearing file is read; direct
          // sensitive-file searches are guarded by the Stage 02 boundary.
          if (_shouldSkipEntry(entity.path, skipSensitive: skipSensitive)) {
            continue;
          }
          final type = await _bounded(
            FileSystemEntity.type(entity.path, followLinks: false),
            budget,
          );
          // Directory walks never follow links. A linked directory/file is
          // examined only when the user names that path directly.
          if (type == FileSystemEntityType.link) continue;
          if (type == FileSystemEntityType.directory) {
            if (recursive && current.depth < limits.maxDepth) {
              queue.add((
                directory: Directory(entity.path),
                depth: current.depth + 1
              ));
            }
            continue;
          }
          if (type != FileSystemEntityType.file) continue;
          if (files.length >= limit) {
            return _SearchScan(files, reachedLimit: true, cancelled: false);
          }
          try {
            final resolved = await pathPolicy.resolveExisting(entity.path);
            if (resolved.isFile) files.add(resolved.path);
          } on WorkspacePathException {
            // The directory may have changed or a race may have introduced a
            // link. Skip that candidate instead of weakening the outer guard.
          }
        }
      } on TimeoutException {
        throw const WorkspaceFileException(
          WorkspaceFileErrorKind.timeout,
          '搜索目录超时。',
        );
      } on WorkspaceFileException {
        rethrow;
      } on Object {
        throw const WorkspaceFileException(
          WorkspaceFileErrorKind.io,
          '无法读取搜索目录。',
        );
      }
      files.sort((a, b) => a.compareTo(b));
    }
    return _SearchScan(files, reachedLimit: false, cancelled: false);
  }

  Future<_ByteRead> _readBytes(
    File file, {
    required int startByte,
    required int endByte,
    required _ReadBudget budget,
    required WorkspaceReadCancellation? cancellation,
  }) async {
    if (endByte <= startByte) {
      return const _ByteRead([], 0, truncated: false, cancelled: false);
    }
    final bytes = BytesBuilder(copy: false);
    var bytesRead = 0;
    try {
      await for (final chunk
          in file.openRead(startByte, endByte).timeout(budget.remaining)) {
        budget.check();
        if (cancellation?.isCancelled == true) {
          return _ByteRead(
            bytes.takeBytes(),
            bytesRead,
            truncated: true,
            cancelled: true,
          );
        }
        bytes.add(chunk);
        bytesRead += chunk.length;
      }
    } on TimeoutException {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.timeout,
        '文件读取超时。',
      );
    } on FileSystemException {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.io,
        '无法读取文件。',
      );
    } on Object {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.io,
        '无法读取文件。',
      );
    }
    final total = await _bounded(file.length(), budget);
    return _ByteRead(
      bytes.takeBytes(),
      bytesRead,
      truncated: startByte + bytesRead < total,
      cancelled: false,
    );
  }

  String _decodeStrict(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.nonText,
        '文件不是有效的 UTF-8 文本。',
      );
    }
  }

  _MatchScan _findMatches(
    String path,
    String text,
    String query, {
    required bool caseSensitive,
    required int outputBudget,
    required bool sensitive,
    required bool allowSensitive,
  }) {
    if (outputBudget <= 0) return const _MatchScan([], 0, truncated: true);
    final needle = caseSensitive ? query : query.toLowerCase();
    final matches = <WorkspaceSearchMatch>[];
    var outputCharacters = 0;
    final lines = text.split('\n');
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      final line = lines[lineIndex];
      final haystack = caseSensitive ? line : line.toLowerCase();
      var offset = 0;
      while (offset <= haystack.length) {
        final found = haystack.indexOf(needle, offset);
        if (found < 0) break;
        final rawSnippet = line.substring(
          found > 80 ? found - 80 : 0,
          (found + query.length + 80).clamp(0, line.length).toInt(),
        );
        final snippet = sensitive && !allowSensitive
            ? _truncateCharacters(
                '[敏感文件内容已隐藏]',
                outputBudget - outputCharacters,
              )
            : _truncateCharacters(
                rawSnippet,
                outputBudget - outputCharacters,
              );
        outputCharacters += snippet.text.runes.length;
        matches.add(
          WorkspaceSearchMatch(
            path: path,
            line: lineIndex + 1,
            column: found + 1,
            snippet: snippet.text,
            sensitive: sensitive,
          ),
        );
        if (snippet.truncated || outputCharacters >= outputBudget) {
          return _MatchScan(
            matches,
            outputCharacters,
            truncated: true,
          );
        }
        offset = found + (needle.isEmpty ? 1 : needle.length);
      }
    }
    return _MatchScan(matches, outputCharacters, truncated: false);
  }

  Future<T> _bounded<T>(Future<T> operation, _ReadBudget budget) {
    final remaining = budget.remaining;
    if (remaining <= Duration.zero) {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.timeout,
        '文件操作超时。',
      );
    }
    return operation.timeout(
      remaining,
      onTimeout: () => throw const WorkspaceFileException(
        WorkspaceFileErrorKind.timeout,
        '文件操作超时。',
      ),
    );
  }

  void _checkCancellation(WorkspaceReadCancellation? cancellation) {
    if (cancellation?.isCancelled == true) {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.invalidRequest,
        '操作已取消。',
      );
    }
  }

  FileSystemEntity _entityFor(WorkspaceResolvedPath path) =>
      path.isDirectory ? Directory(path.path) : File(path.path);

  int _boundedLimit(int? requested, int maximum) {
    if (requested == null) return maximum;
    if (requested <= 0) {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.invalidRequest,
        '预算必须为正数。',
      );
    }
    return requested > maximum ? maximum : requested;
  }

  void _emitSensitive(String operation) {
    try {
      onEvent?.call(
        WorkspaceFileEvent(
          kind: WorkspaceFileEventKind.sensitiveRead,
          operation: operation,
          path: '[redacted]',
          detail: '已读取敏感文件，路径和正文已隐藏。',
        ),
      );
    } on Object {
      // Diagnostics must never turn a successful read into a failed read.
    }
  }

  bool _isSensitiveName(String path) {
    final name = _basename(path).toLowerCase();
    final extension = name.contains('.') ? name.split('.').last : '';
    return name == '.env' ||
        name.startsWith('.env.') ||
        name.contains('credential') ||
        name.contains('secret') ||
        name.contains('password') ||
        name.contains('token') ||
        name.contains('apikey') ||
        name.contains('api_key') ||
        name.contains('api-key') ||
        name.contains('access_token') ||
        name.contains('access-token') ||
        name.contains('client_secret') ||
        name.contains('client-secret') ||
        name == '.git-credentials' ||
        name == '.npmrc' ||
        name == '.pypirc' ||
        name.contains('private-key') ||
        name.contains('private_key') ||
        name == 'id_rsa' ||
        const {'pem', 'key', 'p12', 'pfx', 'crt', 'cer'}.contains(extension);
  }

  bool _shouldSkipEntry(String path, {required bool skipSensitive}) {
    final name = _basename(path).toLowerCase();
    if (const {
      '.git',
      '.dart_tool',
      '.idea',
      '.gradle',
      'build',
      'node_modules',
      'cache',
      '__pycache__',
    }.contains(name)) {
      return true;
    }
    return skipSensitive && (name.startsWith('.env') || _isSensitiveName(path));
  }

  String _basename(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  WorkspaceDirectoryPage _emptyDirectoryPage(
    int page,
    int pageSize,
    bool recursive,
    _ReadBudget budget, {
    bool cancelled = false,
  }) =>
      WorkspaceDirectoryPage(
        entries: const [],
        page: page,
        pageSize: pageSize,
        recursive: recursive,
        hasMore: false,
        truncated: false,
        cancelled: cancelled,
        filesExamined: 0,
        bytesRead: 0,
        outputCharacters: 0,
        elapsed: budget.elapsed,
      );

  WorkspaceTextReadResult _emptyRead(
    String path,
    int startByte,
    _ReadBudget budget, {
    bool cancelled = false,
  }) =>
      WorkspaceTextReadResult(
        path: path,
        text: '',
        startByte: startByte,
        bytesRead: 0,
        outputCharacters: 0,
        truncated: false,
        cancelled: cancelled,
        sensitive: false,
        elapsed: budget.elapsed,
      );

  WorkspaceSearchResult _emptySearch(
    String query,
    bool recursive,
    _ReadBudget budget, {
    bool cancelled = false,
    bool truncated = false,
    int filesExamined = 0,
  }) =>
      WorkspaceSearchResult(
        query: query,
        matches: const [],
        recursive: recursive,
        truncated: truncated,
        cancelled: cancelled,
        filesExamined: filesExamined,
        bytesRead: 0,
        outputCharacters: 0,
        nonTextFiles: 0,
        elapsed: budget.elapsed,
      );
}

class _ReadBudget {
  final Duration limit;
  final Stopwatch _watch = Stopwatch()..start();

  _ReadBudget(this.limit);

  Duration get elapsed => _watch.elapsed;

  Duration get remaining {
    final value = limit - elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  void check() {
    if (remaining <= Duration.zero) {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.timeout,
        '文件操作超时。',
      );
    }
  }
}

class _DirectoryScan {
  final List<WorkspaceDirectoryEntry> entries;
  final int filesExamined;
  final bool reachedLimit;
  final bool cancelled;

  const _DirectoryScan(
    this.entries,
    this.filesExamined, {
    required this.reachedLimit,
    required this.cancelled,
  });
}

class _SearchScan {
  final List<String> files;
  final bool reachedLimit;
  final bool cancelled;

  const _SearchScan(
    this.files, {
    required this.reachedLimit,
    required this.cancelled,
  });
}

class _ByteRead {
  final List<int> bytes;
  final int bytesRead;
  final bool truncated;
  final bool cancelled;

  const _ByteRead(
    this.bytes,
    this.bytesRead, {
    required this.truncated,
    required this.cancelled,
  });
}

class _MatchScan {
  final List<WorkspaceSearchMatch> matches;
  final int outputCharacters;
  final bool truncated;

  const _MatchScan(
    this.matches,
    this.outputCharacters, {
    required this.truncated,
  });
}

class _CharacterLimit {
  final String text;
  final bool truncated;

  const _CharacterLimit(this.text, this.truncated);
}

_CharacterLimit _truncateCharacters(String value, int limit) {
  final runes = value.runes;
  if (runes.length <= limit) return _CharacterLimit(value, false);
  return _CharacterLimit(String.fromCharCodes(runes.take(limit)), true);
}
