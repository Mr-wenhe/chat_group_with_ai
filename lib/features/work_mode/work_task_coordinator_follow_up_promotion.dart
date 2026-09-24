part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorFollowUpPromotion on WorkTaskCoordinator {
  Future<void> _promoteQueuedFollowUp(
    AgentTask task, {
    bool resetRunBudget = false,
    bool allowPausedClarification = false,
  }) async {
    final canPromotePausedClarification =
        allowPausedClarification && _isFollowUpClarification(task);
    final answeringModelClarification =
        allowPausedClarification && WorkTaskClarification.isPending(task);
    if ((!task.isTerminal &&
            !canPromotePausedClarification &&
            !answeringModelClarification) ||
        task.status == AgentTaskStatus.cancelled ||
        task.queuedUserRequests.isEmpty ||
        _disposed) {
      return;
    }
    final nextRequest = task.queuedUserRequests.first.trim();
    final queuedAttachmentIds = _queuedAttachmentMessageIds(
      task.executionStateJson,
      expectedLength: task.queuedUserRequests.length,
    );
    final nextAttachmentId =
        queuedAttachmentIds.isEmpty ? null : queuedAttachmentIds.first.trim();
    if (nextRequest.isEmpty) {
      task.queuedUserRequests = task.queuedUserRequests.skip(1).toList();
      _persistAttachmentQueueMetadata(
        task,
        queuedAttachmentIds.skip(1).toList(),
        currentAttachmentId: null,
      );
      await _promoteQueuedFollowUp(task);
      return;
    }
    final previousFailure = task.workFailure;
    final discussionMarker =
        WorkDiscussionState.decodeExecutionState(task.executionStateJson);
    if (_requiresDiscussionForTask(task) &&
        discussionMarker.present &&
        (discussionMarker.state == null ||
            discussionMarker.state!.conversationId != task.groupId)) {
      await _pauseForDiscussion(
        task,
        '讨论状态无效或属于另一个群组，已阻止追问绕过讨论门禁。',
      );
      await _save(task);
      await _markSnapshotStatus(task);
      return;
    }
    final previousDiscussion =
        _requiresDiscussionForTask(task) ? discussionMarker.state : null;
    final decision = _followUpDecisionForPromotion(
      task,
      nextRequest,
      answeringFollowUpClarification: canPromotePausedClarification,
      previousFailure: previousFailure,
    );
    final modelClarificationNeedsDiscussion = answeringModelClarification &&
        (decision.kind == WorkFollowUpKind.newArtifact ||
            decision.isRevision ||
            decision.kind == WorkFollowUpKind.clarification);
    final startsNewArtifact = decision.kind == WorkFollowUpKind.newArtifact;
    final resetFreshContext = startsNewArtifact &&
        _isTask15Context(task.contextSummary, task.groupId);
    if (decision.isClarification) {
      // Keep the original request at the head of the durable FIFO. A later
      // user answer can therefore resolve it without losing any following
      // requests. No runner is started while the target is ambiguous.
      task
        ..status = AgentTaskStatus.paused
        ..resumeRequired = false
        ..lastError = decision.clarificationQuestion ?? '请明确要修改的文件路径。'
        ..executionStateJson = _withFollowUpDecision(
          task.executionStateJson,
          decision,
        )
        ..updatedAt = _clock();
      _conversationReservations.add(task.groupId);
      _refreshTaskContext(
        task,
        nextStep: task.lastError,
        extraErrors: [task.lastError],
      );
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.paused,
        '需要明确修订目标',
        detail: task.lastError,
      );
      return;
    }
    if (_newArtifactRequiresFreshTask(
      task,
      decision,
      answeringModelClarification: answeringModelClarification,
    )) {
      // A completed task is a lineage checkpoint, not an executor lease for a
      // different deliverable. Split the request so the next discussion can
      // re-evaluate qualified roles without inheriting the old owner/plan.
      await _promoteNewArtifactFollowUp(
        task,
        nextRequest: nextRequest,
        nextAttachmentId: nextAttachmentId,
        remainingRequests: task.queuedUserRequests.skip(1),
        remainingAttachmentIds: queuedAttachmentIds.skip(1),
        decision: decision,
      );
      return;
    }
    task.queuedUserRequests = task.queuedUserRequests.skip(1).toList();
    final remainingAttachmentIds = queuedAttachmentIds.skip(1).toList();
    // A follow-up is a new execution run under the same conversation/task
    // identity.  Do not reuse the previous run's in-memory lock plan: the
    // new request may target a different file, and a stale plan could either
    // block unrelated work or fail to serialize the new target.
    _taskLockPlans.remove(task.id);
    final artifactPathsForRun = startsNewArtifact
        ? <String>[]
        : decision.isRevision && decision.artifactPath != null
            ? <String>[decision.artifactPath!]
            : List<String>.from(task.lastArtifactPaths);
    final nextUserRequest = answeringModelClarification
        ? _mergeClarificationAnswer(task.userRequest, nextRequest)
        : nextRequest;
    task
      ..userRequest = nextUserRequest
      ..status = AgentTaskStatus.queued
      ..plan = startsNewArtifact ? '' : task.plan
      ..resumeRequired = false
      ..softLimitReached = false
      ..pendingToolRequestJson = ''
      ..executionStateJson = ''
      ..lastError = ''
      ..resultSummary = ''
      // Delivery must describe this run, not every artifact ever produced by
      // the durable conversation. A revision keeps only its explicit target.
      ..lastArtifactPaths = artifactPathsForRun
      ..actionCount = resetRunBudget ? 0 : task.actionCount
      ..startedAt = resetRunBudget ? _clock() : task.startedAt
      ..updatedAt = _clock();
    _persistAttachmentQueueMetadata(
      task,
      remainingAttachmentIds,
      currentAttachmentId: nextAttachmentId,
    );
    task.executionStateJson = _withFollowUpDecision(
      task.executionStateJson,
      decision,
    );
    if (previousDiscussion != null &&
        (!answeringModelClarification || modelClarificationNeedsDiscussion)) {
      if (!_discussionExecutorIsPinned(previousDiscussion)) {
        // A renewed group discussion may elect a different qualified owner;
        // do not let the prior election stay in the task identity fields.
        task
          ..characterId = ''
          ..assignedCharacterIds = <String>[];
      }
      final renewedDiscussion = _renewDiscussionForRequest(
        previousDiscussion,
        nextRequest,
        decision: decision,
      );
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        renewedDiscussion,
      );
    } else if (previousDiscussion != null && answeringModelClarification) {
      // A model clarification answer that does not change the deliverable is
      // an execution input, not a new group request. Preserve the ready
      // discussion marker while resuming the same task so the answer cannot
      // discard the elected role or make the next checkpoint look legacy.
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        previousDiscussion,
      );
    }
    if (previousDiscussion != null &&
        (!answeringModelClarification || modelClarificationNeedsDiscussion)) {
      // A revision has to pass through the discussion gate again. Keep the
      // conversation reservation while the renewed state is discussed so the
      // scheduler cannot start the task with a non-ready marker.
      await _pauseForDiscussion(
        task,
        '已进入新的讨论版本，等待群内重新确认修订方案。',
      );
      await _save(task);
      _maybeStartDiscussion(task);
      return;
    }
    // A clarification pause intentionally held the conversation reservation;
    // the user's answer now makes the target runnable again.
    _conversationReservations.remove(task.groupId);
    _refreshTaskContext(
      task,
      nextStep: '开始处理已排队的追问。',
      clearRecentToolResults: true,
      resetTargetAndArtifacts: resetFreshContext,
    );
    await _save(task);
    _enqueueTask(task);
    unawaited(
      _record(task, WorkTaskEventKind.queued, '开始处理已排队的追问'),
    );
  }

  Future<void> _promoteNewArtifactFollowUp(
    AgentTask source, {
    required String nextRequest,
    required String? nextAttachmentId,
    required Iterable<String> remainingRequests,
    required Iterable<String> remainingAttachmentIds,
    required WorkFollowUpDecision decision,
  }) async {
    final normalizedRequest = nextRequest.trim();
    if (normalizedRequest.isEmpty) {
      source.queuedUserRequests = remainingRequests.toList(growable: false);
      _persistAttachmentQueueMetadata(
        source,
        remainingAttachmentIds.toList(growable: false),
        currentAttachmentId: null,
      );
      await _save(source);
      await _promoteQueuedFollowUp(source);
      return;
    }
    final contract = WorkRoleRouter.deliverableContractForRequest(
      normalizedRequest,
      requestRevision: 1,
    );
    final discussion = WorkDiscussionState.initial(
      conversationId: source.groupId,
      requestRevision: 1,
      executorId: null,
      candidateCharacterIds: const [],
      participantCharacterIds: const [],
      deliverableContract: contract.toJson(),
    );
    final execution = <String, dynamic>{
      'sourceTaskId': source.id,
      'followUpKind': decision.kind.name,
      'followUpReason': decision.reason,
      'autoRenameIfExists': decision.autoRenameIfExists,
      if (nextAttachmentId != null && nextAttachmentId.trim().isNotEmpty)
        'attachmentMessageId': nextAttachmentId.trim(),
    };
    final remainingIds =
        remainingAttachmentIds.map((id) => id.trim()).toList(growable: false);
    if (remainingIds.any((id) => id.isNotEmpty)) {
      execution['queuedAttachmentMessageIds'] = remainingIds;
    }
    final fresh = AgentTask(
      groupId: source.groupId,
      characterId: '',
      userRequest: normalizedRequest,
      status: AgentTaskStatus.paused,
      requestedPermissions: const [],
      queuedUserRequests: remainingRequests.toList(growable: false),
      assignedCharacterIds: const [],
      workModeTask: true,
      executionStateJson: WorkDiscussionState.mergeIntoExecutionState(
        jsonEncode(execution),
        discussion,
      ),
    );

    // Keep the completed source as a diagnostic checkpoint while transferring
    // the rest of its FIFO to the new lineage. Revision requests later carry
    // their exact original path through WorkFollowUpPolicy.
    source
      ..queuedUserRequests = <String>[]
      ..executionStateJson = _withoutFollowUpDecision(
        source.executionStateJson,
      )
      ..updatedAt = _clock();
    _persistAttachmentQueueMetadata(
      source,
      const <String>[],
      currentAttachmentId: null,
    );
    _refreshTaskContext(
      source,
      nextStep: '已建立新的工作任务，等待群讨论重新选定执行角色。',
    );
    await _save(source);
    await _pauseForDiscussion(
      fresh,
      '新工作任务已建立，等待群内重新讨论并选定符合职业资格的执行角色。',
    );
    await _save(fresh);
    _maybeStartDiscussion(fresh);
    await _record(
      source,
      WorkTaskEventKind.queued,
      '已建立新的工作任务',
      detail: fresh.id,
    );
  }

  /// 澄清答复的判决分两级。
  ///
  /// 第一级沿用历史行为——对「原句 + 答复」分类。答复只指明目标时
  /// （原句"请修改当前文件" + 答复"report.md"），原句里的修订意图必须保留，
  /// 否则目标改由模型重新猜。第二级只在第一级**仍然无法判定**时执行：被澄清的
  /// 原句本来就解析不出目标，只看它判决永远不变，于是任务反复暂停、用户在会话里
  /// 发什么都等于被吞掉。
  ///
  /// 第二级只认「明确要求新建交付物」的答复：新建不需要旧文件作为覆盖目标，
  /// 是唯一能自洽地绕开歧义的意图。含糊的答复（"不知道"、"随便"）会落到
  /// `continueTask`，那不是解开了目标歧义——放行它等于让任务带着未确定的目标
  /// 开跑，原句的修订意图最终落到哪个文件上仍然没人知道。
  ///
  /// 分级而不是直接只看答复，是为了不丢第一级已经能判定的目标。
  WorkFollowUpDecision _followUpDecisionForPromotion(
    AgentTask task,
    String nextRequest, {
    required bool answeringFollowUpClarification,
    required WorkFailure? previousFailure,
  }) {
    // The model/result runner writes the structured field first. A canonical
    // Task 15 summary is a recovery fallback for tasks imported between field
    // writes; no chat-history or global-file lookup is used.
    final artifacts = _followUpArtifactPaths(task);
    WorkFollowUpDecision resolveFor(String request) => _followUpPolicy.resolve(
          request: request,
          lastArtifactPaths: artifacts,
          failedArtifactPath: previousFailure?.failureTargetPath,
        );

    final merged = resolveFor(nextRequest);
    if (!merged.isClarification || !answeringFollowUpClarification) {
      return merged;
    }
    final answer = _clarificationAnswerOf(nextRequest);
    if (answer == nextRequest) return merged;
    final answered = resolveFor(answer);
    return answered.kind == WorkFollowUpKind.newArtifact ? answered : merged;
  }

  /// 「原句\n用户明确目标：答复」里最新一段答复；没有标记时原样返回。
  String _clarificationAnswerOf(String merged) {
    const marker = WorkTaskCoordinator.clarificationAnswerMarker;
    final index = merged.lastIndexOf(marker);
    if (index < 0) return merged;
    final answer = merged.substring(index + marker.length).trim();
    return answer.isEmpty ? merged : answer;
  }

  String _mergeClarificationAnswer(String original, String answer) {
    final normalizedOriginal = original.trim();
    if (normalizedOriginal.isEmpty) return answer;
    return '$normalizedOriginal\n用户对上述问题的回答：$answer';
  }

  List<String> _followUpArtifactPaths(AgentTask task) {
    if (task.lastArtifactPaths.isNotEmpty) {
      return List<String>.from(task.lastArtifactPaths);
    }
    final raw = task.contextSummary.trim();
    if (raw.isEmpty || !_isTask15Context(raw, task.groupId)) return const [];
    return _contextBuilder.fromTask(task).artifactPaths;
  }

  void _removeActiveRun(String taskId, Future<void> run) {
    if (identical(_activeRuns[taskId], run)) _activeRuns.remove(taskId);
  }

  String _withApprovalDecision(String raw, String decision) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..['approvalDecision'] = decision
          // A decision closes this exact prompt. If the resumed loop reaches
          // another mutation checkpoint, the host must be allowed to present
          // a fresh dialog for that new operation.
          ..remove('approvalPromptShown');
        final parsedDecision = WorkChangeApprovalDecision.fromWire(decision);
        if (parsedDecision?.permitsExecution == true) {
          // A new approval authorizes exactly the checkpoint that prompted it;
          // the runner consumes high-risk approvals on their first attempt.
          copy.remove('approvalConsumed');
        } else {
          copy
            ..remove('approvalCapability')
            ..remove('approvalOperationFingerprint')
            ..remove('approvalConsumed');
        }
        final rawPlan = copy['approvalPlan'];
        if (parsedDecision?.permitsExecution == true && rawPlan is Map) {
          try {
            final plan = WorkChangePlan.fromJson(
              Map<String, dynamic>.from(rawPlan),
            );
            copy['approvalScope'] = WorkApprovalScope.fromPlan(plan).toJson();
          } on Object {
            // The runner will fail closed when a tampered plan cannot produce
            // an exact scope; never synthesize a wildcard approval.
            copy.remove('approvalScope');
          }
        } else {
          // A rejection is not a capability grant. Remove the descriptive
          // scope before the runner continues with the safe skip path, so a
          // later tool cannot inherit the declined mutation's paths.
          copy.remove('approvalScope');
        }
        return jsonEncode(copy);
      }
    } on Object {
      // Replace malformed/non-object execution metadata with a minimal safe
      // checkpoint rather than persisting arbitrary model text.
    }
    return jsonEncode(<String, String>{'approvalDecision': decision});
  }

  String _withoutApprovalCheckpoint(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..remove('approvalDecision')
          ..remove('approvalScope')
          ..remove('approvalPlan')
          ..remove('approvalCapability')
          ..remove('approvalOperationFingerprint')
          ..remove('approvalConsumed')
          // An unsupported checkpoint is rewritten to the current safe
          // allow-list only after this explicit user continuation.
          ..remove('checkpointSchemaUnsupported')
          // The old prompt was bound to the removed operation. A renewed
          // scope must be allowed to surface a fresh approval dialog.
          ..remove('approvalPromptShown');
        return copy.isEmpty ? '' : jsonEncode(copy);
      }
    } on Object {
      // A malformed checkpoint is not safe to reuse after a restart.
    }
    return '';
  }

  String? _requestedFolderPath(AgentTask task) {
    try {
      final decoded = jsonDecode(task.executionStateJson);
      if (decoded is! Map) return null;
      final direct = decoded['folderRequestPath'];
      if (direct is String && direct.trim().isNotEmpty) return direct.trim();
      final plan = decoded['approvalPlan'];
      if (plan is Map) {
        final paths = plan['exactPaths'];
        if (paths is List) {
          for (final path in paths) {
            if (path is String && path.trim().isNotEmpty) return path.trim();
          }
        }
      }
    } on Object {
      // Malformed execution metadata cannot safely identify a requested path.
    }
    return const WorkModeDirectoryService().requestedWorkspacePath(
      task.userRequest,
    );
  }

  bool _requiresWritableFolder(AgentTask task) {
    final execution = _decodeExecutionMap(task.executionStateJson);
    // A concrete command can discover a local write only after the model
    // turn. The tool boundary records this marker before pausing so a resumed
    // task selects a writable workspace instead of retrying the old read root.
    if (execution['folderRequiresWritable'] == true) return true;
    final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
    if (pending == null) {
      // The first model turn may only inspect a read-only grant. Request a
      // writable capability up front only when the user's wording clearly
      // requires a mutation; an ambiguous request is revalidated when the
      // concrete tool call exposes its exact path.
      return _requestLikelyMutates(task.userRequest);
    }
    if (pending.tool == AgentToolName.commandRun) {
      // The checkpoint already contains the structured command fields. Make a
      // conservative preflight classification here so a resumed local
      // mutation asks for a writable grant before the runner resolves its
      // workspace. The runner still performs the authoritative policy check;
      // this only decides which capability the native picker should request.
      return _pendingCommandNeedsWritable(pending.args);
    }
    return pending.tool == AgentToolName.workspacePatch ||
        pending.tool == AgentToolName.workspaceRename ||
        pending.tool == AgentToolName.workspaceDelete;
  }
}
