import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_task_requirements_confirmation.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTask _task({
  String id = 'task-1',
  String userRequest = '输出 Word 需求文档',
  AgentTaskStatus status = AgentTaskStatus.paused,
  String executionStateJson = '',
}) {
  return AgentTask(
    id: id,
    groupId: 'group-1',
    characterId: '',
    userRequest: userRequest,
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
  Map<String, dynamic>? deliverableContract,
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
    deliverableContract: deliverableContract ?? _contract(revision: revision),
  );
}

void main() {
  test('确认飞行棋需求时保留明确玩法并只建议未指定的默认玩法', () {
    const request = '制作两人飞行棋，掷出 5 或 6 都可以起飞，交付 game.html';
    final task = _task(userRequest: request);
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      WorkDiscussionState.forNewTask(task),
    );
    WorkTaskRequirementsConfirmation.requireForCurrentRequest(task);

    final card = WorkTaskRequirementsConfirmation.cardFor(
      task,
      executorName: '程序媛',
    );
    expect(card, contains('按你原话中已明确的规则执行'));
    expect(card, isNot(contains('四人同机轮流')));
    WorkTaskRequirementsConfirmation.acceptCurrentRequest(task);

    final scope = WorkDiscussionState.currentRequestScope(task);
    expect(scope, request);
    expect(scope, isNot(contains('四人同机轮流')));
  });

  test('没有明示玩法时确认卡的默认飞行棋规则会写入任务范围', () {
    final task = _task(userRequest: '制作一款飞行棋游戏');
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      WorkDiscussionState.forNewTask(task),
    );
    WorkTaskRequirementsConfirmation.requireForCurrentRequest(task);

    final card = WorkTaskRequirementsConfirmation.cardFor(
      task,
      executorName: '程序媛',
    );
    expect(card, contains('玩法建议：四人同机轮流'));
    WorkTaskRequirementsConfirmation.acceptCurrentRequest(task);

    expect(
      WorkDiscussionState.currentRequestScope(task),
      contains('用户确认卡中接受的玩法：四人同机轮流'),
    );
  });

  test('flight chess confirmation resolves the requested nested output file',
      () {
    const request = '大家讨论差不多了，现在需要大家决定最终方案，最终由@程序媛 '
        '在我的 /Users/fengye/Desktop/chat_group_out 这个目录中 创建一个飞行棋的目录，'
        '里面放着一份飞行棋的html';
    final task = _task(
      userRequest: request,
      executionStateJson: jsonEncode({
        'discussionState': _discussion(
          phase: WorkDiscussionPhase.awaitingDiscussion,
          blockers: const ['discussionRequired'],
          deliverableContract: {
            ..._contract(),
            'deliverableType': 'source',
            'format': 'html',
            'location': '/Users/fengye/Desktop/chat_group_out',
            'contentScope': request,
          },
        ).toJson(),
      }),
    );
    WorkTaskRequirementsConfirmation.requireForCurrentRequest(task);

    final card = WorkTaskRequirementsConfirmation.cardFor(
      task,
      executorName: '程序媛',
    );
    expect(
      card,
      contains(
        '/Users/fengye/Desktop/chat_group_out/飞行棋/飞行棋.html',
      ),
    );
  });

  test('requirement confirmation is bound to the current request revision', () {
    final task = _task(
      executionStateJson: jsonEncode({
        'discussionState': _discussion(
          deliverableContract: {
            ..._contract(),
            'deliverableType': 'html',
            'format': 'html',
            'location': '/Users/fengye/Desktop/chat_group_out/飞行棋',
            'revisionTarget': '飞行棋.html',
          },
        ).toJson(),
        'retainedMetadata': 'keep-me',
      }),
      userRequest: '制作可实际游玩的单文件 HTML 飞行棋，交付飞行棋.html。'
          'CSS 和 JavaScript 内嵌，无需安装、构建或联网，双击即可打开。'
          '非制作人测试成员实际运行当前候选；失败时程序媛返工，再由测试成员复测。',
    );
    WorkTaskRequirementsConfirmation.requireForCurrentRequest(task);

    final action = WorkTaskUserAction.forTask(task).single;
    expect(action.kind, WorkTaskUserActionKind.confirmRequirements);
    expect(action.version, isNonZero);
    expect(
      WorkTaskUserAction.isCurrent(
        task,
        blockerId: action.blockerId,
        version: action.version,
      ),
      isTrue,
    );
    expect(jsonDecode(task.executionStateJson)['retainedMetadata'], 'keep-me');
    final card = WorkTaskRequirementsConfirmation.cardFor(
      task,
      executorName: '程序媛',
    );
    expect(card, contains('四人同机轮流'));
    expect(card, contains('飞行棋.html'));
    expect(card, contains('程序媛'));
    expect(card, contains('CSS 和 JavaScript 内嵌于同一 HTML'));
    expect(card, contains('无需安装、构建或联网'));
    expect(card, contains('版本摘要、测试项目、预期、实际和执行记录'));
    expect(card, contains('由程序媛返工生成新候选后再独立复测'));

    task.userRequest = '新增需求：增加规则说明和静音开关';
    expect(WorkTaskRequirementsConfirmation.isCurrent(task), isFalse);
    expect(
      WorkTaskUserAction.forTask(task).single.kind,
      WorkTaskUserActionKind.openTask,
    );

    WorkTaskRequirementsConfirmation.requireForCurrentRequest(task);
    final revisedAction = WorkTaskUserAction.forTask(task).single;
    expect(revisedAction.kind, WorkTaskUserActionKind.confirmRequirements);
    expect(revisedAction.version, isNot(action.version));
  });

  test('requirement confirmation is bound to the routed deliverable contract',
      () {
    final task = _task(
      executionStateJson: jsonEncode({
        'discussionState': _discussion().toJson(),
      }),
    );
    WorkTaskRequirementsConfirmation.requireForCurrentRequest(task);
    final action = WorkTaskUserAction.forTask(task).single;
    expect(WorkTaskRequirementsConfirmation.isCurrent(task), isTrue);

    final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    final discussion = Map<String, dynamic>.from(
      root[WorkDiscussionState.jsonKey] as Map,
    );
    discussion['deliverableContract'] = {
      ...discussion['deliverableContract'] as Map,
      'location': '/Users/fengye/Desktop/changed-output',
    };
    root[WorkDiscussionState.jsonKey] = discussion;
    task.executionStateJson = jsonEncode(root);

    expect(WorkTaskRequirementsConfirmation.isCurrent(task), isFalse);
    expect(
      WorkTaskUserAction.isCurrent(
        task,
        blockerId: action.blockerId,
        version: action.version,
      ),
      isFalse,
    );
  });

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

  test('a pin the group cannot satisfy offers an executor confirmation', () {
    final base = _discussion(
      executorId: 'elected',
      candidates: const <String>['elected', 'pinned'],
      phase: WorkDiscussionPhase.blocked,
      blockers: const <String>['executorPinConflict'],
      openQuestions: const <String>['群推举乙作为最终执行人，但交付合同钉定的是甲'],
    );
    final task = _task(
      id: 'pin-conflict-task',
      executionStateJson: jsonEncode({
        'discussionState': base.copyWith(
          deliverableContract: <String, dynamic>{
            ..._contract(),
            'explicitExecutorId': 'pinned',
          },
        ).toJson(),
      }),
    );

    final actions = WorkTaskUserAction.forTask(task);
    expect(actions, hasLength(1));
    expect(actions.single.blockerId, 'executorPinConflict');
    expect(actions.single.kind, WorkTaskUserActionKind.confirmExecutorSwap);
    expect(actions.single.label, '确认执行人');
    expect(
      WorkTaskUserAction.versionFor(task, 'executorPinConflict'),
      actions.single.version,
    );
  });
}
