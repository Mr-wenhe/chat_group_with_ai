import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _IdleRunner implements WorkTaskRunner {
  var runCount = 0;

  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {
    runCount += 1;
  }
}

Future<void> _settle() async {
  for (var index = 0; index < 8; index++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitForTaskStatus(
  Box<AgentTask> taskBox,
  String taskId,
  AgentTaskStatus expected,
) async {
  for (var index = 0; index < 100; index++) {
    if (taskBox.get(taskId)?.status == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitForTaskEvent(
  WorkTaskEventStore eventStore,
  String taskId,
  WorkTaskEventKind expected,
) async {
  for (var index = 0; index < 100; index++) {
    final result = await eventStore.read(taskId);
    if (result.events.any((e) => e.kind == expected)) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('事件 $expected 在限定时间内未出现：$taskId');
}

void main() {
  late Directory hiveDirectory;
  late Box<dynamic> settingsBox;

  setUp(() async {
    hiveDirectory = await Directory.systemTemp.createTemp('folder-grants-');
    Hive.init(hiveDirectory.path);
    await Hive.openBox<dynamic>('app_settings');
    settingsBox = Hive.box<dynamic>('app_settings');
  });

  tearDown(() async {
    await Hive.close();
    if (await hiveDirectory.exists()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  test('deduplicates normalized roots and lets a parent cover its child',
      () async {
    final root = await Directory('${hiveDirectory.path}/project').create();
    final child = await Directory('${root.path}/nested').create();
    final service = WorkFolderGrantService(box: settingsBox, isWindows: false);

    await service.addDirectory('${child.path}/../nested');
    await service.addDirectory(root.path);
    await service.addDirectory('${root.path}/./nested');

    expect(service.grants, hasLength(1));
    expect(service.grants.single.path, Directory(root.path).absolute.path);
    expect(service.isPathAuthorized('${child.path}/report.md'), isTrue);
  });

  test('removal takes effect immediately without deleting the directory',
      () async {
    final root = await Directory('${hiveDirectory.path}/project').create();
    final service = WorkFolderGrantService(box: settingsBox, isWindows: false);

    await service.addDirectory(root.path);
    expect(service.isPathAuthorized('${root.path}/note.md'), isTrue);

    await service.removeDirectory(root.path);

    expect(service.grants, isEmpty);
    expect(service.isPathAuthorized('${root.path}/note.md'), isFalse);
    expect(await root.exists(), isTrue);
  });

  test('keeps a missing root record and marks it unavailable on validation',
      () async {
    final missing = '${hiveDirectory.path}/moved-away';
    final service = WorkFolderGrantService(box: settingsBox, isWindows: false);

    final grant = await service.addDirectory(missing);

    expect(grant.available, isFalse);
    expect(service.grants, hasLength(1));
    expect(service.isPathAuthorized('$missing/file.txt'), isFalse);
  });

  test(
      'normalizes Windows separators and compares drive paths case-insensitively',
      () {
    expect(
      WorkFolderGrantService.normalizePath(
        r'c:\Work\Project\..\Project',
        isWindows: true,
      ),
      'C:/Work/Project',
    );
  });

  test('uses path segments so a similarly-prefixed directory is not covered',
      () async {
    final root = await Directory('${hiveDirectory.path}/a').create();
    final service = WorkFolderGrantService(box: settingsBox, isWindows: false);

    await service.addDirectory(root.path);

    expect(
        service.isPathAuthorized('${hiveDirectory.path}/ab/file.txt'), isFalse);
  });

  test('persists grants and settings across a service restart', () async {
    final root = await Directory('${hiveDirectory.path}/project').create();
    final first = WorkFolderGrantService(box: settingsBox, isWindows: false);
    await first.addDirectory(root.path);
    await first.setOrdinaryWriteConfirmation(false);

    final restarted =
        WorkFolderGrantService(box: settingsBox, isWindows: false);
    await restarted.load();

    expect(restarted.grants.single.path, first.grants.single.path);
    expect(restarted.settings.ordinaryWriteConfirmation, isFalse);
    expect(settingsBox.get(WorkFolderGrantService.grantsStorageKey), isNotNull);
    expect(
        settingsBox.get(WorkFolderGrantService.settingsStorageKey), isNotNull);
  });

  test('folder consent is required before a newly selected root is persisted',
      () async {
    final root = await Directory('${hiveDirectory.path}/consent').create();
    final service = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
    );

    final denied = await service.requestFolder(
      picker: () async => root.path,
      consent: (_) async => false,
    );
    expect(denied.status, WorkFolderRequestStatus.cancelled);
    expect(service.grants, isEmpty);

    final granted = await service.requestFolder(
      picker: () async => root.path,
      consent: (_) async => true,
    );
    expect(granted.granted, isTrue);
    expect(service.grants.single.cloudDisclosureConfirmedAt, isNotNull);
  });

  test('authorizes several directories with one batch consent decision',
      () async {
    final first = await Directory('${hiveDirectory.path}/first').create();
    final second = await Directory('${hiveDirectory.path}/second').create();
    final service = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
    );
    var consentCalls = 0;
    List<WorkFolderGrant>? proposed;

    final granted = await service.authorizeDirectories(
      <String>[first.path, second.path, '${first.path}/.'],
      consent: (candidates) async {
        consentCalls += 1;
        proposed = candidates;
        return true;
      },
    );

    expect(consentCalls, 1);
    expect(proposed, hasLength(2));
    expect(granted, hasLength(2));
    expect(
      service.grants.map((grant) => grant.path),
      containsAll(<String>[first.path, second.path]),
    );
    expect(
      service.grants.every((grant) => grant.cloudDisclosureConfirmedAt != null),
      isTrue,
    );
  });

  test('legacy grants require disclosure before first work-mode use', () async {
    final root =
        await Directory('${hiveDirectory.path}/legacy-consent').create();
    final service = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
    );
    await service.addDirectory(root.path);

    final withoutCallback = await service.requestFolder(
      picker: () async =>
          fail('an existing grant should not reopen the picker'),
    );
    expect(withoutCallback.status, WorkFolderRequestStatus.unavailable);
    expect(service.grants.single.cloudDisclosureConfirmedAt, isNull);

    final confirmed = await service.requestFolder(
      picker: () async =>
          fail('an existing grant should not reopen the picker'),
      consent: (_) async => true,
    );
    expect(confirmed.granted, isTrue);
    expect(service.grants.single.cloudDisclosureConfirmedAt, isNotNull);
  });

  test('legacy grants stay outside the path policy until disclosure', () async {
    final root =
        await Directory('${hiveDirectory.path}/legacy-path-policy').create();
    final service = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
    );
    await service.addDirectory(root.path);
    final policy = WorkspacePathPolicy(grantService: service, isWindows: false);

    expect(
      await service.isPathAuthorizedResolved('${root.path}/note.md'),
      isFalse,
    );
    expect(
      () => policy.resolveExisting('${root.path}/note.md'),
      throwsA(isA<WorkspacePathException>()),
    );

    final confirmed = await service.requestFolder(
      picker: () async =>
          fail('an existing grant should not reopen the picker'),
      consent: (_) async => true,
    );
    expect(confirmed.granted, isTrue);
    expect(
      await service.isPathAuthorizedResolved('${root.path}/note.md'),
      isTrue,
    );
  });

  test('a read-only grant cannot satisfy a writable folder request', () async {
    final root = await Directory('${hiveDirectory.path}/read-only').create();
    final service = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => false,
    );

    final result = await service.requestFolder(
      picker: () async => root.path,
      requireWritable: true,
      consent: (_) async => true,
    );

    expect(result.granted, isFalse);
    expect(result.reason, contains('只读'));
    expect(service.grants, isEmpty);
  });

  test('a cancelled first folder request pauses the task with public events',
      () async {
    if (!Hive.isAdapterRegistered(12)) {
      Hive.registerAdapter(AgentTaskStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(13)) {
      Hive.registerAdapter(AgentTaskAdapter());
    }
    final taskBox =
        await Hive.openBox<AgentTask>(DatabaseService.agentTaskBoxName);
    final eventStore = WorkTaskEventStore(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
    );
    final service = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => false,
    );
    final runner = _IdleRunner();
    final coordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      folderGrantService: service,
      folderPicker: () async => null,
    );
    addTearDown(() async {
      await coordinator.dispose();
      await eventStore.close();
    });

    final task = AgentTask(
      id: 'folder-approval',
      groupId: 'group-a',
      characterId: 'worker',
      userRequest: '读取项目',
      workModeTask: true,
    );
    await coordinator.submit(task);
    await _waitForTaskStatus(taskBox, task.id, AgentTaskStatus.paused);

    expect(taskBox.get(task.id)?.status, AgentTaskStatus.paused);
    expect(taskBox.get(task.id)?.lastError, contains('目录'));
    expect(runner.runCount, 0);
    // Event persistence is an async file write that may lag on slow CI.
    // Poll until the paused event appears before asserting the event list.
    await _waitForTaskEvent(
      eventStore, task.id, WorkTaskEventKind.paused);
    final events = await eventStore.read(task.id);
    expect(
        events.events.map((event) => event.kind),
        containsAll(<WorkTaskEventKind>[
          WorkTaskEventKind.approvalRequired,
          WorkTaskEventKind.paused,
        ]));
    expect(
      events.events.every(
        (event) =>
            !event.title.contains(hiveDirectory.path) &&
            !event.detail.contains(hiveDirectory.path),
      ),
      isTrue,
    );
  });

  test('continues the first task after a picked folder is granted', () async {
    if (!Hive.isAdapterRegistered(12)) {
      Hive.registerAdapter(AgentTaskStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(13)) {
      Hive.registerAdapter(AgentTaskAdapter());
    }
    final taskBox =
        await Hive.openBox<AgentTask>(DatabaseService.agentTaskBoxName);
    final eventStore = WorkTaskEventStore(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
    );
    final root = await Directory('${hiveDirectory.path}/project').create();
    final service = WorkFolderGrantService(
      box: settingsBox,
      isWindows: false,
      directoryValidator: (_) async => true,
    );
    final runner = _IdleRunner();
    final coordinator = WorkTaskCoordinator(
      taskBox: taskBox,
      eventStore: eventStore,
      runner: runner,
      folderGrantService: service,
      folderPicker: () async => root.path,
      folderGrantConsent: (_) async => true,
    );
    addTearDown(() async {
      await coordinator.dispose();
      await eventStore.close();
    });

    final task = AgentTask(
      id: 'folder-granted',
      groupId: 'group-a',
      characterId: 'worker',
      userRequest: '读取项目',
      workModeTask: true,
    );
    await coordinator.submit(task);
    await _settle();

    expect(runner.runCount, 1);
    expect(taskBox.get(task.id)?.status, AgentTaskStatus.completed);
    expect(service.isPathAuthorized('${root.path}/report.md'), isTrue);
  });
}
