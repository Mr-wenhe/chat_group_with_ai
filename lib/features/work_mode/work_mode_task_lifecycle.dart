import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';

/// 任务取消和临时进度消息生命周期的单一规则来源。
class WorkModeTaskLifecycle {
  const WorkModeTaskLifecycle._();

  static String progressMessageId(AgentTask task) =>
      'agent-progress:${task.id}';

  /// 仅当用户取消（[AgentTaskStatus.cancelled]）时删除进度气泡。
  ///
  /// 其余终态（completed / failed / partiallyCompleted）保留气泡，
  /// 由调用方刷新为「已完成摘要」（末行 ⏳→✅、去光标）。
  static bool shouldRemoveProgress(AgentTaskStatus status) =>
      status == AgentTaskStatus.cancelled;

  static void cancelTask(AgentTask task, {required String reason}) {
    task
      ..status = AgentTaskStatus.cancelled
      ..pendingToolRequestJson = ''
      ..lastError = sanitizeWorkTaskError(reason)
      ..updatedAt = DateTime.now();
  }
}
