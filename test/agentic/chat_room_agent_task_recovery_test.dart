import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTask _task(AgentTaskStatus status) => AgentTask(
      id: 'recovery-task-${status.name}',
      groupId: 'group',
      characterId: 'worker',
      userRequest: '继续工作',
      workModeTask: true,
      status: status,
      pendingToolRequestJson: '{"tool":"workspace.read"}',
      lastError: '旧错误',
    );

void main() {
  test('cancelTask clears only resumable state and sanitizes the reason', () {
    final task = _task(AgentTaskStatus.waitingForApproval);

    WorkModeTaskLifecycle.cancelTask(
      task,
      reason: 'https://secret.example/token?key=abc',
    );

    expect(task.status, AgentTaskStatus.cancelled);
    expect(task.pendingToolRequestJson, isEmpty);
    expect(task.lastError, isNot(contains('https://')));
    expect(task.lastError, isNot(contains('abc')));
  });

  test('terminal task progress is retained instead of being removed', () {
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.cancelled),
      isTrue,
    );
    for (final status in <AgentTaskStatus>[
      AgentTaskStatus.completed,
      AgentTaskStatus.failed,
      AgentTaskStatus.partiallyCompleted,
    ]) {
      expect(WorkModeTaskLifecycle.shouldRemoveProgress(status), isFalse);
    }
  });

  test('markInterrupted never revives a terminal or paused task', () {
    final completed = _task(AgentTaskStatus.completed);
    final paused = _task(AgentTaskStatus.paused);

    completed.markInterrupted(reason: '进程关闭');
    paused.markInterrupted(reason: '进程关闭');

    expect(completed.status, AgentTaskStatus.completed);
    expect(paused.status, AgentTaskStatus.paused);
  });
}
