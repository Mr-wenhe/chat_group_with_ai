import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';

import 'work_task_event.dart';

enum WorkTaskEventReadIssueKind {
  truncatedFinalLineIgnored,
  malformedLineIgnored,
  invalidSequenceIgnored,
}

/// A diagnostic suitable for UI/logging. It never contains raw JSONL content.
class WorkTaskEventReadIssue {
  final WorkTaskEventReadIssueKind kind;
  final String taskId;
  final int lineNumber;

  const WorkTaskEventReadIssue({
    required this.kind,
    required this.taskId,
    required this.lineNumber,
  });

  String get message => switch (kind) {
        WorkTaskEventReadIssueKind.truncatedFinalLineIgnored =>
          '已忽略未写完的最后一条任务事件。',
        WorkTaskEventReadIssueKind.malformedLineIgnored => '已忽略格式错误的任务事件。',
        WorkTaskEventReadIssueKind.invalidSequenceIgnored => '已忽略顺序无效的任务事件。',
      };
}

class WorkTaskEventReadResult {
  final List<WorkTaskEvent> events;
  final List<WorkTaskEventReadIssue> issues;

  WorkTaskEventReadResult({
    required List<WorkTaskEvent> events,
    required List<WorkTaskEventReadIssue> issues,
  })  : events = List.unmodifiable(events),
        issues = List.unmodifiable(issues);
}

/// App-support JSONL storage for public work-task progress only.
class WorkTaskEventStore {
  static const int defaultMaxTitleCharacters = 240;
  static const int defaultMaxDetailCharacters = 4000;
  static const int defaultMaxMetadataStringCharacters = 512;
  static const int _maxMetadataEntries = 32;
  static const int _maxMetadataDepth = 4;
  static final RegExp _urlPattern =
      RegExp(r'https?://[^\s,;）)]+', caseSensitive: false);
  static final RegExp _localPathPattern = RegExp(
    // Require a path-like first segment and a token boundary. A bare slash
    // in progress values such as `0/1` is not a local path.
    r'(?:(?<![\w/])(?:[A-Za-z]:[\\/]|\\\\|//|/(?:[A-Za-z_~][A-Za-z0-9._~-]*))[^\s,;）)]+)',
  );

  final Directory appSupportDirectory;
  final int maxTitleCharacters;
  final int maxDetailCharacters;
  final int maxMetadataStringCharacters;
  final SearchSecretScanner _secretScanner;
  final StreamController<WorkTaskEvent> _liveEvents =
      StreamController<WorkTaskEvent>.broadcast();
  final Map<String, Future<void>> _writeChains = {};
  final Map<String, int> _lastSequences = {};
  // Global maintenance (data clear/retention) is serialized with per-task
  // appends. A clear captures only writes that existed when it started, so a
  // new task created after the barrier may append normally without deadlocking
  // the maintenance operation.
  Future<void> _maintenance = Future<void>.value();
  Future<void>? _closeFuture;
  bool _closed = false;
  bool _appendsSuspendedForDataClear = false;

  WorkTaskEventStore({
    required this.appSupportDirectory,
    this.maxTitleCharacters = defaultMaxTitleCharacters,
    this.maxDetailCharacters = defaultMaxDetailCharacters,
    this.maxMetadataStringCharacters = defaultMaxMetadataStringCharacters,
    SearchSecretScanner secretScanner = const SearchSecretScanner(),
  })  : assert(maxTitleCharacters > 0),
        assert(maxDetailCharacters > 0),
        assert(maxMetadataStringCharacters > 0),
        _secretScanner = secretScanner;

  /// Reports whether late diagnostic callbacks must be rejected while the
  /// app-wide data lifecycle owns the event-tree clear barrier.
  bool get appendsSuspendedForDataClear => _appendsSuspendedForDataClear;

  /// Suspends new event writes before a data clear. Existing writes are still
  /// drained by [clearAll], while late callbacks fail closed at [append].
  void suspendAppendsForDataClear() {
    _appendsSuspendedForDataClear = true;
  }

  /// Re-enables diagnostic writes after the data lifecycle has completed (or
  /// safely aborted) the event/snapshot clear operation.
  void resumeAppendsAfterDataClear() {
    _appendsSuspendedForDataClear = false;
  }

  Directory get _eventsDirectory =>
      Directory('${appSupportDirectory.path}/work_mode_agent/events');

  File eventFileFor(String taskId) {
    _validateTaskId(taskId);
    return File('${_eventsDirectory.path}/$taskId.jsonl');
  }

