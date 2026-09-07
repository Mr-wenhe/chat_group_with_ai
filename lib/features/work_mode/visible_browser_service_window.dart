part of 'visible_browser_service.dart';

Future<void> _stopAndClose(VisibleBrowserWindow window) async {
  try {
    // Queue close synchronously before the native navigation delegate can
    // finish its unconditional `.allow` decision on macOS. stop() then
    // cancels any work already queued by that navigation.
    window.close();
  } on Object {
    // Native close is best effort during an unsafe callback.
  }
  try {
    await window.stop();
  } on Object {
    // A closed native window may reject stop; close remains the boundary.
  }
}

extension on VisibleBrowserService {
  bool _pruneSessions() {
    while (_sessions.length >= visibleBrowserMaxSessions) {
      final removable = _sessions.entries
          .where(
            (entry) =>
                entry.value.status == VisibleBrowserStatus.closed ||
                entry.value.status == VisibleBrowserStatus.failed,
          )
          .firstOrNull;
      if (removable == null) return false;
      _sessions.remove(removable.key);
    }
    return true;
  }
}

extension on VisibleBrowserService {
  Future<void> _createWindow(
    String sessionId, {
    bool checkDns = true,
  }) async {
    final session = _requireSession(sessionId);
    try {
      if (checkDns) {
        final uri = _validateUrl(session.url);
        // Restored sessions have no native window yet. Re-check the current
        // hostname before creating one so a previously public-looking URL
        // cannot be resumed after DNS changes to a private address.
        await requirePublicSearchEndpointDns(
          uri,
          isRelease: _isRelease,
          lookup: _dnsLookup,
          lookupTimeout: _dnsLookupTimeout,
        );
      }
      final window = await _windowFactory();
      final latest = _sessions[sessionId];
      if (_disposed ||
          latest == null ||
          latest.status == VisibleBrowserStatus.closed ||
          latest.status == VisibleBrowserStatus.failed) {
        // The user may close the panel while native window creation or its
        // focus request is still awaiting. Never resurrect a session that has
        // already been closed or failed in that gap.
        await _stopAndClose(window);
        return;
      }
      _windows[sessionId] = window;
      _setSession(
        sessionId,
        latest.copyWith(runtimeUnavailable: false),
      );
      window.setOnUrlRequestCallback(
        (url) => _handleNavigation(sessionId, url),
      );
      window.setOnNavigationCompletedCallback(
        () => _handleNavigationCompleted(sessionId),
      );
      unawaited(
        window.onClose.then<void>(
          (_) => _handleClosed(sessionId),
          onError: (Object _, StackTrace __) {},
        ),
      );
      await window.bringToForeground();
      final beforeLaunch = _sessions[sessionId];
      if (_disposed ||
          beforeLaunch == null ||
          beforeLaunch.status == VisibleBrowserStatus.closed ||
          beforeLaunch.status == VisibleBrowserStatus.failed) {
        _windows.remove(sessionId);
        await _stopAndClose(window);
        return;
      }
      window.launch(session.url);
      _record(
        session.taskId,
        WorkTaskEventKind.stepStarted,
        '已打开可见浏览器',
        '等待公开网页加载完成。',
        host: session.host,
      );
    } on SearchEndpointDnsException {
      final current = _sessions[sessionId];
      if (_disposed ||
          current == null ||
          current.status == VisibleBrowserStatus.closed ||
          current.status == VisibleBrowserStatus.failed) {
        return;
      }
      _setSession(
        sessionId,
        current.copyWith(
          status: VisibleBrowserStatus.failed,
          runtimeUnavailable: false,
          message: '网页地址未通过安全网络校验，已阻止打开。',
        ),
      );
      _record(
        current.taskId,
        WorkTaskEventKind.failed,
        '已阻止不安全网页打开',
        '恢复浏览器会话前的 DNS 校验未通过。',
        host: current.host,
      );
    } on VisibleBrowserRuntimeUnavailable catch (error) {
      final current = _sessions[sessionId];
      if (_disposed ||
          current == null ||
          current.status == VisibleBrowserStatus.closed ||
          current.status == VisibleBrowserStatus.failed) {
        return;
      }
      final unavailableWindow = _windows.remove(sessionId);
      if (unavailableWindow != null) {
        unawaited(_stopAndClose(unavailableWindow));
      }
      _setSession(
        sessionId,
        current.copyWith(
          status: VisibleBrowserStatus.paused,
          runtimeUnavailable: true,
          message: '${error.message}请安装 WebView 运行时后点击继续；任务未停止。',
        ),
      );
      _record(
        session.taskId,
        WorkTaskEventKind.paused,
        '可见浏览器暂不可用',
        '任务保持暂停，等待用户处理运行时依赖。',
        host: session.host,
      );
    } on Object {
      final current = _sessions[sessionId];
      if (_disposed ||
          current == null ||
          current.status == VisibleBrowserStatus.closed ||
          current.status == VisibleBrowserStatus.failed) {
        return;
      }
      final failedWindow = _windows.remove(sessionId);
      if (failedWindow != null) unawaited(_stopAndClose(failedWindow));
      _setSession(
        sessionId,
        current.copyWith(
          status: VisibleBrowserStatus.failed,
          runtimeUnavailable: false,
          message: '可见浏览器启动失败；任务仍可由用户重试。',
        ),
      );
      _record(
        session.taskId,
        WorkTaskEventKind.failed,
        '可见浏览器启动失败',
        '未能创建可见浏览器窗口。',
        host: session.host,
      );
    }
  }

