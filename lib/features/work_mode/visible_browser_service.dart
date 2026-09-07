import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/security/search_endpoint_dns_guard.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'visible_browser_models.dart';
import 'visible_browser_page.dart';
import 'visible_browser_window_adapter.dart';
import 'work_task_event.dart';
import 'work_task_event_store.dart';

export 'visible_browser_models.dart';
export 'visible_browser_window_adapter.dart'
    show createDesktopVisibleBrowserWindow, visibleBrowserPageExtractionScript;

part 'visible_browser_service_persistence.dart';
part 'visible_browser_service_window.dart';

const int visibleBrowserMaxPageCharacters = 12000;
const int visibleBrowserMaxNavigationEntries = 20;
const int visibleBrowserMaxSessions = 32;
final RegExp _visibleBrowserTaskIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Owns browser windows without owning the work task lifecycle.
class VisibleBrowserService {
  final VisibleBrowserWindowFactory _windowFactory;
  final WorkTaskEventStore? _eventStore;
  final bool _isRelease;
  final SearchDnsLookup? _dnsLookup;
  final Duration _dnsLookupTimeout;
  final DateTime Function() _clock;
  final SearchSecretScanner _secretScanner;
  final int _maxPageCharacters;
  final Future<bool> Function()? _runtimeInstaller;
  final String? _sessionStatePath;
  final Map<String, VisibleBrowserSession> _sessions =
      <String, VisibleBrowserSession>{};
  final Map<String, VisibleBrowserWindow> _windows =
      <String, VisibleBrowserWindow>{};
  final Map<String, Future<void>> _reads = <String, Future<void>>{};
  final StreamController<List<VisibleBrowserSession>> _changes =
      StreamController<List<VisibleBrowserSession>>.broadcast();
  final Uuid _uuid;
  bool _disposed = false;
  Future<void>? _restoreFuture;
  Future<void> _stateWrite = Future<void>.value();

  VisibleBrowserService({
    VisibleBrowserWindowFactory? windowFactory,
    WorkTaskEventStore? eventStore,
    bool? isRelease,
    SearchDnsLookup? dnsLookup,
    Duration dnsLookupTimeout = searchDnsLookupTimeout,
    DateTime Function()? clock,
    SearchSecretScanner secretScanner = const SearchSecretScanner(),
    int maxPageCharacters = visibleBrowserMaxPageCharacters,
    Uuid? uuid,
    Future<bool> Function()? runtimeInstaller,
    String? sessionStatePath,
  })  : _windowFactory = windowFactory ?? createDesktopVisibleBrowserWindow,
        _eventStore = eventStore,
        _isRelease = isRelease ?? kReleaseMode,
        _dnsLookup = dnsLookup,
        _dnsLookupTimeout = dnsLookupTimeout,
        _clock = clock ?? DateTime.now,
        _secretScanner = secretScanner,
        _maxPageCharacters = maxPageCharacters,
        _uuid = uuid ?? const Uuid(),
        _runtimeInstaller = runtimeInstaller,
        _sessionStatePath = sessionStatePath;

  List<VisibleBrowserSession> get sessions =>
      List.unmodifiable(_sessions.values.toList(growable: false));

  Stream<List<VisibleBrowserSession>> watchSessions() async* {
    yield sessions;
    yield* _changes.stream;
  }

  /// Restores safe browser metadata after an app restart. Native windows and
  /// page bodies are never persisted; restored sessions require an explicit
  /// Continue click before a new window is created.
  Future<void> restore() => _restoreFuture ??= _restoreSessions();

