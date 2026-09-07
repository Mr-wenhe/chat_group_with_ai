import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/work_mode/presentation/visible_browser_panel.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_overlay_host.dart';
import 'package:chat_group/features/work_mode/visible_browser_page.dart';
import 'package:chat_group/features/work_mode/visible_browser_service.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/web_search/security/search_endpoint_dns_guard.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWindow implements VisibleBrowserWindow {
  final Completer<void> _closed = Completer<void>();
  final List<String> launchedUrls = <String>[];
  final List<String> evaluatedScripts = <String>[];
  final ValueNotifier<bool> _navigating = ValueNotifier<bool>(false);
  bool isClosed = false;
  int stopCount = 0;
  FutureOr<void> Function()? onNavigationCompleted;
  bool Function(String url)? onUrlRequest;
  String? nextPageJson;
  bool throwRuntimeUnavailableOnForeground = false;

  @override
  Future<void> get onClose => _closed.future;

  @override
  ValueListenable<bool> get isNavigating => _navigating;

  @override
  void setOnUrlRequestCallback(bool Function(String url) callback) {
    onUrlRequest = callback;
  }

  @override
  void setOnNavigationCompletedCallback(
    FutureOr<void> Function() callback,
  ) {
    onNavigationCompleted = callback;
  }

  @override
  void launch(String url) {
    launchedUrls.add(url);
    onUrlRequest?.call(url);
  }

  @override
  Future<String?> evaluateJavaScript(String javaScript) async {
    evaluatedScripts.add(javaScript);
    return nextPageJson;
  }

  @override
  Future<void> bringToForeground({bool maximized = false}) async {
    if (throwRuntimeUnavailableOnForeground) {
      throw const VisibleBrowserRuntimeUnavailable('WebView2 不可用。');
    }
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  void close() {
    isClosed = true;
    if (!_closed.isCompleted) _closed.complete();
  }

  Future<void> completeNavigation() async {
    await onNavigationCompleted?.call();
  }

  bool requestNavigation(String url) => onUrlRequest?.call(url) ?? false;

  void dispose() {
    _navigating.dispose();
    if (!_closed.isCompleted) _closed.complete();
  }
}

class _FakeWindowFactory {
  final List<_FakeWindow> windows = <_FakeWindow>[];
  String? nextPageJson;
  bool throwRuntimeUnavailableOnForeground = false;

  Future<VisibleBrowserWindow> call() async {
    final window = _FakeWindow()
      ..nextPageJson = nextPageJson
      ..throwRuntimeUnavailableOnForeground =
          throwRuntimeUnavailableOnForeground;
    windows.add(window);
    return window;
  }

  void dispose() {
    for (final window in windows) {
      window.dispose();
    }
  }
}

AgentTask _task(String id) => AgentTask(
      id: id,
      groupId: 'group-one',
      characterId: 'developer',
      userRequest: '搜索公开资料',
      workModeTask: true,
    );

Future<void> _settle() async {
  await Future<void>.value();
  await Future<void>.value();
}

Future<WorkTaskEventStore> _eventStore() async {
  final directory = await Directory.systemTemp.createTemp('visible-browser-');
  return WorkTaskEventStore(appSupportDirectory: directory);
}

