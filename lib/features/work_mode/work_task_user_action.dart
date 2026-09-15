import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_task_clarification.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:crypto/crypto.dart';

/// The small set of user actions that can be advertised in a group message.
/// The action itself is still executed by [WorkTaskCoordinator]; this value is
/// only a durable, display-safe relation between a message and a checkpoint.
enum WorkTaskUserActionKind {
  addMember,
  answerQuestion,
  installTool,
  authorizeFolder,
  approveCommand,
  openTask,
}

class WorkTaskUserAction {
  static const String messagePrefix = 'work-task-action';

  final String taskId;
  final String blockerId;
  final int version;
  final WorkTaskUserActionKind kind;

  const WorkTaskUserAction({
    required this.taskId,
    required this.blockerId,
    required this.version,
    required this.kind,
  });

  String get messageId => '$messagePrefix:$taskId:$blockerId:$version';

  String get label => switch (kind) {
        WorkTaskUserActionKind.addMember => '去补充角色',
        WorkTaskUserActionKind.answerQuestion => '回答问题',
        WorkTaskUserActionKind.installTool => '处理安装',
        WorkTaskUserActionKind.authorizeFolder => '授权目录',
        WorkTaskUserActionKind.approveCommand => '查看审批',
        WorkTaskUserActionKind.openTask => '查看任务',
      };

  String get semanticLabel =>
      '$label（任务 ${taskId.substring(0, taskId.length < 8 ? taskId.length : 8)}）';

  static WorkTaskUserAction? fromMessageId(String value) {
    final parts = value.split(':');
    if (parts.length != 4 || parts.first != messagePrefix) return null;
    final taskId = parts[1].trim();
    final blockerId = parts[2].trim();
    final version = int.tryParse(parts[3]);
    if (taskId.isEmpty || blockerId.isEmpty || version == null || version < 1) {
      return null;
    }
    final kind = _kindForBlocker(blockerId);
    return WorkTaskUserAction(
      taskId: taskId,
      blockerId: blockerId,
      version: version,
      kind: kind,
    );
  }

