part of 'work_task_panel.dart';

class _TaskDetails extends StatefulWidget {
  final AgentTask task;
  final WorkTaskEvent? latestEvent;
  final WorkTaskEvent? latestAction;
  final String? toolName;
  final String? actionError;
  final String? progressHistoryError;

  /// 是否渲染面板上半区（「任务详情」开关、任务需求 / 运行状态 / 执行细节三张卡、
  /// 失败提示与「异常与日志」卡）。
  ///
  /// 默认关闭时面板只剩任务标签、执行动态与底部操作按钮，上半区整块不挂载；
  /// 代码保留在这里，传 true 即可整块恢复。见 [WorkTaskPanel.showTaskSummarySection]。
  final bool showSummarySection;
  final List<UsageLedgerEntry> usageEntries;
  final List<AiRequestDiagnostic> usageDiagnostics;
  final bool usageUnavailable;
  final Set<UsageLedgerEntry> outOfBoundsUsageEntries;

  /// 反显期实体 id → 人话标签；null 表示不提供（文本原样显示 id）。
  final EntityLabels? entityLabels;
  final WorkTaskEventStream eventStreamFor;
  final WorkTaskEventHistory? eventHistoryFor;
  final ValueChanged<WorkTaskEvent> onLatestEvent;
  final DateTime Function() clock;

