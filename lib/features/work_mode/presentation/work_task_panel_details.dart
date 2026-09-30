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

  /// 执行细节卡默认只露「当前动作」，点「详情」才展开计划摘要/工具/结论等。
  bool _detailsExpanded = false;

  /// 执行动态默认只露最近两条（每条一行），点「详情」才展开完整时间线。
  bool _timelineExpanded = false;

  /// 上半区（任务需求 → 执行细节）的固定高度区间。
  ///
  /// 给上半区一个固定高度后，点开「执行细节」只会在这块区域内部出现滚动条，
  /// 不会再向下挤压「执行动态」；面板总高度也就恒定不变。
  /// 上限取 400：折叠态三张卡片（任务需求 / 运行状态 / 执行细节）的实际高度
  /// 大约 330~400，给足这个值默认打开就不需要滚动。
  static const double _detailsRegionMinHeight = 120.0;
  static const double _detailsRegionMaxHeight = 400.0;

  /// 上半区与「执行动态」之间的固定间距。
  static const double _sectionGap = 14.0;

  /// 「执行动态」标题行的固定高度（文字实际约 24，留一点余量）。
  static const double _timelineHeaderHeight = 28.0;

  /// 标题行与动态列表之间的固定间距。
  static const double _timelineHeaderGap = 6.0;

  /// 折叠态一条单行动态的标称高度（卡片 36 + 条目间距 6），留 2px 余量。
  static const double _collapsedTimelineRowHeight = 44.0;

  /// 折叠态最多展示几条动态（和展开态一屏能看到的条数保持一致）。
  static const int _maxCollapsedTimelineRows = 4;

  /// 低于这个高度就整块收起「执行动态」，先保住上半区（够放两条单行动态）。
  static const double _minTimelineListHeight = 88.0;

  @override
  void didUpdateWidget(covariant _TaskDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id == widget.task.id) return;
    // 切到另一个任务后回到折叠态，避免上一个任务的展开状态残留。
    _detailsExpanded = false;
    _timelineExpanded = false;
  }

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
    final colors = Theme.of(context).colorScheme;
    final hintStyle = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    // 进度条必须始终拿到确定值：value 为 null 时 LinearProgressIndicator 会
    // 无限 repeat，测试里的 pumpAndSettle 会因此超时。
    final progress = widget.task.actionLimit <= 0
        ? 0.0
        : (widget.task.actionCount / widget.task.actionLimit)
            .clamp(0.0, 1.0)
            .toDouble();
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep the live execution viewport fully inside the panel. Previously
        // it was nested in the summary scroll view, so its lower scrollbar
        // could be clipped by the outer viewport and become unclickable.
        final availableHeight =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 560.0;
        // 上下半区各自固定高度，展开只让区域内的内容铺开并出现滚动条，
        // 互不挤压、面板总高度恒定。
        //
        // 上半区优先：先把「折叠态三张卡片不用滚动就能看全」所需的高度分给它
        // （最多 _detailsRegionMaxHeight），余下的才留给「执行动态」。
        // 窗口矮到连两条单行动态都放不下（minTimelineRegionHeight 判定）时
        // 整块收起执行动态，全力保住上半区。
        const minTimelineRegionHeight =
            _timelineHeaderHeight + _timelineHeaderGap + _minTimelineListHeight;
        final showTimeline = availableHeight >=
            _detailsRegionMinHeight + _sectionGap + minTimelineRegionHeight;
        final detailsRegionHeight = showTimeline
            ? (availableHeight - _sectionGap - minTimelineRegionHeight)
                .clamp(_detailsRegionMinHeight, _detailsRegionMaxHeight)
                .toDouble()
            : availableHeight;
        final timelineListHeight = showTimeline
            ? (availableHeight -
                    detailsRegionHeight -
                    _sectionGap -
                    _timelineHeaderHeight -
                    _timelineHeaderGap)
                .clamp(0.0, double.infinity)
                .toDouble()
            : 0.0;
        // 折叠态每条动态只占一行：按区域高度算出能完整放下几条，
        // 避免固定条数被 SizedBox 静默裁掉半张卡片。
        final collapsedTimelineRows = showTimeline
            ? (timelineListHeight / _collapsedTimelineRowHeight)
                .floor()
                .clamp(1, _maxCollapsedTimelineRows)
                .toInt()
            : 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: detailsRegionHeight,
              child: _ConditionalScrollbar(
                enabled: _detailsExpanded,
                scrollbarKey: const Key('work-task-details-scrollbar'),
                controller: _detailsScrollController,
                child: SingleChildScrollView(
                  controller: _detailsScrollController,
                  primary: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _PanelCard(
                        title: '任务需求',
                        icon: Icons.description_outlined,
                        child: Text(
                          _safePanelText(widget.task.userRequest),
                          key: const Key('work-task-request'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _PanelCard(
                        title: '运行状态',
                        icon: Icons.monitor_heart_outlined,
                        trailing: _StatusBadge(status: widget.task.status),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('执行角色：$executorLabel'),
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
                                  key: const Key(
                                    'work-discussion-open-questions',
                                  ),
                                ),
                              ],
                            ],
                            const SizedBox(height: 10),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 6,
                                      backgroundColor:
                                          colors.surfaceContainerHighest,
                                      color: colors.primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                // currentStep is the index of the current tool
                                // operation and may intentionally lag behind
                                // model decisions. The user-facing budget must
                                // reflect every counted action.
                                Text(
                                  '步骤 ${widget.task.actionCount} / ${widget.task.actionLimit}',
                                  style: hintStyle,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _durationLabel(widget.task, widget.clock()),
                              style: hintStyle,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      _PanelCard(
                        title: '执行细节',
                        icon: Icons.list_alt_rounded,
                        trailing: _PanelToggleButton(
                          toggleKey: const Key('work-task-details-toggle'),
                          expanded: _detailsExpanded,
                          onPressed: () => setState(
                            () => _detailsExpanded = !_detailsExpanded,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            // 折叠态只留「当前动作」一行，展开后才补齐计划摘要
                            // 与结论等完整信息。
                            if (_detailsExpanded) ...<Widget>[
                              _PublicDetail(
                                title: '计划摘要',
                                text: widget.task.plan.trim().isEmpty
                                    ? '尚未生成公开计划。'
                                    : _safePanelText(widget.task.plan),
                              ),
                              const SizedBox(height: 8),
                            ],
                            _PublicDetail(
                              title: '当前动作',
                              text: displayAction == null
                                  ? _statusLabel(widget.task.status)
                                  : _safePanelText(displayAction.title),
                              inline: true,
                            ),
                            if (_detailsExpanded &&
                                widget.toolName != null) ...<Widget>[
                              const SizedBox(height: 8),
                              _PublicDetail(
                                title: '工具',
                                text: _safePanelText(widget.toolName!),
                                inline: true,
                              ),
                            ],
                            if (_detailsExpanded &&
                                approvalText != null) ...<Widget>[
                              const SizedBox(height: 8),
                              _PublicDetail(
                                title: '审批',
                                text: _safePanelText(approvalText),
                                inline: true,
                              ),
                            ],
                            if (_detailsExpanded &&
                                widget.task.resultSummary
                                    .trim()
                                    .isNotEmpty) ...<Widget>[
                              const SizedBox(height: 8),
                              _PublicDetail(
                                title: '结论',
                                text: _safePanelText(widget.task.resultSummary),
                              ),
                            ],
                            if (_detailsExpanded &&
                                widget.task.lastArtifactPaths
                                    .isNotEmpty) ...<Widget>[
                              const SizedBox(height: 8),
                              _PublicDetail(
                                title: '已生成文件',
                                text: _artifactNames(
                                  widget.task.lastArtifactPaths,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (failure != null) ...<Widget>[
                        const SizedBox(height: 10),
                        _FailureDetails(failure: failure),
                      ],
                      if (widget.task.eventLogIncomplete ||
                          widget.actionError != null) ...<Widget>[
                        const SizedBox(height: 10),
                        _PanelCard(
                          title: '异常与日志',
                          icon: Icons.report_gmailerrorred_outlined,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (widget.task.eventLogIncomplete)
                                const _PublicDetail(
                                  title: '日志',
                                  text: '部分执行动态保存失败，以上日志可能不完整。',
                                ),
                              if (widget.task.eventLogIncomplete &&
                                  widget.actionError != null)
                                const SizedBox(height: 8),
                              if (widget.actionError != null)
                                _PublicDetail(
                                  title: '操作失败',
                                  text: _safePanelText(widget.actionError!),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (showTimeline) ...<Widget>[
              const SizedBox(height: _sectionGap),
              SizedBox(
                height: _timelineHeaderHeight,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '执行动态 · 实时公开输出',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    _PanelToggleButton(
                      toggleKey: const Key('work-task-timeline-toggle'),
                      expanded: _timelineExpanded,
                      onPressed: () => setState(
                        () => _timelineExpanded = !_timelineExpanded,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: _timelineHeaderGap),
              // 保持 SizedBox > _TaskEventTimeline 这一层级不变，只调高度数值，
              // 避免展开/折叠时重建时间线的 State（事件流不重放历史）。
              // 高度固定 => 展开只是让动态铺满这块区域并在内部滚动，
              // 不会再向上挤压上半区或改变面板总高。
              SizedBox(
                height: timelineListHeight,
                child: _TaskEventTimeline(
                  key: ValueKey<String>(widget.task.id),
                  taskId: widget.task.id,
                  eventStreamFor: widget.eventStreamFor,
                  onLatestEvent: widget.onLatestEvent,
                  clock: widget.clock,
                  expanded: _timelineExpanded,
                  collapsedItemLimit: collapsedTimelineRows,
                ),
              ),
            ],
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
