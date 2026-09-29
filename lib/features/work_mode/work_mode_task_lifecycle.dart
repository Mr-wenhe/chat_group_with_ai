import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';

/// 任务取消和临时进度消息生命周期的单一规则来源。
class WorkModeTaskLifecycle {
  const WorkModeTaskLifecycle._();

  /// 进度气泡消息 id 的前缀。判断"这条是不是工作模式进度"一律用它，
  /// 不要在各处重写字面量——已有 4 处调用方依赖这个约定。
  static const String progressMessageIdPrefix = 'agent-progress:';

  static String progressMessageId(AgentTask task) =>
      '$progressMessageIdPrefix${task.id}';

  /// 消息 id 是否指向一条工作模式进度气泡。
  static bool isProgressMessageId(String messageId) =>
      messageId.startsWith(progressMessageIdPrefix);

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
