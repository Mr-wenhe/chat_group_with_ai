import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_task_execution_policy.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTask _task(String id, String conversationId) => AgentTask(
      id: id,
      groupId: conversationId,
      characterId: 'worker',
      userRequest: '读取并完成任务',
      workModeTask: true,
    );

void _attachV2(AgentTask task) {
  final collaboration = WorkCollaborationState.fromLegacy(
    taskId: task.id,
    conversationId: task.groupId,
    projectScopeId: 'project-a',
    requestRevision: 1,
    requestMessageId: '',
    scope: task.userRequest,
    artifactContract: const {
      'type': 'document',
      'format': 'txt',
      'location': 'out.txt',
      'revisionTarget': '',
    },
  );
  final discussion = WorkDiscussionState(
    schemaVersion: WorkDiscussionState.currentSchemaVersion,
    conversationId: task.groupId,
    phase: WorkDiscussionPhase.blocked,
    requestRevision: 1,
    collaboration: collaboration,
  );
  task.executionStateJson =
      WorkDiscussionState.mergeIntoExecutionState('', discussion);
}

void main() {
  test('only a validated task-bound v2 group loses cumulative limits', () {
    final group = _task('v2-task', 'group-a')
      ..actionCount = 101
      ..startedAt = DateTime.utc(2026, 1, 1);
    _attachV2(group);
    expect(WorkTaskExecutionPolicy.enforcesCumulativeLimits(group), isFalse);
    expect(WorkTaskExecutionPolicy.progressTotal(group, 100), isNull);
    expect(group.actionCount, 101);
    expect(group.startedAt, DateTime.utc(2026, 1, 1));

    final dm = _task('dm-task', 'dm:worker');
    _attachV2(dm);
    expect(WorkTaskExecutionPolicy.enforcesCumulativeLimits(dm), isTrue);
    final wrongTask = _task('other-task', 'group-a')
      ..executionStateJson = group.executionStateJson;
    expect(
      WorkTaskExecutionPolicy.enforcesCumulativeLimits(wrongTask),
      isTrue,
    );
    final corrupt = _task('broken', 'group-a')..executionStateJson = '{broken';
    expect(WorkTaskExecutionPolicy.enforcesCumulativeLimits(corrupt), isTrue);
  });

  test('97 new readings remain progress; repeated evidence stalls', () {
    var state = <String, dynamic>{};
    final now = DateTime.utc(2026, 1, 1);
    for (var index = 0; index < 97; index++) {
      final result = WorkProgressGuard.observe(
        state,
        WorkProgressObservation(
          kind: WorkProgressObservationKind.progress,
          fingerprint: 'read-file-$index:content-$index',
          summary: '读取文件 $index 获得新事实',
        ),
        now: now.add(Duration(minutes: index)),
      );
      expect(result.stalled, isFalse);
      expect(result.madeProgress, isTrue);
      state = result.executionState;
    }
    expect(state[WorkProgressGuard.jsonKey]['lastProgressAt'],
        now.add(const Duration(minutes: 96)).millisecondsSinceEpoch);
    for (var index = 0;
        index < WorkProgressGuard.noProgressResultLimit;
        index++) {
      final result = WorkProgressGuard.observe(
        state,
        const WorkProgressObservation(
          kind: WorkProgressObservationKind.noProgress,
          summary: '换一种说法重复原方案',
          missing: '需要新的证据',
        ),
        now: now,
      );
      state = result.executionState;
      expect(
          result.stalled, index == WorkProgressGuard.noProgressResultLimit - 1);
    }
    expect(jsonEncode(state).length, lessThan(30000));
    final guard = state[WorkProgressGuard.jsonKey] as Map;
    expect(guard['lastProgressSummary'], '读取文件 96 获得新事实');
    expect(guard['missing'], '需要新的证据');
    expect((guard['attempts'] as List).length, lessThanOrEqualTo(8));
  });

  test(
      'same failure condition stalls; waiting and same input preserve evidence',
      () {
    var state = <String, dynamic>{};
    final now = DateTime.utc(2026, 1, 1);
    for (var index = 0;
        index < WorkProgressGuard.repeatedFailureLimit;
        index++) {
      state = WorkProgressGuard.observe(
        state,
        const WorkProgressObservation(
          kind: WorkProgressObservationKind.failure,
          fingerprint: 'same-error',
          conditionFingerprint: 'same-input',
          summary: '工具失败',
          missing: '需要更改输入条件',
        ),
        now: now,
      ).executionState;
    }
    expect(state[WorkProgressGuard.jsonKey]['stalled'], isTrue);
    final waiting = WorkProgressGuard.observe(
      state,
      const WorkProgressObservation(
        kind: WorkProgressObservationKind.waiting,
        summary: '等待审批',
      ),
      now: now,
    );
    expect(waiting.executionState, state);
    final sameInput = WorkProgressGuard.observe(
      state,
      const WorkProgressObservation(
        kind: WorkProgressObservationKind.failure,
        fingerprint: 'same-error',
        conditionFingerprint: 'same-input',
        summary: '改了措辞仍是相同失败',
      ),
      now: now,
    );
    expect(sameInput.stalled, isTrue);
    final changed = WorkProgressGuard.observe(
      state,
      const WorkProgressObservation(
        kind: WorkProgressObservationKind.progress,
        fingerprint: 'new-file-fact',
        summary: '新条件下读到不同事实',
      ),
      now: now,
    );
    expect(changed.stalled, isFalse);
    expect(changed.madeProgress, isTrue);
  });
}
