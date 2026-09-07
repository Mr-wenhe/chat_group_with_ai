import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/stage02_workspace_file_tool.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_approval_decision.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_approval_fingerprint.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory appSupport;
  late WorkspacePathPolicy pathPolicy;
  late WorkSnapshotService snapshots;
  late WorkspaceFileService files;
  late WorkspaceMutationService mutations;
  late WorkResourceLockManager resourceLocks;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('stage02-tool-');
    root = await Directory('${sandbox.path}/workspace').create();
    appSupport = Directory('${sandbox.path}/app-support');
    pathPolicy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: false,
    );
    resourceLocks = WorkResourceLockManager(isWindows: false);
    snapshots = WorkSnapshotService(
      appSupportDirectory: appSupport,
      pathPolicy: pathPolicy,
    );
    files = WorkspaceFileService(pathPolicy: pathPolicy);
    mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
      resourceLockManager: resourceLocks,
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  AgentTask task(String id) => AgentTask(
        id: id,
        groupId: 'group-stage02',
        characterId: 'character-stage02',
        userRequest: '写入工作区文件',
        workModeTask: true,
      );

  Stage02WorkspaceFileTool toolFor(
    AgentTask task, {
    void Function(String path, String operation)? onSensitiveRead,
    bool allowWithoutUndo = false,
    WorkChangeApprovalDecision? approvalDecision,
    String? approvedSensitiveOperation,
  }) {
    return Stage02WorkspaceFileTool(
      files: files,
      mutations: mutations,
      pathPolicy: pathPolicy,
      task: task,
      workspaceRoot: root.path,
      // The helper is a direct adapter fixture with an explicit authorized
      // root. Production tasks always provide a durable approval scope.
      allowImplicitScope: true,
      approvalDecision: approvalDecision,
      approvedSensitiveOperation: approvedSensitiveOperation,
      approvalCapability: approvedSensitiveOperation == null
          ? null
          : WorkApprovalCapability.sensitiveRead,
      onSensitiveRead: onSensitiveRead,
      allowWithoutUndo: allowWithoutUndo,
      resourceLockManager: resourceLocks,
    );
  }

  test('routes list/read/write through Stage02 services and supports undo',
      () async {
    final current = task('stage02-write');
    final tool = toolFor(current);

    final before = await tool.list();
    expect(before['ok'], isTrue);
    expect(before['entries'], isEmpty);

    final written = await tool.write('notes.txt', 'hello Stage02');
    expect(written['ok'], isTrue);
    expect(
        await File('${root.path}/notes.txt').readAsString(), 'hello Stage02');

    final read = await tool.read('notes.txt');
    expect(read['content'], 'hello Stage02');
    expect(read['sensitive'], isFalse);

    final manifest = await snapshots.readManifest(current.id);
    expect(manifest?.actions.single.completed, isTrue);
    final undo = await snapshots.undo(current.id);
    expect(undo.succeeded, isTrue);
    expect(await File('${root.path}/notes.txt').exists(), isFalse);
  });

  test('redacts sensitive content and emits a model-boundary audit callback',
      () async {
    final current = task('stage02-secret');
    final events = <String>[];
    final tool = toolFor(
      current,
      onSensitiveRead: (path, operation) => events.add('$path:$operation'),
    );
    final sensitiveFile = await File('${root.path}/.env')
        .writeAsString('TOKEN=super-secret-value');

    final read = await tool.read('.env');
    expect(read['sensitive'], isTrue);
    expect(read['redacted'], isTrue);
    expect(read['content'], isNot(contains('super-secret-value')));
    expect(read['content'], contains('敏感文件内容已隐藏'));
    expect(events, hasLength(1));
    expect(events.single, endsWith(':readTextRange'));

    final blockedMutation = await tool.write(
      sensitiveFile.path,
      'TOKEN=another-secret-value',
    );
    expect(blockedMutation['ok'], isFalse);
    expect(blockedMutation['requiresApproval'], isTrue);
    expect(await sensitiveFile.readAsString(), 'TOKEN=super-secret-value');
  });

  test('keeps a sensitive symlink alias behind the same read and write gates',
      () async {
    final target = await File('${root.path}/config.txt')
        .writeAsString('TOKEN=link-secret');
    final alias = Link('${root.path}/.env.local');
    await alias.create(target.path);
    final current = task('stage02-sensitive-alias');
    final tool = toolFor(current);

    final blockedRead = await tool.read(alias.path);
    expect(blockedRead['ok'], isFalse);
    expect(blockedRead['requiresApproval'], isTrue);
    expect(blockedRead['content'], isNot(contains('link-secret')));

    final blockedWrite = await tool.write(alias.path, 'TOKEN=changed');
    expect(blockedWrite['ok'], isFalse);
    expect(blockedWrite['requiresApproval'], isTrue);
    expect(await target.readAsString(), 'TOKEN=link-secret');
  });

  test('marks an approved sensitive alias mutation so no attachment is made',
      () async {
    final target =
        await File('${root.path}/config.txt').writeAsString('before');
    final alias = Link('${root.path}/.env.local');
    await alias.create(target.path);
    final current = task('stage02-approved-sensitive-alias');
    final plan = WorkChangePlan(
      taskId: current.id,
      actionType: WorkChangeActionType.modify,
      exactPaths: [target.resolveSymbolicLinksSync()],
      knownAffectedDirectories: [root.resolveSymbolicLinksSync()],
      estimatedBytes: 7,
      snapshotAvailable: true,
      reversible: true,
      riskReason: 'sensitive alias fixture',
    );
    final tool = Stage02WorkspaceFileTool(
      files: files,
      mutations: mutations,
      pathPolicy: pathPolicy,
      task: current,
      workspaceRoot: root.path,
      allowImplicitScope: true,
      approvalDecision: WorkChangeApprovalDecision.approved,
      approvalScope: WorkApprovalScope.fromPlan(plan),
    );

    final result = await tool.write(alias.path, 'changed');
    expect(result['ok'], isTrue);
    expect(result['sensitive'], isTrue);
    expect(result['redacted'], isTrue);
    expect(await target.readAsString(), 'changed');
  });

  test('does not hash a sensitive file when the approval scope misses it',
      () async {
    final current = task('stage02-sensitive-scope-mismatch');
    final sensitiveFile =
        await File('${root.path}/.env').writeAsString('TOKEN=scope-secret');
    final unrelatedPlan = WorkChangePlan(
      taskId: current.id,
      actionType: WorkChangeActionType.modify,
      exactPaths: ['${root.path}/other.txt'],
      knownAffectedDirectories: [root.path],
      estimatedBytes: 4,
      snapshotAvailable: true,
      reversible: true,
      riskReason: 'scope mismatch fixture',
    );
    final tool = Stage02WorkspaceFileTool(
      files: files,
      mutations: mutations,
      pathPolicy: pathPolicy,
      task: current,
      workspaceRoot: root.path,
      approvalDecision: WorkChangeApprovalDecision.approved,
      approvalScope: WorkApprovalScope.fromPlan(unrelatedPlan),
    );

    final result = await tool.write(sensitiveFile.path, 'TOKEN=changed');

    expect(result['ok'], isFalse);
    expect(result['error'], 'sensitive_mutation_requires_approval');
    expect(result['requiresApproval'], isTrue);
    expect(result['redacted'], isTrue);
    expect(await sensitiveFile.readAsString(), 'TOKEN=scope-secret');
  });

  test('skips sensitive files during directory search and gates direct access',
      () async {
    final current = task('stage02-sensitive-search');
    await File('${root.path}/.env').writeAsString('TOKEN=search-secret');
    final tool = toolFor(current);

    final directorySearch = await tool.search(root.path, 'TOKEN');
    expect(directorySearch['ok'], isTrue);
    expect(directorySearch['matches'], isEmpty);

    final attemptedBypass = await tool.search(
      root.path,
      'TOKEN',
      allowSensitive: true,
    );
    expect(attemptedBypass['ok'], isTrue);
    expect(attemptedBypass['matches'], isEmpty);

    final blocked = await tool.search('${root.path}/.env', 'TOKEN');
    expect(blocked['ok'], isFalse);
    expect(blocked['requiresApproval'], isTrue);
    expect(blocked['redacted'], isTrue);
    expect(blocked['matches'], isNull);

    final approvedTool = toolFor(
      current,
      approvalDecision: WorkChangeApprovalDecision.approved,
    );
    // A mutation approval alone cannot reveal a sensitive file. The caller
    // must approve this exact file + query operation.
    final exactOperation = approvedTool.sensitiveReadFingerprint(
      operation: 'search',
      path: '${root.path}/.env',
      query: 'TOKEN',
    );
    final exactTool = toolFor(
      current,
      approvalDecision: WorkChangeApprovalDecision.approved,
      approvedSensitiveOperation: exactOperation,
    );
    final approved = await exactTool.search(
      '${root.path}/.env',
      'TOKEN',
      allowSensitive: true,
    );
    expect(approved['ok'], isTrue);
    expect(approved['matches'], isNotEmpty);
    expect(approved['matches'].single['snippet'], contains('search-secret'));
  });

  test('does not treat a mutation capability as a sensitive-read grant',
      () async {
    final current = task('stage02-capability-isolation');
    await File('${root.path}/.env').writeAsString('TOKEN=isolated');
    final exactOperation = toolFor(current).sensitiveReadFingerprint(
      operation: 'readTextRange',
      path: '${root.path}/.env',
    );
    final tool = Stage02WorkspaceFileTool(
      files: files,
      mutations: mutations,
      pathPolicy: pathPolicy,
      task: current,
      workspaceRoot: root.path,
      allowImplicitScope: true,
      approvalDecision: WorkChangeApprovalDecision.approved,
      approvalCapability: WorkApprovalCapability.mutation,
      approvedSensitiveOperation: exactOperation,
      resourceLockManager: resourceLocks,
    );

    final result = await tool.readWithOptions('.env', allowSensitive: true);
    expect(result['requiresApproval'], isTrue);
    expect(result['redacted'], isTrue);
    expect(result['content'], isNot(contains('isolated')));
  });

  test('ordinary-write setting can apply a narrow patch without a prompt',
      () async {
    final current = task('stage02-implicit-patch');
    final file = await File('${root.path}/patch.txt').writeAsString('before');
    final original = await file.readAsBytes();
    final tool = toolFor(current);

    final result = await tool.applyPatch(
      jsonEncode({
        'path': 'patch.txt',
        'expectedSha256': sha256.convert(original).toString(),
        'expectedFragment': 'before',
        'replacement': 'after',
      }),
    );

    expect(result['ok'], isTrue);
    expect(await file.readAsString(), 'after');
  });

  test('rechecks rename and delete postconditions before reporting success',
      () async {
    final current = task('stage02-postconditions');
    final source = await File('${root.path}/before.txt').writeAsString('body');
    final tool = toolFor(current);

    final renamed = await tool.rename(source.path, '${root.path}/after.txt');
    expect(renamed['ok'], isTrue);
    expect(renamed['validation']['valid'], isTrue);
    expect(renamed['validation']['message'], contains('重命名'));
    expect(await source.exists(), isFalse);
    expect(await File('${root.path}/after.txt').readAsString(), 'body');

    final deleted = await tool.delete('${root.path}/after.txt');
    expect(deleted['ok'], isTrue);
    expect(deleted['validation']['valid'], isTrue);
    expect(deleted['validation']['message'], contains('不存在'));
    expect(await File('${root.path}/after.txt').exists(), isFalse);
  });

  test('does not serialize a read behind an unrelated subtree write lock',
      () async {
    final current = task('stage02-narrow-lock');
    final file = await File('${root.path}/narrow.txt').writeAsString('before');
    final tool = toolFor(current);
    final unrelatedSubtreeLease = await resourceLocks.acquire(
      'unrelated-task',
      [WorkResourceLockRequest.treeWrite('${root.path}/other')],
    );

    var completed = false;
    final pending = tool.read(file.path).then((result) {
      completed = true;
      return result;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(resourceLocks.waitingOwnerIds, isEmpty);

    await unrelatedSubtreeLease.release();
    final result = await pending;
    expect(completed, isTrue);
    expect(result['ok'], isTrue);
    expect(result['content'], 'before');
  });

  test('does not silently fall back to patch or command execution', () async {
    final tool = Stage02WorkspaceFileTool(
      files: files,
      mutations: mutations,
      pathPolicy: pathPolicy,
      task: task('stage02-unsupported'),
      workspaceRoot: root.path,
    );

    final patch = await tool.applyPatch('diff --git a/a b/a');
    expect(patch['ok'], isFalse);
    expect(patch['error'], 'stage02_patch_requires_plan');

    final command = await tool.runCommand('echo unsafe');
    expect(command['ok'], isFalse);
    expect(command['error'], 'command_not_available_in_stage02');
  });

  test('fails closed when a typed approval has no durable scope', () async {
    final current = task('stage02-missing-scope');
    final tool = Stage02WorkspaceFileTool(
      files: files,
      mutations: mutations,
      pathPolicy: pathPolicy,
      task: current,
      workspaceRoot: root.path,
      approvalDecision: WorkChangeApprovalDecision.approved,
    );

    final result = await tool.write('missing-scope.txt', 'must not write');

    expect(result['ok'], isFalse);
    expect(result['error'], WorkspaceMutationStatus.notApproved.name);
    expect(await File('${root.path}/missing-scope.txt').exists(), isFalse);
  });

  test('fails closed when a scope exists without a user decision', () async {
    final current = task('stage02-scope-without-decision');
    final plan = WorkChangePlan(
      taskId: current.id,
      actionType: WorkChangeActionType.create,
      exactPaths: ['${root.path}/missing-decision.txt'],
      knownAffectedDirectories: [root.path],
      estimatedBytes: 4,
      snapshotAvailable: true,
      reversible: true,
      riskReason: 'scope-only fixture',
    );
    final tool = Stage02WorkspaceFileTool(
      files: files,
      mutations: mutations,
      pathPolicy: pathPolicy,
      task: current,
      workspaceRoot: root.path,
      approvalScope: WorkApprovalScope.fromPlan(plan),
    );

    final result = await tool.write('missing-decision.txt', 'must not write');

    expect(result['ok'], isFalse);
    expect(result['error'], WorkspaceMutationStatus.notApproved.name);
    expect(await File('${root.path}/missing-decision.txt').exists(), isFalse);
  });
}
