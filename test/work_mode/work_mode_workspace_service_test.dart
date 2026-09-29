import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/features/work_mode/work_mode_directory_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  test('replaces a persisted workspace path outside the conversation scope',
      () async {
    final hiveDir = await Directory.systemTemp.createTemp('work-mode-hive-');
    final workspaceRoot =
        await Directory.systemTemp.createTemp('work-mode-root-');
    final outside = await Directory.systemTemp.createTemp('work-mode-outside-');
    addTearDown(() async {
      await Hive.close();
      for (final directory in [hiveDir, workspaceRoot, outside]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });

    Hive.init(hiveDir.path);
    if (!Hive.isAdapterRegistered(16)) {
      Hive.registerAdapter(WorkModeWorkspaceAdapter());
    }
    await Hive.openBox<dynamic>('app_settings');
    await Hive.openBox<WorkModeWorkspace>(
      DatabaseService.workModeWorkspaceBoxName,
    );
    final db = DatabaseService();
    await db.saveAiProcessingDirPath(workspaceRoot.path);
    await db.workModeWorkspaceBox.put(
      'group-1',
      WorkModeWorkspace(
        conversationId: 'group-1',
        conversationType: 'group',
        workDirPath: outside.path,
      ),
    );

    final workspace = await WorkModeWorkspaceService(db: db).loadOrCreate(
      conversationId: 'group-1',
      isDirectChat: false,
    );

    expect(workspace.workDirPath, isNot(outside.path));
    expect(
      workspace.workDirPath,
      '${workspaceRoot.path}/conversations/group_group-1',
    );
  });

  test('moves a persisted read-only workspace to a writable grant for writes',
      () async {
    final hiveDir = await Directory.systemTemp.createTemp('work-mode-hive-');
    final readRoot = await Directory.systemTemp.createTemp('work-mode-read-');
    final writeRoot = await Directory.systemTemp.createTemp('work-mode-write-');
    addTearDown(() async {
      await Hive.close();
      for (final directory in [hiveDir, readRoot, writeRoot]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });

    Hive.init(hiveDir.path);
    if (!Hive.isAdapterRegistered(16)) {
      Hive.registerAdapter(WorkModeWorkspaceAdapter());
    }
    await Hive.openBox<dynamic>('app_settings');
    await Hive.openBox<WorkModeWorkspace>(
      DatabaseService.workModeWorkspaceBoxName,
    );
    final db = DatabaseService();
    final grants = WorkFolderGrantService(
      box: db.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (path) async => path == writeRoot.path,
      isWindows: false,
    );
    await grants.authorizeDirectory(readRoot.path, consent: (_) async => true);
    final service = WorkModeWorkspaceService(db: db, grantService: grants);

    final inspection = await service.loadOrCreate(
      conversationId: 'group-read-only',
      isDirectChat: false,
    );
    expect(inspection.workDirPath, readRoot.path);

    await grants.authorizeDirectory(writeRoot.path, consent: (_) async => true);
    final writable = await service.loadOrCreate(
      conversationId: 'group-read-only',
      isDirectChat: false,
      requireWritable: true,
    );

    expect(writable.workDirPath, startsWith(writeRoot.path));
    expect(writable.workDirPath, isNot(readRoot.path));
  });

  test('explicit reauthorization clears a stale conversation workspace',
      () async {
    final hiveDir = await Directory.systemTemp.createTemp('work-mode-hive-');
    final oldRoot = await Directory.systemTemp.createTemp('work-mode-old-');
    final newRoot = await Directory.systemTemp.createTemp('work-mode-new-');
    addTearDown(() async {
      await Hive.close();
      for (final directory in [hiveDir, oldRoot, newRoot]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    });

    Hive.init(hiveDir.path);
    if (!Hive.isAdapterRegistered(16)) {
      Hive.registerAdapter(WorkModeWorkspaceAdapter());
    }
    await Hive.openBox<dynamic>('app_settings');
    await Hive.openBox<WorkModeWorkspace>(
      DatabaseService.workModeWorkspaceBoxName,
    );
    final db = DatabaseService();
    final grants = WorkFolderGrantService(
      box: db.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(oldRoot.path, consent: (_) async => true);
    await db.workModeWorkspaceBox.put(
      'group-rebind',
      WorkModeWorkspace(
        conversationId: 'group-rebind',
        conversationType: 'group',
        workDirPath: oldRoot.path,
      ),
    );
    final service = WorkModeWorkspaceService(db: db, grantService: grants);

    await grants.authorizeDirectory(newRoot.path, consent: (_) async => true);
    await service.rebindConversationWorkspace(
      conversationId: 'group-rebind',
      isDirectChat: false,
      grantedPath: newRoot.path,
    );
    final rebound = await service.loadOrCreate(
      conversationId: 'group-rebind',
      isDirectChat: false,
    );

    expect(rebound.workDirPath, newRoot.path);
  });

  test(
      'uses the explicitly requested desktop root instead of a conversation subdirectory',
      () async {
    final hiveDir = await Directory.systemTemp.createTemp('work-mode-hive-');
    final grantRoot = await Directory.systemTemp.createTemp('work-mode-root-');
    final desktop = await Directory('${grantRoot.path}/Desktop').create();
    addTearDown(() async {
      await Hive.close();
      if (await hiveDir.exists()) await hiveDir.delete(recursive: true);
      if (await grantRoot.exists()) await grantRoot.delete(recursive: true);
    });

    Hive.init(hiveDir.path);
    if (!Hive.isAdapterRegistered(16)) {
      Hive.registerAdapter(WorkModeWorkspaceAdapter());
    }
    await Hive.openBox<dynamic>('app_settings');
    await Hive.openBox<WorkModeWorkspace>(
      DatabaseService.workModeWorkspaceBoxName,
    );
    final db = DatabaseService();
    final grants = WorkFolderGrantService(
      box: db.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      grantRoot.path,
      consent: (_) async => true,
    );
    final service = WorkModeWorkspaceService(db: db, grantService: grants);

    final workspace = await service.loadOrCreate(
      conversationId: 'dm:desktop-task',
      isDirectChat: true,
      requireWritable: true,
      preferredRootPath: desktop.path,
    );

    expect(workspace.workDirPath, desktop.path);
    expect(
      await Directory('${desktop.path}/conversations').exists(),
      isFalse,
    );
  });

  test('reads a requested file path as its folder, never as a workspace root',
      () async {
    // 现场（taskId 6f1eefee…，2026-09-29）：修订澄清的答复把目标文件的绝对路径
    // 折进了请求文本，`requestedWorkspacePath` 把它当作工作区根，于是
    // `Directory.create` 对着一个文件执行，抛
    // `Creation failed … Not a directory, errno = 20`，任务在第一个工具调用之前
    // 就死了。文件所在目录才是工作区，也是这次修订本就该待的地方。
    final hiveDir = await Directory.systemTemp.createTemp('work-mode-hive-');
    final grantRoot = await Directory.systemTemp.createTemp('work-mode-root-');
    final project = await Directory('${grantRoot.path}/project').create();
    final target = File('${project.path}/AI聊天需求文档.docx');
    await target.writeAsString('需求');
    addTearDown(() async {
      await Hive.close();
      if (await hiveDir.exists()) await hiveDir.delete(recursive: true);
      if (await grantRoot.exists()) await grantRoot.delete(recursive: true);
    });

    Hive.init(hiveDir.path);
    if (!Hive.isAdapterRegistered(16)) {
      Hive.registerAdapter(WorkModeWorkspaceAdapter());
    }
    await Hive.openBox<dynamic>('app_settings');
    await Hive.openBox<WorkModeWorkspace>(
      DatabaseService.workModeWorkspaceBoxName,
    );
    final db = DatabaseService();
    final grants = WorkFolderGrantService(
      box: db.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      grantRoot.path,
      consent: (_) async => true,
    );
    final service = WorkModeWorkspaceService(db: db, grantService: grants);

    // The request that failed in production, verbatim: the revision-target
    // answer reaches the runner as an absolute path inside the request text.
    const directories = WorkModeDirectoryService();
    final requested = directories.requestedWorkspacePath(
      '再优化下这个文档，最好加点软件截图，文字增加到6K字\n'
      '用户明确目标：是的\n'
      '用户明确目标：是的\n'
      '用户明确目标：${target.path}',
    );
    expect(requested, target.path);

    final workspace = await service.loadOrCreate(
      conversationId: 'dm:revision',
      isDirectChat: true,
      requireWritable: true,
      preferredRootPath: requested,
    );

    expect(workspace.workDirPath, project.absolute.path);
    expect(await target.readAsString(), '需求');
  });
}
