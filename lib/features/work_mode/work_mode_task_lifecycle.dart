import 'package:chat_group/core/models/agent_task.dart';

enum WorkModeApprovalAction { approve, reject, cancelPending }

/// 待审批输入分类、任务取消和临时进度消息生命周期的单一规则来源。
class WorkModeTaskLifecycle {
  const WorkModeTaskLifecycle._();

  static WorkModeApprovalAction actionForDialogDecision(bool? decision) {
    if (decision == true) return WorkModeApprovalAction.approve;
    if (decision == false) return WorkModeApprovalAction.reject;
    return WorkModeApprovalAction.cancelPending;
  }

  static WorkModeApprovalAction actionForInput(String input) {
    final normalized = input.trim().toLowerCase();
    if ({'批准', '同意', '执行', '继续', 'approve', 'yes'}.contains(normalized)) {
      return WorkModeApprovalAction.approve;
    }
    if ({'取消', '拒绝', '不要', 'cancel', 'no'}.contains(normalized)) {
      return WorkModeApprovalAction.reject;
    }
    return WorkModeApprovalAction.cancelPending;
  }

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
      ..lastError = reason
      ..updatedAt = DateTime.now();
  }
}
