import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:chat_group/features/work_mode/visible_browser_window_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exposes a desktop runtime availability probe', () async {
    if (Platform.isWindows) {
      const channel = MethodChannel('webview_window');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      expect(await WebviewWindow.isWebviewAvailable(), isTrue);
      expect(calls, ['isWebviewAvailable']);
      return;
    }

    // 0.3.0 uses the platform WKWebView/WebKit implementation off Windows;
    // the package contract reports those desktop backends as available.
    expect(await WebviewWindow.isWebviewAvailable(), isTrue);
  });

  test('keeps Windows WebView2 data in an explicit writable location', () {
    final path = visibleBrowserWindowsDataPath(
        '/Users/example/Library/Application Support');
    expect(path, contains('chat_group'));
    expect(path, contains('WebView2'));
    expect(path, isNot('chat_group/WebView2'));
  });
}