void main() {
  group('VisibleBrowserService', () {
    test('rejects non-http(s) URLs before creating a window', () async {
      final factory = _FakeWindowFactory();
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });

      for (final url in <String>[
        'file:///tmp/private.txt',
        'javascript:alert(1)',
        'data:text/plain,secret',
      ]) {
        await expectLater(
          service.open(taskId: 'browser-task', url: url),
          throwsArgumentError,
        );
      }
      expect(factory.windows, isEmpty);
    });

    test('rejects task IDs that cannot be written to the audit store',
        () async {
      final factory = _FakeWindowFactory();
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });

      await expectLater(
        service.open(taskId: 'turn:with-colon', url: 'https://example.com'),
        throwsArgumentError,
      );
      expect(factory.windows, isEmpty);
    });

    test('checks the initial hostname before creating a release window',
        () async {
      final factory = _FakeWindowFactory();
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: true,
        dnsLookup: (_) async => const ['10.0.0.8'],
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });

      await expectLater(
        service.open(taskId: 'browser-task', url: 'https://public.example'),
        throwsA(isA<SearchEndpointDnsException>()),
      );
      expect(factory.windows, isEmpty);
      expect(service.sessions, isEmpty);
    });

    test('rechecks DNS before reopening a restored session', () async {
      final directory = await Directory.systemTemp.createTemp('browser-dns-');
      final statePath = '${directory.path}/visible_browser_sessions.json';
      final factory = _FakeWindowFactory();
      final first = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
        sessionStatePath: statePath,
      );
      await first.open(taskId: 'restart-task', url: 'https://example.com');
      final sessionId = first.sessions.single.id;
      await first.closeSession(sessionId);
      await first.dispose();

      final second = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: true,
        dnsLookup: (_) async => const ['10.0.0.8'],
        sessionStatePath: statePath,
      );
      addTearDown(() async {
        factory.dispose();
        await second.dispose();
        await directory.delete(recursive: true);
      });

      await second.restore();
      await second.continueSession(sessionId);
      expect(second.sessions.single.status, VisibleBrowserStatus.failed);
      // The private answer is rejected before the native factory is called.
      expect(factory.windows, hasLength(1));
    });

    test('closes the native window when a post-navigation DNS check fails',
        () async {
      var resolvePrivateAddress = false;
      final factory = _FakeWindowFactory();
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: true,
        dnsLookup: (_) async => resolvePrivateAddress
            ? const ['10.0.0.8']
            : const ['93.184.216.34'],
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });

      await service.open(taskId: 'browser-task', url: 'https://example.com');
      resolvePrivateAddress = true;
      await factory.windows.single.completeNavigation();
      await _settle();

      expect(service.sessions.single.status, VisibleBrowserStatus.failed);
      expect(factory.windows.single.isClosed, isTrue);
      expect(factory.windows.single.stopCount, 1);
    });

    test('rejects a private DNS answer for the page-reported redirect URL',
        () async {
      var lookupCount = 0;
      final factory = _FakeWindowFactory()
        ..nextPageJson = jsonEncode({
          'url': 'https://redirected.example/private',
          'title': 'Results',
          'text': 'must not be retained',
        });
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: true,
        dnsLookup: (_) async {
          lookupCount++;
          // The initial URL and the pre-read session URL are public. The
          // page-reported redirect is the first private answer.
          return lookupCount < 3 ? const ['93.184.216.34'] : const ['10.0.0.8'];
        },
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });

      await service.open(taskId: 'browser-task', url: 'https://example.com');
      await factory.windows.single.completeNavigation();
      await _settle();

      expect(service.sessions.single.status, VisibleBrowserStatus.failed);
      expect(service.sessions.single.pageText, isEmpty);
      expect(factory.windows.single.isClosed, isTrue);
      expect(factory.windows.single.stopCount, 1);
      expect(lookupCount, 3);
    });

    test('cleans up a native window when runtime fails during focus', () async {
      final factory = _FakeWindowFactory()
        ..throwRuntimeUnavailableOnForeground = true;
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });

      final opened = await service.open(
        taskId: 'browser-task',
        url: 'https://example.com',
      );
      await _settle();
      expect(opened.status, VisibleBrowserStatus.paused);
      expect(service.sessions.single.runtimeUnavailable, isTrue);
      expect(factory.windows.single.isClosed, isTrue);

      factory.throwRuntimeUnavailableOnForeground = false;
      await service.continueSession(service.sessions.single.id);
      expect(factory.windows, hasLength(2));
    });

    test('opens public page, exposes host/navigation, and logs safe events',
        () async {
      final factory = _FakeWindowFactory()
        ..nextPageJson = jsonEncode({
          'url': 'https://example.com/results',
          'title': 'Results',
          'text': 'Public answer body',
        });
      final events = await _eventStore();
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        eventStore: events,
        isRelease: false,
      );
      addTearDown(() async {
        factory.dispose();
        await service.dispose();
        await events.close();
      });

      await service.open(
          taskId: 'browser-task', url: 'https://example.com/start');
      final opening = service.sessions.single;
      expect(opening.status, VisibleBrowserStatus.opening);
      expect(opening.host, 'example.com');
      expect(
          factory.windows.single.launchedUrls, ['https://example.com/start']);

      await factory.windows.single.completeNavigation();
      await _settle();
      final ready = service.sessions.single;
      expect(ready.status, VisibleBrowserStatus.ready);
      expect(ready.pageText, contains('Public answer body'));
      expect(ready.navigation.single.host, 'example.com');

      final persisted = await events.read('browser-task');
      expect(persisted.events.map((event) => event.kind),
          contains(WorkTaskEventKind.toolOutput));
      expect(
          persisted.events.every((event) =>
              event.safeMetadata['host'] == null ||
              event.safeMetadata['host'] == 'example.com'),
          isTrue);
      expect(persisted.events.map((event) => event.detail).join(' '),
          isNot(contains('password')));
    });

    test('pauses for login, captcha, and paywall without reading passwords',
        () async {
      final cases = <Map<String, Object>>[
        {
          'title': 'Login required',
          'text': 'Please sign in to continue',
          'reason': VisibleBrowserPauseReason.login
        },
        {
          'title': 'Captcha',
          'text': 'Verify you are human',
          'reason': VisibleBrowserPauseReason.captcha
        },
        {
          'title': 'Subscribe',
          'text': 'Subscribe to continue',
          'reason': VisibleBrowserPauseReason.paywall
        },
      ];
      for (final item in cases) {
        final factory = _FakeWindowFactory()
          ..nextPageJson = jsonEncode({
            'url': 'https://example.com/gated',
            'title': item['title'],
            'text': '${item['text']} password=super-secret',
          });
        final events = await _eventStore();
        final service = VisibleBrowserService(
          windowFactory: factory.call,
          eventStore: events,
          isRelease: false,
        );
        await service.open(
            taskId: 'gated-task', url: 'https://example.com/gated');
        await factory.windows.single.completeNavigation();
        await _settle();

        final paused = service.sessions.single;
        expect(paused.status, VisibleBrowserStatus.paused);
        expect(paused.pauseReason, item['reason']);
        expect(paused.pageText, isEmpty);
        expect(factory.windows.single.evaluatedScripts.single,
            contains('password'));
        final persisted = await events.read('gated-task');
        expect(jsonEncode(persisted.events), isNot(contains('super-secret')));

        factory.dispose();
        await service.dispose();
        await events.close();
      }
    });

    test('closing browser keeps session resumable and does not stop task',
        () async {
      final factory = _FakeWindowFactory()
        ..nextPageJson = jsonEncode({
          'url': 'https://example.com/results',
          'title': 'Results',
          'text': 'public',
        });
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
      );
      var stoppedTaskCount = 0;
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });

      await service.open(taskId: 'browser-task', url: 'https://example.com');
      await factory.windows.single.completeNavigation();
      await _settle();
      await service.closeSession(service.sessions.single.id);
      expect(service.sessions.single.status, VisibleBrowserStatus.closed);
      expect(service.sessions.single.canContinue, isTrue);
      expect(stoppedTaskCount, 0);
      // A late native callback must not resume the closed session implicitly.
      expect(
          factory.windows.single.requestNavigation('https://example.com/late'),
          isFalse);
      expect(service.sessions.single.status, VisibleBrowserStatus.closed);

      await service.continueSession(service.sessions.single.id);
      expect(factory.windows, hasLength(2));
      expect(service.sessions.single.status, VisibleBrowserStatus.opening);
      expect(stoppedTaskCount, 0);
    });

    test('does not create a thirty-third session when all sessions are active',
        () async {
      final factory = _FakeWindowFactory();
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });

      for (var index = 0; index < visibleBrowserMaxSessions; index++) {
        await service.open(
          taskId: 'browser-$index',
          url: 'https://example.com/$index',
        );
      }
      await expectLater(
        service.open(
            taskId: 'browser-overflow', url: 'https://example.com/overflow'),
        throwsStateError,
      );
      expect(service.sessions, hasLength(visibleBrowserMaxSessions));
      expect(factory.windows, hasLength(visibleBrowserMaxSessions));
    });

    test('does not resurrect a session closed during window creation',
        () async {
      final created = Completer<VisibleBrowserWindow>();
      final window = _FakeWindow();
      final service = VisibleBrowserService(
        windowFactory: () => created.future,
        isRelease: false,
      );
      addTearDown(() {
        window.dispose();
        service.dispose();
      });

      final opening = service.open(
        taskId: 'browser-task',
        url: 'https://example.com',
      );
      await _settle();
      final sessionId = service.sessions.single.id;
      await service.closeSession(sessionId);
      created.complete(window);

      final result = await opening;
      expect(result.status, VisibleBrowserStatus.closed);
      expect(window.isClosed, isTrue);
      expect(window.launchedUrls, isEmpty);
      expect(window.stopCount, 1);
    });

    test('restores a closed resumable session after a service restart',
        () async {
      final directory = await Directory.systemTemp.createTemp('browser-state-');
      final statePath = '${directory.path}/visible_browser_sessions.json';
      final factory = _FakeWindowFactory();
      final first = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
        sessionStatePath: statePath,
      );
      await first.open(taskId: 'restart-task', url: 'https://example.com');
      final sessionId = first.sessions.single.id;
      await first.closeSession(sessionId);
      await first.dispose();

      final second = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
        sessionStatePath: statePath,
      );
      addTearDown(() async {
        factory.dispose();
        await second.dispose();
        await directory.delete(recursive: true);
      });
      await second.restore();
      expect(second.sessions, hasLength(1));
      expect(second.sessions.single.id, sessionId);
      expect(second.sessions.single.status, VisibleBrowserStatus.closed);
      expect(second.sessions.single.canContinue, isTrue);
      expect(second.sessions.single.pageText, isEmpty);
      await second.continueSession(sessionId);
      expect(factory.windows, hasLength(2));
    });

    test('continue only re-reads after a manual click', () async {
      final factory = _FakeWindowFactory()
        ..nextPageJson = jsonEncode({
          'url': 'https://login.example',
          'title': 'Login required',
          'text': 'Please sign in',
        });
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });

      await service.open(taskId: 'browser-task', url: 'https://login.example');
      await factory.windows.single.completeNavigation();
      await _settle();
      expect(factory.windows.single.evaluatedScripts, hasLength(1));

      expect(
        factory.windows.single.requestNavigation('https://login.example/home'),
        isTrue,
      );
      await factory.windows.single.completeNavigation();
      await _settle();
      expect(factory.windows.single.evaluatedScripts, hasLength(1));
      expect(service.sessions.single.status, VisibleBrowserStatus.paused);

      factory.windows.single.nextPageJson = jsonEncode({
        'url': 'https://login.example/home',
        'title': 'Home',
        'text': 'public result',
      });
      await service.continueSession(service.sessions.single.id);
      await _settle();
      expect(factory.windows.single.evaluatedScripts, hasLength(2));
      expect(service.sessions.single.status, VisibleBrowserStatus.ready);
    });

    testWidgets('panel shows domain/navigation and manual continue',
        (tester) async {
      final factory = _FakeWindowFactory()
        ..nextPageJson = jsonEncode({
          'url': 'https://login.example',
          'title': 'Login required',
          'text': 'Please sign in',
        });
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });
      await service.open(taskId: 'browser-task', url: 'https://login.example');
      await factory.windows.single.completeNavigation();
      await _settle();
      var continued = false;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: VisibleBrowserPanel(
            sessions: service.sessions,
            selectedSessionId: service.sessions.single.id,
            onSelectSession: (_) {},
            onContinue: (_) async => continued = true,
            onClose: (_) async {},
          ),
        ),
      ));
      expect(find.byKey(const Key('visible-browser-panel')), findsOneWidget);
      expect(find.text('域名：login.example'), findsOneWidget);
      expect(find.text('导航记录'), findsOneWidget);
      expect(find.byKey(const Key('visible-browser-continue')), findsOneWidget);
      await tester.tap(find.byKey(const Key('visible-browser-continue')));
      expect(continued, isTrue);
      expect(find.byKey(const Key('visible-browser-close')), findsOneWidget);
    });

    testWidgets('overlay host keeps browser panel independent from task panel',
        (tester) async {
      final factory = _FakeWindowFactory()
        ..nextPageJson = jsonEncode({
          'url': 'https://example.com',
          'title': 'Results',
          'text': 'public',
        });
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
      );
      final task = _task('task-one');
      final tasks = StreamController<List<AgentTask>>();
      final stoppedTaskIds = <String>[];
      addTearDown(() {
        tasks.close();
        factory.dispose();
        service.dispose();
      });
      await service.open(taskId: task.id, url: 'https://example.com');
      await factory.windows.single.completeNavigation();
      await _settle();
      tasks.add(<AgentTask>[task]);

      await tester.pumpWidget(MaterialApp(
        home: WorkTaskOverlayHost(
          browserService: service,
          taskStream: tasks.stream,
          eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
          onStopTask: (taskId) async => stoppedTaskIds.add(taskId),
          onContinueTask: (_) async {},
          child: const ColoredBox(color: Colors.white),
        ),
      ));
      await tester.pump();
      expect(find.byKey(const Key('visible-browser-panel')), findsOneWidget);
      expect(find.byKey(const Key('work-task-panel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('visible-browser-close')));
      await _settle();
      expect(service.sessions.single.status, VisibleBrowserStatus.closed);
      expect(stoppedTaskIds, isEmpty);
    });

    test('allows public http navigation but blocks unsafe schemes', () async {
      final factory = _FakeWindowFactory()
        ..nextPageJson = jsonEncode({
          'url': 'http://public.example/start',
          'title': 'Results',
          'text': 'public',
        });
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });
      await service.open(
          taskId: 'browser-task', url: 'http://public.example/start');
      final window = factory.windows.single;
      expect(window.requestNavigation('file:///tmp/secret'), isFalse);
      expect(service.sessions.single.url, 'http://public.example/start');
      expect(window.stopCount, 1);
      expect(service.sessions.single.status, VisibleBrowserStatus.failed);
      expect(window.requestNavigation('http://public.example/next'), isFalse);
    });

    test('bounds an untrusted JavaScript result before JSON decoding',
        () async {
      final factory = _FakeWindowFactory()
        ..nextPageJson = 'x' * (visibleBrowserMaxEncodedPageCharacters + 1);
      final service = VisibleBrowserService(
        windowFactory: factory.call,
        isRelease: false,
      );
      addTearDown(() {
        factory.dispose();
        service.dispose();
      });

      await service.open(taskId: 'browser-task', url: 'https://example.com');
      await factory.windows.single.completeNavigation();
      await _settle();

      expect(service.sessions.single.status, VisibleBrowserStatus.failed);
      expect(service.sessions.single.pageText, isEmpty);
    });
  });
}