  /// Waits for a public page to become readable. Paused/closed sessions stay
  /// pending until the user explicitly clicks Continue in the non-modal panel.
  Future<VisibleBrowserSession?> waitForReadablePage(
    String sessionId, {
    CancelToken? cancelToken,
  }) async {
    final current = _sessions[sessionId];
    if (current == null) return null;
    if (current.status == VisibleBrowserStatus.ready ||
        current.status == VisibleBrowserStatus.failed) {
      return current;
    }
    final completer = Completer<VisibleBrowserSession?>();
    StreamSubscription<List<VisibleBrowserSession>>? subscription;
    void complete(VisibleBrowserSession? value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    void inspect(List<VisibleBrowserSession> currentSessions) {
      final session =
          currentSessions.where((item) => item.id == sessionId).firstOrNull;
      if (session == null ||
          session.status == VisibleBrowserStatus.ready ||
          session.status == VisibleBrowserStatus.failed) {
        complete(session);
      }
    }

    subscription = watchSessions().listen(
      inspect,
      onDone: () => complete(null),
    );
    inspect(sessions);
    if (cancelToken != null) {
      unawaited(cancelToken.whenCancel.then<void>((_) => complete(null)));
    }
    final result = await completer.future;
    await subscription.cancel();
    return result;
  }

  /// Opens the platform's official WebView2 installation page when the
  /// native runtime is unavailable. The caller remains responsible for the
  /// user-facing confirmation; this method never installs silently.
  Future<bool> openRuntimeInstallFlow() async {
    final installer = _runtimeInstaller;
    if (installer == null) return false;
    try {
      return await installer();
    } on Object {
      return false;
    }
  }

  Future<VisibleBrowserSession> open({
    required String taskId,
    required String url,
  }) async {
    if (_disposed) throw StateError('可见浏览器服务已关闭。');
    // Provider construction starts restoration eagerly, but the first search
    // can arrive in the same event turn. Awaiting here prevents a late restore
    // from overwriting a newly opened session in the in-memory map.
    await restore();
    if (_disposed) throw StateError('可见浏览器服务已关闭。');
    if (!_visibleBrowserTaskIdPattern.hasMatch(taskId)) {
      throw ArgumentError.value(taskId, 'taskId', '任务标识不合法');
    }
    final uri = _validateUrl(url);
    // Validate the initial destination before creating a native window. The
    // read path re-checks DNS after redirects, but waiting until then would
    // still allow a public-looking hostname to connect to a private address
    // during the first navigation in release builds.
    await requirePublicSearchEndpointDns(
      uri,
      isRelease: _isRelease,
      lookup: _dnsLookup,
      lookupTimeout: _dnsLookupTimeout,
    );
    final id = _uuid.v4();
    final initial = VisibleBrowserSession(
      id: id,
      taskId: taskId,
      url: uri.toString(),
      host: uri.host,
      navigation: <VisibleBrowserNavigation>[
        VisibleBrowserNavigation(
          url: uri.toString(),
          host: uri.host,
          visitedAt: _clock(),
        ),
      ],
    );
    if (!_pruneSessions()) {
      throw StateError('可见浏览器会话已达到上限，请先关闭已有窗口后重试。');
    }
    _sessions[id] = initial;
    _queuePersist();
    _emit();
    // The initial URL was already DNS-checked before the session was
    // inserted. The window helper performs the same check for restored
    // sessions, so avoid a duplicate lookup on a brand-new session.
    await _createWindow(id, checkDns: false);
    return _sessions[id] ?? initial;
  }

  Future<VisibleBrowserSession> continueSession(String sessionId) async {
    if (_disposed) throw StateError('可见浏览器服务已关闭。');
    await restore();
    if (_disposed) throw StateError('可见浏览器服务已关闭。');
    final current = _requireSession(sessionId);
    if (current.status == VisibleBrowserStatus.paused) {
      _setSession(
        sessionId,
        current.copyWith(
          status: VisibleBrowserStatus.opening,
          message: '正在重新读取当前公开页面。',
        ),
      );
      if (_windows[sessionId] == null) {
        await _createWindow(sessionId);
      } else {
        await _readPage(sessionId);
      }
    } else if (current.status == VisibleBrowserStatus.closed) {
      _setSession(
        sessionId,
        current.copyWith(
          status: VisibleBrowserStatus.opening,
          message: '正在重新打开浏览器；任务仍在继续。',
        ),
      );
      await _createWindow(sessionId);
    }
    return _requireSession(sessionId);
  }

  Future<void> closeSession(String sessionId) async {
    final current = _requireSession(sessionId);
    if (current.status == VisibleBrowserStatus.closed) return;
    _setSession(
      sessionId,
      current.copyWith(
        status: VisibleBrowserStatus.closed,
        message: '浏览器窗口已关闭，任务未停止；点击继续可重新打开。',
      ),
    );
    _record(
      current.taskId,
      WorkTaskEventKind.toolOutput,
      '浏览器窗口已关闭',
      '任务未停止；等待用户点击继续。',
      host: current.host,
      metadata: const <String, Object?>{'taskContinues': true},
    );
    final window = _windows.remove(sessionId);
    window?.close();
  }

  Future<void> bringToForeground(String sessionId) async {
    final window = _windows[sessionId];
    if (window == null) return;
    await window.bringToForeground();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final window in _windows.values) {
      window.close();
    }
    _windows.clear();
    try {
      await _stateWrite;
    } on Object {
      // Session metadata is best effort during shutdown.
    }
    await _changes.close();
  }

  VisibleBrowserSession _requireSession(String id) {
    final session = _sessions[id];
    if (session == null) throw ArgumentError.value(id, 'sessionId');
    return session;
  }

  Uri _validateUrl(String rawUrl) {
    final uri = tryValidateSearchUrl(
      Uri.tryParse(rawUrl),
      allowInsecureHttp: true,
    );
    if (uri == null) {
      throw ArgumentError.value(
        rawUrl,
        'url',
        'Only absolute http/https public URLs are supported',
      );
    }
    return uri;
  }

  String _safeText(String value, int maxCharacters) {
    return _safeTextValue(value, maxCharacters);
  }

  void _setSession(String id, VisibleBrowserSession session) {
    if (_disposed) return;
    _sessions[id] = session;
    _emit();
    _queuePersist();
  }

  void _emit() {
    if (!_disposed && !_changes.isClosed) _changes.add(sessions);
  }
}
