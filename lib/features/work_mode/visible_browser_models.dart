import 'dart:async';

import 'package:flutter/foundation.dart';

abstract interface class VisibleBrowserWindow {
  Future<void> get onClose;

  ValueListenable<bool> get isNavigating;

  void setOnUrlRequestCallback(bool Function(String url) callback);

  void setOnNavigationCompletedCallback(FutureOr<void> Function() callback);

  void launch(String url);

  Future<String?> evaluateJavaScript(String javaScript);

  Future<void> bringToForeground({bool maximized = false});

  /// Stops pending navigation before an unsafe URL callback can be accepted
  /// by a native implementation whose boolean return value is advisory.
  Future<void> stop();

  void close();
}

typedef VisibleBrowserWindowFactory = Future<VisibleBrowserWindow> Function();

enum VisibleBrowserStatus { opening, ready, paused, closed, failed }

enum VisibleBrowserPauseReason { login, captcha, paywall }

class VisibleBrowserNavigation {
  final String url;
  final String host;
  final DateTime visitedAt;

  VisibleBrowserNavigation({
    required this.url,
    required this.host,
    DateTime? visitedAt,
  }) : visitedAt = (visitedAt ?? DateTime.now()).toUtc();

  DateTime get timestamp => visitedAt;
}

class VisibleBrowserSession {
  final String id;
  final String taskId;
  final String url;
  final String host;
  final String title;
  final String pageText;
  final String message;
  final VisibleBrowserStatus status;
  final VisibleBrowserPauseReason? pauseReason;
  final bool runtimeUnavailable;
  final List<VisibleBrowserNavigation> navigation;

  VisibleBrowserSession({
    required this.id,
    required this.taskId,
    required this.url,
    required this.host,
    this.title = '',
    this.pageText = '',
    this.message = '',
    this.status = VisibleBrowserStatus.opening,
    this.pauseReason,
    this.runtimeUnavailable = false,
    List<VisibleBrowserNavigation> navigation = const [],
  }) : navigation = List.unmodifiable(navigation);

  bool get canContinue =>
      status == VisibleBrowserStatus.paused ||
      status == VisibleBrowserStatus.closed;

  bool get isOpen =>
      status == VisibleBrowserStatus.opening ||
      status == VisibleBrowserStatus.ready ||
      status == VisibleBrowserStatus.paused;

  VisibleBrowserSession copyWith({
    String? url,
    String? host,
    String? title,
    String? pageText,
    String? message,
    VisibleBrowserStatus? status,
    VisibleBrowserPauseReason? pauseReason,
    bool clearPauseReason = false,
    bool? runtimeUnavailable,
    List<VisibleBrowserNavigation>? navigation,
  }) {
    return VisibleBrowserSession(
      id: id,
      taskId: taskId,
      url: url ?? this.url,
      host: host ?? this.host,
      title: title ?? this.title,
      pageText: pageText ?? this.pageText,
      message: message ?? this.message,
      status: status ?? this.status,
      pauseReason: clearPauseReason ? null : pauseReason ?? this.pauseReason,
      runtimeUnavailable: runtimeUnavailable ?? this.runtimeUnavailable,
      navigation: navigation ?? this.navigation,
    );
  }
}

class VisibleBrowserRuntimeUnavailable implements Exception {
  final String message;

  const VisibleBrowserRuntimeUnavailable([
    this.message = '当前设备没有可用的 WebView 运行时。',
  ]);

  @override
  String toString() => message;
}
