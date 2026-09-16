part of 'work_task_panel.dart';

class _TaskDetails extends StatefulWidget {
  final AgentTask task;
  final WorkTaskEvent? latestAction;
  final String? toolName;
  final String? actionError;
  final String Function(String characterId)? characterNameFor;
  final WorkTaskEventStream eventStreamFor;
  final ValueChanged<WorkTaskEvent> onLatestEvent;
  final DateTime Function() clock;

  const _TaskDetails({
    required this.task,
    required this.latestAction,
    required this.toolName,
    required this.actionError,
    required this.characterNameFor,
    required this.eventStreamFor,
    required this.onLatestEvent,
    required this.clock,
  });

  @override
  State<_TaskDetails> createState() => _TaskDetailsState();
}

class _TaskDetailsState extends State<_TaskDetails> {
  final ScrollController _detailsScrollController = ScrollController();

  @override
  void dispose() {
    _detailsScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final approvalText =
        widget.task.status == AgentTaskStatus.waitingForApproval
            ? '等待你批准当前操作。'
            : null;
    final failure = _visibleWorkFailure(widget.task);
    // A terminal task may retain the last stepStarted event for its timeline.
    // Do not present that historical action as if it were still running after
    // the durable task status has already become completed/failed/cancelled.
    final displayAction = widget.task.isTerminal
        ? null
        : _isStaleRecoveryAction(widget.task, widget.latestAction)
            ? null
            : widget.latestAction;
    final discussion = WorkDiscussionState.decodeExecutionState(
      widget.task.executionStateJson,
    );
    final discussionState = discussion.state;
    final characterName =
        widget.characterNameFor?.call(widget.task.characterId).trim();
    final discussionExecutorName = discussionState?.executorId == null
        ? null
        : widget.characterNameFor?.call(discussionState!.executorId!).trim();
    final executorLabel = characterName?.isNotEmpty == true
        ? characterName!
        : discussionExecutorName?.isNotEmpty == true
            ? discussionExecutorName!
            : discussionState != null
                ? '待群内推举'
                : widget.task.characterId.trim().isEmpty
                    ? '待确定'
                    : widget.task.characterId;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep the live execution viewport fully inside the panel. Previously
        // it was nested in the summary scroll view, so its lower scrollbar
        // could be clipped by the outer viewport and become unclickable.
        final availableHeight =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 560.0;
        // A discussion reply box can consume most of a short desktop window.
        // Let the live timeline yield space before the panel's action row is
        // pushed outside the Positioned viewport.
        const timelineHeaderHeight = 40.0;
        final timelineHeight = availableHeight < 300
            ? (availableHeight - timelineHeaderHeight)
                .clamp(0.0, 180.0)
                .toDouble()
            : (availableHeight * 0.46).clamp(220.0, 360.0).toDouble();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Scrollbar(
                key: const Key('work-task-details-scrollbar'),
                controller: _detailsScrollController,
                thumbVisibility: true,
                interactive: true,
                child: SingleChildScrollView(
                  controller: _detailsScrollController,
                  primary: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _safePanelText(widget.task.userRequest),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '执行角色：$executorLabel',
                      ),
                      if (discussionState != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          '讨论理解进度：${discussionState.understandingPercent}% · 第${discussionState.round}轮',
                          key: const Key('work-discussion-understanding'),
                        ),
                        if (discussionState
                            .openQuestions.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            '待解决：${discussionState.openQuestions.take(3).join('；')}',
                            key: const Key('work-discussion-open-questions'),
                          ),
                        ],
                      ],
                      const SizedBox(height: 4),
                      // currentStep is the index of the current tool operation
                      // and may intentionally lag behind model decisions. The
                      // user-facing budget must reflect every counted action.
                      Text(
                        '步骤 ${widget.task.actionCount} / ${widget.task.actionLimit}',
                      ),
                      const SizedBox(height: 4),
                      Text(_durationLabel(widget.task, widget.clock())),
                      const SizedBox(height: 12),
                      _PublicDetail(
                        title: '计划摘要',
                        text: widget.task.plan.trim().isEmpty
                            ? '尚未生成公开计划。'
                            : _safePanelText(widget.task.plan),
                      ),
                      const SizedBox(height: 8),
                      _PublicDetail(
                        title: '当前动作',
                        text: displayAction == null
                            ? _statusLabel(widget.task.status)
                            : _safePanelText(displayAction.title),
                        inline: true,
                      ),
                      if (widget.toolName != null) ...<Widget>[
                        const SizedBox(height: 8),
                        _PublicDetail(
                          title: '工具',
                          text: _safePanelText(widget.toolName!),
                          inline: true,
                        ),
                      ],
                      if (approvalText != null) ...<Widget>[
                        const SizedBox(height: 8),
                        _PublicDetail(
                          title: '审批',
                          text: _safePanelText(approvalText),
                          inline: true,
                        ),
                      ],
                      if (widget.task.resultSummary
                          .trim()
                          .isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        _PublicDetail(
                          title: '结论',
                          text: _safePanelText(widget.task.resultSummary),
                        ),
                      ],
                      if (widget.task.lastArtifactPaths.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        _PublicDetail(
                          title: '已生成文件',
                          text: _artifactNames(widget.task.lastArtifactPaths),
                        ),
                      ],
                      if (failure != null) ...<Widget>[
                        const SizedBox(height: 10),
                        _FailureDetails(failure: failure),
                      ],
                      if (widget.task.eventLogIncomplete) ...<Widget>[
                        const SizedBox(height: 8),
                        const _PublicDetail(
                          title: '日志',
                          text: '部分执行动态保存失败，以上日志可能不完整。',
                        ),
                      ],
                      if (widget.actionError != null) ...<Widget>[
                        const SizedBox(height: 8),
                        _PublicDetail(
                          title: '操作失败',
                          text: _safePanelText(widget.actionError!),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '执行动态 · 实时公开输出',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: timelineHeight,
              child: _TaskEventTimeline(
                key: ValueKey<String>(widget.task.id),
                taskId: widget.task.id,
                eventStreamFor: widget.eventStreamFor,
                onLatestEvent: widget.onLatestEvent,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FailureDetails extends StatelessWidget {
  final WorkFailure failure;

  const _FailureDetails({required this.failure});

  @override
  Widget build(BuildContext context) {
    final completed = failure.completedContent;
    return DecoratedBox(
      key: const Key('work-task-failure'),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${_safePanelText(failure.title)} · ${failure.type.name}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            _PublicDetail(
              title: '具体原因',
              text: _safePanelText(failure.reason),
            ),
            const SizedBox(height: 4),
            _PublicDetail(
              title: '技术细节',
              text: _safePanelText(failure.technicalDetail),
            ),
            if (completed.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              _PublicDetail(
                title: '已完成内容',
                text: completed.map(_safePanelText).join('；'),
              ),
            ],
            const SizedBox(height: 4),
            _PublicDetail(
              title: '下一步',
              text: _safePanelText(failure.panelSuggestedAction),
            ),
          ],
        ),
      ),
    );
  }
}