  /// Returns the currently advertised blockers for a task. The list is
  /// derived from the authoritative checkpoint on every save, so replaying a
  /// task after restart cannot create a second reminder for the same version.
  static List<WorkTaskUserAction> forTask(AgentTask task) {
    // A failed task may still expose retry/reauthorize actions in the existing
    // panel. Completed, cancelled and partially-completed tasks have no live
    // user-action checkpoint, so their old chat buttons must be inert.
    if (!task.workModeTask ||
        task.status == AgentTaskStatus.completed ||
        task.status == AgentTaskStatus.cancelled ||
        task.status == AgentTaskStatus.partiallyCompleted ||
        task.id.trim().isEmpty) {
      return const <WorkTaskUserAction>[];
    }
    final actions = <WorkTaskUserAction>[];
    final metadata = _metadata(task.executionStateJson);
    final discussion = _discussionMap(task.executionStateJson);
    final parsedDiscussion = discussion?['state'] is Map
        ? WorkDiscussionState.tryParse(discussion!['state'])
        : null;
    final checkpointNeedsReview =
        workExecutionCheckpointRequiresReview(task.executionStateJson);
    var checkpointReviewAdded = false;
    if (checkpointNeedsReview &&
        (discussion == null ||
            parsedDiscussion == null ||
            parsedDiscussion.isExecutionReady)) {
      actions.add(
        _openAction(
          task,
          'checkpointReview',
          material: <String>['checkpointSchemaUnsupported'],
        ),
      );
      checkpointReviewAdded = true;
    }
    if (metadata.containsKey('discussionState') &&
        (discussion == null || parsedDiscussion == null)) {
      // A typed marker that cannot pass strict parsing must have a durable
      // recovery action. Otherwise the task can remain paused forever while
      // the raw malformed map looks present to this display layer. If the
      // whole checkpoint already needs a schema review, keep that single
      // action so an old button does not expose two competing repairs.
      if (!checkpointReviewAdded) {
        actions.add(_openAction(task, 'discussionStateInvalid'));
      }
    } else if (parsedDiscussion != null) {
      final state = parsedDiscussion;
      final blockers = state.blockers;
      final questions = state.openQuestions;
      final phase = state.phase;
      final executor = state.executorId?.trim() ?? '';
      final candidates = state.candidateCharacterIds;
      final candidateRoleBlocker = blockers.firstWhere(
        (item) => _roleBlockers.contains(item),
        orElse: () => '',
      );
      // executorSelectionRequired is a normal intermediate state when the
      // group has qualified candidates and the discussion runner is still
      // electing one. It becomes a user blocker only when no candidate is
      // available; a blocked discussion with candidates still has a panel
      // answer/continue path rather than asking the user to add a role.
      final roleBlocker = candidateRoleBlocker == 'executorSelectionRequired' &&
              (candidates.isNotEmpty ||
                  phase == WorkDiscussionPhase.awaitingExecutor)
          ? ''
          : candidateRoleBlocker;
      // `awaitingExecutor` is also the runner's initial, transient phase:
      // it may still be resolving the complete group and qualified
      // candidates. Only an explicit role blocker (or a malformed blocked
      // state with no other explanation) should @ the user to add a member.
      // This prevents a fresh task from flashing a false "补角色" reminder
      // before the discussion runner has had a chance to elect one.
      final hasRoleGap = roleBlocker.isNotEmpty ||
          (executor.isEmpty &&
              candidates.isEmpty &&
              phase == 'blocked' &&
              blockers.isEmpty);
      if (hasRoleGap) {
        final blockerId =
            roleBlocker.isEmpty ? 'missingQualifiedRole' : roleBlocker;
        actions.add(
          WorkTaskUserAction(
            taskId: task.id,
            blockerId: blockerId,
            version: _discussionVersion(
              task,
              blockerId,
              <String>[...blockers, ...candidates, executor],
            ),
            kind: _kindForBlocker(blockerId),
          ),
        );
      }
      final informationBlocker = blockers.firstWhere(
        (item) => _informationBlockers.contains(item),
        orElse: () => '',
      );
      if (questions.isNotEmpty || informationBlocker.isNotEmpty) {
        final blockerId = informationBlocker.isEmpty
            ? 'missingUserInformation'
            : informationBlocker;
        actions.add(
          WorkTaskUserAction(
            taskId: task.id,
            blockerId: blockerId,
            version: _discussionVersion(
              task,
              blockerId,
              <String>[...questions, ...blockers],
            ),
            kind: WorkTaskUserActionKind.answerQuestion,
          ),
        );
      }
    }

    if (WorkTaskClarification.isPending(task)) {
      actions.add(_openAction(task, 'clarificationRequired',
          kind: WorkTaskUserActionKind.answerQuestion));
    }

    if (WorkFailure.hasInstallableMissingTool(task)) {
      actions.add(
        _openAction(
          task,
          'toolMissing',
          kind: WorkTaskUserActionKind.installTool,
          material: <String>[
            task.pendingToolRequestJson,
          ],
        ),
      );
    }
    final folderPending = _folderPending(task, metadata);
    if (folderPending) {
      actions.add(
        _openAction(
          task,
          'folderAuthorization',
          kind: WorkTaskUserActionKind.authorizeFolder,
          material: <String>[
            metadata['folderRequestPath']?.toString() ?? '',
            metadata['folderGrantPending']?.toString() ?? '',
          ],
        ),
      );
    }
    final discussionAllowsApproval = _discussionAllowsApproval(task);
    if (!folderPending &&
        discussionAllowsApproval &&
        task.status == AgentTaskStatus.waitingForApproval &&
        task.pendingToolRequestJson.trim().isNotEmpty) {
      actions.add(
        _openAction(
          task,
          'commandApproval',
          kind: WorkTaskUserActionKind.approveCommand,
          material: <String>[task.pendingToolRequestJson],
        ),
      );
    }

    // A user-action failure that predates the typed markers still needs a
    // durable way back to the existing panel. Do not invent an executable
    // operation for unknown failures.
    if (actions.isEmpty &&
        (task.status == AgentTaskStatus.paused ||
            task.status == AgentTaskStatus.interrupted) &&
        (task.resumeRequired || task.lastError.trim().isNotEmpty)) {
      final failure = WorkFailure.fromTask(task);
      if (failure?.canContinue == true ||
          failure?.canReauthorize == true ||
          failure?.canRetry == true) {
        actions.add(_openAction(task, 'userActionRequired'));
      }
    }
    return _deduplicate(actions);
  }

  static bool isCurrent(
    AgentTask task, {
    required String blockerId,
    required int version,
  }) {
    return forTask(task).any(
      (action) => action.blockerId == blockerId && action.version == version,
    );
  }

  static int versionFor(AgentTask task, String blockerId) {
    for (final action in forTask(task)) {
      if (action.blockerId == blockerId) return action.version;
    }
    return 0;
  }

  /// Returns a stable version for a discussion checkpoint that has not yet
  /// exposed a concrete user blocker. The panel uses this for its harmless
  /// "稍后处理" action; keeping it versioned still makes an old button inert
  /// when a newer discussion request replaces the checkpoint.
  static int discussionCheckpointVersion(AgentTask task) {
    final discussion = _discussionMap(task.executionStateJson);
    final raw = discussion?['state'];
    if (raw is! Map) return 0;
    final phase = raw['phase']?.toString() ?? '';
    if (phase == WorkDiscussionPhase.ready) return 0;
    return _digestVersion(<String>[
      task.id,
      'discussionRequired',
      task.currentStep.toString(),
      task.userRequest,
      ...task.queuedUserRequests,
      ..._taskIdentityMaterial(task),
      raw['requestRevision']?.toString() ?? '',
      phase,
      raw['executorId']?.toString() ?? '',
      ..._strings(raw['blockers']),
      ..._strings(raw['openQuestions']),
      raw['understandingPercent']?.toString() ?? '',
    ]);
  }

