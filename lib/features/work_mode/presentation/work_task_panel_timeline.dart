part of 'work_task_panel.dart';

class _EventStreamError extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _EventStreamError({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: Text('执行动态读取失败：${_safePanelText(error)}')),
            TextButton(
              key: const Key('work-task-event-retry'),
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingPublicOutput extends StatelessWidget {
  final String text;

  const _PendingPublicOutput({this.text = 'AI 正在整理公开进度…'});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const Key('work-task-public-output-pending'),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(text),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  final WorkTaskEvent event;

  const _EventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final title = _safePanelText(event.title);
    final detail = _safePanelText(event.detail);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title),
            if (detail.isNotEmpty && detail != title) ...<Widget>[
              const SizedBox(height: 2),
              Text(detail),
            ],
          ],
        ),
      ),
    );
  }
}

String _publicDraftFromEvent(WorkTaskEvent event) {
  final metadataDraft = event.safeMetadata['publicDraft'];
  if (metadataDraft is String && metadataDraft.trim().isNotEmpty) {
    return metadataDraft;
  }
  // Only model-output events are allowed to use their detail as a draft.
  // Transport diagnostics may carry character counts or other non-display
  // text, which must never replace the public progress card.
  return event.kind == WorkTaskEventKind.modelOutput ? event.detail : '';
}

class _LivePublicOutput extends StatelessWidget {
  final String text;

  const _LivePublicOutput({required this.text});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const Key('work-task-live-output'),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'AI 正在输出公开进度',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colorScheme.onPrimaryContainer,
                  ),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: SelectableText(
                    text,
                    style: TextStyle(color: colorScheme.onPrimaryContainer),
                  ),
                ),
                const SizedBox(width: 2),
                BlinkingCursor(color: colorScheme.onPrimaryContainer),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _safePanelText(String value) {
  var safe = const SearchSecretScanner().redact(
    value.trim(),
    includeOpaqueTokens: true,
  );
  safe = safe.replaceAll(RegExp(r'https?://[^\s,;）)]+'), '[外部地址]');
  safe = safe.replaceAll(
    RegExp(
      r'(?:(?:[A-Za-z]:[\\/])|(?:\\\\|//)|/(?:Users|home|Volumes|private|tmp|var|etc|usr|opt|bin|sbin|Applications|System|Library|Desktop|Documents|Downloads)/)[^\s,;）)]*',
    ),
    '[本地路径]',
  );
  return safe.length <= 4000 ? safe : '${safe.substring(0, 3999)}…';
}

