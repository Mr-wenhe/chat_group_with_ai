import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dismissed approval cancels instead of leaving a pending task', () {
    expect(
      WorkModeTaskLifecycle.actionForDialogDecision(null),
      WorkModeApprovalAction.cancelPending,
    );
  });

  test('new input cancels the old approval before becoming a new task', () {
    expect(
      WorkModeTaskLifecycle.actionForInput('另外再生成一份 PDF'),
      WorkModeApprovalAction.cancelPending,
    );
    expect(
      WorkModeTaskLifecycle.actionForInput('批准'),
      WorkModeApprovalAction.approve,
    );
    expect(
      WorkModeTaskLifecycle.actionForInput('拒绝'),
      WorkModeApprovalAction.reject,
    );
  });

  test('cancelling a pending approval clears its resumable checkpoint', () {
    final task = AgentTask(
      groupId: 'group',
      characterId: 'worker',
      userRequest: '生成报告',
      status: AgentTaskStatus.waitingForApproval,
      pendingToolRequestJson: '{"tool":"workspace.read"}',
      workModeTask: true,
    );

    WorkModeTaskLifecycle.cancelTask(task, reason: '用户开始了新任务');

    expect(task.status, AgentTaskStatus.cancelled);
    expect(task.pendingToolRequestJson, isEmpty);
    expect(task.lastError, '用户开始了新任务');
    expect(task.canResumeInWorkMode, isFalse);
  });

  test('terminal tasks remove their temporary progress message', () {
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.completed),
      isTrue,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.failed),
      isTrue,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.cancelled),
      isTrue,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(
        AgentTaskStatus.partiallyCompleted,
      ),
      isTrue,
    );
  });
}
