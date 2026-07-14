import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
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
}
