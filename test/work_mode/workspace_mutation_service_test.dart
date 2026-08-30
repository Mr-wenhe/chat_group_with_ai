import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory outside;
  late WorkspacePathPolicy pathPolicy;
  late RecordingSnapshotPort snapshots;
  late WorkTaskEventStore eventStore;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('workspace-mutation-');
    root = await Directory('${sandbox.path}/work').create();
    outside = await Directory('${sandbox.path}/outside').create();
    pathPolicy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: false,
    );
    snapshots = RecordingSnapshotPort();
    eventStore = WorkTaskEventStore(
      appSupportDirectory: Directory('${sandbox.path}/app-support'),
    );
  });

  tearDown(() async {
    await eventStore.close();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  WorkChangePlan planFor(
    WorkChangeActionType action,
    List<String> paths, {
    bool snapshotAvailable = true,
    bool reversible = true,
  }) {
    return WorkChangePlan(
      taskId: 'task-10',
      actionType: action,
      exactPaths: paths,
      knownAffectedDirectories: [root.path],
      estimatedBytes: 1024,
      snapshotAvailable: snapshotAvailable,
      reversible: reversible,
      riskReason: 'Task 10 mutation test',
    );
  }

  WorkApprovalScope approvalFor(WorkChangePlan plan) =>
      WorkApprovalScope.fromPlan(plan);

  WorkspaceMutationService service({
    WorkspaceMutationFailureInjector? failureInjector,
    WorkspacePathPolicy? policy,
    WorkTaskEventStore? events,
  }) {
    return WorkspaceMutationService(
      pathPolicy: policy ?? pathPolicy,
      snapshotPort: snapshots,
      eventStore: events ?? eventStore,
      failureInjector: failureInjector,
    );
  }

  test('does not write when a plan is not approved', () async {
    final path = '${root.path}/new.txt';
    final plan = planFor(WorkChangeActionType.create, [path]);

    final result = await service().execute(
      plan: plan,
      request: WorkspaceMutationRequest.text(path: path, contents: 'secret'),
    );

    expect(result.status, WorkspaceMutationStatus.notApproved);
    expect(await File(path).exists(), isFalse);
    expect(snapshots.calls, 0);
    final events = await eventStore.read(plan.taskId);
    expect(events.events.single.kind, WorkTaskEventKind.failed);
    expect(events.events.single.detail, isNot(contains('secret')));
    expect(events.events.single.safeMetadata['path'], 'new.txt');
  });

  test('reserves the snapshot interface even for a new file', () async {
    final path = '${root.path}/new.txt';
    final plan = planFor(WorkChangeActionType.create, [path]);

    final result = await service().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.text(path: path, contents: 'created'),
    );

    expect(result.succeeded, isTrue);
    expect(await File(path).readAsString(), 'created');
    expect(snapshots.calls, 1);
  });

  test('flushes a same-directory temp file before atomic replacement',
      () async {
    final file = await File('${root.path}/note.txt').writeAsString('before');
    final plan = planFor(WorkChangeActionType.modify, [file.path]);
    var observedBeforeRename = false;

    final result = await service(
      failureInjector: (phase) {
        if (phase == WorkspaceMutationPhase.afterTempFlush) {
          observedBeforeRename = file.readAsStringSync() == 'before';
          final tempFiles = root.listSync().whereType<File>().where(
              (candidate) => candidate.path.contains('.codex-mutation-'));
          expect(tempFiles, isNotEmpty);
        }
      },
    ).execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.text(
        path: file.path,
        contents: 'after',
      ),
    );

    expect(result.succeeded, isTrue);
    expect(observedBeforeRename, isTrue);
    expect(await file.readAsString(), 'after');
    expect(
      root.listSync().whereType<File>().where(
            (candidate) => candidate.path.contains('.codex-mutation-'),
          ),
      isEmpty,
    );
    final events = await eventStore.read(plan.taskId);
    expect(events.events.single.kind, WorkTaskEventKind.stepCompleted);
    expect(events.events.single.detail, isNot(contains('after')));
  });

  test('surfaces completion bookkeeping failure instead of claiming success',
      () async {
    final file = File('${root.path}/completion-failure.txt');
    final completion = _CompletionFailureSnapshotPort();
    final mutationService = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: completion,
    );
    final plan = planFor(WorkChangeActionType.create, [file.path]);

    final result = await mutationService.execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.text(path: file.path, contents: 'x'),
    );

    expect(result.status, WorkspaceMutationStatus.failed);
    expect(result.reason, contains('撤销记录未完成'));
    expect(completion.abortCalls, 1);
    expect(await file.readAsString(), 'x');
  });

  test('keeps the original bytes when a failure happens before replace',
      () async {
    final file = await File('${root.path}/note.txt').writeAsString('before');
    final beforeHash = sha256.convert(await file.readAsBytes()).toString();
    final plan = planFor(WorkChangeActionType.modify, [file.path]);

    final result = await service(
      failureInjector: (phase) {
        if (phase == WorkspaceMutationPhase.beforeReplace) {
          throw StateError('injected failure');
        }
      },
    ).execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request:
          WorkspaceMutationRequest.text(path: file.path, contents: 'after'),
    );

    final afterHash = sha256.convert(await file.readAsBytes()).toString();
    expect(result.status, WorkspaceMutationStatus.failed);
    expect(afterHash, beforeHash);
    expect(
        root.listSync().whereType<File>().where(
              (candidate) => candidate.path.contains('.codex-mutation-'),
            ),
        isEmpty);
  });

  test('returns a conflict when patch SHA-256 is stale', () async {
    final file = await File('${root.path}/note.txt').writeAsString('current');
    final plan = planFor(WorkChangeActionType.patch, [file.path]);

    final result = await service().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.patch(
        path: file.path,
        expectedSha256: sha256.convert(utf8.encode('old')).toString(),
        expectedFragment: 'old',
        replacement: 'new',
      ),
    );

    expect(result.status, WorkspaceMutationStatus.conflict);
    expect(await file.readAsString(), 'current');
    expect(snapshots.calls, 0);
  });

  test('applies one exact UTF-8 patch and records a safe completion event',
      () async {
    final file = await File('${root.path}/note.txt').writeAsString(
      'header\nneedle\nfooter',
    );
    final original = await file.readAsBytes();
    final plan = planFor(WorkChangeActionType.patch, [file.path]);

    final result = await service().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.patch(
        path: file.path,
        expectedSha256: sha256.convert(original).toString(),
        expectedFragment: 'needle',
        replacement: 'updated',
      ),
    );

    expect(result.succeeded, isTrue);
    expect(await file.readAsString(), 'header\nupdated\nfooter');
    final events = await eventStore.read(plan.taskId);
    expect(events.events.single.kind, WorkTaskEventKind.stepCompleted);
    expect(events.events.single.detail, isNot(contains('updated')));
  });

  test('rejects an absent or ambiguous patch fragment without writing',
      () async {
    final file = await File('${root.path}/note.txt').writeAsString('same same');
    final before = await file.readAsBytes();
    final plan = planFor(WorkChangeActionType.patch, [file.path]);

    final result = await service().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.patch(
        path: file.path,
        expectedSha256: sha256.convert(before).toString(),
        expectedFragment: 'same',
        replacement: 'changed',
      ),
    );

    expect(result.status, WorkspaceMutationStatus.conflict);
    expect(await file.readAsBytes(), before);
  });

  test('rejects a patch without a strict 64-character SHA-256 precondition',
      () async {
    final file = await File('${root.path}/note.txt').writeAsString('same');
    final plan = planFor(WorkChangeActionType.patch, [file.path]);

    final result = await service().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.patch(
        path: file.path,
        expectedSha256: '',
        expectedFragment: 'same',
        replacement: 'changed',
      ),
    );

    expect(result.status, WorkspaceMutationStatus.invalidRequest);
    expect(await file.readAsString(), 'same');
    expect(snapshots.calls, 0);
  });

  test('detects content changed after temp flush before replacement', () async {
    final file = await File('${root.path}/note.txt').writeAsString('before');
    final before = await file.readAsBytes();
    final plan = planFor(WorkChangeActionType.modify, [file.path]);

    final result = await service(
      failureInjector: (phase) {
        if (phase == WorkspaceMutationPhase.afterTempFlush) {
          file.writeAsStringSync('external change');
        }
      },
    ).execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest(
        path: file.path,
        contents: 'agent change',
        expectedSha256: sha256.convert(before).toString(),
      ),
    );

    expect(result.status, WorkspaceMutationStatus.conflict);
    expect(await file.readAsString(), 'external change');
    expect(sha256.convert(await file.readAsBytes()).toString(),
        isNot(sha256.convert(utf8.encode('agent change')).toString()));
  });

  test('reclassifies an existing rename target as conflict', () async {
    final source =
        await File('${root.path}/source.txt').writeAsString('source');
    final destination =
        await File('${root.path}/destination.txt').writeAsString('keep');
    final plan = planFor(
      WorkChangeActionType.rename,
      [source.path, destination.path],
    );

    final result = await service().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.rename(
        sourcePath: source.path,
        destinationPath: destination.path,
      ),
    );

    expect(result.status, WorkspaceMutationStatus.conflict);
    expect(await source.readAsString(), 'source');
    expect(await destination.readAsString(), 'keep');
  });

  test('deletes only the exact file and never recursively deletes siblings',
      () async {
    final target = await File('${root.path}/remove.txt').writeAsString('x');
    final sibling = await File('${root.path}/keep.txt').writeAsString('y');
    final nested = await Directory('${root.path}/nested').create();
    final nestedFile =
        await File('${nested.path}/child.txt').writeAsString('z');
    final plan = planFor(WorkChangeActionType.delete, [target.path]);

    final result = await service().execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request: WorkspaceMutationRequest.delete(path: target.path),
    );

    expect(result.succeeded, isTrue);
    expect(await target.exists(), isFalse);
    expect(await sibling.exists(), isTrue);
    expect(await nestedFile.exists(), isTrue);
  });

  test('cancellation after flush leaves no half-written target or temp file',
      () async {
    final file = await File('${root.path}/note.txt').writeAsString('before');
    final plan = planFor(WorkChangeActionType.modify, [file.path]);
    final cancellation = WorkTaskCancellation();

    final result = await service(
      failureInjector: (phase) {
        if (phase == WorkspaceMutationPhase.afterTempFlush) {
          cancellation.cancel();
        }
      },
    ).execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      cancellation: cancellation,
      request:
          WorkspaceMutationRequest.text(path: file.path, contents: 'after'),
    );

    expect(result.status, WorkspaceMutationStatus.cancelled);
    expect(await file.readAsString(), 'before');
    expect(
        root.listSync().whereType<File>().where(
              (candidate) => candidate.path.contains('.codex-mutation-'),
            ),
        isEmpty);
  });

  test('rejects a symlink that changes after approval during revalidation',
      () async {
    final inside =
        await File('${root.path}/inside.txt').writeAsString('inside');
    final outsideFile =
        await File('${outside.path}/outside.txt').writeAsString('outside');
    final link = Link('${root.path}/linked.txt');
    await link.create(inside.path);
    final plan = planFor(WorkChangeActionType.modify, [link.path]);

    final result = await service(
      failureInjector: (phase) {
        if (phase == WorkspaceMutationPhase.afterSnapshot) {
          link.deleteSync();
          link.createSync(outsideFile.path);
        }
      },
    ).execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request:
          WorkspaceMutationRequest.text(path: link.path, contents: 'changed'),
    );

    expect(result.status, WorkspaceMutationStatus.pathRejected);
    expect(await inside.readAsString(), 'inside');
    expect(await outsideFile.readAsString(), 'outside');
  });

  test('requires a snapshot reservation for a Windows-style overwrite path',
      () async {
    final file = await File('${root.path}/note.txt').writeAsString('before');
    final windowsPolicy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: true,
    );
    snapshots.available = false;
    final plan = planFor(WorkChangeActionType.modify, [file.path]);

    final result = await service(policy: windowsPolicy).execute(
      plan: plan,
      approvalScope: approvalFor(plan),
      request:
          WorkspaceMutationRequest.text(path: file.path, contents: 'after'),
    );

    expect(result.status, WorkspaceMutationStatus.snapshotUnavailable);
    expect(await file.readAsString(), 'before');
  });
}

