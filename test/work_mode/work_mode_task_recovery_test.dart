import 'package:chat_group/core/models/agent_task.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy agent tasks are not recoverable as work-mode tasks', () {
    final legacy = AgentTask(
      groupId: 'group',
      characterId: 'worker',
      userRequest: '旧任务',
    );
    final workMode = AgentTask(
      groupId: 'group',
      characterId: 'worker',
      userRequest: '工作任务',
      workModeTask: true,
    );

    expect(legacy.canResumeInWorkMode, isFalse);
    expect(workMode.canResumeInWorkMode, isTrue);
  });
}
