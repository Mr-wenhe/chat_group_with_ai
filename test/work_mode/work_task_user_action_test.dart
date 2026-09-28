import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTask _task({
  String id = 'task-1',
  AgentTaskStatus status = AgentTaskStatus.paused,
  String executionStateJson = '',
}) {
  return AgentTask(
    id: id,
    groupId: 'group-1',
    characterId: '',
    userRequest: '输出 Word 需求文档',
    status: status,
    executionStateJson: executionStateJson,
    workModeTask: true,
  );
}

Map<String, dynamic> _contract({int revision = 1}) => <String, dynamic>{
      'deliverableType': 'document',
      'format': 'docx',
      'location': 'desktop',
      'contentScope': '输出 Word 需求文档',
      'explicitExecutorId': null,
      'revisionTarget': '',
      'requestRevision': revision,
    };

WorkDiscussionState _discussion({
  int revision = 1,
  Iterable<String> candidates = const <String>[],
  String? executorId,
  String phase = WorkDiscussionPhase.blocked,
  Iterable<String> openQuestions = const <String>[],
  Iterable<String> blockers = const <String>['missingUserInformation'],
}) {
  return WorkDiscussionState(
    conversationId: 'group-1',
    phase: phase,
    requestRevision: revision,
    executorId: executorId,
    candidateCharacterIds: candidates,
    participants: [
      for (final id in candidates) WorkDiscussionParticipant(characterId: id),
    ],
    round: 2,
    understandingPercent: 60,
    understandingEvidence: const ['范围已记录'],
    openQuestions: openQuestions,
    blockers: blockers,
    deliverableContract: _contract(revision: revision),
  );
}

