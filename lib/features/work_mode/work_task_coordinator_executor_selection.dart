part of 'work_task_coordinator.dart';

/// 用户在任务面板里直接指定最终执行人。
///
/// 讨论有权推举，但没有权利替用户决定"我不想等这轮推举"。这条路径刻意独立于
/// `_implConfirmExecutorSwap`：那条路处理的是"合同钉定人 vs 群推举人"的冲突，
/// 必须重开一个请求版本来重新校验；这里只是把**空着**的执行人填上——用户改的是
/// "谁来干"，不是"要干什么"，递增 `requestRevision` 会把已形成的方案与认可全部
/// 作废，为一次选人重跑一整轮讨论。
extension _WorkTaskCoordinatorExecutorSelection on WorkTaskCoordinator {
  Future<void> _implSelectDiscussionExecutor(
    String taskId, {
    required String characterId,
  }) {
    return _serialize(() async {
      _ensureOpen();
      final task = _requireWorkTask(taskId);
      final selectedId = characterId.trim();
      if (task.isTerminal) {
        throw StateError('任务已结束，不能再指定执行人。');
      }
      if (selectedId.isEmpty) {
        throw StateError('没有指定要接手的角色。');
      }
      final decoded = WorkDiscussionState.decodeExecutionState(
        task.executionStateJson,
      );
      final state = decoded.state;
      if (!decoded.isValid || state == null) {
        throw StateError('讨论状态已失效，不能指定执行人。');
      }
      if ((state.executorId ?? '').trim().isNotEmpty) {
        throw StateError('本任务已经有执行人，不能重复指定。');
      }
      // 候选列表是 S1 按当前群成员与职业资格算出来的，面板不能凭空造一个资格：
      // 不在候选里的人只能先补进群，再让讨论重新判定。
      if (!state.candidateCharacterIds.contains(selectedId)) {
        throw StateError('该角色不在本任务的合格候选内，请先在群内补充合格的执行角色。');
      }
      // 方案已进入制作/审查之后再换人，工作项归属和已冻结的候选会对不上；那时该
      // 交给讨论或换人确认流程，不走这条"把空位填上"的路。
      final collaboration = state.collaboration;
      if (collaboration != null &&
          collaboration.phase != 'forming' &&
          collaboration.phase != 'clarifying') {
        throw StateError('任务已进入制作阶段，不能在此时更换执行人。');
      }
      _discussionCancellations[taskId]?.cancel();
      final next = state.copyWith(
        // 停在"等执行人"或"阻塞"上的状态在用户给出执行人后重新可跑；其它 blockers
        // 原样保留（legacy 的恢复门禁看的就是这份列表），所以这里不是解阻塞。
        phase: state.phase == WorkDiscussionPhase.blocked ||
                state.phase == WorkDiscussionPhase.awaitingExecutor
            ? WorkDiscussionPhase.awaitingDiscussion
            : state.phase,
        executorId: selectedId,
        coordinatorId: selectedId,
        blockers: state.blockers.where(
          (blocker) => blocker != 'executorSelectionRequired',
        ),
        // 用户点选是一次明确表态（与 `@` 路径同性质），所以写钉定：讨论不再自行
        // 改派，出现不一致时走既有的执行人确认框。
        deliverableContract: <String, dynamic>{
          ...?state.deliverableContract,
          'explicitExecutorId': selectedId,
        },
        collaboration: collaboration == null
            ? null
            : WorkCollaborationState.tryParse(collaboration.toJson()
              ..['revision'] = collaboration.revision + 1),
      );
      final nextJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        next,
        expectedCollaborationRevision: collaboration?.revision,
      );
      final needsConfirmation = WorkTaskRequirementsConfirmation.hasMarker(
          task.executionStateJson);
      task
        ..characterId = selectedId
        ..assignedCharacterIds = <String>{
          ...task.assignedCharacterIds,
          selectedId,
        }.toList(growable: false)
        ..status = AgentTaskStatus.paused
        ..resumeRequired = false
        ..lastError = '执行人已由用户指定，正在重新校验群讨论执行门禁。'
        ..executionStateJson = nextJson
        ..updatedAt = _clock();
      if (needsConfirmation) {
        WorkTaskRequirementsConfirmation.requireForCurrentRequest(task);
      }
      await _save(task);
      await _record(
        task,
        WorkTaskEventKind.queued,
        '用户指定最终执行人',
      );
      _maybeStartDiscussion(task);
    });
  }
}
