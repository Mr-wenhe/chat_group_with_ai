part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorDecisions on WorkTaskCoordinator {
  String _v2EventKey(String kind, String value) =>
      '$kind:${sha256.convert(utf8.encode(value)).toString().substring(0, 24)}';

  bool _hasPendingV2Input(AgentTask task) {
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    return decoded.isValid &&
        decoded.state?.collaboration?.taskId == task.id &&
        decoded.state?.collaboration?.pendingInputIds.isNotEmpty == true;
  }

  Future<void> _enqueueV2Input(
    AgentTask task,
    String request, {
    String? sourceMessageId,
    String? attachmentMessageId,
  }) async {
    final state = _v2DecisionState(task);
    final current = state.collaboration!;
    final messageId = sourceMessageId?.trim().isNotEmpty == true
        ? sourceMessageId!.trim()
        : 'input:${task.id}:${current.revision + 1}';
    final eventId = _v2EventKey('input', messageId);
    if (messageId.length > 128) {
      throw StateError('输入消息引用过长。');
    }
    if (current.pendingInputIds.contains(messageId) ||
        current.appliedEventIds.contains(eventId) ||
        current.appliedEventIds.contains(_v2EventKey('apply', messageId))) {
      return;
    }
    final nextJson = current.toJson();
    nextJson['revision'] = current.revision + 1;
    nextJson['pendingInputIds'] = [...current.pendingInputIds, messageId];
    nextJson['appliedEventIds'] = [
      ...current.appliedEventIds
          .skip(current.appliedEventIds.length == 64 ? 1 : 0),
      eventId,
    ];
    final next = WorkCollaborationState.tryParse(nextJson);
    if (next == null) throw StateError('待处理输入队列已满或检查点无效。');
    current.apply(WorkCollaborationUpdate(
      taskId: task.id,
      conversationId: task.groupId,
      expectedRevision: current.revision,
      eventId: eventId,
      sourceRole: 'user',
      sourceId: 'user',
      next: next,
    ));
    final queuedAttachmentIds = _queuedAttachmentMessageIds(
      task.executionStateJson,
      expectedLength: task.queuedUserRequests.length,
    );
    task
      ..queuedUserRequests = [...task.queuedUserRequests, request]
      ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        state.copyWith(collaboration: next),
        expectedCollaborationRevision: current.revision,
      )
      ..updatedAt = _clock();
    task.executionStateJson = _withQueuedAttachmentMessageIds(
      task.executionStateJson,
      [...queuedAttachmentIds, attachmentMessageId?.trim() ?? ''],
    );
    await _save(task);
    await _record(task, WorkTaskEventKind.queued, '已收到执行中补充要求',
        detail: '将在当前不可分割动作完成后的安全检查点处理。');
    if (!isTaskInFlight(task.id)) {
      await _applyPendingV2Inputs(task);
      // 纳入补充要求会把任务推到新的需求版本，但那条路径只写 paused。任务空闲
      // （讨论已经结束、没有在跑的回调）时没有任何角色会再调度它，于是补充要求
      // 落了盘却永远等不到重新讨论。旧讨论入口在同名情形下也这样补一次调度。
      _maybeStartDiscussion(task);
    }
  }

  Future<void> _applyPendingV2Inputs(AgentTask task) async {
    while (true) {
      final state = _v2DecisionState(task);
      final current = state.collaboration!;
      if (current.pendingInputIds.isEmpty) return;
      if (task.queuedUserRequests.isEmpty) {
        throw StateError('待处理输入缺少原文，已停止推进以防丢失。');
      }
      final inputId = current.pendingInputIds.first;
      final request = task.queuedUserRequests.first;
      final queuedAttachmentIds = _queuedAttachmentMessageIds(
        task.executionStateJson,
        expectedLength: task.queuedUserRequests.length,
      );
      final attachmentId = queuedAttachmentIds.first;
      final nextJson = current.toJson();
      final compactRequest =
          request.replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ');
      final mergedScope = '${current.scope}；用户补充要求：$compactRequest'.trim();
      nextJson['scope'] =
          mergedScope.length <= 4096 ? mergedScope : current.scope;
      nextJson['revision'] = current.revision + 1;
      nextJson['requestRevision'] = current.requestRevision + 1;
      nextJson['pendingInputIds'] = current.pendingInputIds.skip(1).toList();
      final eventId = _v2EventKey('apply', inputId);
      nextJson['appliedEventIds'] = [
        ...current.appliedEventIds
            .skip(current.appliedEventIds.length == 64 ? 1 : 0),
        eventId,
      ];
      final next = WorkCollaborationState.tryParse(nextJson);
      if (next == null) throw StateError('补充要求无法形成有效需求版本。');
      current.apply(WorkCollaborationUpdate(
        taskId: task.id,
        conversationId: task.groupId,
        expectedRevision: current.revision,
        eventId: eventId,
        sourceRole: 'user',
        sourceId: 'user',
        next: next,
      ));
      final mergedRequest = '${task.userRequest}\n用户补充要求：$request'.trim();
      task
        ..userRequest = mergedRequest
        ..queuedUserRequests = task.queuedUserRequests.skip(1).toList()
        ..status = AgentTaskStatus.paused
        ..resumeRequired = false
        ..pendingToolRequestJson = ''
        ..lastError = '补充要求已纳入新需求版本，等待受影响部分重新讨论。'
        ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          _withoutApprovalCheckpoint(task.executionStateJson),
          state.copyWith(
            requestRevision: next.requestRevision,
            phase: WorkDiscussionPhase.blocked,
            collaboration: next,
          ),
          expectedCollaborationRevision: current.revision,
        )
        ..updatedAt = _clock();
      _persistAttachmentQueueMetadata(
          task, queuedAttachmentIds.skip(1).toList(),
          currentAttachmentId: attachmentId);
      _conversationReservations.add(task.groupId);
      _refreshTaskContext(task, nextStep: task.lastError);
      await _save(task);
      await _record(task, WorkTaskEventKind.paused, '已按顺序纳入补充要求',
          detail: inputId);
    }
  }

  /// 放弃被停止打断的追加输入时，把它们的待处理引用一起清掉。
  ///
  /// `pendingInputIds` 与 `queuedUserRequests` 是并排的 FIFO：`_applyPendingV2Inputs`
  /// 要求两者同时有值，只剩引用而没有原文时会抛"待处理输入缺少原文"并停住推进，
  /// 任务因此既跑不动也退不出。用户已经在继续时明确放弃这批输入，引用必须一起清。
  ///
  /// 清空整条列表是安全的：能兑现这些引用的原文只可能来自被一起清掉的队列，留下
  /// 任何一条都只会让恢复后的第一轮就撞上那条报错。
  Future<void> _dropAbandonedPendingInputs(AgentTask task) async {
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final state = decoded.state;
    final current = state?.collaboration;
    if (!decoded.isValid ||
        state == null ||
        current == null ||
        current.pendingInputIds.isEmpty) {
      return;
    }
    final eventId = _v2EventKey('dropInputs', '${task.id}:${current.revision}');
    final nextJson = current.toJson()
      ..['revision'] = current.revision + 1
      ..['pendingInputIds'] = <String>[]
      ..['appliedEventIds'] = [
        ...current.appliedEventIds
            .skip(current.appliedEventIds.length == 64 ? 1 : 0),
        eventId,
      ];
    final next = WorkCollaborationState.tryParse(nextJson);
    if (next == null) {
      throw StateError('待处理输入引用无法安全清除，原检查点已保留。');
    }
    // 用户身份落盘：放弃的是用户自己发出的输入。校验走的是统一入口，字段越界
    // 或越权改写会在这里被拒绝，不会写进检查点。
    current.apply(WorkCollaborationUpdate(
      taskId: task.id,
      conversationId: task.groupId,
      expectedRevision: current.revision,
      eventId: eventId,
      sourceRole: 'user',
      sourceId: 'user',
      next: next,
    ));
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      task.executionStateJson,
      state.copyWith(collaboration: next),
      expectedCollaborationRevision: current.revision,
    );
  }

  WorkDiscussionState _v2DecisionState(AgentTask task) {
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final state = decoded.state;
    if (!decoded.isValid ||
        state?.collaboration == null ||
        state!.collaboration!.taskId != task.id ||
        state.collaboration!.conversationId != task.groupId) {
      throw StateError('任务没有有效的 v2 决策状态。');
    }
    return state;
  }

  Future<bool> _implRespondToDecision(
    String taskId, {
    required String decisionId,
    required int revision,
    required String answer,
    String? choiceId,
    required String disposition,
    String? responseMessageId,
  }) =>
      _serialize(() async {
        _ensureOpen();
        final task = _requireWorkTask(taskId);
        if (task.isTerminal) throw StateError('终态任务不能接收决策答复。');
        final state = _v2DecisionState(task);
        final current = state.collaboration!;
        if (responseMessageId?.trim().isNotEmpty == true &&
            current.decisions.any((item) =>
                item['id'] == decisionId &&
                item['responseRef'] == responseMessageId!.trim())) {
          return true;
        }
        final index = current.decisions.indexWhere(
            (item) => item['id'] == decisionId && item['revision'] == revision);
        if (index < 0 ||
            !{'pending', 'deferred'}
                .contains(current.decisions[index]['status'])) {
          throw StateError('决策已更新，请重新打开任务查看最新问题。');
        }
        final original = current.decisions[index];
        final text =
            answer.trim().replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ');
        if (text.isEmpty && choiceId == null && disposition == 'answer') {
          throw StateError('请填写建议或选择方案。');
        }
        if (text.length > 4096) throw StateError('答复过长，请缩短后重试。');
        if (!{'answer', 'defer', 'waive', 'manual'}.contains(disposition)) {
          throw StateError('未知的决策动作。');
        }
        final targetId = original['targetId']?.toString() ?? '';
        if (disposition == 'defer' && targetId.isEmpty) {
          throw StateError('暂缓需要明确指向一个事项。');
        }
        final acceptanceTarget =
            current.acceptances.any((item) => item['id'] == targetId);
        final issueTarget =
            current.issues.any((item) => item['id'] == targetId);
        if ((disposition == 'waive' &&
                    !(original['kind'] == 'acceptance' && acceptanceTarget ||
                        original['kind'] == 'dispute' && issueTarget) ||
                disposition == 'manual' &&
                    !(original['kind'] == 'acceptance' && acceptanceTarget)) ||
            {'waive', 'manual'}.contains(disposition) && text.isEmpty) {
          throw StateError('仅能对指定验收项或异议明确记录豁免／人工结果及依据。');
        }
        final options = original['options'] is List
            ? original['options'] as List
            : const [];
        final selected = options
            .where((item) =>
                item is Map &&
                (item['id'] == choiceId ||
                    choiceId == null &&
                        (item['id'] == text || item['label'] == text)))
            .firstOrNull;
        if (choiceId != null && selected == null) {
          throw StateError('所选方案已失效。');
        }
        final looksLikeDefer = RegExp(
                r'^(先继续|其他先做|先放着|稍后处理|continue|later)[。.!！\s]*$',
                caseSensitive: false)
            .hasMatch(text);
        final deferred = disposition == 'defer' ||
            disposition == 'answer' && looksLikeDefer && targetId.isNotEmpty;
        final noAnswer =
            RegExp(r'^(不清楚|不知道|没想好|待定|再斟酌一下)[。.!！\s]*$').hasMatch(text);
        final unresolved = disposition == 'answer' &&
            !deferred &&
            (looksLikeDefer && targetId.isEmpty ||
                noAnswer && selected == null ||
                selected == null && original['kind'] == 'choice');
        final sourceRef = responseMessageId?.trim().isNotEmpty == true
            ? responseMessageId!.trim()
            : _v2EventKey(
                'decision-response', '$taskId:$decisionId:${revision + 1}');
        if (sourceRef.length > 128) throw StateError('答复引用过长。');
        final nextDecision = <String, dynamic>{
          ...original,
          'revision': revision + 1,
          'status': deferred
              ? 'deferred'
              : disposition == 'waive'
                  ? 'waived'
                  : unresolved
                      ? 'pending'
                      : 'answered',
          'answer': selected is Map ? selected['label'] as String : text,
          'answerKind': disposition == 'manual'
              ? 'manual'
              : disposition == 'waive'
                  ? 'waiver'
                  : selected != null
                      ? 'choice'
                      : 'text',
          'responseRef': sourceRef,
          'missingCondition': unresolved
              ? looksLikeDefer && targetId.isEmpty
                  ? '请明确指出要暂缓的具体事项；“继续”不能作为验收或豁免。'
                  : noAnswer && original['kind'] != 'choice'
                      ? '原问题尚未得到具体条件；这次答复已保存，可补充建议或指定要暂缓的事项。'
                      : '上次建议已保存；仍需从给定方案中明确选择，或补充能解决原问题的条件。'
              : original['missingCondition'] ?? '',
          if (unresolved) 'promptedReminder': 'initial',
        };
        if (!unresolved) nextDecision.remove('promptedReminder');
        final nextJson = current.toJson();
        final decisions =
            current.decisions.map((e) => Map<String, dynamic>.from(e)).toList();
        decisions[index] = nextDecision;
        nextJson['decisions'] = decisions;
        nextJson['revision'] = current.revision + 1;
        nextJson['requestRevision'] = current.requestRevision + 1;
        if (disposition == 'waive' || disposition == 'manual') {
          nextJson['verificationRevision'] = current.verificationRevision + 1;
          if (acceptanceTarget) {
            nextJson['acceptances'] = [
              for (final item in current.acceptances)
                item['id'] == targetId
                    ? {
                        ...item,
                        'status': disposition == 'waive' ? 'waived' : 'manual',
                        'evidenceRef': sourceRef,
                        'requestRevision': current.requestRevision + 1,
                        'verificationRevision':
                            current.verificationRevision + 1,
                      }
                    : item,
            ];
          } else {
            nextJson['issues'] = [
              for (final item in current.issues)
                item['id'] == targetId
                    ? {
                        ...item,
                        'status': 'waived',
                        'resolution': text,
                        'resolutionRef': sourceRef,
                      }
                    : item,
            ];
          }
        }
        if (selected is Map &&
            original['kind'] == 'dispute' &&
            {'reject-idea', 'revise-idea'}.contains(selected['id']) &&
            current.issues
                .any((i) => i['id'] == targetId && i['kind'] == 'idea')) {
          nextJson['verificationRevision'] = current.verificationRevision + 1;
          nextJson['issues'] = [
            for (final issue in current.issues)
              issue['id'] == targetId
                  ? {
                      ...issue,
                      'status':
                          selected['id'] == 'reject-idea' ? 'rejected' : 'open',
                      'resolution': selected['id'] == 'reject-idea'
                          ? nextDecision['answer']
                          : '',
                      'resolutionRef':
                          selected['id'] == 'reject-idea' ? sourceRef : '',
                      'requestRevision': current.requestRevision + 1,
                    }
                  : issue
          ];
        }
        final eventId =
            _v2EventKey('decision', '$taskId:$decisionId:${revision + 1}');
        nextJson['appliedEventIds'] = [
          ...current.appliedEventIds
              .skip(current.appliedEventIds.length == 64 ? 1 : 0),
          eventId,
        ];
        final next = WorkCollaborationState.tryParse(nextJson);
        if (next == null) throw StateError('决策答复无法形成有效检查点。');
        current.apply(WorkCollaborationUpdate(
          taskId: task.id,
          conversationId: task.groupId,
          expectedRevision: current.revision,
          eventId: eventId,
          sourceRole: 'user',
          sourceId: 'user',
          next: next,
        ));
        task
          ..executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
            _withoutApprovalCheckpoint(task.executionStateJson),
            state.copyWith(
              requestRevision: next.requestRevision,
              phase: WorkDiscussionPhase.blocked,
              collaboration: next,
            ),
            expectedCollaborationRevision: current.revision,
          )
          ..status = AgentTaskStatus.paused
          ..resumeRequired = false
          ..pendingToolRequestJson = ''
          ..lastError = unresolved
              ? nextDecision['missingCondition'] as String
              : '用户决策已纳入新需求版本，等待受影响部分重新讨论。'
          ..updatedAt = _clock();
        await _save(task);
        await _record(
            task,
            WorkTaskEventKind.paused,
            unresolved
                ? '已收到建议，仍需明确选择'
                : deferred
                    ? '已暂缓指定事项'
                    : '已收到用户决策',
            detail:
                unresolved ? nextDecision['missingCondition'] as String : '');
        if (!unresolved) _maybeStartDiscussion(task);
        return !unresolved;
      });

  Future<bool> _implMarkDecisionPromptShown(
    String taskId, {
    required String decisionId,
    required int revision,
    required String reminderKind,
  }) =>
      _serialize(() async {
        _ensureOpen();
        final task = _requireWorkTask(taskId);
        if (task.isTerminal) return false;
        final visible = WorkTaskDecision.forTask(task)
            .where((item) =>
                item.id == decisionId &&
                item.revision == revision &&
                item.reminderKind == reminderKind &&
                item.promptedReminder != reminderKind)
            .firstOrNull;
        if (visible == null) return false;
        final state = _v2DecisionState(task);
        final current = state.collaboration!;
        final nextJson = current.toJson();
        nextJson['decisions'] = [
          for (final item in current.decisions)
            item['id'] == decisionId
                ? {...item, 'promptedReminder': reminderKind}
                : item,
        ];
        nextJson['revision'] = current.revision + 1;
        final eventId = _v2EventKey(
            'prompt', '$taskId:$decisionId:$revision:$reminderKind');
        nextJson['appliedEventIds'] = [
          ...current.appliedEventIds
              .skip(current.appliedEventIds.length == 64 ? 1 : 0),
          eventId,
        ];
        final next = WorkCollaborationState.tryParse(nextJson);
        if (next == null) throw StateError('决策提醒检查点无效。');
        current.apply(WorkCollaborationUpdate(
          taskId: task.id,
          conversationId: task.groupId,
          expectedRevision: current.revision,
          eventId: eventId,
          sourceRole: 'system',
          sourceId: 'system',
          next: next,
        ));
        task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          task.executionStateJson,
          state.copyWith(collaboration: next),
          expectedCollaborationRevision: current.revision,
        );
        await _save(task);
        return true;
      });
}
