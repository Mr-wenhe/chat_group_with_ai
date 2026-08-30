import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'work_folder_grant_service.dart';
import 'workspace_path_policy.dart';

part 'workspace_file_service_models.dart';
part 'workspace_file_service_support.dart';

/// Bounded read-only access to paths accepted by [WorkspacePathPolicy].
///
/// ponytail: Mutation is deliberately absent here and belongs to the later
/// approval/atomic-change stage.
class WorkspaceFileService {
  final WorkspacePathPolicy pathPolicy;
  final WorkspaceReadLimits limits;
  final WorkspaceFileEventSink? onEvent;

  WorkspaceFileService({
    WorkspacePathPolicy? pathPolicy,
    WorkFolderGrantService? grantService,
    this.limits = const WorkspaceReadLimits(),
    this.onEvent,
  }) : pathPolicy =
            pathPolicy ?? WorkspacePathPolicy(grantService: grantService) {
    if (pathPolicy == null && grantService == null) {
      throw ArgumentError('pathPolicy or grantService is required.');
    }
  }

  /// Exposes the same filename classification used by read/search redaction
  /// so the agent approval layer can request a second confirmation before a
  /// sensitive file is returned to a model.
  bool isSensitivePath(String path) => _isSensitiveName(path);

  Future<WorkspaceDirectoryPage> listDirectory(
    String rawPath, {
    int page = 0,
    int pageSize = WorkspaceReadLimits.defaultMaxDirectoryEntries,
    bool recursive = false,
    WorkspaceReadCancellation? cancellation,
  }) async {
    if (page < 0 || pageSize <= 0 || pageSize > limits.maxDirectoryEntries) {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.invalidRequest,
        '目录分页参数无效。',
      );
    }
    final budget = _ReadBudget(limits.maxDuration);
    if (cancellation?.isCancelled == true) {
      return _emptyDirectoryPage(page, pageSize, recursive, budget,
          cancelled: true);
    }
    final resolved = await pathPolicy.resolveExisting(rawPath);
    if (!resolved.isDirectory) {
      throw WorkspaceFileException(
        WorkspaceFileErrorKind.notDirectory,
        '目标不是目录。',
        path: resolved.path,
      );
    }
    final offset = page * pageSize;
    final scanLimit = offset + pageSize + 1;
    final scan = await _collectDirectory(
      Directory(resolved.path),
      recursive: recursive,
      limit: scanLimit > limits.maxDirectoryEntries
          ? limits.maxDirectoryEntries
          : scanLimit,
      budget: budget,
      cancellation: cancellation,
    );
    final start = offset.clamp(0, scan.entries.length).toInt();
    final end = (start + pageSize).clamp(start, scan.entries.length).toInt();
    final entries = scan.entries.sublist(start, end);
    final outputCharacters = entries.fold<int>(
      0,
      (total, entry) => total + entry.name.length + entry.path.length,
    );
    final hasMore = scan.entries.length > end || scan.reachedLimit;
    return WorkspaceDirectoryPage(
      entries: entries,
      page: page,
      pageSize: pageSize,
      recursive: recursive,
      hasMore: hasMore,
      truncated: scan.reachedLimit,
      cancelled: scan.cancelled,
      filesExamined: scan.filesExamined,
      bytesRead: 0,
      outputCharacters: outputCharacters,
      elapsed: budget.elapsed,
    );
  }

  Future<WorkspaceStat> stat(
    String rawPath, {
    WorkspaceReadCancellation? cancellation,
  }) async {
    final budget = _ReadBudget(limits.maxDuration);
    _checkCancellation(cancellation);
    final resolved = await pathPolicy.resolveExisting(rawPath);
    _checkCancellation(cancellation);
    final entity = _entityFor(resolved);
    final fileStat = await _bounded(entity.stat(), budget);
    return WorkspaceStat(
      path: resolved.path,
      type: resolved.type,
      size: fileStat.size,
      modified: fileStat.modified,
      accessed: fileStat.accessed,
      wasSymbolicLink: resolved.wasSymbolicLink,
      filesExamined: 1,
      bytesRead: 0,
      outputCharacters: 0,
      elapsed: budget.elapsed,
    );
  }

  Future<WorkspaceTextReadResult> readTextRange(
    String rawPath, {
    int startByte = 0,
    int? byteLength,
    WorkspaceReadCancellation? cancellation,
  }) async {
    if (startByte < 0 || (byteLength != null && byteLength < 0)) {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.invalidRequest,
        '读取范围参数无效。',
      );
    }
    final budget = _ReadBudget(limits.maxDuration);
    if (cancellation?.isCancelled == true) {
      return _emptyRead(rawPath, startByte, budget, cancelled: true);
    }
    final resolved = await pathPolicy.resolveExisting(rawPath);
    if (!resolved.isFile) {
      throw WorkspaceFileException(
        WorkspaceFileErrorKind.notFile,
        '目标不是普通文件。',
        path: resolved.path,
      );
    }
    final file = File(resolved.path);
    final totalBytes = await _bounded(file.length(), budget);
    final sensitive = _isSensitiveName(resolved.path);
    if (startByte >= totalBytes || byteLength == 0) {
      if (sensitive) _emitSensitive('readTextRange');
      return WorkspaceTextReadResult(
        path: resolved.path,
        text: '',
        startByte: startByte,
        bytesRead: 0,
        filesExamined: 1,
        outputCharacters: 0,
        truncated: false,
        cancelled: false,
        sensitive: sensitive,
        elapsed: budget.elapsed,
      );
    }
    final requested = byteLength ?? limits.maxReadBytes;
    final boundedLength =
        requested > limits.maxReadBytes ? limits.maxReadBytes : requested;
    final end =
        (startByte + boundedLength).clamp(startByte, totalBytes).toInt();
    final limitedByReadBudget = requested > boundedLength && end < totalBytes;
    final read = await _readBytes(
      file,
      startByte: startByte,
      endByte: end,
      budget: budget,
      cancellation: cancellation,
    );
    if (sensitive) _emitSensitive('readTextRange');
    if (read.cancelled) {
      return WorkspaceTextReadResult(
        path: resolved.path,
        text: '',
        startByte: startByte,
        bytesRead: read.bytesRead,
        filesExamined: 1,
        outputCharacters: 0,
        truncated: true,
        cancelled: true,
        sensitive: sensitive,
        elapsed: budget.elapsed,
      );
    }
    String text;
    try {
      text = _decodeStrict(read.bytes);
    } on WorkspaceFileException catch (error) {
      if (error.kind != WorkspaceFileErrorKind.nonText) {
        rethrow;
      }
      // A byte range may begin/end in the middle of a UTF-8 code point. Read
      // a few surrounding bytes and decode the complete boundary instead of
      // misclassifying an otherwise valid text file as binary.
      final expandedStart = (startByte - 3).clamp(0, startByte).toInt();
      final expandedEnd = (end + 3).clamp(end, totalBytes).toInt();
      final expanded = await _readBytes(
        file,
        startByte: expandedStart,
        endByte: expandedEnd,
        budget: budget,
        cancellation: cancellation,
      );
      text = _decodeStrict(expanded.bytes);
    }
    final output = _truncateCharacters(text, limits.maxOutputCharacters);
    return WorkspaceTextReadResult(
      path: resolved.path,
      text: output.text,
      startByte: startByte,
      bytesRead: read.bytesRead,
      filesExamined: 1,
      outputCharacters: output.text.runes.length,
      truncated: read.truncated || limitedByReadBudget || output.truncated,
      cancelled: false,
      sensitive: sensitive,
      elapsed: budget.elapsed,
    );
  }

  Future<WorkspaceSearchResult> searchText(
    String rawPath,
    String query, {
    bool recursive = false,
    bool caseSensitive = true,
    bool allowSensitive = false,
    int? maxFiles,
    int? maxBytes,
    int? maxOutputCharacters,
    WorkspaceReadCancellation? cancellation,
  }) async {
    final normalizedQuery = query;
    if (normalizedQuery.isEmpty || normalizedQuery.length > 4096) {
      throw const WorkspaceFileException(
        WorkspaceFileErrorKind.invalidRequest,
        '搜索词为空或超过长度上限。',
      );
    }
    final fileLimit = _boundedLimit(maxFiles, limits.maxFiles);
    final byteLimit = _boundedLimit(maxBytes, limits.maxSearchBytes);
    final outputLimit = _boundedLimit(
      maxOutputCharacters,
      limits.maxOutputCharacters,
    );
    final budget = _ReadBudget(limits.maxDuration);
    if (cancellation?.isCancelled == true) {
      return _emptySearch(normalizedQuery, recursive, budget, cancelled: true);
    }
    final resolved = await pathPolicy.resolveExisting(rawPath);
    final candidates = <String>[];
    var truncated = false;
    if (resolved.isFile) {
      candidates.add(resolved.path);
    } else if (resolved.isDirectory) {
      final scan = await _collectSearchFiles(
        Directory(resolved.path),
        recursive: recursive,
        limit: fileLimit,
        budget: budget,
        cancellation: cancellation,
        skipSensitive: !allowSensitive,
      );
      candidates.addAll(scan.files);
      truncated = scan.reachedLimit;
      if (scan.cancelled) {
        return _emptySearch(
          normalizedQuery,
          recursive,
          budget,
          cancelled: true,
          truncated: truncated,
          filesExamined: 0,
        );
      }
    } else {
      throw WorkspaceFileException(
        WorkspaceFileErrorKind.notFile,
        '目标不是文件或目录。',
        path: resolved.path,
      );
    }
    final matches = <WorkspaceSearchMatch>[];
    var filesExamined = 0;
    var bytesRead = 0;
    var outputCharacters = 0;
    var nonTextFiles = 0;
    for (final candidate in candidates) {
      if (cancellation?.isCancelled == true) {
        return WorkspaceSearchResult(
          query: normalizedQuery,
          matches: matches,
          recursive: recursive,
          truncated: true,
          cancelled: true,
          filesExamined: filesExamined,
          bytesRead: bytesRead,
          outputCharacters: outputCharacters,
          nonTextFiles: nonTextFiles,
          elapsed: budget.elapsed,
        );
      }
      if (filesExamined >= fileLimit || bytesRead >= byteLimit) {
        truncated = true;
        break;
      }
      final file = File(candidate);
      filesExamined++;
      final remaining = byteLimit - bytesRead;
      final read = await _readBytes(
        file,
        startByte: 0,
        endByte:
            remaining > limits.maxReadBytes ? limits.maxReadBytes : remaining,
        budget: budget,
        cancellation: cancellation,
      );
      bytesRead += read.bytesRead;
      truncated = truncated || read.truncated;
      if (read.cancelled) {
        return WorkspaceSearchResult(
          query: normalizedQuery,
          matches: matches,
          recursive: recursive,
          truncated: true,
          cancelled: true,
          filesExamined: filesExamined,
          bytesRead: bytesRead,
          outputCharacters: outputCharacters,
          nonTextFiles: nonTextFiles,
          elapsed: budget.elapsed,
        );
      }
      final sensitive = _isSensitiveName(candidate);
      // Audit the access even when the sensitive file is empty or the read
      // range yields zero bytes; the boundary is the file classification, not
      // the amount of secret material returned to the caller.
      if (sensitive) _emitSensitive('searchText');
      String text;
      try {
        text = _decodeStrict(read.bytes);
      } on WorkspaceFileException catch (error) {
        if (error.kind != WorkspaceFileErrorKind.nonText) rethrow;
        nonTextFiles++;
        continue;
      }
      final found = _findMatches(
        candidate,
        text,
        normalizedQuery,
        caseSensitive: caseSensitive,
        outputBudget: outputLimit - outputCharacters,
        sensitive: sensitive,
        allowSensitive: allowSensitive,
      );
      matches.addAll(found.matches);
      outputCharacters += found.outputCharacters;
      if (found.truncated) {
        truncated = true;
        break;
      }
    }
    return WorkspaceSearchResult(
      query: normalizedQuery,
      matches: matches,
      recursive: recursive,
      truncated: truncated,
      cancelled: false,
      filesExamined: filesExamined,
      bytesRead: bytesRead,
      outputCharacters: outputCharacters,
      nonTextFiles: nonTextFiles,
      elapsed: budget.elapsed,
    );
  }
}
