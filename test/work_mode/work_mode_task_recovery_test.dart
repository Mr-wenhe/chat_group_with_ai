import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/backup/backup_entity_codec.dart';
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

  test('new work tasks persist the V1 execution defaults and queue order', () {
    final inputQueue = <String>['先分析', '再修改'];
    final artifactPaths = <String>['/workspace/report.md'];
    final task = AgentTask(
      groupId: 'group',
      characterId: 'worker',
      userRequest: '完成文档',
      workModeTask: true,
      queuedUserRequests: inputQueue,
      assignedCharacterIds: const ['product', 'developer'],
      lastArtifactPaths: artifactPaths,
    );
    inputQueue.add('不应共享');
    artifactPaths.add('/workspace/other.md');

    expect(task.actionLimit, AgentTask.defaultActionLimit);
    expect(task.softTimeLimit, AgentTask.defaultSoftTimeLimit);
    expect(task.queuedUserRequests, ['先分析', '再修改']);
    expect(task.assignedCharacterIds, ['product', 'developer']);
    expect(task.lastArtifactPaths, ['/workspace/report.md']);
    expect(task.contextSummary, isEmpty);
    expect(task.executionStateJson, isEmpty);
    expect(task.startedAt, isNull);
    expect(task.actionCount, 0);
    expect(task.softLimitReached, isFalse);
    expect(task.resumeRequired, isFalse);
  });

  test('queued paused and interrupted work tasks have distinct resume state',
      () {
    final queued = AgentTask(
      groupId: 'group',
      characterId: 'worker',
      userRequest: '排队中',
      workModeTask: true,
      status: AgentTaskStatus.queued,
    );
    final paused = AgentTask(
      groupId: 'group',
      characterId: 'worker',
      userRequest: '已暂停',
      workModeTask: true,
      status: AgentTaskStatus.paused,
    );
    final interrupted = AgentTask(
      groupId: 'group',
      characterId: 'worker',
      userRequest: '进程已中断',
      workModeTask: true,
      status: AgentTaskStatus.interrupted,
      resumeRequired: true,
    );

    expect(queued.isTerminal, isFalse);
    expect(paused.isTerminal, isFalse);
    expect(interrupted.isTerminal, isFalse);
    expect(interrupted.requiresUserResume, isTrue);
    expect(interrupted.canResumeInWorkMode, isTrue);
  });

  test('backup round trip keeps resumable V1 task metadata', () {
    final original = AgentTask(
      id: 'task-v1',
      groupId: 'group',
      characterId: 'worker',
      userRequest: '恢复工作',
      workModeTask: true,
      status: AgentTaskStatus.interrupted,
      queuedUserRequests: const ['继续', '生成总结'],
      contextSummary: '已完成读取',
      assignedCharacterIds: const ['product', 'developer'],
      startedAt: DateTime.utc(2026, 8, 27, 10),
      actionCount: 8,
      softLimitReached: true,
      resumeRequired: true,
      executionStateJson: '{"phase":"paused"}',
      lastArtifactPaths: const ['/workspace/summary.md'],
    );

    final restored = BackupEntityCodec.decodeTask(
      BackupEntityCodec.task(original),
    );

    expect(restored.status, AgentTaskStatus.interrupted);
    expect(restored.queuedUserRequests, original.queuedUserRequests);
    expect(restored.contextSummary, original.contextSummary);
    expect(restored.assignedCharacterIds, original.assignedCharacterIds);
    expect(restored.startedAt, original.startedAt);
    expect(restored.actionCount, original.actionCount);
    expect(restored.softLimitReached, isTrue);
    expect(restored.resumeRequired, isTrue);
    expect(restored.executionStateJson, original.executionStateJson);
    expect(restored.lastArtifactPaths, original.lastArtifactPaths);
    expect(restored.actionLimit, AgentTask.defaultActionLimit);
    expect(restored.softTimeLimit, AgentTask.defaultSoftTimeLimit);
  });
}