  /// Appends one event after every earlier write for the same task has flushed.
  Future<WorkTaskEvent> append({
    required String taskId,
    required WorkTaskEventKind kind,
    required String title,
    String detail = '',
    int? progressCurrent,
    int? progressTotal,
    Map<String, Object?>? safeMetadata,
    DateTime? timestamp,
  }) {
    if (_closed) {
      return Future<WorkTaskEvent>.error(
        StateError('工作任务事件存储已关闭。'),
      );
    }
    if (_appendsSuspendedForDataClear) {
      return Future<WorkTaskEvent>.error(
        StateError('工作模式事件记录已暂停清理。'),
      );
    }
    _validateTaskId(taskId);
    final previous = _writeChains[taskId] ?? Future<void>.value();
    final maintenance = _maintenance;
    late final Future<WorkTaskEvent> operation;
    operation =
        previous.catchError((Object _) {}).then((_) => maintenance).then(
              (_) => _appendInternal(
                taskId: taskId,
                kind: kind,
                title: title,
                detail: detail,
                progressCurrent: progressCurrent,
                progressTotal: progressTotal,
                safeMetadata: safeMetadata,
                timestamp: timestamp,
              ),
            );
    late final Future<void> tracked;
    tracked = operation.then<void>(
      (_) => _finishWrite(taskId, tracked),
      onError: (Object _, StackTrace __) => _finishWrite(taskId, tracked),
    );
    _writeChains[taskId] = tracked;
    return operation;
  }

  Future<WorkTaskEventReadResult> read(String taskId) async {
    _validateTaskId(taskId);
    await _maintenance;
    final pending = _writeChains[taskId];
    if (pending != null) await pending;
    return _readPersisted(taskId);
  }

