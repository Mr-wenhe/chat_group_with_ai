part of 'work_task_panel.dart';

class _EventStreamError extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  final bool singleLine;

  const _EventStreamError({
    required this.error,
    required this.onRetry,
    this.singleLine = false,
  });

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
            Icon(
              Icons.cloud_off_rounded,
              size: 15,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '执行动态读取失败：${_safePanelText(error)}',
                maxLines: singleLine ? 1 : null,
                overflow: singleLine ? TextOverflow.ellipsis : null,
              ),
            ),
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
  final bool singleLine;

  const _PendingPublicOutput({
    this.text = 'AI 正在整理公开进度…',
    this.singleLine = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const Key('work-task-public-output-pending'),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              Icons.hourglass_top_rounded,
              size: 15,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                maxLines: singleLine ? 1 : null,
                overflow: singleLine ? TextOverflow.ellipsis : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  final WorkTaskEvent event;

  /// 折叠态只占一行：标题超长省略，详情整行不渲染。展开态完整显示。
  final bool singleLine;

  const _EventCard({required this.event, this.singleLine = false});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tone = _eventTone(context, event.kind);
    final title = _safePanelText(event.title);
    final detail = _safePanelText(event.detail);
    // 左侧竖条用 ClipRRect 裁圆角，而不是给非均匀 Border 直接加 borderRadius：
    // `BoxDecoration` 在边框各边宽度不等时会断言"圆角只允许均匀边框"。
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          border: Border(left: BorderSide(color: tone, width: 3)),
        ),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(_eventIcon(event.kind), size: 15, color: tone),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          title,
                          maxLines: singleLine ? 1 : null,
                          overflow: singleLine ? TextOverflow.ellipsis : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _eventTimeLabel(event.timestamp),
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  if (!singleLine && detail.isNotEmpty && detail != title)
                    ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 事件时间只取到分钟；`WorkTaskEvent.timestamp` 存的是 UTC，展示前必须转本地。
String _eventTimeLabel(DateTime timestamp) {
  final local = timestamp.toLocal();
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${pad(local.hour)}:${pad(local.minute)}';
}

IconData _eventIcon(WorkTaskEventKind kind) {
  return switch (kind) {
    WorkTaskEventKind.queued => Icons.schedule_rounded,
    WorkTaskEventKind.planning => Icons.auto_awesome_rounded,
    WorkTaskEventKind.stepStarted => Icons.play_arrow_rounded,
    WorkTaskEventKind.toolOutput => Icons.terminal_rounded,
    WorkTaskEventKind.approvalRequired => Icons.gavel_rounded,
    WorkTaskEventKind.paused => Icons.pause_circle_outline_rounded,
    WorkTaskEventKind.stepCompleted => Icons.check_circle_outline_rounded,
    WorkTaskEventKind.failed => Icons.error_outline_rounded,
    WorkTaskEventKind.completed => Icons.task_alt_rounded,
    WorkTaskEventKind.undoCompleted => Icons.undo_rounded,
    WorkTaskEventKind.modelOutput => Icons.auto_awesome_rounded,
  };
}

Color _eventTone(BuildContext context, WorkTaskEventKind kind) {
  final colors = Theme.of(context).colorScheme;
  final semantic = AppSemanticColors.of(context);
  return switch (kind) {
    WorkTaskEventKind.completed ||
    WorkTaskEventKind.stepCompleted ||
    WorkTaskEventKind.undoCompleted =>
      semantic.success,
    WorkTaskEventKind.failed => colors.error,
    WorkTaskEventKind.approvalRequired => colors.tertiary,
    WorkTaskEventKind.paused => colors.secondary,
    WorkTaskEventKind.toolOutput || WorkTaskEventKind.modelOutput =>
      colors.onSurfaceVariant,
    WorkTaskEventKind.queued ||
    WorkTaskEventKind.planning ||
    WorkTaskEventKind.stepStarted =>
      colors.primary,
  };
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

  /// 折叠态把流式正文压成一行，避免正在生成的长文把面板撑高。
  final bool singleLine;

  const _LivePublicOutput({required this.text, this.singleLine = false});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bodyStyle = TextStyle(color: colorScheme.onPrimaryContainer);
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
            Row(
              children: <Widget>[
                Icon(
                  Icons.bolt_rounded,
                  size: 15,
                  color: colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 6),
                Text(
                  'AI 正在输出公开进度',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colorScheme.onPrimaryContainer,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  // SelectableText 没有 overflow 参数，maxLines: 1 只会硬裁掉
                  // 不给省略号。折叠态改用普通 Text，保证"超长以…结尾"。
                  child: singleLine
                      ? Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: bodyStyle,
                        )
                      : SelectableText(text, style: bodyStyle),
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
  // 追问澄清同样在等用户输入：让"继续"当场可见地不可用，而不是点下去才报错。
  if (WorkTaskClarification.isFollowUpPending(task)) {
    return '请先在上方明确要修订哪一个文件。';
  }
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

/// 任务还在推进时，面板上的"已执行"才继续走表。
///
/// 完成 / 失败 / 停止 / 部分完成是结束，暂停 / 中断是停手，这些状态都必须停止
/// 计时，否则任务早就不动了，面板上的数字还在往上涨。
/// 等待审批仍算进行中：批准后不会重置 [AgentTask.attemptStartedAt]，此处若冻结
/// 再恢复，耗时会一次性跳掉整段等待时间。
bool _isDurationTicking(AgentTaskStatus status) =>
    _isActiveExecutionStatus(status) ||
    status == AgentTaskStatus.waitingForApproval;

String _durationLabel(AgentTask task, DateTime now) {
  // 面板展示的是"这次尝试跑了多久"。每次执行会重新计时，但 60 分钟预算仍按
  // `startedAt` 计算，两者刻意分开。
  final startedAt = task.attemptStartedAt ?? task.startedAt ?? task.createdAt;
  // 停下来的任务用最后一次状态变更的时间封口：`updatedAt` 随每次状态切换刷新，
  // 正好落在它停手的那一刻。后续的追问/重跑会重置 `attemptStartedAt`，重新归零。
  final endAt =
      _isDurationTicking(task.status) ? now : (task.updatedAt ?? now);
  final duration = endAt.difference(startedAt);
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
