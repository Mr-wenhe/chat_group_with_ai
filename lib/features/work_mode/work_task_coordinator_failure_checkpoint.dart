part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorFailureCheckpoint on WorkTaskCoordinator {
  Future<void> _checkpointFromRunner(AgentTask task) async {
    if (_disposed || _dataClearInProgress || task.isTerminal) return;
    await _serialize(() async {
      final running = _running[task.id];
      if (_disposed ||
          _dataClearInProgress ||
          task.isTerminal ||
          running == null ||
          !identical(running.task, task) ||
          running.cancellation.isCancelled) {
        return;
      }
      await _save(task);
    });
  }

  void _refreshTaskContext(
    AgentTask task, {
    String? nextStep,
    Iterable<String> extraErrors = const [],
    bool clearRecentToolResults = false,
    bool resetTargetAndArtifacts = false,
  }) {
    final raw = task.contextSummary.trim();
    if (raw.isNotEmpty && !_isTask15Context(raw, task.groupId)) {
      if (_hasForeignConversationContext(raw, task.groupId) ||
          resetTargetAndArtifacts) {
        // A checkpoint carrying another conversation id is never a legacy
        // summary. A new artifact also needs a fresh target even when the
        // legacy summary belongs to this conversation; otherwise its old
        // target can steer the new run back to the previous file.
        final discussionState =
            WorkDiscussionState.fromExecutionState(task.executionStateJson);
        task.contextSummary = _contextBuilder
            .build(
              conversationId: task.groupId,
              target: task.userRequest,
              pendingFollowUps: task.queuedUserRequests,
              completedSummaries: task.resultSummary.trim().isEmpty
                  ? const []
                  : [task.resultSummary],
              artifactPaths: task.lastArtifactPaths,
              discussionState: discussionState,
              errors:
                  task.lastError.trim().isEmpty ? const [] : [task.lastError],
              nextStep: nextStep ?? '',
            )
            .toJsonString();
      }
      // Keep older Stage 02 summaries byte-for-byte compatible. The durable
      // AgentTask queue/artifact fields still carry the new state, and a
      // subsequent Task 15 checkpoint will migrate it through the builder.
      return;
    }
    final previous = raw.isEmpty
        ? WorkContextSnapshot(conversationId: task.groupId)
        : _contextBuilder.fromTask(task);
    final errors = _uniqueStrings(<String>[
      ...previous.errors,
      ...extraErrors,
      if (task.lastError.trim().isNotEmpty) task.lastError,
    ]);
    final completed = _uniqueStrings(<String>[
      ...previous.completedSummaries,
      if (task.resultSummary.trim().isNotEmpty) task.resultSummary,
    ]);
    final execution = _decodeExecutionMap(task.executionStateJson);
    final discussionState = previous.discussionState ??
        WorkDiscussionState.fromExecutionState(task.executionStateJson);
    final approvalScope = previous.approvalScope ??
        (execution['approvalScope'] is Map
            ? Map<String, dynamic>.from(execution['approvalScope'] as Map)
            : null);
    task.contextSummary = _contextBuilder
        .build(
          conversationId: task.groupId,
          target: resetTargetAndArtifacts || previous.target.isEmpty
              ? task.userRequest
              : previous.target,
          pendingFollowUps: task.queuedUserRequests,
          completedSummaries: completed,
          // Tool results describe the previous execution run. Keep the
          // durable summary/artifacts for continuity, but do not let a
          // follow-up satisfy a new tool request with stale output.
          recentToolResults:
              clearRecentToolResults ? const [] : previous.recentToolResults,
          approvalScope: approvalScope,
          artifactPaths: resetTargetAndArtifacts
              ? task.lastArtifactPaths
              : <String>[...previous.artifactPaths, ...task.lastArtifactPaths],
          roleHandoff: previous.roleHandoff,
          discussionState: discussionState,
          errors: errors,
          nextStep: nextStep ?? previous.nextStep,
        )
        .toJsonString();
  }

  List<String> _uniqueStrings(Iterable<String> values) {
    final seen = <String>{};
    return values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && seen.add(value))
        .toList(growable: false);
  }

  bool _isTask15Context(String raw, String conversationId) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map &&
          decoded['conversationId'] == conversationId &&
          decoded.containsKey('pendingFollowUps');
    } on Object {
      return false;
    }
  }

  bool _hasForeignConversationContext(String raw, String conversationId) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map &&
          decoded['conversationId'] is String &&
          decoded['conversationId'] != conversationId;
    } on Object {
      return false;
    }
  }

  bool _isFollowUpClarification(AgentTask task) {
    final execution = _decodeExecutionMap(task.executionStateJson);
    return execution['followUpKind'] == WorkFollowUpKind.clarification.name &&
        execution['clarificationQuestion'] is String;
  }

  bool _requiresExplicitCommandRequest(AgentTask task) {
    return _decodeExecutionMap(
            task.executionStateJson)['explicitCommandRequestRequired'] ==
        true;
  }

  bool _requiresMissingToolAction(AgentTask task) {
    return _decodeExecutionMap(task.executionStateJson)['toolMissing'] == true;
  }

  bool _requiresVisionModelSelection(AgentTask task) {
    return _decodeExecutionMap(
            task.executionStateJson)['visionModelRequired'] ==
        true;
  }

  bool _folderPending(AgentTask task, Map<String, dynamic> execution) {
    if (task.isTerminal) return false;
    return execution['folderGrantPending'] == true ||
        (execution['folderRequestPath'] is String &&
            (task.status == AgentTaskStatus.paused ||
                task.status == AgentTaskStatus.interrupted ||
                task.status == AgentTaskStatus.waitingForApproval));
  }

  Map<String, dynamic> _decodeExecutionMap(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, dynamic>{};
      // Keep every string-keyed checkpoint entry even when an old/hand-written
      // payload also contains a non-string key. Dropping the discussion marker
      // while updating an unrelated field would turn a malformed checkpoint
      // into a legacy task that can bypass the execution gate.
      return <String, dynamic>{
        for (final entry in decoded.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
    } on Object {
      return <String, dynamic>{};
    }
  }

  List<String> _queuedAttachmentMessageIds(
    String raw, {
    required int expectedLength,
  }) {
    final value = _decodeExecutionMap(raw)['queuedAttachmentMessageIds'];
    final ids = value is List
        ? value
            .map((item) => item is String ? item.trim() : '')
            .toList(growable: true)
        : <String>[];
    if (ids.length > expectedLength) {
      ids.removeRange(expectedLength, ids.length);
    }
    while (ids.length < expectedLength) {
      ids.add('');
    }
    return ids;
  }

  String _withQueuedAttachmentMessageIds(
    String raw,
    List<String> ids,
  ) {
    final metadata = _decodeExecutionMap(raw);
    final normalized = ids.map((id) => id.trim()).toList(growable: false);
    if (normalized.any((id) => id.isNotEmpty)) {
      metadata['queuedAttachmentMessageIds'] = normalized;
    } else {
      metadata.remove('queuedAttachmentMessageIds');
    }
    return metadata.isEmpty ? '' : jsonEncode(metadata);
  }

  String _withDiscussionAttachmentMetadata(
    String raw,
    String? attachmentMessageId,
  ) {
    final metadata = _decodeExecutionMap(raw);
    final id = attachmentMessageId?.trim() ?? '';
    if (id.isNotEmpty) {
      final existing = metadata['discussionAttachmentMessageIds'] is List
          ? (metadata['discussionAttachmentMessageIds'] as List)
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(growable: true)
          : <String>[];
      final previousCurrent = metadata['attachmentMessageId'];
      if (previousCurrent is String &&
          previousCurrent.trim().isNotEmpty &&
          !existing.contains(previousCurrent.trim())) {
        existing.add(previousCurrent.trim());
      }
      if (!existing.contains(id)) existing.add(id);
      metadata['attachmentMessageId'] = id;
      metadata['discussionAttachmentMessageIds'] = existing.take(32).toList();
    }
    return metadata.isEmpty ? '' : jsonEncode(metadata);
  }

  void _persistAttachmentQueueMetadata(
    AgentTask task,
    List<String> queuedIds, {
    required String? currentAttachmentId,
  }) {
    final metadata = _decodeExecutionMap(task.executionStateJson)
      ..remove('attachmentMessageId')
      ..remove('queuedAttachmentMessageIds');
    final current = currentAttachmentId?.trim();
    if (current != null && current.isNotEmpty) {
      metadata['attachmentMessageId'] = current;
    }
    final normalized = queuedIds.map((id) => id.trim()).toList(growable: false);
    if (normalized.any((id) => id.isNotEmpty)) {
      metadata['queuedAttachmentMessageIds'] = normalized;
    }
    task.executionStateJson = metadata.isEmpty ? '' : jsonEncode(metadata);
  }

  String _withFollowUpDecision(
    String raw,
    WorkFollowUpDecision decision,
  ) {
    final metadata = _decodeExecutionMap(raw)
      ..['followUpKind'] = decision.kind.name
      ..['followUpReason'] = decision.reason;
    if (decision.artifactPath != null) {
      metadata['revisionTargetPath'] = decision.artifactPath;
    } else {
      metadata.remove('revisionTargetPath');
    }
    metadata['autoRenameIfExists'] = decision.autoRenameIfExists;
    if (decision.clarificationQuestion != null) {
      metadata['clarificationQuestion'] = decision.clarificationQuestion;
    } else {
      metadata.remove('clarificationQuestion');
    }
    return jsonEncode(metadata);
  }

  String _withoutFollowUpDecision(String raw) {
    final metadata = _decodeExecutionMap(raw)
      ..remove('followUpKind')
      ..remove('followUpReason')
      ..remove('revisionTargetPath')
      ..remove('autoRenameIfExists')
      ..remove('clarificationQuestion');
    return metadata.isEmpty ? '' : jsonEncode(metadata);
  }

  bool _followUpChangesApprovalScope(WorkFollowUpDecision decision) =>
      decision.kind == WorkFollowUpKind.newArtifact ||
      decision.kind == WorkFollowUpKind.reviseArtifact ||
      decision.kind == WorkFollowUpKind.clarification;

  void _publish(AgentTask task) {
    if (!_disposed) _taskUpdates.add(task);
  }

  /// Progress callbacks originate from the in-process runner and may arrive
  /// after [stop] has committed cancellation. Keep them behind the same
  /// identity/cancellation check as checkpoint writes so a late UI update
  /// cannot project a stale runner as the current task.
  void _publishFromRunner(AgentTask task) {
    if (_disposed || task.isTerminal) return;
    final stored = _taskBox.get(task.id);
    // Lightweight embedders may exercise the progress sink before submitting
    // a task; retain that compatibility. Once a task is durable, callbacks
    // must prove ownership of the current in-process run.
    if (stored == null) {
      _publish(task);
      return;
    }
    final running = _running[task.id];
    if (running == null ||
        !identical(running.task, task) ||
        running.cancellation.isCancelled) {
      return;
    }
    _publish(task);
  }

  List<AgentTask> _allWorkTasks() {
    final tasks = _taskBox.values.where((task) => task.workModeTask).toList();
    tasks.sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return List<AgentTask>.unmodifiable(tasks);
  }

  Future<void> _record(
    AgentTask task,
    WorkTaskEventKind kind,
    String title, {
    String detail = '',
  }) async {
    // Data clear owns a hard lifecycle barrier. Late runner callbacks must not
    // recreate event files after the clear has removed the app-managed tree.
    if (_disposed || _dataClearInProgress) return;
    try {
      await _eventStore.append(
        taskId: task.id,
        kind: kind,
        title: title,
        detail: detail,
      );
    } on Object catch (error) {
      // Event persistence is diagnostic only; never replace a valid task
      // outcome with a logging exception. The durable flag tells the panel
      // that the timeline may have gaps.
      if (_disposed ||
          _dataClearInProgress ||
          _eventStore.appendsSuspendedForDataClear ||
          task.eventLogIncomplete) {
        return;
      }
      task.eventLogIncomplete = true;
      if (task.lastError.isEmpty) {
        task.lastError = '任务日志保存不完整：${sanitizeWorkTaskError(error)}';
      }
      try {
        await _taskBox.put(task.id, task);
        _publish(task);
      } on Object {
        // The database may already be closing. The task outcome must remain
        // authoritative even when there is no storage left for this flag.
      }
    }
  }

  Future<void> _markSnapshotStatus(AgentTask task) async {
    if (_dataClearInProgress) return;
    final updater = _snapshotStatusUpdater;
    if (updater == null) return;
    final status = switch (task.status) {
      AgentTaskStatus.completed => WorkSnapshotTaskStatus.completed,
      AgentTaskStatus.failed => WorkSnapshotTaskStatus.failed,
      AgentTaskStatus.cancelled => WorkSnapshotTaskStatus.cancelled,
      AgentTaskStatus.partiallyCompleted =>
        WorkSnapshotTaskStatus.partiallyCompleted,
      _ => WorkSnapshotTaskStatus.active,
    };
    try {
      await updater(task.id, status);
    } on Object {
      // Snapshot bookkeeping must not turn a valid task checkpoint into a
      // failed run. The next cleanup pass can retry this metadata update.
    }
  }
}
