part of 'work_task_panel.dart';

class _TaskDetails extends StatefulWidget {
  final AgentTask task;
  final WorkTaskEvent? latestAction;
  final String? toolName;
  final String? actionError;

  /// 是否渲染面板上半区（「任务详情」开关、任务需求 / 运行状态 / 执行细节三张卡、
  /// 失败提示与「异常与日志」卡）。
  ///
  /// 默认关闭时面板只剩任务标签、执行动态与底部操作按钮，上半区整块不挂载；
  /// 代码保留在这里，传 true 即可整块恢复。见 [WorkTaskPanel.showTaskSummarySection]。
  final bool showSummarySection;

  final String Function(String characterId)? characterNameFor;
  final WorkTaskEventStream eventStreamFor;
  final ValueChanged<WorkTaskEvent> onLatestEvent;
  final DateTime Function() clock;

  const _TaskDetails({
    required this.task,
    required this.latestAction,
    required this.toolName,
    required this.actionError,
    required this.showSummarySection,
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

  /// 上半区（任务详情）整体展开开关。
  ///
  /// 默认收起时「任务需求 / 运行状态 / 执行细节」三张卡各只占一行，
  /// 把面板剩余高度尽量让给「执行动态」；点「详情」才把三张卡的内容补出来
  /// （超出上限时在区域内部滚动）。异常块与「异常与日志」卡同样受这个开关控制。
  bool _summaryExpanded = false;
  bool _discussionExpanded = false;
  static const double _discussionHeaderHeight = 48;
  static const double _discussionBodyMaxHeight = 160;

  /// 执行动态默认展开，打开面板就能看到最新一条公开进度。
  ///
  /// 展开态自带滚动条，并默认停在最新一条（见 `_TaskEventTimeline` 的自动跟随），
  /// 点「收起」才压成"每条一行"的摘要。
  bool _timelineExpanded = true;

  /// 是否渲染上半区（任务详情开关、任务需求 / 运行状态 / 执行细节三张卡、
  /// 失败提示与「异常与日志」卡）。
  ///
  /// 由 `WorkTaskPanel.showTaskSummarySection` 决定：默认 false，面板自上而下只剩
  /// 任务标签、执行动态与底部操作按钮；置为 true 即可整块恢复，不用改下半区
  /// 任何代码。刻意保留成 widget 参数而不是 `static const`：编译期常量条件会让
  /// analyzer 把整块内容判成 dead code 报警告。
  bool get _showSummarySection => widget.showSummarySection;

  /// 上半区顶部独立开关行的高度（与「执行动态」标题行同高，视觉对称）。
  static const double _summaryHeaderHeight = 28.0;

  /// 开关行与卡片区之间的固定间距。
  static const double _summaryHeaderGap = 6.0;

  /// 上半区（含顶部开关行）的整体高度区间。
  ///
  /// 收起态可见内容固定：开关行 28 + 间距 6 + 三张单行卡
  /// （`_collapsedSummaryRowHeight` 30×3 + 间距 10×2）= 144，下限取 150 留一点余量；
  /// 上限 260 是展开态的天花板，展开超过后在区域内部滚动，
  /// 「执行动态」因此始终拿得到 minTimelineRegionHeight 那份高度。
  static const double _summaryRegionMinHeight = 150.0;
  static const double _summaryRegionMaxHeight = 260.0;

  /// 上半区与「执行动态」之间的固定间距。
  static const double _sectionGap = 14.0;

  /// 「执行动态」标题行的固定高度（文字实际约 24，留一点余量）。
  static const double _timelineHeaderHeight = 28.0;

  /// 标题行与动态列表之间的固定间距。
  static const double _timelineHeaderGap = 6.0;

  /// 折叠态一条单行动态的标称高度（卡片 36 + 条目间距 6），留 2px 余量。
  ///
  /// 折叠态先按这个值把区域高度换算成条数，宁可少露一条也不让
  /// `SizedBox` 静默裁掉半张卡片。
  static const double _collapsedTimelineRowHeight = 44.0;

  /// 低于这个高度就整块收起「执行动态」，先保住上半区（够放两条单行动态）。
  static const double _minTimelineListHeight = 88.0;

  String _v2ApprovalLabel(
      WorkCollaborationState state, Map<String, dynamic> approval) {
    if (approval['requestRevision'] != state.requestRevision ||
        approval['teamRevision'] != state.teamRevision ||
        approval['verificationRevision'] != state.verificationRevision ||
        approval['artifactDigest'] !=
            state.currentIteration?['artifactDigest']) {
      return '已失效';
    }
    return approval['approved'] == true ? '同意' : '异议';
  }

  @override
  void didUpdateWidget(covariant _TaskDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id == widget.task.id) return;
    // 切到另一个任务后回到默认态（上半区收起 + 执行动态展开），
    // 避免上一个任务的展开状态残留。
    _summaryExpanded = false;
    _timelineExpanded = true;
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
    final hintStyle = TextStyle(fontSize: 11, color: colors.onSurfaceVariant);
    // 进度条必须始终拿到确定值：value 为 null 时 LinearProgressIndicator 会
    // 无限 repeat，测试里的 pumpAndSettle 会因此超时。
    final hasCumulativeLimit =
        WorkTaskExecutionPolicy.enforcesCumulativeLimits(widget.task);
    final progress = !hasCumulativeLimit || widget.task.actionLimit <= 0
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
        // 上下半区各自独立占位，展开只让区域内的内容铺开并出现滚动条，
        // 互不挤压、面板总高度恒定。
        //
        // 收起态上半区是三张单行卡（各 30 高），高度由内容决定（很小），
        // 剩下的高度全部让给「执行动态」，所以默认就像"执行动态占满整屏"。
        // 窗口矮到连两条单行动态都放不下（minTimelineRegionHeight 判定）时
        // 整块收起执行动态，全力保住上半区。
        const minTimelineRegionHeight =
            _timelineHeaderHeight + _timelineHeaderGap + _minTimelineListHeight;
        // 上半区不渲染时不必为它预留高度，阈值只剩「执行动态」自己那份。
        final summaryRegionReserve =
            _showSummarySection ? _summaryRegionMinHeight + _sectionGap : 0.0;
        final hasDiscussion = discussionState?.collaboration != null;
        final discussionHeaderHeight = hasDiscussion
            ? availableHeight.clamp(0.0, _discussionHeaderHeight).toDouble()
            : 0.0;
        // The collaboration details share this viewport with the timeline.
        // Their former fixed 160px cap ignored the timeline header and caused
        // a RenderFlex overflow in the real desktop overlay.
        final discussionBodyHeight = hasDiscussion && _discussionExpanded
            ? (availableHeight -
                    discussionHeaderHeight -
                    summaryRegionReserve -
                    minTimelineRegionHeight)
                .clamp(0.0, _discussionBodyMaxHeight)
                .toDouble()
            : 0.0;
        final remainingHeight =
            availableHeight - discussionHeaderHeight - discussionBodyHeight;
        final showTimeline =
            remainingHeight >= summaryRegionReserve + minTimelineRegionHeight;
        // summaryRegionHeight 是上半区（含顶部开关行）能占的最大高度。
        // 这里只是"展开态"的上限：收起态内容更矮，外层 ConstrainedBox 会按内容收，
        // 不会把这份上限当成占位高度。
        final summaryRegionHeight = _showSummarySection && showTimeline
            ? (remainingHeight - _sectionGap - minTimelineRegionHeight)
                .clamp(_summaryRegionMinHeight, _summaryRegionMaxHeight)
                .toDouble()
            : remainingHeight;
        // 卡片区（可滚动部分）要扣掉顶部那行开关：开关放在滚动区外面，
        // 展开后把卡片滚到底时它依然可点。
        final summaryScrollMaxHeight =
            (summaryRegionHeight - _summaryHeaderHeight - _summaryHeaderGap)
                .clamp(0.0, double.infinity)
                .toDouble();
        // 下半区不预分配高度，交给 Expanded + LayoutBuilder 按剩余空间实测，
        // 这样上半区收起/展开导致的高度变化会自动补给「执行动态」。
        return SizedBox(
          height: availableHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (discussionState?.collaboration != null) ...[
                SizedBox(
                    height: discussionHeaderHeight,
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: const Key('work-v2-discussion-details'),
                          onPressed: () => setState(
                              () => _discussionExpanded = !_discussionExpanded),
                          child:
                              Text(_discussionExpanded ? '收起问题与方案' : '问题与方案详情'),
                        ))),
                if (_discussionExpanded)
                  ConstrainedBox(
                    constraints:
                        BoxConstraints(maxHeight: discussionBodyHeight),
                    child: SingleChildScrollView(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          SelectableText(WorkPublicUpdateStream.sanitize(
                              discussionState!.collaboration!.plan)),
                          Text(
                              '阶段：${discussionState.collaboration!.phase} · 当前成员：${widget.characterNameFor?.call(widget.task.characterId) ?? widget.task.characterId}'),
                          for (final iteration
                              in discussionState.collaboration!.iterations)
                            SelectableText(
                                '候选 ${iteration['id']} · ${iteration['status']}\n${iteration['artifactDigest']}\n审查 ${iteration['reviewRef']}'),
                          for (final approval in discussionState
                              .collaboration!.approvals
                              .where((a) =>
                                  a['kind'] == 'delivery' &&
                                  a['subjectId'] ==
                                      discussionState.collaboration!
                                          .currentIteration?['id']))
                            Text(
                                '认可 ${widget.characterNameFor?.call(approval['memberId'] as String) ?? approval['memberId']}：${_v2ApprovalLabel(discussionState.collaboration!, approval)} · ${approval['iterationId']} · 验证版本 ${approval['verificationRevision']}'),
                          for (final issue
                              in discussionState.collaboration!.issues)
                            Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: SelectableText(
                                    WorkPublicUpdateStream.sanitize(
                                        '${issue['problem']}\n处置：${issue['resolution']}\n核查条件：${issue['retestCondition']}\n依据：${issue['resolutionRef'] == '' ? issue['evidenceRef'] : issue['resolutionRef']}'))),
                          for (final item
                              in discussionState.collaboration!.workItems)
                            Text(
                                '工作项 ${item['id']}：${widget.characterNameFor?.call(item['ownerId'] as String) ?? item['ownerId']} · ${item['status']}\n交接依据：${item['resultRef'] ?? ''}'),
                          for (final item
                              in discussionState.collaboration!.acceptances)
                            SelectableText(WorkPublicUpdateStream.sanitize(
                                '验收：${item['method']} · ${item['status']}\n版本 ${item['verificationRevision']} · 证据 ${item['evidenceRef']}')),
                        ])),
                  ),
              ],
              // 上半区整块可关：关掉后（默认）面板自上而下只剩任务标签、
              // 执行动态与底部操作按钮，见 `_showSummarySection`。
              if (_showSummarySection) ...<Widget>[
                // 上半区唯一的展开/收起开关，固定在卡片区右上角，
                // 与下方「执行动态 · 实时公开输出」标题行左右对称。
                SizedBox(
                  height: _summaryHeaderHeight,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '任务详情',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      _PanelToggleButton(
                        toggleKey: const Key('work-task-details-toggle'),
                        expanded: _summaryExpanded,
                        onPressed: () => setState(
                          () => _summaryExpanded = !_summaryExpanded,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: _summaryHeaderGap),
                ConstrainedBox(
                  constraints:
                      BoxConstraints(maxHeight: summaryScrollMaxHeight),
                  child: _ConditionalScrollbar(
                    enabled: _summaryExpanded,
                    scrollbarKey: const Key('work-task-details-scrollbar'),
                    controller: _detailsScrollController,
                    child: SingleChildScrollView(
                      controller: _detailsScrollController,
                      primary: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          // 三张卡始终渲染，收起态各只占一行（collapsed），
                          // 由顶部那个开关统一控制内容是否补出来。
                          _PanelCard(
                            title: '任务需求',
                            icon: Icons.description_outlined,
                            collapsed: !_summaryExpanded,
                            child: Text(
                              _safePanelText(widget.task.userRequest),
                              key: const Key('work-task-request'),
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontSize: 14),
                            ),
                          ),
                          const SizedBox(height: 10),
                          _PanelCard(
                            title: '运行状态',
                            icon: Icons.monitor_heart_outlined,
                            collapsed: !_summaryExpanded,
                            trailing: _StatusBadge(status: widget.task.status),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text('执行角色：$executorLabel'),
                                if (discussionState != null &&
                                    hasCumulativeLimit) ...<Widget>[
                                  const SizedBox(height: 4),
                                  Text(
                                    '讨论理解进度：${discussionState.understandingPercent}% · 第${discussionState.round}轮',
                                    key: const Key(
                                        'work-discussion-understanding'),
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
                                if (hasCumulativeLimit)
                                  Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(999),
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
                                      // currentStep is the index of the current
                                      // tool operation and may intentionally lag
                                      // behind model decisions. The user-facing
                                      // budget must reflect every counted action.
                                      Text(
                                        '步骤 ${widget.task.actionCount} / ${widget.task.actionLimit}',
                                        style: hintStyle,
                                      ),
                                    ],
                                  ),
                                if (!hasCumulativeLimit)
                                  Text(
                                      '已执行 ${widget.task.actionCount} 个动作 · 按有效进展继续',
                                      style: hintStyle),
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
                            collapsed: !_summaryExpanded,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
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
                                    text: _safePanelText(
                                        widget.task.resultSummary),
                                  ),
                                ],
                                if (widget.task.lastArtifactPaths
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
                            _FailureDetails(
                              failure: failure,
                              collapsed: !_summaryExpanded,
                            ),
                          ],
                          if (widget.task.eventLogIncomplete ||
                              widget.actionError != null) ...<Widget>[
                            const SizedBox(height: 10),
                            _PanelCard(
                              title: '异常与日志',
                              icon: Icons.report_gmailerrorred_outlined,
                              collapsed: !_summaryExpanded,
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
              ],
              if (!_showSummarySection &&
                  widget.actionError?.trim().isNotEmpty == true) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  '操作失败：${_safePanelText(widget.actionError!)}',
                  key: const Key('work-task-action-error'),
                  style: TextStyle(color: colors.error),
                ),
              ],
              if (showTimeline) ...<Widget>[
                if (_showSummarySection) const SizedBox(height: _sectionGap),
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
                // 高度按剩余空间实测 => 上半区收起后动态自然铺满整屏，
                // 展开也只是在内部滚动，不会向上挤压上半区或改变面板总高。
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, timelineConstraints) {
                      final timelineListHeight =
                          timelineConstraints.maxHeight.isFinite
                              ? timelineConstraints.maxHeight
                              : 0.0;
                      // 折叠态每条动态只占一行：按真实高度算出能完整放下几条，
                      // 上限由条目总数自然收敛，不再人为砍成 4 条。
                      final collapsedTimelineRows =
                          (timelineListHeight / _collapsedTimelineRowHeight)
                              .floor()
                              .clamp(1, 9999)
                              .toInt();
                      return SizedBox(
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
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _FailureDetails extends StatelessWidget {
  final WorkFailure failure;

  /// 收起态：只留标题行，和上半区另外几张卡一样只占一行。
  final bool collapsed;

  const _FailureDetails({required this.failure, this.collapsed = false});

  @override
  Widget build(BuildContext context) {
    final completed = failure.completedContent;
    final title = '${_safePanelText(failure.title)} · ${failure.type.name}';
    return DecoratedBox(
      key: const Key('work-task-failure'),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: collapsed
          ? SizedBox(
              // 和上半区另外几张卡一样钉在同一个行高里，收起态整体更紧凑。
              height: _collapsedSummaryRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.error_outline,
                      size: 14,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
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
