import 'dart:async';
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
}