class RecordingSnapshotPort implements WorkspaceMutationSnapshotPort {
  int calls = 0;
  bool available = true;

  @override
  Future<WorkspaceSnapshotReservation> reserve({
    required WorkChangePlan plan,
    required List<String> paths,
  }) async {
    calls++;
    return WorkspaceSnapshotReservation(available: available);
  }
}

class _CompletionFailureSnapshotPort
    implements
        WorkspaceMutationSnapshotPort,
        WorkspaceMutationSnapshotCompletionPort,
        WorkspaceMutationSnapshotAbortPort {
  int abortCalls = 0;

  @override
  Future<WorkspaceSnapshotReservation> reserve({
    required WorkChangePlan plan,
    required List<String> paths,
  }) async =>
      const WorkspaceSnapshotReservation(available: true, reservationId: 'x');

  @override
  Future<void> complete({
    required WorkspaceSnapshotReservation reservation,
    required WorkChangePlan plan,
    required List<String> paths,
    required WorkspaceMutationResult result,
  }) async {
    throw StateError('manifest write failed');
  }

  @override
  Future<void> abort({
    required WorkspaceSnapshotReservation reservation,
    required WorkChangePlan plan,
    required List<String> paths,
    required WorkspaceMutationResult result,
  }) async {
    abortCalls++;
  }
}
