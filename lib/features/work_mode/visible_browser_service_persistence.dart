part of 'visible_browser_service.dart';

const int _visibleBrowserStateMaxBytes = 256 * 1024;
final RegExp _visibleBrowserStateId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

extension _VisibleBrowserPersistence on VisibleBrowserService {
  File? get _sessionStateFile {
    final explicit = _sessionStatePath?.trim();
    if (explicit != null && explicit.isNotEmpty) return File(explicit);
    final store = _eventStore;
    if (store == null) return null;
    return File(
      '${store.appSupportDirectory.path}/work_mode_agent/visible_browser_sessions.json',
    );
  }

  String _safeTextValue(String value, int maxCharacters) {
    final normalized = _secretScanner
        .redact(value, includeOpaqueTokens: true)
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalized.length <= maxCharacters
        ? normalized
        : normalized.substring(0, maxCharacters);
  }

  void _record(
    String taskId,
    WorkTaskEventKind kind,
    String title,
    String detail, {
    required String host,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final store = _eventStore;
    if (store == null || taskId.trim().isEmpty) return;
    try {
      unawaited(
        store.append(
          taskId: taskId,
          kind: kind,
          title: title,
          detail: detail,
          safeMetadata: <String, Object?>{
            'browser': 'visible',
            'host': host,
            ...metadata,
          },
        ).then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ),
      );
    } on Object {
      // Event persistence is best effort and must not block handoff.
    }
  }

  void _queuePersist() {
    final file = _sessionStateFile;
    if (_disposed || file == null) return;
    _stateWrite = _stateWrite.catchError((Object _) {}).then<void>(
          (_) => _writeSessionState(file),
        );
  }

  Future<void> _writeSessionState(File file) async {
    try {
      await file.parent.create(recursive: true);
      final payload = <String, Object?>{
        'version': 1,
        'sessions': _sessions.values.map(_sessionToMap).toList(growable: false),
      };
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(payload), flush: true);
      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        // Windows cannot replace an existing file with rename(). Copy has
        // replace semantics there; keep the same bounded metadata payload and
        // remove the temporary file after the fallback succeeds.
        await temporary.copy(file.path);
        await temporary.delete();
      }
    } on Object {
      // Browser metadata is a recovery aid; a failed write must not stop a task.
    }
  }

  Map<String, Object?> _sessionToMap(VisibleBrowserSession session) {
    return <String, Object?>{
      'id': session.id,
      'taskId': session.taskId,
      'url': session.url,
      'host': session.host,
      'title': _safeTextValue(session.title, 240),
      'message': _safeTextValue(session.message, 400),
      'status': session.status.name,
      'pauseReason': session.pauseReason?.name,
      'runtimeUnavailable': session.runtimeUnavailable,
      'navigation': session.navigation
          .map(
            (entry) => <String, Object?>{
              'url': entry.url,
              'host': entry.host,
              'visitedAt': entry.visitedAt.toIso8601String(),
            },
          )
          .toList(growable: false),
    };
  }

  Future<void> _restoreSessions() async {
    final file = _sessionStateFile;
    if (_disposed || file == null || !await file.exists()) return;
    try {
      final bytes = await _readStateBytes(file);
      if (_disposed) return;
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map || decoded['version'] != 1) return;
      final rawSessions = decoded['sessions'];
      if (rawSessions is! List) return;
      for (final raw in rawSessions.take(visibleBrowserMaxSessions)) {
        final session = _sessionFromMap(raw);
        if (session != null) _sessions[session.id] = session;
      }
      _emit();
    } on Object {
      // A corrupt recovery file is ignored; the task checkpoint remains source
      // of truth and a fresh browser session can still be opened.
    }
  }

  Future<Uint8List> _readStateBytes(File file) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk
        in file.openRead(0, _visibleBrowserStateMaxBytes + 1)) {
      builder.add(chunk);
      if (builder.length > _visibleBrowserStateMaxBytes) {
        throw const FormatException('浏览器会话恢复文件过大');
      }
    }
    return builder.takeBytes();
  }

  VisibleBrowserSession? _sessionFromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final taskId = raw['taskId'];
    final rawUrl = raw['url'];
    if (id is! String ||
        taskId is! String ||
        rawUrl is! String ||
        !_visibleBrowserStateId.hasMatch(id) ||
        !_visibleBrowserStateId.hasMatch(taskId)) {
      return null;
    }
    final uri =
        tryValidateSearchUrl(Uri.tryParse(rawUrl), allowInsecureHttp: true);
    if (uri == null) return null;
    final navigation = <VisibleBrowserNavigation>[];
    final rawNavigation = raw['navigation'];
    if (rawNavigation is List) {
      for (final entry
          in rawNavigation.take(visibleBrowserMaxNavigationEntries)) {
        if (entry is! Map ||
            entry['url'] is! String ||
            entry['host'] is! String) {
          continue;
        }
        final entryUri = tryValidateSearchUrl(
          Uri.tryParse(entry['url'] as String),
          allowInsecureHttp: true,
        );
        if (entryUri == null) continue;
        final visitedAt =
            DateTime.tryParse(entry['visitedAt']?.toString() ?? '');
        navigation.add(
          VisibleBrowserNavigation(
            url: entryUri.toString(),
            host: entryUri.host,
            visitedAt: visitedAt ?? DateTime.now().toUtc(),
          ),
        );
      }
    }
    final storedStatus = VisibleBrowserStatus.values.where(
      (status) => status.name == raw['status'],
    );
    final status = storedStatus.isEmpty ||
            storedStatus.single == VisibleBrowserStatus.opening ||
            storedStatus.single == VisibleBrowserStatus.ready
        ? VisibleBrowserStatus.closed
        : storedStatus.single;
    final pause = VisibleBrowserPauseReason.values.where(
      (reason) => reason.name == raw['pauseReason'],
    );
    final message = status == VisibleBrowserStatus.closed
        ? '应用重启后已恢复浏览器会话；点击继续重新打开，任务仍在继续。'
        : _safeTextValue(raw['message']?.toString() ?? '', 400);
    return VisibleBrowserSession(
      id: id,
      taskId: taskId,
      url: uri.toString(),
      host: uri.host,
      title: _safeTextValue(raw['title']?.toString() ?? '', 240),
      message: message,
      status: status,
      pauseReason: pause.isEmpty ? null : pause.single,
      runtimeUnavailable: status == VisibleBrowserStatus.paused &&
          raw['runtimeUnavailable'] == true,
      navigation: navigation.isEmpty
          ? <VisibleBrowserNavigation>[
              VisibleBrowserNavigation(
                url: uri.toString(),
                host: uri.host,
              ),
            ]
          : navigation,
    );
  }
}
