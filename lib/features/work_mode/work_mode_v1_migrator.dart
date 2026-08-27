import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:hive/hive.dart';

/// Removes retired work-mode records once, then marks interrupted V1 work
/// tasks as requiring an explicit user resume after a new app process starts.
class WorkModeV1Migrator {
  static const String schemaVersionKey = 'work_mode_agent_schema_version';
  static const int currentSchemaVersion = 1;
  static const String interruptedByRestartReason = '应用已关闭，请由用户手动继续任务。';

  final Box<AgentTask> taskBox;
  final Box<WorkModeWorkspace> workspaceBox;
  final Box<dynamic> appSettingsBox;

  const WorkModeV1Migrator({
    required this.taskBox,
    required this.workspaceBox,
    required this.appSettingsBox,
  });

  Future<void> migrate() async {
    if (appSettingsBox.get(schemaVersionKey) == currentSchemaVersion) return;

    final retiredTaskIds = taskBox.values
        .where((task) => task.workModeTask)
        .map((task) => task.id)
        .toList(growable: false);
    if (retiredTaskIds.isNotEmpty) await taskBox.deleteAll(retiredTaskIds);
    if (workspaceBox.isNotEmpty) await workspaceBox.clear();
    await appSettingsBox.put(schemaVersionKey, currentSchemaVersion);
  }

  /// Running, planning, approval, and queued tasks cannot safely continue
  /// after a process restart. Paused tasks already await an explicit user
  /// action and terminal tasks must remain unchanged.
  Future<void> markInFlightWorkTasksInterrupted() async {
    final inFlightTasks = taskBox.values
        .where(
          (task) =>
              task.workModeTask &&
              !task.isTerminal &&
              task.status != AgentTaskStatus.paused,
        )
        .toList(growable: false);
    for (final task in inFlightTasks) {
      task.markInterrupted(reason: interruptedByRestartReason);
      await taskBox.put(task.id, task);
    }
  }
}
