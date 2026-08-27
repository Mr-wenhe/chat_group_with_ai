import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/features/work_mode/work_mode_v1_migrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory directory;
  late Box<AgentTask> taskBox;
  late Box<WorkModeWorkspace> workspaceBox;
  late Box<dynamic> settingsBox;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('work-mode-v1-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(12)) {
      Hive.registerAdapter(AgentTaskStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(13)) {
      Hive.registerAdapter(AgentTaskAdapter());
    }
    if (!Hive.isAdapterRegistered(16)) {
      Hive.registerAdapter(WorkModeWorkspaceAdapter());
    }
    taskBox = await Hive.openBox<AgentTask>(DatabaseService.agentTaskBoxName);
    workspaceBox = await Hive.openBox<WorkModeWorkspace>(
      DatabaseService.workModeWorkspaceBoxName,
    );
    settingsBox = await Hive.openBox<dynamic>('app_settings');
  });

  tearDown(() async {
    await Hive.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  WorkModeV1Migrator createMigrator() => WorkModeV1Migrator(
        taskBox: taskBox,
        workspaceBox: workspaceBox,
        appSettingsBox: settingsBox,
      );

  test('first migration removes only legacy work tasks and workspaces',
      () async {
    final legacyWorkTask = AgentTask(
      id: 'legacy-work',
      groupId: 'group-1',
      characterId: 'worker',
      userRequest: '旧工作模式任务',
      workModeTask: true,
    );
    final normalTask = AgentTask(
      id: 'normal-agentic',
      groupId: 'group-1',
      characterId: 'worker',
      userRequest: '普通 agentic 任务',
    );
    await taskBox.putAll({
      legacyWorkTask.id: legacyWorkTask,
      normalTask.id: normalTask,
    });
    await workspaceBox.put(
      'group-1',
      WorkModeWorkspace(
        conversationId: 'group-1',
        conversationType: 'group',
        workDirPath: '/legacy/workspace',
      ),
    );
    await settingsBox.put('unrelated_setting', 'keep-me');

    await createMigrator().migrate();

    expect(taskBox.containsKey(legacyWorkTask.id), isFalse);
    expect(taskBox.get(normalTask.id)?.userRequest, normalTask.userRequest);
    expect(workspaceBox, isEmpty);
    expect(settingsBox.get('unrelated_setting'), 'keep-me');
    expect(
      settingsBox.get(WorkModeV1Migrator.schemaVersionKey),
      WorkModeV1Migrator.currentSchemaVersion,
    );
  });

  test('completed migration is idempotent and preserves V1 work tasks',
      () async {
    final migrator = createMigrator();
    await migrator.migrate();
    final v1Task = AgentTask(
      id: 'v1-work',
      groupId: 'group-1',
      characterId: 'worker',
      userRequest: '新的工作模式任务',
      workModeTask: true,
    );
    await taskBox.put(v1Task.id, v1Task);
    await workspaceBox.put(
      'new-workspace',
      WorkModeWorkspace(
        conversationId: 'group-1',
        conversationType: 'group',
      ),
    );

    await migrator.migrate();

    expect(taskBox.get(v1Task.id)?.id, v1Task.id);
    expect(workspaceBox.containsKey('new-workspace'), isTrue);
  });

  test('startup interruption requires the user to explicitly continue',
      () async {
    await createMigrator().migrate();
    final runningTask = AgentTask(
      id: 'running-v1-work',
      groupId: 'group-1',
      characterId: 'worker',
      userRequest: '正在执行',
      workModeTask: true,
      status: AgentTaskStatus.runningTool,
    );
    final pausedTask = AgentTask(
      id: 'paused-v1-work',
      groupId: 'group-1',
      characterId: 'worker',
      userRequest: '等待用户输入',
      workModeTask: true,
      status: AgentTaskStatus.paused,
    );
    final completedTask = AgentTask(
      id: 'completed-v1-work',
      groupId: 'group-1',
      characterId: 'worker',
      userRequest: '已完成',
      workModeTask: true,
      status: AgentTaskStatus.completed,
    );
    await taskBox.putAll({
      runningTask.id: runningTask,
      pausedTask.id: pausedTask,
      completedTask.id: completedTask,
    });

    await createMigrator().markInFlightWorkTasksInterrupted();

    final restored = taskBox.get(runningTask.id)!;
    expect(restored.status, AgentTaskStatus.interrupted);
    expect(restored.resumeRequired, isTrue);
    expect(restored.requiresUserResume, isTrue);
    expect(restored.canResumeInWorkMode, isTrue);
    expect(taskBox.get(pausedTask.id)?.status, AgentTaskStatus.paused);
    expect(taskBox.get(completedTask.id)?.status, AgentTaskStatus.completed);
  });

  test('V1 task state survives a Hive reopen', () async {
    final task = AgentTask(
      id: 'persisted-v1-work',
      groupId: 'group-1',
      characterId: 'worker',
      userRequest: '恢复我',
      workModeTask: true,
      status: AgentTaskStatus.interrupted,
      queuedUserRequests: const ['继续检查', '再写摘要'],
      contextSummary: '已读取两个文件',
      assignedCharacterIds: const ['product', 'developer'],
      startedAt: DateTime.utc(2026, 8, 27, 12),
      actionCount: 7,
      softLimitReached: true,
      resumeRequired: true,
      executionStateJson: '{"phase":"awaiting_user"}',
      lastArtifactPaths: const ['/workspace/report.md'],
      actionLimit: 100,
      softTimeLimitMinutes: 60,
    );
    await taskBox.put(task.id, task);

    await taskBox.close();
    taskBox = await Hive.openBox<AgentTask>(DatabaseService.agentTaskBoxName);

    final restored = taskBox.get(task.id)!;
    expect(restored.status, AgentTaskStatus.interrupted);
    expect(restored.queuedUserRequests, task.queuedUserRequests);
    expect(restored.contextSummary, task.contextSummary);
    expect(restored.assignedCharacterIds, task.assignedCharacterIds);
    expect(restored.startedAt, task.startedAt);
    expect(restored.actionCount, 7);
    expect(restored.softLimitReached, isTrue);
    expect(restored.resumeRequired, isTrue);
    expect(restored.executionStateJson, task.executionStateJson);
    expect(restored.lastArtifactPaths, task.lastArtifactPaths);
    expect(restored.actionLimit, 100);
    expect(restored.softTimeLimit, const Duration(minutes: 60));
  });
}
