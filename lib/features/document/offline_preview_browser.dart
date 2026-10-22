import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_windows/webview_windows.dart' as windows;

import 'offline_preview_html.dart';
import 'attachment_media_preview.dart';

/// Uses the same WKWebView engine as work-mode testing, with a separate viewer.
class OfflinePreviewBrowser extends StatefulWidget {
  const OfflinePreviewBrowser(
      {super.key, required this.html, this.mediaControls = false});
  final bool mediaControls;
  final String html;
  @override
  State<OfflinePreviewBrowser> createState() => _OfflinePreviewBrowserState();
}

class _OfflinePreviewBrowserState extends State<OfflinePreviewBrowser> {
  WebKitWebViewController? _mac;
  windows.WebviewController? _windows;
  Directory? _pageDirectory;
  bool _initializing = true;
  bool _ready = false;
  String? _error;
  double _zoom = 1;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final html =
          offlinePreviewHtml(widget.html, mediaPlayback: widget.mediaControls);
      if (Platform.isMacOS) {
        await _initializeMac(html);
      } else if (Platform.isWindows) {
        final controller = windows.WebviewController();
        _windows = controller;
        await controller.initialize();
        if (!mounted) {
          return;
        }
        await controller
            .setPopupWindowPolicy(windows.WebviewPopupWindowPolicy.deny);
        await controller.setBackgroundColor(Colors.white);
        // WebView2 NavigateToString has a 2 MiB limit; a private wrapper file
        // also supports larger local media without granting the sandbox file access.
        final directory = await Directory.systemTemp
            .createTemp('chat-group-browser-preview-');
        _pageDirectory = directory;
        final page =
            await File('${directory.path}/index.html').writeAsString(html);
        if (!mounted) return;
        await controller.loadUrl(page.uri.toString());
      } else {
        throw UnsupportedError('desktop only');
      }
      if (mounted) setState(() => _ready = true);
    } on Object {
      if (mounted) {
        setState(() => _error = Platform.isWindows
            ? '浏览器无法启动，请安装 Microsoft Edge WebView2 Runtime 后重试。'
            : '内嵌浏览器无法启动，请尝试用系统应用打开。');
      }
    } finally {
      _initializing = false;
      if (!mounted || !_ready) await _disposeWindows();
    }
  }

  Future<void> _initializeMac(String html) async {
    final controller = WebKitWebViewController(
        WebKitWebViewControllerCreationParams(
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: widget.mediaControls
                ? const <PlaybackMediaTypes>{}
                : const <PlaybackMediaTypes>{
                    PlaybackMediaTypes.audio,
                    PlaybackMediaTypes.video
                  }));
    _mac = controller;
    final navigation = WebKitNavigationDelegate(
        const PlatformNavigationDelegateCreationParams());
    await navigation.setOnNavigationRequest((request) =>
        request.url == 'about:blank' || request.url == 'about:srcdoc'
            ? NavigationDecision.navigate
            : NavigationDecision.prevent);
    await controller.setPlatformNavigationDelegate(navigation);
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    if (!mounted) return;
    await controller.loadHtmlString(html);
  }

  Future<void> _disposeWindows() async {
    final controller = _windows;
    _windows = null;
    if (controller != null) {
      try {
        await controller.dispose();
      } on Object {/* Failed initialization has no texture to release. */}
    }
    final directory = _pageDirectory;
    _pageDirectory = null;
    if (directory != null) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {/* WebView2 may still hold its file. */}
    }
  }

  @override
  void dispose() {
    // WKWebView is released with its platform view; blank it to stop page timers/media.
    unawaited(_mac?.loadHtmlString('').catchError((Object _) {}) ??
        Future<void>.value());
    if (!_initializing) unawaited(_disposeWindows());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(_error!));
    if (!_ready) return const Center(child: CircularProgressIndicator());
    final content = _mac != null
        ? WebKitWebViewWidget(
                WebKitWebViewWidgetCreationParams(controller: _mac!))
            .build(context)
        : windows.Webview(_windows!,
            permissionRequested: (_, __, ___) =>
                windows.WebviewPermissionDecision.deny);
    return Column(children: [
      if (!widget.mediaControls)
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          IconButton(
              tooltip: '缩小',
              onPressed: () => _changeZoom(.8),
              icon: const Icon(Icons.zoom_out)),
          IconButton(
              tooltip: '放大',
              onPressed: () => _changeZoom(1.25),
              icon: const Icon(Icons.zoom_in)),
        ]),
      Expanded(child: content),
      if (widget.mediaControls)
        AttachmentMediaControls(onCommand: _mediaCommand),
    ]);
  }

  Future<void> _mediaCommand(AttachmentMediaCommand command) async {
    final script =
        'document.querySelector("iframe").contentWindow.postMessage(${jsonEncode(command.name)}, "*");';
    try {
      if (_mac != null) await _mac!.runJavaScript(script);
      if (_windows != null) await _windows!.executeScript(script);
    } on Object {
      if (mounted) setState(() => _error = '播放控制失败，请用系统应用打开。');
    }
  }

  Future<void> _changeZoom(double factor) async {
    _zoom = (_zoom * factor).clamp(.5, 3);
    try {
      if (_mac != null) {
        await _mac!.runJavaScript('document.body.style.zoom = "$_zoom";');
      }
      if (_windows != null) await _windows!.setZoomFactor(_zoom);
    } on Object {/* A view being closed has no zoom target. */}
  }
}
