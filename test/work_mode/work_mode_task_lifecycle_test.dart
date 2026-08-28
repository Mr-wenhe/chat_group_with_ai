import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('explicit task cancellation clears its resumable checkpoint', () {
    final task = AgentTask(
      groupId: 'group',
      characterId: 'worker',
      userRequest: '生成报告',
      status: AgentTaskStatus.waitingForApproval,
      pendingToolRequestJson: '{"tool":"workspace.read"}',
      workModeTask: true,
    );

    WorkModeTaskLifecycle.cancelTask(task, reason: '用户明确停止任务');

    expect(task.status, AgentTaskStatus.cancelled);
    expect(task.pendingToolRequestJson, isEmpty);
    expect(task.lastError, '用户明确停止任务');
    expect(task.canResumeInWorkMode, isFalse);
  });

  test('only cancelled tasks remove their temporary progress message', () {
    // 终态（completed / failed / partiallyCompleted）保留气泡，
    // 由调用方刷新为「已完成摘要」；仅 cancelled 直接删除。
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.cancelled),
      isTrue,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.completed),
      isFalse,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.failed),
      isFalse,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(
        AgentTaskStatus.partiallyCompleted,
      ),
      isFalse,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(
        AgentTaskStatus.waitingForApproval,
      ),
      isFalse,
    );
  });
}
