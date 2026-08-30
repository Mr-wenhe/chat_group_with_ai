import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_approval_decision.dart';
import 'package:chat_group/features/work_mode/work_snapshot_manifest.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory appSupport;
  late WorkspacePathPolicy pathPolicy;
  late WorkSnapshotService snapshots;
  late DateTime now;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('work-snapshot-');
    root = await Directory('${sandbox.path}/work').create();
    appSupport = Directory('${sandbox.path}/app-support');
    pathPolicy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: false,
    );
    now = DateTime.utc(2026, 8, 28, 12);
    snapshots = WorkSnapshotService(
      appSupportDirectory: appSupport,
      pathPolicy: pathPolicy,
      clock: () => now,
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  WorkChangePlan planFor(
    String taskId,
    WorkChangeActionType action,
    List<String> paths, {
    bool snapshotAvailable = true,
    bool reversible = true,
  }) {
    return WorkChangePlan(
      taskId: taskId,
      actionType: action,
      exactPaths: paths,
      knownAffectedDirectories: [root.path],
      estimatedBytes: 1024,
      snapshotAvailable: snapshotAvailable,
      reversible: reversible,
      riskReason: 'Task 11 snapshot test',
    );
  }

  WorkApprovalScope approvalFor(WorkChangePlan plan) =>
      WorkApprovalScope.fromPlan(plan);

  WorkspaceMutationService mutation() => WorkspaceMutationService(
        pathPolicy: pathPolicy,
        snapshotPort: snapshots,
      );

  test('backs up an overwritten file and restores its hash on undo', () async {
    final file = await File('${root.path}/note.txt').writeAsString('before');
    final oldHash = sha256.convert(await file.readAsBytes()).toString();
    final plan =
        planFor('overwrite-task', WorkChangeActionType.modify, [file.path]);

    final result = await mutation().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request:
          WorkspaceMutationRequest.text(path: file.path, contents: 'after'),
    );

    expect(result.succeeded, isTrue);
    expect(
      await snapshots.manifestFileFor(plan.taskId).exists(),
      isTrue,
    );
    final manifest = await snapshots.readManifest(plan.taskId);
    expect(manifest, isNotNull);
    expect(manifest!.actions.single.sequence, 1);
    expect(manifest.actions.single.originalPath,
        (await pathPolicy.resolveExisting(file.path)).path);
    expect(manifest.actions.single.targetPath, isNull);
    expect(manifest.actions.single.mtime, isNotNull);
    expect(manifest.actions.single.size, 6);
    expect(manifest.actions.single.sha256, oldHash);
    expect(manifest.actions.single.backupRelativePath, isNotNull);
    expect(manifest.actions.single.completed, isTrue);
    expect(jsonEncode(manifest.toJson()), isNot(contains('apiKey')));

    final undo = await snapshots.undo(plan.taskId);
    expect(undo.succeeded, isTrue);
    expect(sha256.convert(await file.readAsBytes()).toString(), oldHash);
  });

  test('backs up a deleted file and restores it on undo', () async {
    final file = await File('${root.path}/remove.txt').writeAsString('keep me');
    final plan =
        planFor('delete-task', WorkChangeActionType.delete, [file.path]);

    final result = await mutation().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.delete(path: file.path),
    );

    expect(result.succeeded, isTrue);
    expect(await file.exists(), isFalse);
    final undo = await snapshots.undo(plan.taskId);
    expect(undo.succeeded, isTrue);
    expect(await file.readAsString(), 'keep me');
  });

  test('records a new file and deletes it on undo', () async {
    final file = File('${root.path}/new.txt');
    final plan =
        planFor('create-task', WorkChangeActionType.create, [file.path]);

    final result = await mutation().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.text(path: file.path, contents: 'new'),
    );

    expect(result.succeeded, isTrue);
    final action = (await snapshots.readManifest(plan.taskId))!.actions.single;
    expect(action.existedBefore, isFalse);
    expect(action.backupRelativePath, isNull);
    expect(action.sha256, isNull);
    expect(action.postMtime, isNotNull);
    expect(action.postSize, 3);
    expect(action.postSha256, isNotNull);
    final undo = await snapshots.undo(plan.taskId);
    expect(undo.succeeded, isTrue);
    expect(await file.exists(), isFalse);
  });

  test('reverses a rename without overwriting an existing target', () async {
    final source =
        await File('${root.path}/source.txt').writeAsString('source');
    final destination = File('${root.path}/renamed.txt');
    final plan = planFor(
      'rename-task',
      WorkChangeActionType.rename,
      [source.path, destination.path],
    );

    final result = await mutation().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.rename(
        sourcePath: source.path,
        destinationPath: destination.path,
      ),
    );

    expect(result.succeeded, isTrue);
    expect(await source.exists(), isFalse);
    expect(await destination.readAsString(), 'source');
    final action = (await snapshots.readManifest(plan.taskId))!.actions.single;
    expect(action.targetPath,
        (await pathPolicy.resolveNewTarget(destination.path)).path);
    expect(action.postSha256, isNotNull);

    final undo = await snapshots.undo(plan.taskId);
    expect(undo.succeeded, isTrue);
    expect(await source.readAsString(), 'source');
    expect(await destination.exists(), isFalse);
  });

  test('undoes multiple actions in reverse sequence', () async {
    final file = await File('${root.path}/multi.txt').writeAsString('one');
    const taskId = 'multi-task';
    final first = planFor(taskId, WorkChangeActionType.modify, [file.path]);
    final second = planFor(taskId, WorkChangeActionType.modify, [file.path]);

    expect(
      (await mutation().execute(
        plan: first,
        approvalScope: approvalFor(first),
        request:
            WorkspaceMutationRequest.text(path: file.path, contents: 'two'),
      ))
          .succeeded,
      isTrue,
    );
    expect(
      (await mutation().execute(
        plan: second,
        approvalScope: approvalFor(second),
        request:
            WorkspaceMutationRequest.text(path: file.path, contents: 'three'),
      ))
          .succeeded,
      isTrue,
    );

    final manifest = await snapshots.readManifest(taskId);
    expect(manifest!.actions.map((item) => item.sequence), [1, 2]);
    final undo = await snapshots.undo(taskId);
    expect(undo.succeeded, isTrue);
    expect(await file.readAsString(), 'one');
  });

  test('reports external modification as a conflict and preserves it',
      () async {
    final file =
        await File('${root.path}/conflict.txt').writeAsString('before');
    final plan =
        planFor('conflict-task', WorkChangeActionType.modify, [file.path]);
    expect(
      (await mutation().execute(
        plan: plan,
        approvalScope: approvalFor(plan),
        request:
            WorkspaceMutationRequest.text(path: file.path, contents: 'agent'),
      ))
          .succeeded,
      isTrue,
    );
    await file.writeAsString('external');

    final undo = await snapshots.undo(plan.taskId);
    expect(undo.status, WorkSnapshotUndoStatus.conflict);
    expect(undo.conflicts.single.path,
        (await pathPolicy.resolveExisting(file.path)).path);
    expect(await file.readAsString(), 'external');
  });

  test('rejects a tampered backup before it can overwrite the current file',
      () async {
    final file =
        await File('${root.path}/tampered.txt').writeAsString('before');
    final plan =
        planFor('tampered-task', WorkChangeActionType.modify, [file.path]);
    expect(
      (await mutation().execute(
        plan: plan,
        approvalScope: approvalFor(plan),
        request:
            WorkspaceMutationRequest.text(path: file.path, contents: 'agent'),
      ))
          .succeeded,
      isTrue,
    );
    final action = (await snapshots.readManifest(plan.taskId))!.actions.single;
    final backup = File(
      '${snapshots.snapshotDirectoryFor(plan.taskId).path}/${action.backupRelativePath}',
    );
    await backup.writeAsString('tampered backup');

    final undo = await snapshots.undo(plan.taskId);
    expect(undo.status, WorkSnapshotUndoStatus.conflict);
    expect(undo.conflicts.single.reason, contains('哈希校验失败'));
    expect(await file.readAsString(), 'agent');
  });

  test('refuses undo while the task is active', () async {
    final file = await File('${root.path}/active.txt').writeAsString('before');
    final plan =
        planFor('active-undo-task', WorkChangeActionType.modify, [file.path]);
    expect(
      (await mutation().execute(
        plan: plan,
        approvalScope: approvalFor(plan),
        request:
            WorkspaceMutationRequest.text(path: file.path, contents: 'agent'),
      ))
          .succeeded,
      isTrue,
    );
    final guarded = WorkSnapshotService(
      appSupportDirectory: appSupport,
      pathPolicy: pathPolicy,
      taskActivityResolver: (_) async => true,
    );

    final undo = await guarded.undo(plan.taskId);
    expect(undo.status, WorkSnapshotUndoStatus.unavailable);
    expect(undo.reason, contains('仍在执行'));
    expect(await file.readAsString(), 'agent');
  });

  test('reports a corrupt manifest instead of treating it as empty', () async {
    final directory = snapshots.snapshotDirectoryFor('corrupt-task');
    await directory.create(recursive: true);
    await snapshots.manifestFileFor('corrupt-task').writeAsString('{broken');

    expect(
      () => snapshots.previewUndo('corrupt-task'),
      throwsA(isA<StateError>()),
    );
    expect(
      () => snapshots.previewUndoSync('corrupt-task'),
      throwsA(isA<StateError>()),
    );
    final undo = await snapshots.undo('corrupt-task');
    expect(undo.status, WorkSnapshotUndoStatus.unavailable);
    expect(undo.reason, contains('损坏'));
  });

  test('reports corrupt manifests during retention cleanup and preserves them',
      () async {
    final directory = snapshots.snapshotDirectoryFor('cleanup-corrupt');
    await directory.create(recursive: true);
    await snapshots.manifestFileFor('cleanup-corrupt').writeAsString('{broken');

    final result = await snapshots.cleanup();

    expect(result.corruptedTaskIds, contains('cleanup-corrupt'));
    expect(await directory.exists(), isTrue);
    expect(await snapshots.manifestFileFor('cleanup-corrupt').exists(), isTrue);
  });

  test('restores a deleted file on a Windows-style policy', () async {
    final windowsPolicy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: true,
    );
    final windowsSnapshots = WorkSnapshotService(
      appSupportDirectory: appSupport,
      pathPolicy: windowsPolicy,
    );
    final windowsMutation = WorkspaceMutationService(
      pathPolicy: windowsPolicy,
      snapshotPort: windowsSnapshots,
    );
    final file =
        await File('${root.path}/windows-delete.txt').writeAsString('keep');
    final plan = planFor(
      'windows-delete-task',
      WorkChangeActionType.delete,
      [file.path],
    );
    expect(
      (await windowsMutation.execute(
        plan: plan,
        approvalScope: approvalFor(plan),
        request: WorkspaceMutationRequest.delete(path: file.path),
      ))
          .succeeded,
      isTrue,
    );
    expect(await file.exists(), isFalse);
    final undo = await windowsSnapshots.undo(plan.taskId);
    expect(undo.succeeded, isTrue);
    expect(await file.readAsString(), 'keep');
  });

  test('enforces the snapshot size limit before mutating', () async {
    final limited = WorkSnapshotService(
      appSupportDirectory: appSupport,
      pathPolicy: pathPolicy,
      snapshotLimitBytes: 2,
    );
    final limitedMutation = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: limited,
    );
    final file = await File('${root.path}/too-large.txt').writeAsString('123');
    final plan =
        planFor('quota-task', WorkChangeActionType.modify, [file.path]);
    final result = await limitedMutation.execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.text(path: file.path, contents: '456'),
    );
    expect(result.status, WorkspaceMutationStatus.snapshotUnavailable);
    expect(await file.readAsString(), '123');
  });

  test('rechecks authorization before undo and leaves content untouched',
      () async {
    final file =
        await File('${root.path}/authorization.txt').writeAsString('before');
    final plan = planFor(
      'authorization-task',
      WorkChangeActionType.modify,
      [file.path],
    );
    expect(
      (await mutation().execute(
        plan: plan,
        approvalScope: approvalFor(plan),
        request:
            WorkspaceMutationRequest.text(path: file.path, contents: 'agent'),
      ))
          .succeeded,
      isTrue,
    );

    final undo = await snapshots.undo(
      plan.taskId,
      authorization: WorkspacePathPolicy(
        authorizedRoots: const [],
        isWindows: false,
      ),
    );
    expect(undo.status, WorkSnapshotUndoStatus.unavailable);
    expect(await file.readAsString(), 'agent');
  });

  test('snapshot failure returns snapshotUnavailable and does not mutate',
      () async {
    final file = File('${root.path}/blocked.txt');
    final failing = _FailingSnapshotPort();
    final service = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: failing,
    );
    final plan =
        planFor('blocked-task', WorkChangeActionType.create, [file.path]);

    final result = await service.execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request:
          WorkspaceMutationRequest.text(path: file.path, contents: 'blocked'),
    );

    expect(result.status, WorkspaceMutationStatus.snapshotUnavailable);
    expect(await file.exists(), isFalse);
  });

  test('ordinary write settings cannot bypass explicit no-undo confirmation',
      () async {
    final file = File('${root.path}/no-undo.txt');
    final plan = planFor(
      'no-undo-task',
      WorkChangeActionType.create,
      [file.path],
      snapshotAvailable: false,
      reversible: false,
    );

    final blocked = await mutation().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request:
          WorkspaceMutationRequest.text(path: file.path, contents: 'safe?'),
    );
    expect(blocked.status, WorkspaceMutationStatus.snapshotUnavailable);
    expect(await file.exists(), isFalse);

    final legacyFlag = await mutation().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      allowWithoutUndo: true,
      request:
          WorkspaceMutationRequest.text(path: file.path, contents: 'unsafe'),
    );
    expect(legacyFlag.status, WorkspaceMutationStatus.notApproved);
    expect(await file.exists(), isFalse);

    final confirmed = await mutation().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      approvalDecision: WorkChangeApprovalDecision.approvedWithoutUndo,
      request:
          WorkspaceMutationRequest.text(path: file.path, contents: 'confirmed'),
    );
    expect(confirmed.succeeded, isTrue);
    expect(await file.readAsString(), 'confirmed');
  });

  test('cleans expired terminal snapshots before oldest terminal size eviction',
      () async {
    final sizes = <String, int>{};
    final baseNow = now;
    snapshots = WorkSnapshotService(
      appSupportDirectory: appSupport,
      pathPolicy: pathPolicy,
      clock: () => now,
      snapshotSizeResolver: (directory) async => sizes[directory.path] ?? 0,
    );

    Future<void> createSnapshot(String taskId, DateTime createdAt) async {
      now = createdAt;
      final file = await File('${root.path}/$taskId.txt').writeAsString(taskId);
      final plan = planFor(taskId, WorkChangeActionType.modify, [file.path]);
      expect(
        (await mutation().execute(
          plan: plan,
          approvalScope: approvalFor(plan),
          request: WorkspaceMutationRequest.text(
              path: file.path, contents: 'changed'),
        ))
            .succeeded,
        isTrue,
      );
      await snapshots.markTaskStatus(taskId, WorkSnapshotTaskStatus.completed);
      sizes[snapshots.snapshotDirectoryFor(taskId).path] = taskId == 'expired'
          ? 100
          : taskId == 'old-terminal'
              ? 100
              : 50;
    }

    await createSnapshot('expired', baseNow.subtract(const Duration(days: 31)));
    await createSnapshot(
        'old-terminal', baseNow.subtract(const Duration(days: 2)));
    await createSnapshot(
        'new-terminal', baseNow.subtract(const Duration(days: 1)));
    now = baseNow;
    final activeFile =
        await File('${root.path}/active.txt').writeAsString('active');
    final activePlan =
        planFor('active-task', WorkChangeActionType.modify, [activeFile.path]);
    expect(
      (await mutation().execute(
        plan: activePlan,
        approvalScope: approvalFor(activePlan),
        request: WorkspaceMutationRequest.text(
            path: activeFile.path, contents: 'active2'),
      ))
          .succeeded,
      isTrue,
    );
    sizes[snapshots.snapshotDirectoryFor('active-task').path] =
        10 * 1024 * 1024 * 1024;

    final cleaned = await snapshots.cleanup(
      retentionDays: 30,
      snapshotLimitBytes: 120,
      isTaskActive: (taskId) => taskId == 'active-task',
    );
    expect(cleaned.expiredTaskIds, contains('expired'));
    expect(cleaned.sizeEvictedTaskIds, contains('old-terminal'));
    expect(await snapshots.snapshotDirectoryFor('expired').exists(), isFalse);
    expect(
        await snapshots.snapshotDirectoryFor('old-terminal').exists(), isFalse);
    expect(
        await snapshots.snapshotDirectoryFor('new-terminal').exists(), isTrue);
    expect(
        await snapshots.snapshotDirectoryFor('active-task').exists(), isTrue);
  });
}

class _FailingSnapshotPort implements WorkspaceMutationSnapshotPort {
  @override
  Future<WorkspaceSnapshotReservation> reserve({
    required WorkChangePlan plan,
    required List<String> paths,
  }) {
    return Future<WorkspaceSnapshotReservation>.error(StateError('disk full'));
  }
}
