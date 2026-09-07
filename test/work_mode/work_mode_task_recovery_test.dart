import 'dart:convert';

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

  test('terminal tasks cannot be revived by generic recovery or late progress',
      () {
    for (final status in <AgentTaskStatus>[
      AgentTaskStatus.completed,
      AgentTaskStatus.failed,
      AgentTaskStatus.partiallyCompleted,
      AgentTaskStatus.cancelled,
    ]) {
      final task = AgentTask(
        groupId: 'group',
        characterId: 'worker',
        userRequest: '终态任务',
        workModeTask: true,
        status: status,
      );

      expect(task.canResumeInWorkMode, isFalse, reason: status.name);
      expect(task.canResume, isFalse, reason: status.name);
      task.markProgress(step: 2, operations: const ['late']);
      expect(task.status, status, reason: status.name);
      expect(task.currentStep, 0, reason: status.name);
      expect(task.completedOperations, isEmpty, reason: status.name);
    }
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
    expect(restored.lastArtifactPaths, isEmpty);
    expect(restored.actionLimit, AgentTask.defaultActionLimit);
    expect(restored.softTimeLimit, AgentTask.defaultSoftTimeLimit);
  });

  test('backup import strips unsafe artifact paths from legacy payloads', () {
    final restored = BackupEntityCodec.decodeTask({
      'id': 'unsafe-task',
      'groupId': 'group',
      'characterId': 'worker',
      'userRequest': '恢复',
      'status': AgentTaskStatus.completed.name,
      'createdAt': DateTime.utc(2026, 8, 27).toIso8601String(),
      'lastArtifactPaths': [
        '/Users/alice/private/report.md',
        r'C:\Users\alice\private\result.txt',
        r'C:relative.txt',
        '../outside.txt',
        './dot.txt',
        'docs:external.txt',
        'docs/ok.md',
      ],
    });

    expect(restored.lastArtifactPaths, ['docs/ok.md']);
  });

  test('portable task backup drops capability state and local paths', () {
    final task = AgentTask(
      id: 'portable-boundary',
      groupId: 'group',
      characterId: 'worker',
      userRequest: '审查 /Users/alice/project',
      workModeTask: true,
      status: AgentTaskStatus.paused,
      executionStateJson: jsonEncode({
        'phase': 'paused',
        'approvalScope': {
          'paths': ['/Users/alice/project/private.txt'],
        },
        'resourceLocks': [
          {'path': '/Users/alice/project'},
        ],
        'lastToolResult': {
          'content': 'PRIVATE_FILE_BODY',
          'token': 'sk-live-secret-token',
        },
        'revisionTargetPath': '/Users/alice/project/private.txt',
      }),
      completedOperations: [
        jsonEncode({
          'tool': 'command.run',
          'reason': '执行 /Users/alice/project/private.sh',
          'args': {
            'workingDirectory': '/Users/alice/project',
            'declaredImpact': ['/Users/alice/project/private.txt'],
            'command': 'cat sk-live-secret-token',
            'content': 'PRIVATE_FILE_BODY',
          },
        }),
      ],
      pendingToolRequestJson: jsonEncode({
        'tool': 'workspace.patch',
        'reason': '写入 /Users/alice/project/private.txt',
        'args': {
          'path': '/Users/alice/project/private.txt',
          'content': 'PRIVATE_FILE_BODY',
        },
      }),
      contextSummary: jsonEncode({
        'conversationId': 'group',
        'target': '继续 /Users/alice/project',
        'approvalScope': {
          'paths': ['/Users/alice/project']
        },
        'artifactPaths': ['/Users/alice/project/report.md'],
        'recentToolResults': [
          {'content': 'PRIVATE_FILE_BODY'},
        ],
      }),
      lastArtifactPaths: const ['/Users/alice/project/report.md'],
    );

    final encoded = BackupEntityCodec.task(task);
    expect(encoded['executionStateJson'], '{"phase":"paused"}');
    expect(encoded['lastArtifactPaths'], isEmpty);
    expect(
      encoded['completedOperations'].toString(),
      isNot(contains('/Users/alice/project')),
    );
    expect(
      encoded['pendingToolRequestJson'].toString(),
      isNot(contains('/Users/alice/project')),
    );
    expect(encoded['contextSummary'].toString(), contains('继续'));
    expect(encoded.toString(), isNot(contains('PRIVATE_FILE_BODY')));
    expect(encoded.toString(), isNot(contains('sk-live-secret-token')));
    expect(encoded.toString(), isNot(contains('/Users/alice/project')));

    final restored = BackupEntityCodec.decodeTask(encoded);
    expect(restored.executionStateJson, '{"phase":"paused"}');
    expect(restored.lastArtifactPaths, isEmpty);
    expect(restored.completedOperations.single, contains('command.run'));
    expect(restored.pendingToolRequestJson, contains('workspace.patch'));
    expect(restored.pendingToolRequestJson, isNot(contains('private.txt')));
    expect(restored.contextSummary, isNot(contains('approvalScope')));
  });

  test('portable task backup redacts opaque legacy operation text', () {
    final encoded = BackupEntityCodec.task(
      AgentTask(
        id: 'opaque-operation',
        groupId: 'group',
        characterId: 'worker',
        userRequest: '恢复',
        workModeTask: true,
        completedOperations: const [
          '命令输出: PRIVATE_FILE_BODY /Users/alice/project sk-live-secret-token',
        ],
      ),
    );

    final serialized = jsonEncode(encoded);
    expect(serialized, isNot(contains('PRIVATE_FILE_BODY')));
    expect(serialized, isNot(contains('/Users/alice/project')));
    expect(serialized, isNot(contains('sk-live-secret-token')));
    expect(
      encoded['completedOperations'],
      ['{"kind":"legacyOperation","redacted":true}'],
    );
  });

  test('portable task backup redacts unsafe context keys as well as values',
      () {
    final encoded = BackupEntityCodec.task(
      AgentTask(
        id: 'unsafe-context-key',
        groupId: 'group',
        characterId: 'worker',
        userRequest: '恢复',
        workModeTask: true,
        contextSummary: jsonEncode({
          '/Users/alice/private.txt': 'safe metadata',
          'ordinaryField': '/Users/alice/private.txt',
        }),
      ),
    );

    final serialized = jsonEncode(encoded);
    expect(serialized, isNot(contains('/Users/alice/private.txt')));
    final context = jsonDecode(encoded['contextSummary'] as String) as Map;
    expect(context.keys, contains('[本地路径]'));
    expect(context['ordinaryField'], '[本地路径]');
  });
}