  bool _handleNavigation(String sessionId, String rawUrl) {
    final current = _sessions[sessionId];
    // A native window can deliver one late URL callback after close(). Do not
    // let that callback implicitly reopen a session; only Continue may do so.
    if (current == null ||
        current.status == VisibleBrowserStatus.closed ||
        current.status == VisibleBrowserStatus.failed) {
      return false;
    }
    final uri = tryValidateSearchUrl(
      Uri.tryParse(rawUrl),
      allowInsecureHttp: true,
    );
    if (uri == null) {
      final window = _windows.remove(sessionId);
      if (window != null) unawaited(_stopAndClose(window));
      _setSession(
        sessionId,
        current.copyWith(
          status: VisibleBrowserStatus.failed,
          message: '已阻止不安全网页导航；任务未停止。',
        ),
      );
      _record(
        current.taskId,
        WorkTaskEventKind.failed,
        '已阻止不安全网页导航',
        '仅允许公开 http/https 网页。',
        host: current.host,
        metadata: <String, Object?>{
          'scheme': Uri.tryParse(rawUrl)?.scheme.toLowerCase() ?? 'invalid',
        },
      );
      return false;
    }
    if (uri.toString() == current.url) return true;
    final navigation = <VisibleBrowserNavigation>[
      ...current.navigation,
      VisibleBrowserNavigation(
        url: uri.toString(),
        host: uri.host,
        visitedAt: _clock(),
      ),
    ];
    if (navigation.length > visibleBrowserMaxNavigationEntries) {
      navigation.removeRange(
        0,
        navigation.length - visibleBrowserMaxNavigationEntries,
      );
    }
    final waitingForManualContinue =
        current.status == VisibleBrowserStatus.paused;
    _setSession(
      sessionId,
      current.copyWith(
        // A challenge remains paused until the explicit Continue action.
        status: waitingForManualContinue
            ? VisibleBrowserStatus.paused
            : VisibleBrowserStatus.opening,
        url: uri.toString(),
        host: uri.host,
        message: waitingForManualContinue ? '页面已导航；完成人工处理后请手点继续。' : '正在加载公开网页。',
        navigation: navigation,
      ),
    );
    _record(
      current.taskId,
      WorkTaskEventKind.toolOutput,
      '正在导航到公开网页',
      '域名：${uri.host}',
      host: uri.host,
      metadata: <String, Object?>{
        'navigationIndex': navigation.length,
      },
    );
    return true;
  }