void main() {
  test('binds role and question reminders to a stable task checkpoint', () {
    final roleTask = _task(
      executionStateJson: jsonEncode({
        'discussionState': _discussion(
          candidates: const <String>[],
          executorId: null,
          blockers: const <String>['missingQualifiedRole'],
        ).toJson(),
      }),
    );
    final roleAction = WorkTaskUserAction.forTask(roleTask).single;
    expect(roleAction.kind, WorkTaskUserActionKind.addMember);
    expect(roleAction.blockerId, 'missingQualifiedRole');
    expect(
      WorkTaskUserAction.fromMessageId(roleAction.messageId)?.messageId,
      roleAction.messageId,
    );
    expect(
      WorkTaskUserAction.forTask(roleTask).single.messageId,
      roleAction.messageId,
    );

    final questionTask = _task(
      id: 'question-task',
      executionStateJson: jsonEncode({
        'discussionState': _discussion(
          openQuestions: const <String>['请确认桌面目录'],
          blockers: const <String>['missingUserInformation'],
        ).toJson(),
      }),
    );
    final questionAction = WorkTaskUserAction.forTask(questionTask).firstWhere(
      (action) => action.kind == WorkTaskUserActionKind.answerQuestion,
    );
    expect(questionAction.kind, WorkTaskUserActionKind.answerQuestion);
    expect(questionAction.blockerId, 'missingUserInformation');

    final inGroupDecisionTask = _task(
      id: 'in-group-decision-task',
      executionStateJson: jsonEncode({
        'discussionState': _discussion(
          candidates: const <String>['front'],
          executorId: 'front',
          phase: WorkDiscussionPhase.awaitingDiscussion,
          openQuestions: const <String>['请在群内确定默认重试次数'],
          blockers: const <String>[],
        ).toJson(),
      }),
    );
    expect(WorkTaskUserAction.forTask(inGroupDecisionTask), isEmpty);
  });

  test('a follow-up clarification exposes the same answer action', () {
    // 追问澄清和模型澄清一样是"必须由用户回答"的问题，可回答性判据只能有一处。
    // 分开维护过一次的后果：面板不给回复框、聊天没有回答入口，而"继续"又按
    // 另一个判据拒绝，任务既答不了也退不出。
    final task = _task(
      id: 'follow-up-clarification-task',
      executionStateJson: jsonEncode({
        'followUpKind': 'clarification',
        'clarificationQuestion': '请明确要修改的文件路径（a.md、b.md）？',
      }),
    );

    final action = WorkTaskUserAction.forTask(task).singleWhere(
      (item) => item.kind == WorkTaskUserActionKind.answerQuestion,
    );
    expect(action.blockerId, 'clarificationRequired');
  });

  test('does not ask the user to add a role while candidates are being elected',
      () {
    final task = _task(
      executionStateJson: jsonEncode({
        'discussionState': _discussion(
          candidates: const <String>['frontend'],
          executorId: null,
          phase: WorkDiscussionPhase.awaitingExecutor,
          blockers: const <String>[
            'discussionRequired',
            'executorSelectionRequired'
          ],
          openQuestions: const <String>[],
        ).toJson(),
      }),
    );

    expect(WorkTaskUserAction.forTask(task), isEmpty);
  });

  test('does not advertise a role gap during the initial runner phase', () {
    final task = _task(
      executionStateJson: jsonEncode({
        'discussionState': WorkDiscussionState.initial(
          conversationId: 'group-1',
          executorId: null,
          candidateCharacterIds: const <String>[],
          participantCharacterIds: const <String>[],
        ).toJson(),
      }),
    );

    expect(WorkTaskUserAction.forTask(task), isEmpty);
  });

  test('changes the version when a discussion revision changes', () {
    final first = _task(
      executionStateJson: jsonEncode({
        'discussionState': _discussion(
          revision: 1,
          openQuestions: const <String>['请确认桌面目录'],
        ).toJson(),
      }),
    );
    final firstAction = WorkTaskUserAction.forTask(first).firstWhere(
      (action) => action.kind == WorkTaskUserActionKind.answerQuestion,
    );
    expect(
      WorkTaskUserAction.isCurrent(
        first,
        blockerId: firstAction.blockerId,
        version: firstAction.version,
      ),
      isTrue,
    );

    final second = _task(
      executionStateJson: jsonEncode({
        'discussionState': _discussion(
          revision: 2,
          openQuestions: const <String>['请确认最终文件名'],
        ).toJson(),
      }),
    );
    expect(
      WorkTaskUserAction.isCurrent(
        second,
        blockerId: firstAction.blockerId,
        version: firstAction.version,
      ),
      isFalse,
    );
  });

  test('keeps a folder checkpoint version across a waiting-to-paused update',
      () {
    final task = _task(
      status: AgentTaskStatus.waitingForApproval,
      executionStateJson: jsonEncode({
        'folderGrantPending': true,
      }),
    );
    final waiting = WorkTaskUserAction.forTask(task).single;
    task.status = AgentTaskStatus.paused;

    final paused = WorkTaskUserAction.forTask(task).single;
    expect(waiting.blockerId, 'folderAuthorization');
    expect(paused.version, waiting.version);
  });

  test('restored interrupted folder checkpoints still expose authorization',
      () {
    final task = _task(
      status: AgentTaskStatus.interrupted,
      executionStateJson: jsonEncode({
        'folderRequestPath': '/workspace/project',
      }),
    );

    final actions = WorkTaskUserAction.forTask(task);
    expect(actions, hasLength(1));
    expect(actions.single.kind, WorkTaskUserActionKind.authorizeFolder);
  });

  test('unsupported execution checkpoint exposes one review action', () {
    final task = _task(
      executionStateJson: jsonEncode({
        'schemaVersion': 99,
        'approvalDecision': 'approved',
      }),
    );

    final actions = WorkTaskUserAction.forTask(task);
    expect(actions, hasLength(1));
    expect(actions.single.blockerId, 'checkpointReview');
    expect(actions.single.kind, WorkTaskUserActionKind.openTask);
  });

  test('malformed execution checkpoint exposes one review action', () {
    final task = _task(
      executionStateJson: '{malformed execution checkpoint',
    );

    final actions = WorkTaskUserAction.forTask(task);
    expect(actions, hasLength(1));
    expect(actions.single.blockerId, 'checkpointReview');
    expect(actions.single.kind, WorkTaskUserActionKind.openTask);
  });

  test('unsupported checkpoint with malformed discussion still exposes review',
      () {
    final task = _task(
      executionStateJson: jsonEncode({
        'schemaVersion': 99,
        'discussionState': {'schemaVersion': 99},
      }),
    );

    final actions = WorkTaskUserAction.forTask(task);
    expect(actions, hasLength(1));
    expect(actions.single.blockerId, 'checkpointReview');
  });

  test('malformed typed discussion marker exposes a recovery action', () {
    final task = _task(
      executionStateJson: jsonEncode({
        'discussionState': {'schemaVersion': 99},
      }),
    );

    final actions = WorkTaskUserAction.forTask(task);
    expect(actions, hasLength(1));
    expect(actions.single.blockerId, 'discussionStateInvalid');
    expect(actions.single.kind, WorkTaskUserActionKind.openTask);
  });

  test('maps approval and tool checkpoints to their existing actions', () {
    final approval = _task(
      id: 'approval-task',
      status: AgentTaskStatus.waitingForApproval,
    )..pendingToolRequestJson = jsonEncode({
        'tool': 'command.run',
        'args': <String, dynamic>{'executable': 'pandoc'},
      });
    final approvalAction = WorkTaskUserAction.forTask(approval).single;
    expect(approvalAction.kind, WorkTaskUserActionKind.approveCommand);

    final tool = _task(
      id: 'tool-task',
      executionStateJson: jsonEncode({'toolMissing': true}),
    )..pendingToolRequestJson = jsonEncode({
        'tool': 'command.run',
        'args': <String, dynamic>{'executable': 'pandoc'},
      });
    final toolAction = WorkTaskUserAction.forTask(
      tool,
      isMacOS: true,
    ).single;
    expect(toolAction.kind, WorkTaskUserActionKind.installTool);

    expect(
      WorkTaskUserAction.forTask(
        tool,
        isWindows: false,
        isMacOS: false,
      ),
      isEmpty,
    );
  });

  test('completed and cancelled tasks invalidate old action buttons', () {
    for (final status in <AgentTaskStatus>[
      AgentTaskStatus.completed,
      AgentTaskStatus.cancelled,
      AgentTaskStatus.partiallyCompleted,
    ]) {
      expect(
        WorkTaskUserAction.forTask(_task(status: status)),
        isEmpty,
      );
    }
  });

  test('only repairable role blockers open the member editor', () {
    for (final entry in <String, WorkTaskUserActionKind>{
      'missingQualifiedRole': WorkTaskUserActionKind.addMember,
      'executorUnavailable': WorkTaskUserActionKind.addMember,
      'executorSelectionRequired': WorkTaskUserActionKind.addMember,
      'routingUnavailable': WorkTaskUserActionKind.addMember,
      'executorIdentityMismatch': WorkTaskUserActionKind.openTask,
      'groupUnavailable': WorkTaskUserActionKind.openTask,
    }.entries) {
      final action = WorkTaskUserAction.fromMessageId(
        'work-task-action:task-${entry.key}:${entry.key}:123',
      );
      expect(action, isNotNull, reason: entry.key);
      expect(action!.kind, entry.value, reason: entry.key);
    }
  });

  test('role mismatch state keeps a diagnostic task action', () {
    final task = _task(
      id: 'identity-mismatch-task',
      executionStateJson: jsonEncode({
        'discussionState': _discussion(
          executorId: 'new-executor',
          candidates: const <String>['new-executor'],
          blockers: const <String>['executorIdentityMismatch'],
        ).toJson(),
      }),
    );

    final action = WorkTaskUserAction.forTask(task).single;
    expect(action.blockerId, 'executorIdentityMismatch');
    expect(action.kind, WorkTaskUserActionKind.openTask);
  });
}