  /// Removes old JSONL files without touching active tasks. Event files are
  /// diagnostics only, so a failed deletion is ignored and the task remains
  /// authoritative in Hive.
  Future<int> cleanup({
    Duration retention = const Duration(days: 30),
    bool Function(String taskId)? isTaskActive,
  }) async {
    return _scheduleMaintenance(() async {
      if (retention <= Duration.zero ||
          !await _ensureEventsDirectory(create: false)) {
        return 0;
      }
      final cutoff = DateTime.now().subtract(retention);
      var removed = 0;
      await for (final entity in _eventsDirectory.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
        final taskId = entity.uri.pathSegments.last.replaceFirst('.jsonl', '');
        if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(taskId) ||
            isTaskActive?.call(taskId) == true) {
          continue;
        }
        try {
          final modified = (await entity.stat()).modified;
          if (modified.isBefore(cutoff)) {
            await entity.delete();
            removed++;
          }
        } on Object {
          // Cleanup is best effort; diagnostics must never interrupt tasks.
        }
      }
      return removed;
    });
  }

  /// Deletes only the app-managed work-mode event tree. Symlink roots and
  /// descendants are removed as links, never traversed, so a clear operation
  /// cannot touch a user project directory.
  Future<int> clearAll() {
    final pending = Map<String, Future<void>>.from(_writeChains);
    return _scheduleMaintenance(() async {
      if (!await _ensureManagedParents(create: false)) return 0;
      final removed = await _deleteTreeNoFollow(_eventsDirectory);
      for (final entry in pending.entries) {
        if (identical(_writeChains[entry.key], entry.value)) {
          _writeChains.remove(entry.key);
          _lastSequences.remove(entry.key);
        }
      }
      return removed;
    });
  }

  Future<WorkTaskEventReadResult> _readPersisted(String taskId) async {
    if (!await _ensureEventsDirectory(create: false)) {
      return WorkTaskEventReadResult(events: const [], issues: const []);
    }
    final file = eventFileFor(taskId);
    final fileType = await FileSystemEntity.type(
      file.path,
      followLinks: false,
    );
    if (fileType == FileSystemEntityType.notFound) {
      return WorkTaskEventReadResult(events: const [], issues: const []);
    }
    if (fileType != FileSystemEntityType.file) {
      throw StateError('任务日志文件不是受信任的普通文件。');
    }

    final text = await file.readAsString();
    final lines = text.split(RegExp(r'\r?\n'));
    final lastNonEmptyIndex = lines.lastIndexWhere((line) => line.isNotEmpty);
    final hasUnterminatedFinalLine =
        lastNonEmptyIndex >= 0 && !text.endsWith('\n');
    final events = <WorkTaskEvent>[];
    final issues = <WorkTaskEventReadIssue>[];
    var lastSequence = 0;

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (line.isEmpty) continue;
      WorkTaskEvent event;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) throw const FormatException('任务事件不是对象');
        event = WorkTaskEvent.fromJson(Map<String, dynamic>.from(decoded));
        event = _sanitizePersistedEvent(event);
      } on Object {
        issues.add(
          WorkTaskEventReadIssue(
            kind: index == lastNonEmptyIndex && hasUnterminatedFinalLine
                ? WorkTaskEventReadIssueKind.truncatedFinalLineIgnored
                : WorkTaskEventReadIssueKind.malformedLineIgnored,
            taskId: taskId,
            lineNumber: index + 1,
          ),
        );
        continue;
      }
      if (event.taskId != taskId || event.sequence <= lastSequence) {
        issues.add(
          WorkTaskEventReadIssue(
            kind: WorkTaskEventReadIssueKind.invalidSequenceIgnored,
            taskId: taskId,
            lineNumber: index + 1,
          ),
        );
        continue;
      }
      events.add(event);
      lastSequence = event.sequence;
    }
    return WorkTaskEventReadResult(events: events, issues: issues);
  }

  /// Older JSONL files may predate the public-event sanitizer (or may have
  /// been edited by another process). Re-sanitize on read so persisted data
  /// cannot bypass the current secret/path redaction policy.
  WorkTaskEvent _sanitizePersistedEvent(WorkTaskEvent event) {
    return WorkTaskEvent(
      taskId: event.taskId,
      sequence: event.sequence,
      timestamp: event.timestamp,
      kind: event.kind,
      title: _safeText(event.title, maxTitleCharacters),
      detail: _safeText(event.detail, maxDetailCharacters),
      progressCurrent: event.progressCurrent,
      progressTotal: event.progressTotal,
      safeMetadata: _safeMetadata(event.safeMetadata),
    );
  }

  /// Replays durable events first, then emits later appends for this task.
  Stream<WorkTaskEvent> watch(String taskId) async* {
    _validateTaskId(taskId);
    final buffered = StreamController<WorkTaskEvent>();
    final subscription =
        _liveEvents.stream.where((event) => event.taskId == taskId).listen(
              buffered.add,
              onError: buffered.addError,
              onDone: () => unawaited(buffered.close()),
            );
    var lastSequence = 0;
    try {
      final replay = await read(taskId);
      for (final event in replay.events) {
        if (event.sequence > lastSequence) {
          lastSequence = event.sequence;
          yield event;
        }
      }
      if (replay.issues.isNotEmpty) {
        // Replay remains useful, but the UI must not silently present a
        // partial timeline as complete. Throw only after valid events have
        // been yielded so the panel can show an actionable retry state.
        throw StateError('任务日志部分记录无法读取，请重试。');
      }
      await for (final event in buffered.stream) {
        if (event.sequence > lastSequence) {
          lastSequence = event.sequence;
          yield event;
        }
      }
    } finally {
      await subscription.cancel();
      // Awaiting close here deadlocks: this async generator is the buffered
      // stream's active listener while it is handling cancellation.
      unawaited(buffered.close());
    }
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    final pending = List<Future<void>>.from(_writeChains.values);
    final closing = Future.wait<void>([
      _maintenance,
      ...pending,
    ], eagerError: false)
        .then<void>((_) => _liveEvents.close());
    _closeFuture = closing;
    return closing;
  }

  Future<WorkTaskEvent> _appendInternal({
    required String taskId,
    required WorkTaskEventKind kind,
    required String title,
    required String detail,
    required int? progressCurrent,
    required int? progressTotal,
    required Map<String, Object?>? safeMetadata,
    required DateTime? timestamp,
  }) async {
    await _ensureEventsDirectory(create: true);
    final sequence = await _nextSequence(taskId) + 1;
    final event = WorkTaskEvent(
      taskId: taskId,
      sequence: sequence,
      timestamp: timestamp ?? DateTime.now(),
      kind: kind,
      title: _safeText(title, maxTitleCharacters),
      detail: _safeText(detail, maxDetailCharacters),
      progressCurrent: progressCurrent,
      progressTotal: progressTotal,
      safeMetadata: _safeMetadata(safeMetadata),
    );
    final file = eventFileFor(taskId);
    final fileType = await FileSystemEntity.type(
      file.path,
      followLinks: false,
    );
    if (fileType != FileSystemEntityType.notFound &&
        fileType != FileSystemEntityType.file) {
      throw StateError('任务日志文件不是受信任的普通文件。');
    }
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.writeString('${jsonEncode(event.toJson())}\n');
      await handle.flush();
    } finally {
      await handle.close();
    }
    _lastSequences[taskId] = sequence;
    _liveEvents.add(event);
    return event;
  }

  Future<int> _nextSequence(String taskId) async {
    final known = _lastSequences[taskId];
    if (known != null) return known;
    final replay = await _readPersisted(taskId);
    final sequence = replay.events.isEmpty ? 0 : replay.events.last.sequence;
    _lastSequences[taskId] = sequence;
    return sequence;
  }

  void _finishWrite(String taskId, Future<void> operation) {
    final tracked = _writeChains[taskId];
    if (tracked == null || tracked != operation) return;
    _writeChains.remove(taskId);
    _lastSequences.remove(taskId);
  }

  Future<T> _scheduleMaintenance<T>(Future<T> Function() operation) {
    final previous = _maintenance;
    final pendingWrites = List<Future<void>>.from(_writeChains.values);
    late final Future<T> scheduled;
    scheduled = previous
        .catchError((Object _) {})
        .then((_) => Future.wait<void>(pendingWrites, eagerError: false))
        .then((_) => operation());
    _maintenance = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return scheduled;
  }

  Future<int> _deleteTreeNoFollow(FileSystemEntity entity) async {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return 0;
    if (type != FileSystemEntityType.directory) {
      await entity.delete();
      return 1;
    }
    var removed = 0;
    await for (final child in Directory(entity.path).list(followLinks: false)) {
      removed += await _deleteTreeNoFollow(child);
    }
    await entity.delete();
    return removed + 1;
  }

  /// Validates the app-managed parent chain before any operation can create or
  /// read a child. `FileSystemEntity.type(..., followLinks: false)` only
  /// protects the final path component; checking these parents prevents a
  /// malicious `work_mode_agent` link from redirecting JSONL I/O elsewhere.
  Future<bool> _ensureEventsDirectory({required bool create}) async {
    if (!await _ensureManagedParents(create: create)) return false;

    final eventsType = await FileSystemEntity.type(
      _eventsDirectory.path,
      followLinks: false,
    );
    if (eventsType == FileSystemEntityType.link) {
      // A clear operation may safely remove this link itself, but reads and
      // writes must fail closed instead of following it to a user path.
      if (!create) return false;
      throw StateError('工作模式事件目录不是受信任目录。');
    }
    if (eventsType == FileSystemEntityType.notFound) {
      if (!create) return false;
      await _eventsDirectory.create(recursive: false);
    } else if (eventsType != FileSystemEntityType.directory) {
      throw StateError('工作模式事件目录不是普通目录。');
    }
    return true;
  }

  Future<bool> _ensureManagedParents({required bool create}) async {
    final appSupportType = await FileSystemEntity.type(
      appSupportDirectory.path,
      followLinks: false,
    );
    if (appSupportType == FileSystemEntityType.link) {
      throw StateError('工作模式事件目录的应用数据根不是受信任目录。');
    }
    if (appSupportType == FileSystemEntityType.notFound) {
      if (!create) return false;
      await appSupportDirectory.create(recursive: true);
    } else if (appSupportType != FileSystemEntityType.directory) {
      throw StateError('工作模式事件目录的应用数据根不是普通目录。');
    }

    final container = Directory('${appSupportDirectory.path}/work_mode_agent');
    final containerType = await FileSystemEntity.type(
      container.path,
      followLinks: false,
    );
    if (containerType == FileSystemEntityType.link) {
      throw StateError('工作模式事件目录不是受信任目录。');
    }
    if (containerType == FileSystemEntityType.notFound) {
      if (!create) return false;
      await container.create(recursive: false);
    } else if (containerType != FileSystemEntityType.directory) {
      throw StateError('工作模式事件目录不是普通目录。');
    }
    return true;
  }

  String _safeText(String value, int maximum) {
    var redacted = _secretScanner.redact(value, includeOpaqueTokens: true);
    redacted = redacted.replaceAll(_urlPattern, '[外部地址]');
    redacted = redacted.replaceAll(_localPathPattern, '[本地路径]');
    if (redacted.length <= maximum) return redacted;
    return maximum == 1 ? '…' : '${redacted.substring(0, maximum - 1)}…';
  }

  Map<String, dynamic> _safeMetadata(Map<String, Object?>? source) {
    if (source == null || source.isEmpty) return const {};
    final result = <String, dynamic>{};
    for (final entry in source.entries.take(_maxMetadataEntries)) {
      result[_safeText(entry.key, maxMetadataStringCharacters)] =
          _safeMetadataValue(entry.value, 0);
    }
    return result;
  }

  dynamic _safeMetadataValue(Object? value, int depth) {
    if (value == null || value is num || value is bool) return value;
    if (value is String) return _safeText(value, maxMetadataStringCharacters);
    if (depth >= _maxMetadataDepth) {
      return _safeText(value.toString(), maxMetadataStringCharacters);
    }
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries.take(_maxMetadataEntries)) {
        result[_safeText(entry.key.toString(), maxMetadataStringCharacters)] =
            _safeMetadataValue(entry.value, depth + 1);
      }
      return result;
    }
    if (value is Iterable) {
      return value
          .take(_maxMetadataEntries)
          .map((item) => _safeMetadataValue(item, depth + 1))
          .toList(growable: false);
    }
    return _safeText(value.toString(), maxMetadataStringCharacters);
  }

  void _validateTaskId(String taskId) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(taskId)) {
      throw ArgumentError.value(taskId, 'taskId', '任务标识不合法');
    }
  }
}