  Future<void> _handleNavigationCompleted(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null ||
        session.status == VisibleBrowserStatus.closed ||
        session.status == VisibleBrowserStatus.paused) {
      return;
    }
    await _readPage(sessionId);
  }

  Future<void> _readPage(String sessionId) async {
    final existing = _reads[sessionId];
    if (existing != null) {
      await existing;
      return;
    }
    final operation = _readPageInternal(sessionId);
    _reads[sessionId] = operation;
    try {
      await operation;
    } finally {
      if (identical(_reads[sessionId], operation)) _reads.remove(sessionId);
    }
  }

  Future<void> _readPageInternal(String sessionId) async {
    final session = _requireSession(sessionId);
    final window = _windows[sessionId];
    if (window == null) return;
    final uri = _validateUrl(session.url);
    try {
      await requirePublicSearchEndpointDns(
        uri,
        isRelease: _isRelease,
        lookup: _dnsLookup,
        lookupTimeout: _dnsLookupTimeout,
      );
      final encoded = await window.evaluateJavaScript(
        visibleBrowserPageExtractionScript,
      );
      if (encoded != null &&
          encoded.length > visibleBrowserMaxEncodedPageCharacters) {
        throw const FormatException('公开网页读取结果超过大小上限');
      }
      final page = decodeVisibleBrowserPage(encoded, uri);
      // Validate the URL reported by the page before processing title/text.
      // Some native implementations treat the callback's boolean as
      // advisory, so this second boundary must fail closed as well.
      final pageUri = _validateUrl(page.url);
      // The page-reported location is the authoritative post-redirect URL.
      // A native adapter may omit an intermediate URL callback, so validate
      // this hostname independently before retaining or exposing any text.
      await requirePublicSearchEndpointDns(
        pageUri,
        isRelease: _isRelease,
        lookup: _dnsLookup,
        lookupTimeout: _dnsLookupTimeout,
      );
      final reason = detectVisibleBrowserPauseReason(page.title, page.text);
      final safeTitle = _safeText(page.title, 240);
      final safeText = _safeText(page.text, _maxPageCharacters);
      final latest = _sessions[sessionId];
      if (latest == null ||
          latest.status == VisibleBrowserStatus.closed ||
          latest.status == VisibleBrowserStatus.paused) {
        return;
      }
      if (reason != null) {
        _setSession(
          sessionId,
          latest.copyWith(
            status: VisibleBrowserStatus.paused,
            url: pageUri.toString(),
            host: pageUri.host,
            title: safeTitle,
            pageText: '',
            message:
                '${visibleBrowserPauseReasonLabel(reason)}；不会读取密码或账号信息，完成后请手点继续。',
            pauseReason: reason,
          ),
        );
        _record(
          session.taskId,
          WorkTaskEventKind.paused,
          '网页需要人工处理',
          '${visibleBrowserPauseReasonLabel(reason)}；请完成后手点继续。',
          host: pageUri.host,
          metadata: <String, Object?>{'pauseReason': reason.name},
        );
        return;
      }
      _setSession(
        sessionId,
        latest.copyWith(
          status: VisibleBrowserStatus.ready,
          url: pageUri.toString(),
          host: pageUri.host,
          title: safeTitle,
          pageText: safeText,
          message: '已读取公开网页正文。',
          clearPauseReason: true,
        ),
      );
      _record(
        session.taskId,
        WorkTaskEventKind.toolOutput,
        '已读取公开网页正文',
        '域名：${pageUri.host}，共 ${safeText.length} 个字符。',
        host: pageUri.host,
        metadata: <String, Object?>{'characters': safeText.length},
      );
    } on SearchEndpointDnsException {
      final unsafeWindow = _windows.remove(sessionId);
      if (unsafeWindow != null) unawaited(_stopAndClose(unsafeWindow));
      _markReadFailed(sessionId, '网页地址未通过安全网络校验，已阻止读取。');
    } on ArgumentError {
      final unsafeWindow = _windows.remove(sessionId);
      if (unsafeWindow != null) unawaited(_stopAndClose(unsafeWindow));
      _markReadFailed(sessionId, '网页返回了不允许的地址，已阻止读取。');
    } on Object {
      _markReadFailed(sessionId, '公开网页读取失败；任务仍可由用户重试。');
    }
  }

  void _markReadFailed(String sessionId, String message) {
    final latest = _sessions[sessionId];
    if (latest == null ||
        latest.status == VisibleBrowserStatus.closed ||
        latest.status == VisibleBrowserStatus.failed) {
      return;
    }
    _setSession(
      sessionId,
      latest.copyWith(status: VisibleBrowserStatus.failed, message: message),
    );
    _record(
      latest.taskId,
      WorkTaskEventKind.failed,
      '公开网页读取失败',
      message,
      host: latest.host,
    );
  }

  void _handleClosed(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null ||
        session.status == VisibleBrowserStatus.closed ||
        session.status == VisibleBrowserStatus.failed) {
      return;
    }
    _windows.remove(sessionId);
    _setSession(
      sessionId,
      session.copyWith(
        status: VisibleBrowserStatus.closed,
        message: '浏览器窗口已关闭，任务未停止；点击继续可重新打开。',
      ),
    );
    _record(
      session.taskId,
      WorkTaskEventKind.toolOutput,
      '浏览器窗口已关闭',
      '任务未停止；等待用户点击继续。',
      host: session.host,
      metadata: const <String, Object?>{'taskContinues': true},
    );
  }
}
