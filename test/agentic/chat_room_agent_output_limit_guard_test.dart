import 'package:chat_group/core/models/agent_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('work tasks use the documented 100-action and 60-minute soft limits',
      () {
    final task = AgentTask(
      groupId: 'group',
      characterId: 'worker',
      userRequest: '生成报告',
      workModeTask: true,
    );

    expect(task.actionLimit, 100);
    expect(task.softTimeLimit, const Duration(minutes: 60));
  });

  test('progress checkpoints switch between running and approval states', () {
    final task = AgentTask(
      groupId: 'group',
      characterId: 'worker',
      userRequest: '修改文件',
      workModeTask: true,
    );

    task.markProgress(step: 1, operations: const ['read']);
    expect(task.status, AgentTaskStatus.runningTool);
    expect(task.currentStep, 1);
    expect(task.resumeRequired, isFalse);

    task.markProgress(
      step: 1,
      operations: const ['read'],
      pendingToolJson: '{"tool":"workspace.patch"}',
    );
    expect(task.status, AgentTaskStatus.waitingForApproval);
    expect(task.pendingToolRequestJson, contains('workspace.patch'));
  });
}
