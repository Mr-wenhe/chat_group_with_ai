import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:hive/hive.dart';
import 'work_discussion_state.dart';

/// Preserves historical work and marks only DM work as manually interrupted.
/// Group recovery and explicit v1 conversion belong to the coordinator.
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

    // Schema bookkeeping is not permission to erase user work. Both old
    // artifacts and unknown checkpoints must survive the v2 transition.
    await appSettingsBox.put(schemaVersionKey, currentSchemaVersion);
  }

  /// DM keeps its legacy manual restart boundary. Groups retain their durable
  /// phase for coordinator revalidation; terminal tasks stay unchanged.
  Future<void> markInFlightWorkTasksInterrupted() async {
    final inFlightTasks = taskBox.values
        .where(
          (task) =>
              task.workModeTask &&
              !task.isTerminal &&
              !WorkDiscussionState.requiresDiscussionForConversation(
                  task.groupId) &&
              task.status != AgentTaskStatus.paused,
        )
        .toList(growable: false);
    for (final task in inFlightTasks) {
      task.markInterrupted(reason: interruptedByRestartReason);
      await taskBox.put(task.id, task);
    }
  }
}