String _artifactNames(Iterable<String> paths) {
  final names = paths
      .map((path) => path.replaceAll('\\', '/').split('/').last.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .take(8)
      .toList(growable: false);
  if (names.isEmpty) return '已生成文件（名称不可用）。';
  final suffix = paths.length > names.length ? ' 等' : '';
  return '${names.join('、')}$suffix（位于当前授权工作目录）';
}

/// Undo confirmation must retain exact local paths so the user can verify the
/// restore/delete scope; only credential-like tokens are redacted here.
String _safeUndoItemText(String value) {
  var safe = const SearchSecretScanner().redact(
    value.trim(),
    includeOpaqueTokens: true,
  );
  return safe.length <= 4000 ? safe : '${safe.substring(0, 3999)}…';
}

bool _isPausedStatus(AgentTaskStatus status) {
  return status == AgentTaskStatus.paused ||
      status == AgentTaskStatus.interrupted;
}

bool _isActiveExecutionStatus(AgentTaskStatus status) {
  return status == AgentTaskStatus.queued ||
      status == AgentTaskStatus.planning ||
      status == AgentTaskStatus.runningTool;
}

WorkFailure? _visibleWorkFailure(AgentTask task) {
  // A queued retry intentionally retains its old failure checkpoint until the
  // runner starts. Do not render that stale diagnostic as a current blocker.
  if (_isActiveExecutionStatus(task.status)) return null;
  return task.workFailure;
}

bool _isStaleRecoveryAction(AgentTask task, WorkTaskEvent? event) {
  return event?.kind == WorkTaskEventKind.paused &&
      _isActiveExecutionStatus(task.status);
}

bool _pendingToolRequiresPlan(AgentTask task) {
  final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
  return pending?.tool == AgentToolName.workspacePatch ||
      pending?.tool == AgentToolName.workspaceRename ||
      pending?.tool == AgentToolName.workspaceDelete;
}

bool _taskNeedsFolderGrant(AgentTask task) {
  if (task.status != AgentTaskStatus.waitingForApproval &&
      task.status != AgentTaskStatus.paused &&
      task.status != AgentTaskStatus.interrupted) {
    return false;
  }
  try {
    final decoded = jsonDecode(task.executionStateJson);
    if (decoded is! Map) return false;
    final path = decoded['folderRequestPath'];
    return decoded['folderGrantPending'] == true ||
        path is String && path.trim().isNotEmpty;
  } on Object {
    return false;
  }
}

bool _taskHasInstallSuggestion(AgentTask task) {
  return WorkFailure.hasInstallableMissingTool(task);
}

bool _taskNeedsVisionModel(AgentTask task) {
  if (task.status != AgentTaskStatus.paused &&
      task.status != AgentTaskStatus.interrupted) {
    return false;
  }
  try {
    final decoded = jsonDecode(task.executionStateJson);
    if (decoded is Map && decoded['visionModelRequired'] == true) return true;
  } on Object {
    // Fall through to the safe user-facing message check below.
  }
  return task.lastError.contains('视觉模型') ||
      task.lastError.toLowerCase().contains('vision model');
}

String? _continueUnavailableReasonForPanel(AgentTask task) {
  if (task.isTerminal) return '任务已结束，无需继续。';
  final discussion = WorkDiscussionState.decodeExecutionState(
    task.executionStateJson,
  );
  // Continuing an invalid checkpoint rebuilds discussion, never execution.
  if (discussion.present &&
      discussion.state == null &&
      _isPausedStatus(task.status)) {
    return null;
  }
  if (_hasPendingGroupDiscussion(task)) {
    return '请先完成群讨论并确定最终执行角色。';
  }
  final isSoftLimitPause =
      task.softLimitReached && _isPausedStatus(task.status);
  if (_taskNeedsVisionModel(task)) return '请先选择支持图片的视觉模型。';
  if (WorkTaskClarification.isPending(task)) return '请先回答上方模型问题。';
  if (_requiresExplicitCommandRequest(task)) {
    return '请发送明确的测试、构建或分析请求后继续。';
  }
  final failure = _visibleWorkFailure(task);
  if (failure != null) {
    if (failure.canContinueAfterRolePermissionUpdate) return null;
    if (failure.canReauthorize) return failure.panelSuggestedAction;
    if (failure.canViewConflict) return failure.panelSuggestedAction;
    if (!isSoftLimitPause && failure.canRetry) {
      return '请先点击“重试”从安全检查点继续。';
    }
    if (failure.canContinue) return null;
  }
  if (isSoftLimitPause) return null;
  if (task.status == AgentTaskStatus.interrupted ||
      task.status == AgentTaskStatus.paused) {
    return null;
  }
  if (task.status == AgentTaskStatus.waitingForApproval) {
    return '请先批准当前操作。';
  }
  return '任务正在执行，无需继续。';
}

bool _hasPendingGroupDiscussion(AgentTask task) {
  if (!task.workModeTask ||
      !WorkDiscussionState.requiresDiscussionForConversation(task.groupId)) {
    return false;
  }
  final discussion = WorkDiscussionState.decodeExecutionState(
    task.executionStateJson,
  );
  return discussion.present &&
      (discussion.state == null || !discussion.state!.isExecutionReady);
}

bool _requiresExplicitCommandRequest(AgentTask task) {
  try {
    final decoded = jsonDecode(task.executionStateJson);
    return decoded is Map && decoded['explicitCommandRequestRequired'] == true;
  } on Object {
    return false;
  }
}

String _durationLabel(AgentTask task, DateTime now) {
  // 面板展示的是"这次尝试跑了多久"。每次执行会重新计时，但 60 分钟预算仍按
  // `startedAt` 计算，两者刻意分开。
  final startedAt = task.attemptStartedAt ?? task.startedAt ?? task.createdAt;
  final duration = now.difference(startedAt);
  if (duration.inMinutes <= 0) return '刚刚开始执行';
  if (duration.inHours > 0) {
    return '已执行 ${duration.inHours} 小时 ${duration.inMinutes.remainder(60)} 分钟';
  }
  return '已执行 ${duration.inMinutes} 分钟';
}

String _statusLabel(AgentTaskStatus status) {
  return switch (status) {
    AgentTaskStatus.queued => '任务正在排队。',
    AgentTaskStatus.planning => '正在规划下一步。',
    AgentTaskStatus.waitingForApproval => '等待你批准当前操作。',
    AgentTaskStatus.runningTool => '正在执行工具。',
    AgentTaskStatus.completed => '任务已完成。',
    AgentTaskStatus.failed => '任务执行失败。',
    AgentTaskStatus.cancelled => '任务已停止。',
    AgentTaskStatus.partiallyCompleted => '任务部分完成。',
    AgentTaskStatus.paused => '任务已暂停，等待继续。',
    AgentTaskStatus.interrupted => '任务已中断，等待继续。',
  };
}
