import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory appSupportDirectory;

  setUp(() async {
    appSupportDirectory =
        await Directory.systemTemp.createTemp('work-task-events-');
  });

  tearDown(() async {
    if (await appSupportDirectory.exists()) {
      await appSupportDirectory.delete(recursive: true);
    }
  });

  test('appends monotonically sequenced events and replays after restart',
      () async {
    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);

    final first = await store.append(
      taskId: 'task-1',
      kind: WorkTaskEventKind.queued,
      title: '已排队',
    );
    final second = await store.append(
      taskId: 'task-1',
      kind: WorkTaskEventKind.planning,
      title: '正在规划',
      detail: '读取项目结构',
    );

    expect([first.sequence, second.sequence], [1, 2]);

    final restored =
        WorkTaskEventStore(appSupportDirectory: appSupportDirectory);
    final replay = await restored.read('task-1');

    expect(replay.events, hasLength(2));
    expect(replay.events.map((event) => event.sequence), [1, 2]);
    expect(replay.events.last.detail, '读取项目结构');
    expect(replay.issues, isEmpty);
  });

  test('serializes concurrent appends for the same task', () async {
    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);

    final appended = await Future.wait(
      List.generate(
        40,
        (index) => store.append(
          taskId: 'task-concurrent',
          kind: WorkTaskEventKind.toolOutput,
          title: '工具输出 $index',
          detail: 'line $index',
        ),
      ),
    );
    final replay = await store.read('task-concurrent');

    expect(
      appended.map((event) => event.sequence).toSet(),
      Set<int>.from(List.generate(40, (index) => index + 1)),
    );
    expect(
      replay.events.map((event) => event.sequence),
      List<int>.generate(40, (index) => index + 1),
    );
  });

  test('replays persisted events and then streams future events', () async {
    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);
    await store.append(
      taskId: 'task-stream',
      kind: WorkTaskEventKind.queued,
      title: '已排队',
    );

    final received = <WorkTaskEvent>[];
    final replayed = Completer<void>();
    final receivedBoth = Completer<void>();
    final subscription = store.watch('task-stream').listen((event) {
      received.add(event);
      if (event.sequence == 1 && !replayed.isCompleted) replayed.complete();
      if (received.length == 2 && !receivedBoth.isCompleted) {
        receivedBoth.complete();
      }
    });
    await replayed.future.timeout(const Duration(seconds: 2));
    await store.append(
      taskId: 'task-stream',
      kind: WorkTaskEventKind.completed,
      title: '已完成',
    );
    await receivedBoth.future.timeout(const Duration(seconds: 2));
    await subscription.cancel();

    expect(received.map((event) => event.sequence), [1, 2]);
  });

  test('ignores a truncated final JSONL line and reports a safe issue',
      () async {
    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);
    await store.append(
      taskId: 'task-truncated',
      kind: WorkTaskEventKind.stepStarted,
      title: '开始读取',
    );
    final file = store.eventFileFor('task-truncated');
    await file.writeAsString('{"sequence":2', mode: FileMode.append);

    final replay = await store.read('task-truncated');

    expect(replay.events.map((event) => event.sequence), [1]);
    expect(replay.issues, hasLength(1));
    expect(
      replay.issues.single.kind,
      WorkTaskEventReadIssueKind.truncatedFinalLineIgnored,
    );
    expect(replay.issues.single.message, isNot(contains('{"sequence"')));
  });

  test('watch surfaces replay issues after valid events for panel recovery',
      () async {
    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);
    await store.append(
      taskId: 'task-watch-issue',
      kind: WorkTaskEventKind.stepStarted,
      title: '开始读取',
    );
    await store.eventFileFor('task-watch-issue').writeAsString(
          '{"sequence":2',
          mode: FileMode.append,
        );

    await expectLater(
      store.watch('task-watch-issue'),
      emitsInOrder(<Object>[
        isA<WorkTaskEvent>(),
        emitsError(isA<StateError>()),
      ]),
    );
  });

  test('bounds and redacts persisted public details and metadata', () async {
    final store = WorkTaskEventStore(
      appSupportDirectory: appSupportDirectory,
      maxDetailCharacters: 48,
      maxTitleCharacters: 24,
      maxMetadataStringCharacters: 32,
    );
    const secret = 'sk-live-secret-token-123456789';

    final event = await store.append(
      taskId: 'task-safe',
      kind: WorkTaskEventKind.toolOutput,
      title: '很长的标题' * 20,
      detail: 'Authorization: Bearer $secret ${'输出内容' * 30}',
      safeMetadata: {
        'token': secret,
        'nested': {'authorization': 'Bearer $secret'},
      },
    );
    final persisted = await store.eventFileFor('task-safe').readAsString();

    expect(event.title.length, lessThanOrEqualTo(24));
    expect(event.detail.length, lessThanOrEqualTo(48));
    expect(event.detail, contains('[REDACTED]'));
    expect(event.safeMetadata['token'], '[REDACTED]');
    expect(persisted, isNot(contains(secret)));
    expect(persisted, contains('[REDACTED]'));
  });

  test('re-sanitizes legacy persisted events before exposing them', () async {
    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);
    final file = store.eventFileFor('task-legacy');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode({
            'taskId': 'task-legacy',
            'sequence': 1,
            'timestamp': DateTime.utc(2026, 8, 30).toIso8601String(),
            'kind': WorkTaskEventKind.toolOutput.name,
            'title': '读取 /Users/alice/project.md',
            'detail': '输出 /tmp/private.txt',
            'safeMetadata': {
              'path': '/Users/alice/project.md',
              'token': 'sk-legacy-secret',
            },
          })}\n',
    );

    final replay = await store.read('task-legacy');

    expect(replay.events, hasLength(1));
    final event = replay.events.single;
    expect(event.title, contains('[本地路径]'));
    expect(event.detail, contains('[本地路径]'));
    expect(event.safeMetadata['path'], '[本地路径]');
    expect(event.safeMetadata['token'], '[REDACTED]');
    expect(event.toJson().toString(), isNot(contains('sk-legacy-secret')));
  });

  test('closing the store completes idle watchers and is idempotent', () async {
    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);
    final watchFuture = store.watch('task-close').toList();

    final firstClose = store.close();
    final secondClose = store.close();
    expect(identical(firstClose, secondClose), isTrue);
    await firstClose;
    expect(await watchFuture, isEmpty);
  });

  test('clearAll removes only app events and leaves a project untouched',
      () async {
    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);
    await store.append(
      taskId: 'task-clear',
      kind: WorkTaskEventKind.queued,
      title: '待清理',
    );
    final project = Directory('${appSupportDirectory.path}-project')
      ..createSync();
    final projectFile = File('${project.path}/important.txt')
      ..writeAsStringSync('keep');
    addTearDown(() async {
      if (await project.exists()) await project.delete(recursive: true);
    });

    final removed = await store.clearAll();

    expect(removed, greaterThan(0));
    expect(await store.eventFileFor('task-clear').exists(), isFalse);
    expect(await projectFile.readAsString(), 'keep');
    final next = await store.append(
      taskId: 'task-after-clear',
      kind: WorkTaskEventKind.completed,
      title: '清理后仍可用',
    );
    expect(next.sequence, 1);
  });

  test('data-clear suspension rejects late appends and resumes explicitly',
      () async {
    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);

    store.suspendAppendsForDataClear();
    expect(
      store.append(
        taskId: 'task-suspended',
        kind: WorkTaskEventKind.toolOutput,
        title: '不应在清理期间写入',
      ),
      throwsA(isA<StateError>()),
    );

    store.resumeAppendsAfterDataClear();
    final event = await store.append(
      taskId: 'task-suspended',
      kind: WorkTaskEventKind.completed,
      title: '清理后可写入',
    );
    expect(event.sequence, 1);
  });

  test('clearAll removes a symlink root without following its target',
      () async {
    final root =
        Directory('${appSupportDirectory.path}/work_mode_agent/events');
    final project = Directory('${appSupportDirectory.path}-linked-project')
      ..createSync();
    final projectFile = File('${project.path}/important.txt')
      ..writeAsStringSync('keep');
    addTearDown(() async {
      if (await project.exists()) await project.delete(recursive: true);
    });
    await root.parent.create(recursive: true);
    final link = Link(root.path);
    await link.create(project.path);

    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);
    await store.clearAll();

    expect(await link.exists(), isFalse);
    expect(await projectFile.readAsString(), 'keep');
  }, skip: Platform.isWindows ? 'symlink privileges vary on Windows' : null);

  test('read and append reject a symlinked event file', () async {
    final target = File('${appSupportDirectory.path}-event-target.jsonl')
      ..writeAsStringSync('{"outside":true}\n');
    final events = Directory(
      '${appSupportDirectory.path}/work_mode_agent/events',
    );
    await events.create(recursive: true);
    final link = Link('${events.path}/task-link.jsonl');
    await link.create(target.path);
    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);

    await expectLater(
      store.read('task-link'),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      store.append(
        taskId: 'task-link',
        kind: WorkTaskEventKind.queued,
        title: '不应写入链接目标',
      ),
      throwsA(isA<StateError>()),
    );
    expect(await target.readAsString(), '{"outside":true}\n');
  }, skip: Platform.isWindows ? 'symlink privileges vary on Windows' : null);

  test('clearAll fails closed when the app-managed parent is a symlink',
      () async {
    final target = Directory('${appSupportDirectory.path}-parent-target')
      ..createSync();
    final targetFile = File('${target.path}/keep.jsonl')
      ..writeAsStringSync('keep');
    final parent = Directory(
      '${appSupportDirectory.path}/work_mode_agent',
    );
    await parent.parent.create(recursive: true);
    final link = Link(parent.path);
    await link.create(target.path);

    final store = WorkTaskEventStore(appSupportDirectory: appSupportDirectory);
    await expectLater(store.clearAll(), throwsA(isA<StateError>()));
    expect(await targetFile.readAsString(), 'keep');
    expect(await link.exists(), isTrue);
  }, skip: Platform.isWindows ? 'symlink privileges vary on Windows' : null);
}
