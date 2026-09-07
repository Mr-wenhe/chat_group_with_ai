import 'dart:async';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart' as desktop;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'visible_browser_models.dart';

class _DesktopVisibleBrowserWindow implements VisibleBrowserWindow {
  final desktop.Webview _webview;
  bool _wasNavigating = false;
  VoidCallback? _navigationListener;

  _DesktopVisibleBrowserWindow(this._webview);

  @override
  Future<void> get onClose => _webview.onClose;

  @override
  ValueListenable<bool> get isNavigating => _webview.isNavigating;

  @override
  void setOnUrlRequestCallback(bool Function(String url) callback) {
    _webview.setOnUrlRequestCallback(callback);
  }

  @override
  void setOnNavigationCompletedCallback(
    FutureOr<void> Function() callback,
  ) {
    void listener() {
      final navigating = _webview.isNavigating.value;
      final completed = _wasNavigating && !navigating;
      _wasNavigating = navigating;
      if (completed) unawaited(Future<void>.sync(callback));
    }

    _navigationListener = listener;
    _webview.isNavigating.addListener(listener);
  }

  @override
  void launch(String url) => _webview.launch(url);

  @override
  Future<String?> evaluateJavaScript(String javaScript) =>
      _webview.evaluateJavaScript(javaScript);

  @override
  Future<void> bringToForeground({bool maximized = false}) =>
      _webview.bringToForeground(maximized: maximized);

  @override
  Future<void> stop() async {
    await _webview.stop();
  }

  @override
  void close() {
    final listener = _navigationListener;
    if (listener != null) _webview.isNavigating.removeListener(listener);
    _navigationListener = null;
    _webview.close();
  }
}

Future<VisibleBrowserWindow> createDesktopVisibleBrowserWindow() async {
  if (!await desktop.WebviewWindow.isWebviewAvailable()) {
    throw const VisibleBrowserRuntimeUnavailable();
  }
  final userDataFolderWindows = Platform.isWindows
      ? await _windowsWebViewDataDirectory()
      : 'webview_window_WebView2';
  final webview = await desktop.WebviewWindow.create(
    configuration: desktop.CreateConfiguration(
      title: '可见浏览器',
      userDataFolderWindows: userDataFolderWindows,
    ),
  );
  return _DesktopVisibleBrowserWindow(webview);
}

/// Returns a stable, writable Windows WebView2 profile location beneath the
/// platform Application Support directory instead of the read-only install
/// directory (for example, Program Files).
String visibleBrowserWindowsDataPath(String applicationSupportPath) {
  final root = Directory(applicationSupportPath).path;
  return Directory(
          '$root${Platform.pathSeparator}chat_group${Platform.pathSeparator}WebView2')
      .path;
}

Future<String> _windowsWebViewDataDirectory() async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory(visibleBrowserWindowsDataPath(support.path));
  await directory.create(recursive: true);
  return directory.path;
}

/// The browser walks only a bounded text prefix, skipping active controls and
/// embedded documents. It never clones an untrusted full DOM or reads form
/// values, cookies, storage, or files.
const String visibleBrowserPageExtractionScript = r'''
(() => {
  const source = document.body || document.documentElement;
  if (!source) return JSON.stringify({url: location.href, title: document.title, text: ''});
  const maxCharacters = 24000;
  const maxVisitedNodes = 100000;
  const blockedTags = new Set([
    'script', 'style', 'noscript', 'template', 'iframe', 'object', 'embed',
    'svg', 'canvas', 'input', 'textarea', 'select', 'button'
  ]);
  const chunks = [];
  let characterCount = 0;
  let visitedNodes = 0;
  const appendText = (value) => {
    if (!value || characterCount >= maxCharacters) return;
    const normalized = value.replace(/\s+/g, ' ').trim();
    if (!normalized) return;
    const remaining = maxCharacters - characterCount;
    const bounded = normalized.slice(0, remaining);
    chunks.push(bounded);
    characterCount += bounded.length;
  };
  const shouldSkip = (element) => {
    const tag = (element.tagName || '').toLowerCase();
    if (blockedTags.has(tag)) return true;
    if (element.hidden ||
        (element.getAttribute('aria-hidden') || '').toLowerCase() === 'true') {
      return true;
    }
    try {
      const style = window.getComputedStyle(element);
      if (style.display === 'none' ||
          style.visibility === 'hidden' ||
          style.visibility === 'collapse') {
        return true;
      }
    } catch (_) {
      // A detached/hostile element may not expose computed style. The other
      // structural guards still apply, so continue without reading its text.
    }
    const editable = (element.getAttribute('contenteditable') || '').toLowerCase();
    if (editable && editable !== 'false') return true;
    return (element.getAttribute('type') || '').toLowerCase() === 'password';
  };
  if (shouldSkip(source)) {
    return JSON.stringify({url: location.href, title: document.title, text: ''});
  }
  const collect = (node) => {
    if (characterCount >= maxCharacters || ++visitedNodes > maxVisitedNodes) return;
    if (node.nodeType === Node.TEXT_NODE) {
      appendText(node.nodeValue || '');
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    if (node !== source && shouldSkip(node)) return;
    for (let child = node.firstChild; child; child = child.nextSibling) {
      collect(child);
      if (characterCount >= maxCharacters || visitedNodes > maxVisitedNodes) return;
    }
  };
  collect(source);
  const text = chunks.join(' ').replace(/\s+/g, ' ').trim();
  return JSON.stringify({
    url: location.href,
    title: (document.title || '').slice(0, 240),
    text
  });
})()
''';
