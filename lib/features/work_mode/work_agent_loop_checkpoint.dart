part of 'work_agent_loop.dart';

extension _WorkAgentLoopCheckpoint on WorkAgentLoop {
  Future<void> _checkpoint(_LoopState state) async {
    final task = state.task;
    if (task.resultSummary.trim().isNotEmpty) {
      task.resultSummary = _checkpointSummary(task.resultSummary);
    }
    final execution = _safeExistingMap(task.executionStateJson);
    execution['schemaVersion'] = 1;
    execution['committedActionKeys'] =
        state.committedActionKeys.take(128).toList(growable: false);
    // Do not carry a raw/legacy tool result forward. The same allow-list used
    // by WorkContextBuilder is the persistence boundary for this diagnostic
    // mirror as well; file bodies are re-read on demand from artifactPaths.
    execution.remove('lastToolResult');
    if (state.recentResults.isNotEmpty) {
      final safeResults = const WorkContextBuilder().build(
        conversationId: task.groupId,
        target: '',
        recentToolResults: [state.recentResults.last],
      ).recentToolResults;
      if (safeResults.isNotEmpty) {
        execution['lastToolResult'] = safeResults.last;
      }
    }
    execution['publicUpdates'] =
        state.publicUpdates.takeLast(20).toList(growable: false);
    if (state.failure != null) {
      execution['workFailure'] = state.failure!.toJson();
    } else {
      execution.remove('workFailure');
    }
    task.executionStateJson = jsonEncode(execution);

    const contextBuilder = WorkContextBuilder();
    final previous = contextBuilder.fromTask(task);
    final completed = <String>[
      ...previous.completedSummaries,
      if (task.resultSummary.trim().isNotEmpty) _publicText(task.resultSummary),
    ];
    task.contextSummary = contextBuilder
        .build(
          conversationId: task.groupId,
          target: previous.target.isEmpty ? task.userRequest : previous.target,
          pendingFollowUps: task.queuedUserRequests,
          completedSummaries: completed,
          recentToolResults: state.recentResults.takeLast(8),
          approvalScope: previous.approvalScope,
          artifactPaths: task.lastArtifactPaths,
          roleHandoff: state.handoff,
          errors: [
            ...previous.errors,
            if (task.lastError.trim().isNotEmpty) _publicText(task.lastError),
            if (state.failure != null)
              _publicText(
                '${state.failure!.title}：${state.failure!.reason} 下一步：${state.failure!.suggestedAction}',
              ),
          ],
          nextStep: task.pendingToolRequestJson.trim().isNotEmpty
              ? '等待当前工具审批或恢复。'
              : state.failure?.suggestedAction ?? '继续执行下一步。',
        )
        .toJsonString();
    task.updatedAt = clock();
    final sink = _taskCheckpointSink ?? onCheckpoint;
    if (sink != null) await sink(task);
    // The coordinator checkpoint sink already persists and publishes the task
    // once. Avoid sending a duplicate update through the progress sink.
    if (_taskCheckpointSink == null) _taskUpdateSink?.call(task);
  }

  String _checkpointSummary(String raw) {
    final safe = _publicText(raw, maximum: 1024).trim();
    if (safe.isEmpty) return '';
    if (raw.length > 512 ||
        safe.contains('```') ||
        RegExp(r'<(!DOCTYPE|html|body)\b|\b(import|class|function)\b|[{};]{3}')
            .hasMatch(safe)) {
      return '文件正文已省略，后续按需重新读取产物。';
    }
    return safe.length <= 512 ? safe : '${safe.substring(0, 511)}…';
  }

  Future<void> _emit(
    _LoopState state,
    WorkTaskEventKind kind,
    String title, {
    String detail = '',
    Map<String, Object?>? safeMetadata,
  }) async {
    final safeTitle = _publicText(title);
    final safeDetail = _publicText(detail);
    final event = await _appendEvent(
      state,
      kind: kind,
      title: safeTitle,
      detail: safeDetail,
      safeMetadata: safeMetadata,
    );
    state.events.add(event);
    try {
      await onEvent?.call(event);
    } on Object {
      // A UI listener is diagnostic only; it cannot change task semantics.
    }
  }