  const _TaskDetails({
    required this.task,
    required this.latestEvent,
    required this.latestAction,
    required this.toolName,
    required this.actionError,
    required this.progressHistoryError,
    required this.showSummarySection,
    required this.usageEntries,
    required this.usageDiagnostics,
    required this.usageUnavailable,
    required this.outOfBoundsUsageEntries,
    required this.entityLabels,
    required this.eventStreamFor,
    required this.eventHistoryFor,
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
  static const double _discussionHeaderHeight = 100;
  static const double _discussionBodyMaxHeight = 160;
  static const int _tokensPerThousand = 1000;
  static const int _tokensPerWan = 10000;

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

  List<UsageLedgerEntry> get _taskUsageEntries => widget.usageEntries
      .where((entry) => entry.taskId == widget.task.id)
      .toList(growable: false);

  List<UsageLedgerEntry> get _countedTaskUsageEntries => _taskUsageEntries
      .where((entry) => !widget.outOfBoundsUsageEntries.contains(entry))
      .toList(growable: false);

  List<AiRequestDiagnostic> get _taskUsageDiagnostics => widget.usageDiagnostics
      .where((entry) => entry.taskId == widget.task.id)
      .toList(growable: false);

  String _formatTaskTokenCount(int count) {
    if (count >= _tokensPerWan) return formatTokenCount(count);
    if (count >= _tokensPerThousand) {
      final thousands = (count / _tokensPerThousand).toStringAsFixed(1);
      final value = thousands.endsWith('.0')
          ? thousands.substring(0, thousands.length - 2)
          : thousands;
      return '$value 千';
    }
    return '$count 个';
  }

  String _taskUsageLabel(List<UsageLedgerEntry> entries) {
    final countedEntries = entries
        .where((entry) => !widget.outOfBoundsUsageEntries.contains(entry))
        .toList(growable: false);
    final tokens = countedEntries.fold<int>(
      0,
      (total, entry) => total + entry.inputTokens + entry.outputTokens,
    );
    final excluded = entries.length - countedEntries.length;
    final excludedLabel = excluded == 0 ? '' : ' · 异常 $excluded 条';
    return '用量 ${_formatTaskTokenCount(tokens)} Token$excludedLabel';
  }

  Future<void> _showTaskUsageDetails() {
    final allEntries = _taskUsageEntries;
    final entries = _countedTaskUsageEntries;
    final diagnostics = _taskUsageDiagnostics;
    final requestIds = allEntries.map((entry) => entry.requestId).toSet();
    final unrepresentedDiagnostics = diagnostics
        .where((item) => !requestIds.contains(item.requestId))
        .toList(growable: false);
    final unknownUsage = unrepresentedDiagnostics
        .where((item) =>
            item.inputTokens == null ||
            item.outputTokens == null ||
            item.exactUsage == null)
        .length;
    final estimatedUsage = entries.where((entry) => !entry.exactUsage).length;
    final unknownPrices = entries
        .where((entry) =>
            entry.estimatedCostMicros == null || entry.currency == null)
        .length;
    final total = UsageTotals();
    for (final entry in entries) {
      total.add(entry);
    }
    final byRunAndMember = <(int?, String), UsageTotals>{};
    for (final entry in entries) {
      final key = (entry.runBoundary, entry.characterId);
      byRunAndMember.putIfAbsent(key, UsageTotals.new).add(entry);
    }
    final details = byRunAndMember.entries.toList()
      ..sort((left, right) {
        final run = (left.key.$1 ?? 0).compareTo(right.key.$1 ?? 0);
        return run != 0 ? run : left.key.$2.compareTo(right.key.$2);
      });
    final costs = total.costMicrosByCurrency.entries
        .map((item) => '${item.key} ${MoneyMicros.display(item.value)}')
        .join(' · ');
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('当前任务用量'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.usageUnavailable)
                  const Text('当前设备账本不可用，未显示估算总量。')
                else if (allEntries.isEmpty)
                  const Text('没有带当前 taskId 的用量记录；旧记录不会按会话推断归属。')
                else ...[
                  Text(
                    '输入 ${total.inputTokens} Token（缓存 ${total.cachedInputTokens}，已包含在输入中）'
                    ' · 输出 ${total.outputTokens} Token · ${total.requestCount} 次记录',
                  ),
                  const SizedBox(height: 8),
                  Text(costs.isEmpty ? '费用未知或无可计价记录' : costs),
                  const SizedBox(height: 4),
                  Text(
                    '估算用量 $estimatedUsage · 未知用量 $unknownUsage · 价格未知 $unknownPrices',
                  ),
                  if (allEntries.length > entries.length)
                    Text(
                      '另有 ${allEntries.length - entries.length} 条历史记录超过当前模型能力上限，'
                      '已从统计中排除，原账本保留。',
                    ),
                  if (details.isNotEmpty)
                    ExpansionTile(
                      key: const Key('work-task-usage-breakdown'),
                      tilePadding: EdgeInsets.zero,
                      title: const Text('按运行段和成员展开'),
                      children: [
                        for (final item in details)
                          ListTile(
                            dense: true,
                            title: Text(
                              '运行段 ${item.key.$1 ?? '未知'} · '
                              '${widget.entityLabels?.labelFor(item.key.$2) ?? item.key.$2}',
                            ),
                            subtitle: Text(
                              '输入 ${item.value.inputTokens}（缓存 ${item.value.cachedInputTokens}）'
                              ' · 输出 ${item.value.outputTokens} · '
                              '${item.value.requestCount} 次 · '
                              '${item.value.costMicrosByCurrency.entries.map((cost) => '${cost.key} ${MoneyMicros.display(cost.value)}').join(' · ')}',
                            ),
                          ),
                      ],
                    ),
                ],
                if (unrepresentedDiagnostics.isNotEmpty &&
                    unknownUsage == 0) ...[
                  const SizedBox(height: 8),
                  Text('另有 ${unrepresentedDiagnostics.length} 条未计入账本的请求诊断。'),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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

  /// 宿主的通用标签 + 本任务的协作状态解析器（候选/问题/验收/工作项）。
  ///
  /// 领域 id 只有 work_mode 认识，而状态就在面板手里，所以在这里叠加，
  /// 不去扫任务集合；判据与决策弹窗共用 `WorkDomainLabels.labelsForTask`。
  EntityLabels? _labelsWithDomain(WorkDiscussionState? discussionState) =>
      WorkDomainLabels.labelsForTask(
        widget.entityLabels,
        widget.task.executionStateJson,
      );

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
    final discussionState =
        WorkDiscussionState.requiresDiscussionForConversation(
                widget.task.groupId)
            ? discussion.state
            : null;
    final labels = _labelsWithDomain(discussionState);
    final characterName =
        widget.entityLabels?.resolveOrNull(widget.task.characterId);
    final discussionExecutorName = discussionState?.executorId == null
        ? null
        : widget.entityLabels?.resolveOrNull(discussionState!.executorId!);
    final autonomous = discussionState?.collaboration?.isAutonomous == true;
    final plannedMakerId = discussionState?.collaboration?.workItems
        .where((i) => i['kind'] != 'material')
        .firstOrNull?['ownerId'] as String?;
    final makerId = autonomous
        ? plannedMakerId ?? discussionState?.executorId
        : discussionState?.executorId ?? plannedMakerId;
    final makerLabel = makerId == null
        ? '待群内定案'
        : widget.entityLabels?.labelFor(makerId) ?? makerId;
    final executorLabel = autonomous
        ? makerLabel
        : characterName?.isNotEmpty == true
            ? characterName!
            : discussionExecutorName?.isNotEmpty == true
                ? discussionExecutorName!
                : discussionState != null
                    ? '待群内推举'
                    : widget.task.characterId.trim().isEmpty
                        ? '待确定'
                        : widget.entityLabels
                                ?.labelFor(widget.task.characterId) ??
                            widget.task.characterId;
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
        final usageLabel = widget.usageUnavailable
            ? '用量不可用'
            : _taskUsageLabel(_taskUsageEntries);
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
            ? (availableHeight - discussionHeaderHeight - summaryRegionReserve)
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
                  child: discussionHeaderHeight < _discussionHeaderHeight
                      ? _CurrentWorkProgressCard(
                          task: widget.task,
                          state: discussionState!.collaboration!,
                          latestEvent: widget.latestEvent,
                          latestAction: displayAction,
                          historyError: widget.progressHistoryError,
                          entityLabels: labels,
                          clock: widget.clock,
                          compact: true,
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _CurrentWorkProgressCard(
                                task: widget.task,
                                state: discussionState!.collaboration!,
                                latestEvent: widget.latestEvent,
                                latestAction: displayAction,
                                historyError: widget.progressHistoryError,
                                entityLabels: labels,
                                clock: widget.clock,
                              ),
                            ),
                            SizedBox(
                              height: 24,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  key: const Key('work-v2-discussion-details'),
                                  style: TextButton.styleFrom(
                                    minimumSize: Size.zero,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 0,
                                    ),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  onPressed: () => setState(() =>
                                      _discussionExpanded =
                                          !_discussionExpanded),
                                  child: Text(_discussionExpanded
                                      ? '收起问题与方案'
                                      : '问题与方案详情'),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
                if (_discussionExpanded)
                  ConstrainedBox(
                    constraints:
                        BoxConstraints(maxHeight: discussionBodyHeight),
                    child: SingleChildScrollView(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          SelectableText(WorkPublicUpdateStream.sanitize(
                              discussionState.collaboration!.plan)),
                          Text(
                              '阶段：${_collaborationPhaseLabel(discussionState.collaboration!)} · 当前成员：${labels?.labelFor(widget.task.characterId) ?? widget.task.characterId}'),
                          if (autonomous) ...[
                            Text('制作执行者：$makerLabel'),
                            for (final assignment in discussionState
                                .collaboration!.usageAssignments)
                              Text(WorkPublicUpdateStream.sanitize(
                                  '使用场景 ${labels?.labelFor(assignment['memberId'] as String) ?? assignment['memberId']}：${assignment['goal']} · ${discussionState.collaboration!.currentUsageFor(assignment['memberId'] as String) == null ? '待实际使用' : '已记录本轮反馈'}')),
                            for (final ruling in discussionState
                                .collaboration!.currentCoordinatorDecisions)
                              SelectableText(WorkPublicUpdateStream.sanitize(
                                  '协调定案：${ruling['reason']}')),
                          ],
                          for (final iteration
                              in discussionState.collaboration!.iterations)
                            SelectableText(
                                '候选 ${labels?.labelFor(iteration['id'] as String) ?? iteration['id']} · ${iteration['status']}\n${iteration['artifactDigest']}\n审查 ${iteration['reviewRef']}'),
                          for (final approval in discussionState
                              .collaboration!.approvals
                              .where((a) =>
                                  a['kind'] == 'delivery' &&
                                  a['subjectId'] ==
                                      discussionState.collaboration!
                                          .currentIteration?['id']))
                            Text(
                                '认可 ${labels?.labelFor(approval['memberId'] as String) ?? approval['memberId']}：${_v2ApprovalLabel(discussionState.collaboration!, approval)} · ${labels?.labelFor(approval['iterationId'] as String) ?? approval['iterationId']} · 验证版本 ${approval['verificationRevision']}'),
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
                                '工作项 ${labels?.labelFor(item['id'] as String) ?? item['id']}：${labels?.labelFor(item['ownerId'] as String) ?? item['ownerId']} · ${item['status']}\n交接依据：${item['resultRef'] ?? ''}'),
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
                // 与下方「执行动态」标题行左右对称。
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
                              // 任务需求是用户原话，与真人消息同一条克制原则：不改写。
                              _safePanelText(widget.task.userRequest, null),
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
                                Text(
                                    '${autonomous ? '制作执行者' : '执行角色'}：$executorLabel'),
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
                                      : _safePanelText(
                                          widget.task.plan, labels),
                                ),
                                const SizedBox(height: 8),
                                _PublicDetail(
                                  title: '当前动作',
                                  text: displayAction == null
                                      ? _statusLabel(widget.task.status)
                                      : _safePanelText(
                                          displayAction.title, labels),
                                  inline: true,
                                ),
                                if (widget.toolName != null) ...<Widget>[
                                  const SizedBox(height: 8),
                                  _PublicDetail(
                                    title: '工具',
                                    text: _safePanelText(
                                        widget.toolName!, labels),
                                    inline: true,
                                  ),
                                ],
                                if (approvalText != null) ...<Widget>[
                                  const SizedBox(height: 8),
                                  _PublicDetail(
                                    title: '审批',
                                    text: _safePanelText(approvalText, labels),
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
                                        widget.task.resultSummary,
                                        widget.entityLabels),
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
                              entityLabels: labels,
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
                                      text: _safePanelText(
                                          widget.actionError!, labels),
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
                  '操作失败：${_safePanelText(widget.actionError!, labels)}',
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
                      Tooltip(
                        message: '执行动态',
                        child: Text(
                          '执行动态',
                          maxLines: 1,
                          softWrap: false,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      if (_taskUsageEntries.isNotEmpty ||
                          _taskUsageDiagnostics.isNotEmpty ||
                          widget.usageUnavailable)
                        Flexible(
                          child: Tooltip(
                            message: usageLabel,
                            child: TextButton(
                              key: const Key('work-task-usage-details'),
                              onPressed: _showTaskUsageDetails,
                              child: Text(
                                usageLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                softWrap: false,
                              ),
                            ),
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
                          entityLabels: labels,
                          eventStreamFor: widget.eventStreamFor,
                          eventHistoryFor: widget.eventHistoryFor,
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

bool _isDiscussionModelWait(WorkTaskEvent event) =>
    event.kind == WorkTaskEventKind.planning &&
    const {
      '正在等待成员模型回应',
      '群讨论请求通道已确认',
      '模型已有响应活动',
      '正在接收成员模型响应',
    }.contains(event.title);

class _CurrentWorkProgressCard extends StatelessWidget {
  const _CurrentWorkProgressCard({
    required this.task,
    required this.state,
    required this.latestEvent,
    required this.latestAction,
    required this.historyError,
    required this.entityLabels,
    required this.clock,
    this.compact = false,
  });

  final AgentTask task;
  final WorkCollaborationState state;
  final WorkTaskEvent? latestEvent;
  final WorkTaskEvent? latestAction;
  final String? historyError;
  final EntityLabels? entityLabels;
  final DateTime Function() clock;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final currentLatestEvent = latestEvent;
    final openDefect = state.issues
        .any((issue) => issue['kind'] == 'defect' && issue['status'] == 'open');
    final userAction = WorkTaskUserAction.forTask(task).firstOrNull;
    final discussionCanProgress = !task.groupId.startsWith('dm:') &&
        task.status == AgentTaskStatus.paused &&
        !task.resumeRequired &&
        userAction == null &&
        (const {'forming', 'clarifying'}.contains(state.phase) ||
            !state.planReady) &&
        !state.hasBlockingDecision &&
        state.pendingInputIds.isEmpty;
    final lastEventAge = currentLatestEvent == null
        ? null
        : clock().toUtc().difference(currentLatestEvent.timestamp);
    final activeDiscussion = discussionCanProgress &&
        lastEventAge != null &&
        lastEventAge <= WorkDiscussionRunner.defaultRoleTimeout &&
        currentLatestEvent?.kind != WorkTaskEventKind.failed;
    final stalledDiscussion = discussionCanProgress && !activeDiscussion;
    final waitingForMember =
        activeDiscussion && _isDiscussionModelWait(currentLatestEvent!);
    final waitingForGroupDiscussion = activeDiscussion &&
        currentLatestEvent!.kind == WorkTaskEventKind.paused &&
        currentLatestEvent.title == '等待群讨论完成';
    final (stage, icon, tone) = activeDiscussion && openDefect
        ? ('发现问题', Icons.report_problem_outlined, colors.error)
        : activeDiscussion
            ? ('讨论中', Icons.forum_outlined, colors.primary)
            : stalledDiscussion
                ? ('疑似停滞', Icons.hourglass_bottom_rounded, colors.error)
                : _currentProgressPresentation(
                    task,
                    state,
                    colors,
                    openDefect,
                    userAction,
                    latestEvent,
                  );
    final workItem =
        state.workItems.where((item) => item['status'] != 'done').firstOrNull;
    final ownerId = activeDiscussion || const {'forming', 'clarifying'}.contains(state.phase)
        ? state.coordinatorId
        : workItem?['ownerId'] as String? ?? state.coordinatorId;
    final owner =
        ownerId.isEmpty ? '待团队确定' : entityLabels?.labelFor(ownerId) ?? ownerId;
    final operation = task.isUserStopped
        ? '已停止，保留当前检查点'
        : task.status == AgentTaskStatus.failed
            ? '执行失败，检查点已保留'
            : activeDiscussion
                ? waitingForMember
                    ? currentLatestEvent.title
                    : waitingForGroupDiscussion
                        ? '等待群内成员回应'
                        : '团队继续讨论并收敛方案'
                : stalledDiscussion
                    ? '最近没有新的讨论事件'
                    : latestAction?.title ??
                        (workItem == null
                            ? _statusLabel(task.status)
                            : '处理工作项：${entityLabels?.labelFor(workItem['id'] as String) ?? workItem['id']}');
    final progressEvent = currentLatestEvent != null &&
            (currentLatestEvent.kind == WorkTaskEventKind.toolOutput &&
                    currentLatestEvent.safeMetadata['stream'] == 'model' ||
                _isDiscussionModelWait(currentLatestEvent) ||
                currentLatestEvent.kind == WorkTaskEventKind.paused &&
                    currentLatestEvent.title == '等待群讨论完成')
        ? null
        : currentLatestEvent;
    final lastProgress = historyError != null
        ? '执行动态读取失败'
        : progressEvent?.title ?? latestAction?.title ?? '尚无新的阶段事件';
    final deferredDiscussion = task.status == AgentTaskStatus.paused &&
        task.resumeRequired &&
        userAction == null &&
        !state.hasBlockingDecision;
    final next = task.isUserStopped
        ? '如需恢复，请点击任务面板“继续”'
        : task.status == AgentTaskStatus.failed
            ? '查看失败记录，处理原因后在任务面板重试'
            : deferredDiscussion
                ? '点击任务面板“继续”，从当前讨论检查点恢复'
                : userAction != null
                    ? '等待你${userAction.label}'
                    : activeDiscussion
                        ? waitingForMember
                            ? '等待成员回应后继续收敛方案'
                            : waitingForGroupDiscussion
                                ? '等待群成员回应后继续收敛方案'
                                : '团队继续收敛方案并更新工作分工'
                        : stalledDiscussion
                            ? '检查失败记录与恢复入口'
                            : _nextCollaborationStep(state);
    final requiredOperation = task.isUserStopped
        ? '当前已停止；如需恢复由你点击继续'
        : task.status == AgentTaskStatus.failed
            ? '需要你操作：查看失败记录并决定重试'
            : deferredDiscussion
                ? '需要你操作：点击继续'
                : userAction != null
                    ? '需要你操作：${userAction.label}'
                    : stalledDiscussion
                        ? '需要你检查恢复入口'
                        : '当前不需要你操作';
    final elapsed = _durationLabel(task, clock());
    if (compact) {
      return DecoratedBox(
        key: const Key('work-current-progress-card'),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tone.withValues(alpha: 0.42)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              Icon(icon, size: 16, color: tone),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '$stage · 需求版本 ${state.requestRevision} · 候选轮次 ${state.iterations.length} · $requiredOperation',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tone,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return DecoratedBox(
      key: const Key('work-current-progress-card'),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withValues(alpha: 0.42)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 17, color: tone),
                const SizedBox(width: 5),
                Text(
                  stage,
                  style: TextStyle(
                    color: tone,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '需求版本 ${state.requestRevision} · 候选轮次 ${state.iterations.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5, color: colors.onSurfaceVariant),
                  ),
                ),
                Text(
                  elapsed,
                  style:
                      TextStyle(fontSize: 10.5, color: colors.onSurfaceVariant),
                ),
              ],
            ),
            Text(
              '负责人：$owner · 当前操作：${_safePanelText(operation, entityLabels)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5),
            ),
            Text(
              '最近进展：${_safePanelText(lastProgress, entityLabels)} · 接下来：${_safePanelText(next, entityLabels)} · $requiredOperation',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: userAction == null ? colors.onSurfaceVariant : tone,
                fontWeight:
                    userAction == null ? FontWeight.normal : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

(String, IconData, Color) _currentProgressPresentation(
  AgentTask task,
  WorkCollaborationState state,
  ColorScheme colors,
  bool openDefect,
  WorkTaskUserAction? userAction,
  WorkTaskEvent? latestEvent,
) {
  if (task.status == AgentTaskStatus.failed) {
    return ('失败', Icons.error_outline_rounded, colors.error);
  }
  if (task.status == AgentTaskStatus.cancelled) {
    return ('已停止', Icons.stop_circle_outlined, colors.onSurfaceVariant);
  }
  if (userAction != null) {
    switch (userAction.kind) {
      case WorkTaskUserActionKind.confirmRequirements:
        return ('待你确认', Icons.fact_check_outlined, colors.tertiary);
      case WorkTaskUserActionKind.answerQuestion:
        return ('需要你回答', Icons.help_outline_rounded, colors.primary);
      case WorkTaskUserActionKind.authorizeFolder:
      case WorkTaskUserActionKind.approveCommand:
      case WorkTaskUserActionKind.installTool:
        return ('等待授权', Icons.lock_clock_outlined, colors.tertiary);
      case WorkTaskUserActionKind.confirmExecutorSwap:
        return ('待你确认', Icons.groups_2_outlined, colors.tertiary);
      case WorkTaskUserActionKind.addMember:
        return ('需要你补充成员', Icons.group_add_outlined, colors.secondary);
      case WorkTaskUserActionKind.openTask:
        break;
    }
  }
  switch (task.status) {
    case AgentTaskStatus.failed:
      return ('失败', Icons.error_outline_rounded, colors.error);
    case AgentTaskStatus.cancelled:
      return ('已停止', Icons.stop_circle_outlined, colors.onSurfaceVariant);
    case AgentTaskStatus.interrupted:
      return ('已中断', Icons.pause_circle_outline_rounded, colors.error);
    case AgentTaskStatus.waitingForApproval:
      return ('等待授权', Icons.lock_clock_outlined, colors.tertiary);
    case AgentTaskStatus.queued:
      return ('排队中', Icons.pending_outlined, colors.secondary);
    case AgentTaskStatus.paused:
      final reason = '${task.lastError} ${latestEvent?.title ?? ''}';
      if (reason.contains('停滞') ||
          reason.contains('无进展') ||
          reason.contains('未采纳') ||
          reason.contains('协议') ||
          reason.contains('状态校验')) {
        return ('疑似停滞', Icons.hourglass_bottom_rounded, colors.error);
      }
      return ('等待处理', Icons.pause_circle_outline_rounded, colors.tertiary);
    case AgentTaskStatus.partiallyCompleted:
      return ('部分完成', Icons.check_circle_outline_rounded, colors.tertiary);
    case AgentTaskStatus.completed:
      return state.phase == 'delivered'
          ? ('已交付', Icons.task_alt_rounded, colors.primary)
          : ('已完成', Icons.check_circle_outline_rounded, colors.primary);
    case AgentTaskStatus.planning:
    case AgentTaskStatus.runningTool:
      return _phasePresentation(state, colors, openDefect);
  }
}

(String, IconData, Color) _phasePresentation(
  WorkCollaborationState state,
  ColorScheme colors,
  bool openDefect,
) {
  if (openDefect && state.phase == 'producing') {
    return ('修复中', Icons.build_circle_outlined, colors.error);
  }
  if (openDefect && state.phase != 'verifying') {
    return ('发现问题', Icons.report_problem_outlined, colors.error);
  }
  return switch (state.phase) {
    'forming' || 'clarifying' => ('讨论中', Icons.forum_outlined, colors.primary),
    'ready' => ('方案已确定', Icons.fact_check_outlined, colors.tertiary),
    'producing' => ('制作中', Icons.construction_outlined, colors.secondary),
    'verifying' => state.issues.any((issue) => issue['kind'] == 'defect')
        ? ('复测中', Icons.replay_circle_filled_outlined, colors.tertiary)
        : ('测试中', Icons.science_outlined, colors.primary),
    'reviewing' => ('交付验收中', Icons.rule_folder_outlined, colors.tertiary),
    'delivered' => ('已交付', Icons.task_alt_rounded, colors.primary),
    _ => ('处理中', Icons.pending_outlined, colors.secondary),
  };
}

String _collaborationPhaseLabel(WorkCollaborationState state) {
  final openDefect = state.issues
      .any((issue) => issue['kind'] == 'defect' && issue['status'] == 'open');
  if (openDefect && state.phase == 'producing') return '修复中';
  if (openDefect && state.phase != 'verifying') return '发现问题';
  return switch (state.phase) {
    'forming' || 'clarifying' => '讨论中',
    'ready' => '方案已确定',
    'producing' => '制作中',
    'verifying' =>
      state.issues.any((issue) => issue['kind'] == 'defect') ? '复测中' : '测试中',
    'reviewing' => '交付验收中',
    'delivered' => '已交付',
    _ => '处理中',
  };
}

String _nextCollaborationStep(WorkCollaborationState state) {
  if (state.hasBlockingDecision || state.pendingInputIds.isNotEmpty) {
    return '等待你查看并回答问题';
  }
  return switch (state.phase) {
    'ready' => '由已确认的执行人开始制作',
    'producing' => '完成当前实现并提交候选文件',
    'verifying' => '测试成员执行本版验收',
    'reviewing' => '核对测试证据和交付认可',
    'delivered' => '交付已完成',
    _ => '团队继续讨论并收敛方案',
  };
}

class _FailureDetails extends StatelessWidget {
  final WorkFailure failure;

  /// 收起态：只留标题行，和上半区另外几张卡一样只占一行。
  final bool collapsed;

  /// 反显期实体 id → 人话标签；null 表示不提供。
  final EntityLabels? entityLabels;

  const _FailureDetails({
    required this.failure,
    this.collapsed = false,
    this.entityLabels,
  });

  @override
  Widget build(BuildContext context) {
    final completed = failure.completedContent;
    final labels = entityLabels;
    final title =
        '${_safePanelText(failure.title, labels)} · ${failure.type.name}';
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
                    text: _safePanelText(failure.reason, labels),
                  ),
                  const SizedBox(height: 4),
                  _PublicDetail(
                    title: '技术细节',
                    text: _safePanelText(failure.technicalDetail, labels),
                  ),
                  if (completed.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    _PublicDetail(
                      title: '已完成内容',
                      text: completed
                          .map((value) => _safePanelText(value, labels))
                          .join('；'),
                    ),
                  ],
                  const SizedBox(height: 4),
                  _PublicDetail(
                    title: '下一步',
                    text: _safePanelText(failure.panelSuggestedAction, labels),
                  ),
                ],
              ),
            ),
    );
  }
}
