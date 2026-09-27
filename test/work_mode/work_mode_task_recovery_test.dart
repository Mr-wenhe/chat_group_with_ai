import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/backup/backup_entity_codec.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
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

  test('portable backup keeps discussion progress but blocks local targets',
      () {
    final discussion = WorkDiscussionState(
      conversationId: 'group-portable',
      phase: WorkDiscussionPhase.ready,
      requestRevision: 3,
      coordinatorId: 'product',
      executorId: 'frontend',
      candidateCharacterIds: const ['frontend', 'tester'],
      participants: const [
        WorkDiscussionParticipant(
          characterId: 'frontend',
          status: 'accepted',
          contributionCount: 4,
          lastContribution: '已确认页面结构',
        ),
      ],
      round: 5,
      understandingPercent: 92,
      understandingEvidence: const ['开发已确认可实现'],
      deliverableContract: const {
        'deliverableType': 'document',
        'format': 'docx',
        'location': '/Users/alice/Desktop/需求.docx',
        'contentScope': '输出完整需求文档',
        'explicitExecutorId': 'frontend',
        'revisionTarget': '/Users/alice/Desktop/旧需求.docx',
        'requestRevision': 3,
      },
      decisionSummary: '保留开发与测试的取舍',
    );
    final task = AgentTask(
      id: 'portable-discussion',
      groupId: 'group-portable',
      characterId: 'frontend',
      userRequest: '恢复讨论',
      workModeTask: true,
      status: AgentTaskStatus.paused,
      executionStateJson: jsonEncode({
        'discussionState': discussion.toJson(),
        'workFailure': {
          'type': 'authorizationLost',
          'reason': '工作目录授权失效',
          'technicalDetail': '原路径 /Users/alice/Desktop 不可用',
          'retryable': false,
        },
        'folderGrantPending': true,
        'artifactDeliveryNoticePublished': true,
        'artifactDeliveryRetryOnly': true,
        'artifactDeliveryMessageId': 'message-from-old-device',
      }),
    );

    final encoded = BackupEntityCodec.task(task);
    final execution = jsonDecode(encoded['executionStateJson'] as String)
        as Map<String, dynamic>;
    final restored = BackupEntityCodec.decodeTask(encoded);
    final state = WorkDiscussionState.fromExecutionState(
      restored.executionStateJson,
    );

    expect(state, isNotNull);
    expect(state!.requestRevision, 3);
    expect(state.understandingPercent, 92);
    expect(state.executorId, 'frontend');
    expect(state.phase, WorkDiscussionPhase.blocked);
    expect(
      state.blockers,
      contains('backupWorkspaceReauthorizationRequired'),
    );
    expect(state.deliverableContract?['location'], 'unspecified');
    expect(state.deliverableContract?['revisionTarget'], isEmpty);
    expect(execution, contains('workFailure'));
    expect(execution['artifactDeliveryNoticePublished'], isTrue);
    expect(execution, isNot(contains('artifactDeliveryRetryOnly')));
    expect(execution, isNot(contains('artifactDeliveryMessageId')));
    expect(encoded.toString(), isNot(contains('/Users/alice/Desktop')));
  });

  test('unknown backup task status becomes an interrupted user-resume state',
      () {
    final restored = BackupEntityCodec.decodeTask({
      'id': 'future-status',
      'groupId': 'group',
      'characterId': 'worker',
      'userRequest': '恢复未知版本任务',
      'status': 'futureStatusFromNewerBuild',
      'createdAt': DateTime.utc(2026, 8, 27).toIso8601String(),
      'workModeTask': true,
      'executionStateJson': jsonEncode({
        'discussionState': <String, dynamic>{'schemaVersion': 99},
      }),
    });

    expect(restored.status, AgentTaskStatus.interrupted);
    expect(restored.resumeRequired, isTrue);
    expect(restored.canResumeInWorkMode, isTrue);
    expect(restored.executionStateJson, contains('discussionState'));
  });

  test('fractional backup counters fail closed instead of being truncated', () {
    final restored = BackupEntityCodec.decodeTask({
      'id': 'fractional-counters',
      'groupId': 'group',
      'characterId': 'worker',
      'userRequest': '恢复边界',
      'status': 'paused',
      'createdAt': DateTime.utc(2026, 8, 27).toIso8601String(),
      'workModeTask': true,
      'currentStep': 2.5,
      'actionCount': 3.5,
      'actionLimit': 4.5,
      'softTimeLimitMinutes': 5.5,
    });

    expect(restored.currentStep, 0);
    expect(restored.actionCount, 0);
    expect(restored.actionLimit, AgentTask.defaultActionLimit);
    expect(
      restored.softTimeLimitMinutes,
      AgentTask.defaultSoftTimeLimitMinutes,
    );
  });

  test('portable execution checkpoints canonicalize legacy key casing', () {
    final restored = BackupEntityCodec.decodeTask({
      'id': 'legacy-key-casing',
      'groupId': 'group',
      'characterId': 'worker',
      'userRequest': '恢复旧键名',
      'status': 'paused',
      'createdAt': DateTime.utc(2026, 8, 27).toIso8601String(),
      'workModeTask': true,
      'executionStateJson': jsonEncode({
        'ToolMissing': true,
        'FolderGrantPending': true,
        'unknownCapability': 'drop-me',
      }),
    });

    final decoded = jsonDecode(restored.executionStateJson) as Map;
    expect(decoded['toolMissing'], isTrue);
    expect(decoded['folderGrantPending'], isTrue);
    expect(decoded.containsKey('ToolMissing'), isFalse);
    expect(decoded.containsKey('unknownCapability'), isFalse);
  });
}