  Future<WorkTaskEvent> _appendEvent(
    _LoopState state, {
    required WorkTaskEventKind kind,
    required String title,
    required String detail,
    required Map<String, Object?>? safeMetadata,
  }) async {
    final store = eventStore;
    if (store != null) {
      try {
        final event = await store.append(
          taskId: state.task.id,
          kind: kind,
          title: title,
          detail: detail,
          progressCurrent: state.task.actionCount,
          progressTotal: _effectiveActionLimit(state.task),
          safeMetadata: safeMetadata,
          timestamp: clock(),
        );
        final current = _localSequences[state.task.id] ?? 0;
        if (event.sequence > current) {
          _localSequences[state.task.id] = event.sequence;
        }
        return event;
      } on Object {
        // Event persistence is diagnostic. Keep the task outcome authoritative
        // and surface the incomplete timeline on the task instead of failing
        // a completed tool action because its log file is unavailable.
        if (!store.appendsSuspendedForDataClear) {
          state.task.eventLogIncomplete = true;
        }
      }
    }
    final nextSequence = (_localSequences[state.task.id] ?? 0) + 1;
    _localSequences[state.task.id] = nextSequence;
    return WorkTaskEvent(
      taskId: state.task.id,
      sequence: nextSequence,
      timestamp: clock(),
      kind: kind,
      title: title,
      detail: detail,
      safeMetadata: safeMetadata,
    );
  }

  Future<void> _delayFor(_LoopState state, int retryNumber) async {
    final index = retryNumber
        .clamp(0, WorkAgentLoop.defaultRetryDelays.length - 1)
        .toInt();
    final delay = sleep(WorkAgentLoop.defaultRetryDelays[index]);
    await Future.any<void>(<Future<void>>[
      delay,
      state.cancellation.whenCancelled,
    ]);
  }

  Map<String, dynamic> _buildContext(_LoopState state) {
    final task = state.task;
    return <String, dynamic>{
      'goal': _publicText(task.userRequest),
      'plan': _publicText(task.plan),
      'resultSummary': _publicText(task.resultSummary),
      'lastError': _publicText(task.lastError),
      if (state.failure != null) 'workFailure': state.failure!.toJson(),
      'actionCount': task.actionCount,
      'actionLimit': _effectiveActionLimit(task),
      'completedActions':
          task.completedOperations.takeLast(32).map(_publicText).toList(),
      'committedWrites': state.committedActionKeys.take(128).toList(),
      'publicUpdates': state.publicUpdates.takeLast(20).toList(),
      // Prefer the ephemeral model view while this process is alive. On a
      // restart it is empty and the redacted persisted results are used.
      'recentToolResults': (state.modelResults.isEmpty
              ? state.recentResults
              : state.modelResults)
          .takeLast(8)
          .toList(),
      'artifacts': List<String>.unmodifiable(task.lastArtifactPaths),
      if (task.pendingToolRequestJson.trim().isNotEmpty)
        'pendingToolRequest':
            _publicText(task.pendingToolRequestJson, maximum: 2000),
      'conversationHistory': state.conversationHistory
          .takeLast(16)
          .map(_safeHistoryMessage)
          .toList(growable: false),
      if (task.contextSummary.trim().isNotEmpty)
        'checkpointSummary': jsonEncode(_safeExistingMap(task.contextSummary)),
    };
  }

  Map<String, String> _safeHistoryMessage(Map<String, dynamic> message) {
    final role = message['role'];
    final content = message['content'];
    return {
      'role': role is String && role.trim().isNotEmpty ? role.trim() : 'user',
      'content': content is String ? _publicText(content, maximum: 1000) : '',
    };
  }