  static WorkTaskUserAction _openAction(
    AgentTask task,
    String blockerId, {
    WorkTaskUserActionKind kind = WorkTaskUserActionKind.openTask,
    Iterable<String> material = const <String>[],
  }) {
    return WorkTaskUserAction(
      taskId: task.id,
      blockerId: blockerId,
      version: _digestVersion(<String>[
        task.id,
        blockerId,
        task.currentStep.toString(),
        // A follow-up can change the task request while leaving the same
        // approval/install/folder marker in place. Include the durable request
        // FIFO so an old chat button cannot act on the revised scope.
        task.userRequest,
        ...task.queuedUserRequests,
        ..._taskIdentityMaterial(task),
        ...material,
      ]),
      kind: kind,
    );
  }

  static int _discussionVersion(
    AgentTask task,
    String blockerId,
    Iterable<String> material,
  ) {
    final state = _discussionMap(task.executionStateJson);
    final raw = state?['state'];
    final revision = raw is Map ? raw['requestRevision']?.toString() ?? '' : '';
    return _digestVersion(<String>[
      task.id,
      revision,
      blockerId,
      ..._taskIdentityMaterial(task),
      ...material,
    ]);
  }

  /// Sender identity is part of the checkpoint relation. If a role is
  /// replaced while a chat reminder is in flight, its old button/message must
  /// become stale instead of authorizing or speaking for the new executor.
  static List<String> _taskIdentityMaterial(AgentTask task) => <String>[
        task.characterId,
        ...task.assignedCharacterIds,
      ];

  static int _digestVersion(Iterable<String> values) {
    final digest =
        sha256.convert(utf8.encode(values.join('\u001f'))).toString();
    final value = int.tryParse(digest.substring(0, 8), radix: 16) ?? 1;
    return value == 0 ? 1 : value;
  }

  static Map<String, dynamic>? _discussionMap(String raw) {
    final metadata = _metadata(raw);
    final value = metadata['discussionState'];
    if (value is! Map) return null;
    try {
      return <String, dynamic>{
        'state': Map<String, dynamic>.from(value),
      };
    } on Object {
      return null;
    }
  }

  static Map<String, dynamic> _metadata(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, dynamic>{};
      return <String, dynamic>{
        for (final entry in decoded.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
    } on Object {
      return <String, dynamic>{};
    }
  }

  static bool _folderPending(AgentTask task, Map<String, dynamic> metadata) {
    if (task.isTerminal) return false;
    return metadata['folderGrantPending'] == true ||
        metadata['folderRequestPath'] is String &&
            (task.status == AgentTaskStatus.paused ||
                task.status == AgentTaskStatus.waitingForApproval ||
                task.status == AgentTaskStatus.interrupted);
  }

  static bool _discussionAllowsApproval(AgentTask task) {
    final discussion = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    if (!discussion.present) return true;
    return discussion.state?.isExecutionReady == true;
  }

  static List<String> _strings(Object? value) {
    if (value is! Iterable) return <String>[];
    return value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static List<WorkTaskUserAction> _deduplicate(
    Iterable<WorkTaskUserAction> actions,
  ) {
    final seen = <String>{};
    return actions.where((action) => seen.add(action.messageId)).toList();
  }

  static WorkTaskUserActionKind _kindForBlocker(String blockerId) {
    if (_memberActionRoleBlockers.contains(blockerId)) {
      return WorkTaskUserActionKind.addMember;
    }
    if (_informationBlockers.contains(blockerId) ||
        blockerId == 'clarificationRequired') {
      return WorkTaskUserActionKind.answerQuestion;
    }
    if (blockerId == 'toolMissing') return WorkTaskUserActionKind.installTool;
    if (blockerId == 'folderAuthorization') {
      return WorkTaskUserActionKind.authorizeFolder;
    }
    if (blockerId == 'commandApproval') {
      return WorkTaskUserActionKind.approveCommand;
    }
    return WorkTaskUserActionKind.openTask;
  }

  static const Set<String> roleBlockersForValidation = <String>{
    'missingQualifiedRole',
    'executorUnavailable',
    'executorIdentityMismatch',
    'groupUnavailable',
    'routingUnavailable',
    'executorSelectionRequired',
  };

  static const Set<String> _roleBlockers = roleBlockersForValidation;

  /// Only blockers that can be repaired through the existing group-member
  /// editor belong to the "补充角色" action.  Identity corruption and a
  /// missing group still need the task panel's diagnostic surface; opening a
  /// member form for those states would suggest a repair that cannot work.
  static const Set<String> _memberActionRoleBlockers = <String>{
    'missingQualifiedRole',
    'executorUnavailable',
    'executorSelectionRequired',
    'routingUnavailable',
  };

  static const Set<String> _informationBlockers = <String>{
    'missingUserInformation',
    'mentionClarification',
    'discussionNotConverged',
    'discussionRoundLimit',
  };
}