  List<Map<String, dynamic>> _buildMessages(
    AgentTask task,
    Map<String, dynamic> context,
  ) {
    final imageParts = _nativeImageParts(context);
    final promptContext =
        imageParts == null ? context : _replaceImagePayloadsWithMarker(context);
    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': '${systemPrompt.trim()}\n'
            '工作模式只允许输出一个严格 AgentDecision JSON object；'
            'public_update 只能描述公开动作、依据或结论，不得输出思维链。',
      },
      {'role': 'user', 'content': _publicText(task.userRequest)},
      {
        'role': 'system',
        'content': '公开任务检查点：${jsonEncode(promptContext)}',
      },
    ];
    if (imageParts != null) {
      // Image bytes must remain a native content-part message. Embedding the
      // list in the JSON checkpoint would turn it into text and bypass the
      // gateway's vision capability guard.
      messages.add({'role': 'user', 'content': imageParts});
    }
    return messages;
  }

  List<Map<String, dynamic>>? _nativeImageParts(
    Map<String, dynamic> context,
  ) {
    final recent = context['recentToolResults'];
    if (recent is! List) return null;
    for (final rawResult in recent.reversed) {
      if (!_isDocumentImageResult(rawResult)) continue;
      final data = rawResult['data'];
      if (data is! Map || data['content'] is! List) continue;
      final parts = <Map<String, dynamic>>[];
      var hasImage = false;
      for (final rawPart in data['content'] as List) {
        if (rawPart is! Map) continue;
        if (rawPart['type'] == 'text' && rawPart['text'] is String) {
          parts.add({
            'type': 'text',
            'text': _publicText(rawPart['text'] as String, maximum: 12000),
          });
          continue;
        }
        if (rawPart['type'] != 'image_url' || rawPart['image_url'] is! Map) {
          continue;
        }
        final url = (rawPart['image_url'] as Map)['url'];
        if (url is! String ||
            !url.startsWith('data:image/') ||
            url.length > _maxModelImageDataUriChars) {
          continue;
        }
        parts.add({
          'type': 'image_url',
          'image_url': {'url': url},
        });
        hasImage = true;
      }
      if (hasImage) return List<Map<String, dynamic>>.unmodifiable(parts);
    }
    return null;
  }

  Map<String, dynamic> _replaceImagePayloadsWithMarker(
    Map<String, dynamic> context,
  ) {
    final recent = context['recentToolResults'];
    if (recent is! List) return context;
    final replaced = recent.map((rawResult) {
      if (!_isDocumentImageResult(rawResult)) return rawResult;
      final data = rawResult['data'];
      if (data is! Map || !_hasImagePart(data['content'])) return rawResult;
      return <String, dynamic>{
        ...Map<String, dynamic>.from(rawResult),
        'data': <String, dynamic>{
          ...Map<String, dynamic>.from(data),
          'content': '[图片已作为多模态消息附加]',
        },
      };
    }).toList(growable: false);
    return <String, dynamic>{...context, 'recentToolResults': replaced};
  }

  bool _isDocumentImageResult(Object? rawResult) {
    if (rawResult is! Map) return false;
    return rawResult['tool'] == AgentToolName.workspaceDocument.wireName &&
        rawResult['status'] == WorkToolResultStatus.success.name;
  }

  bool _hasImagePart(Object? content) {
    if (content is! List) return false;
    return content.any(
      (part) => part is Map && part['type'] == 'image_url',
    );
  }

  int _effectiveActionLimit(AgentTask task) {
    // A caller may lower the budget for a narrower task, but cannot raise the
    // Stage 03 safety ceiling above 100 actions.
    final ceiling = maxActions < 1
        ? 1
        : maxActions.clamp(1, AgentTask.defaultActionLimit).toInt();
    final configured = task.actionLimit < 1
        ? 1
        : task.actionLimit.clamp(1, AgentTask.defaultActionLimit).toInt();
    return configured > ceiling ? ceiling : configured;
  }

  Duration _effectiveTimeLimit(AgentTask task) {
    final configured = task.softTimeLimit;
    final effective = [
      configured,
      softTimeLimit,
      AgentTask.defaultSoftTimeLimit,
    ].reduce((left, right) => left <= right ? left : right);
    return effective <= Duration.zero
        ? const Duration(milliseconds: 1)
        : effective;
  }

  WorkAgentLoopStatus _statusForTask(AgentTask task) => switch (task.status) {
        AgentTaskStatus.completed => WorkAgentLoopStatus.completed,
        AgentTaskStatus.cancelled => WorkAgentLoopStatus.cancelled,
        AgentTaskStatus.waitingForApproval =>
          WorkAgentLoopStatus.waitingForApproval,
        AgentTaskStatus.paused ||
        AgentTaskStatus.interrupted =>
          WorkAgentLoopStatus.paused,
        _ => WorkAgentLoopStatus.failed,
      };

  WorkAgentLoopResult _result(
    _LoopState state,
    WorkAgentLoopStatus status,
    String message,
  ) {
    return WorkAgentLoopResult(
      status: status,
      message: _publicText(message),
      actionCount: state.task.actionCount,
      retryCount: state.modelRetryCount + state.toolRetryCount,
      modelRetryCount: state.modelRetryCount,
      toolRetryCount: state.toolRetryCount,
      protocolRepairAttempts: state.protocolRepairAttempts,
      pendingToolRequest: state.pendingToolRequest,
      events: List<WorkTaskEvent>.unmodifiable(state.events),
      failure: state.failure,
    );
  }
}
