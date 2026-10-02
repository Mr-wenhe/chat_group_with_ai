part of 'work_task_panel.dart';

const _discussionContinuationReply =
    '请继续基于现有任务上下文完成两轮可验证讨论：测试给出验收标准，开发给出改造边界，设计给出交互方案，产品经理整合结论；信息充分后再更新到100%，不要虚报进度。';

class _TaskReplyBox extends StatelessWidget {
  final AgentTask task;
  final String? discussionQuestion;

  /// 追问澄清与模型澄清都是"任务在等用户回答"，但问题性质不同：前者问的是
  /// 要改哪个既有产物，文案要说明这一点，否则用户看到"请回答模型的问题"
  /// 会以为模型在对话里提问。
  final bool isFollowUpClarification;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool actionInFlight;
  final String? actionError;
  final Future<void> Function(String reply) onSubmit;

  const _TaskReplyBox({
    required this.task,
    this.discussionQuestion,
    this.isFollowUpClarification = false,
    required this.controller,
    required this.focusNode,
    required this.actionInFlight,
    required this.actionError,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDiscussionQuestion = discussionQuestion != null;
    final question =
        discussionQuestion ?? WorkTaskClarification.answerableQuestion(task);
    // 只有追问澄清带结构化候选。模型提问没有可点的目标，给一排按钮等于把
    // 用户的选择权换成我们的猜测。
    final options = isFollowUpClarification
        ? WorkTaskClarification.options(task)
        : const <WorkFollowUpOption>[];
    final answerRejected =
        isFollowUpClarification && WorkTaskClarification.answerRejected(task);
    final prompt = isDiscussionQuestion
        ? '请回答群讨论的问题'
        : isFollowUpClarification
            ? '请明确修订目标'
            : '请回答模型的问题';
    return DecoratedBox(
      key: const Key('work-task-reply-box'),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.primary.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              prompt,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            SelectableText(
              _safePanelText(question),
              key: const Key('work-task-reply-question'),
            ),
            if (answerRejected) ...[
              const SizedBox(height: 6),
              // 问题原样再问一遍时，用户分不清系统是没收到答复还是读不懂答复。
              // 只有真有候选时才提"点选"：没有候选的任务里那排按钮不存在。
              Text(
                options.isEmpty
                    ? '没能从上次回复里认出要改的文件，请回复完整路径。'
                    : '没能从上次回复里认出要改的文件，请点选下面的选项，或回复完整路径。',
                key: const Key('work-task-reply-rejected'),
                style: TextStyle(color: colors.error),
              ),
            ],
            if (isFollowUpClarification && options.isNotEmpty) ...[
              const SizedBox(height: 6),
              _CandidateButtons(
                options: options,
                enabled: !actionInFlight,
                onSubmit: onSubmit,
              ),
            ],
            const SizedBox(height: 8),
            Semantics(
              container: true,
              textField: true,
              label: '任务回复输入框',
              onTap: focusNode.requestFocus,
              child: TextField(
                key: const Key('work-task-reply-input'),
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 4,
                enabled: !actionInFlight,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(
                  hintText: '输入回复…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (value) {
                  final reply = value.trim();
                  if (!actionInFlight && reply.isNotEmpty) {
                    unawaited(onSubmit(reply));
                  }
                },
              ),
            ),
            if (actionError != null && actionError!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '发送失败：${_safePanelText(actionError!)}',
                key: const Key('work-task-reply-error'),
                style: TextStyle(color: colors.error),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (isDiscussionQuestion &&
                    WorkTaskExecutionPolicy.enforcesCumulativeLimits(task))
                  TextButton.icon(
                    key: const Key('work-task-continue-discussion'),
                    onPressed: actionInFlight
                        ? null
                        : () => onSubmit(_discussionContinuationReply),
                    icon: const Icon(Icons.forum_outlined, size: 16),
                    label: const Text('继续讨论'),
                  ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    final canSend =
                        !actionInFlight && value.text.trim().isNotEmpty;
                    final label = actionInFlight ? '发送中…' : '发送回复';
                    return Semantics(
                      container: true,
                      excludeSemantics: true,
                      button: true,
                      enabled: canSend,
                      label: label,
                      onTap: canSend ? () => onSubmit(value.text.trim()) : null,
                      child: FilledButton.icon(
                        key: const Key('work-task-reply-send'),
                        onPressed:
                            canSend ? () => onSubmit(value.text.trim()) : null,
                        icon: actionInFlight
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.send_rounded),
                        label: Text(label),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  final VoidCallback onCollapse;

  /// 进入历史任务视图；为空时不显示历史入口。
  final VoidCallback? onOpenHistory;

  /// 历史视图里的返回按钮：详情 → 列表，列表 → 任务面板。
  final VoidCallback? onBackFromHistory;
  final bool inHistory;

  const _PanelHeader({
    required this.onCollapse,
    this.onOpenHistory,
    this.onBackFromHistory,
    this.inHistory = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        if (inHistory)
          IconButton(
            key: const Key('work-task-history-back'),
            tooltip: '返回任务面板',
            onPressed: onBackFromHistory,
            icon: const Icon(Icons.arrow_back_rounded),
          )
        else
          const _PanelBrandMark(),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            inHistory ? '历史任务' : '工作任务',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        if (!inHistory && onOpenHistory != null)
          IconButton(
            key: const Key('work-task-history-open'),
            tooltip: '查看历史任务',
            onPressed: onOpenHistory,
            icon: const Icon(Icons.history_rounded),
          ),
        IconButton(
          key: const Key('work-task-collapse'),
          tooltip: '收起执行面板（任务继续运行）',
          onPressed: onCollapse,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
      ],
    );
  }
}

class _TaskTabs extends StatelessWidget {
  final List<AgentTask> tasks;
  final String selectedTaskId;
  final ValueChanged<String> onSelectTask;

  /// 关掉某个任务标签；为空时不显示关闭按钮。
  final ValueChanged<String>? onHideTask;

  const _TaskTabs({
    required this.tasks,
    required this.selectedTaskId,
    required this.onSelectTask,
    this.onHideTask,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: tasks.map(
        // 只有终态任务允许关掉标签：执行中 / 等待审批的任务一旦隐藏，
        // 用户就看不到它卡在哪里，因此不提供关闭入口。
        (task) {
          final selected = task.id == selectedTaskId;
          return InputChip(
            key: Key('work-task-tab-${task.id}'),
            label: Text(workTaskTabLabel(task)),
            labelStyle: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: selected
                  ? colors.onPrimaryContainer
                  : colors.onSurfaceVariant,
            ),
            selected: selected,
            backgroundColor: colors.surfaceContainerHighest,
            selectedColor: colors.primaryContainer,
            side: BorderSide(
              color: selected
                  ? colors.primary.withValues(alpha: 0.45)
                  : colors.outlineVariant,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
            ),
            onSelected: (_) => onSelectTask(task.id),
            onDeleted: onHideTask == null || !task.isTerminal
                ? null
                : () => onHideTask!(task.id),
            deleteIcon: const Icon(Icons.close_rounded, size: 16),
            deleteButtonTooltipMessage: '关掉这个标签（记录保留在历史任务中）',
          );
        },
      ).toList(growable: false),
    );
  }
}

class _PublicDetail extends StatelessWidget {
  final String title;
  final String text;
  final bool inline;

  const _PublicDetail({
    required this.title,
    required this.text,
    this.inline = false,
  });

  @override
  Widget build(BuildContext context) {
    if (inline) {
      return Text('$title：$text', style: const TextStyle(fontSize: 12.5));
    }
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(text, style: const TextStyle(fontSize: 12.5)),
      ],
    );
  }
}

class _TaskEventTimeline extends StatefulWidget {
  final String taskId;
  final WorkTaskEventStream eventStreamFor;
  final ValueChanged<WorkTaskEvent> onLatestEvent;

  /// 展开态渲染完整时间线与滚动条；折叠态只保留最近若干条且不渲染滚动条。
  final bool expanded;

  /// 折叠态最多展示的条目数（含流式输出等临时卡片）。
  ///
  /// 由外层按「执行动态」区域的可用高度算出，保证列出的每条都是完整的一行卡片，
  /// 不会因为 `shrinkWrap + NeverScrollableScrollPhysics` 被 SizedBox 静默裁掉半张。
  final int collapsedItemLimit;

  /// 面板的"现在"。等待时长按它计算，而不是各自 `DateTime.now()`：面板每 30 秒
  /// 重绘一次，这个值跟着走，等待分钟数就自己往前跳。
  final DateTime Function() clock;

  const _TaskEventTimeline({
    super.key,
    required this.taskId,
    required this.eventStreamFor,
    required this.onLatestEvent,
    required this.clock,
    this.expanded = false,
    this.collapsedItemLimit = 4,
  });

  @override
  State<_TaskEventTimeline> createState() => _TaskEventTimelineState();
}

class _TaskEventTimelineState extends State<_TaskEventTimeline> {
  /// 贴着底部多少像素内仍算"在看最新"。
  static const double _followThreshold = 48.0;

  final List<WorkTaskEvent> _events = <WorkTaskEvent>[];
  final Set<int> _seenSequences = <int>{};
  final ScrollController _eventScrollController = ScrollController();
  StreamSubscription<WorkTaskEvent>? _subscription;
  String? _streamError;
  String? _livePublicDraft;
  WorkTaskEvent? _livePublicEvent;
  bool _modelOutputPending = false;
  String _modelOutputPendingText = 'AI 正在整理公开进度…';

  /// 新动态到达时是否自动滚到最新一条。
  ///
  /// 展开默认贴底（面板一打开就停在最新进度）；用户主动往上翻历史时置为
  /// false，不再把他拽回底部，翻回底部后自动恢复跟随。
  bool _followLatest = true;

  /// 本次"等待首段公开输出"的起点。
  ///
  /// 只有 [_modelOutputPending] 为真时才有意义，所以清空 pending 的地方不需要
  /// 跟着清它——每次进入等待都会用事件自己的时间戳覆盖。刻意不用 `??=`：那会
  /// 让上一次等待的起点漏到下一次。
  DateTime? _modelOutputPendingSince;

  /// 用户是否点开了"更早的运行段"。
  ///
  /// 默认关闭：同一条记录里被并入的旧请求可能来自很久以前，一打开面板就铺满当时
  /// 的进度，会让人以为新请求继承了旧任务。
  bool _earlierExpanded = false;

  /// 分界行的位置锚点，用于展开后把视口重新对到同一处。
  final GlobalKey _earlierToggleKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _eventScrollController.addListener(_syncFollowLatest);
    _listen();
  }

  @override
  void didUpdateWidget(covariant _TaskEventTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId == widget.taskId) {
      if (widget.expanded && !oldWidget.expanded) {
        _followLatest = true;
        _scrollToLatest();
      }
      return;
    }
    _events.clear();
    _seenSequences.clear();
    _streamError = null;
    _livePublicDraft = null;
    _livePublicEvent = null;
    _modelOutputPending = false;
    _modelOutputPendingText = 'AI 正在整理公开进度…';
    _followLatest = true;
    _earlierExpanded = false;
    unawaited(_subscription?.cancel());
    _listen();
  }

  @override
  void dispose() {
    _eventScrollController.removeListener(_syncFollowLatest);
    unawaited(_subscription?.cancel());
    _eventScrollController.dispose();
    super.dispose();
  }

  /// 只有本来就贴着底部才继续跟随最新动态。
  void _syncFollowLatest() {
    if (!_eventScrollController.hasClients) return;
    final position = _eventScrollController.position;
    _followLatest =
        position.pixels >= position.maxScrollExtent - _followThreshold;
  }

  /// 展开态把视口滚到最新一条。
  ///
  /// 必须在布局之后执行：新动态到达时 `maxScrollExtent` 这一帧才更新，
  /// 提前滚会停在旧的底部。
  void _scrollToLatest() {
    if (!widget.expanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_followLatest) return;
      if (!_eventScrollController.hasClients) return;
      final position = _eventScrollController.position;
      if (position.maxScrollExtent <= 0) return;
      _eventScrollController.jumpTo(position.maxScrollExtent);
    });
  }

  void _listen() {
    _subscription = widget.eventStreamFor(widget.taskId).listen(
      (event) {
        if (event.taskId != widget.taskId ||
            _seenSequences.contains(event.sequence)) {
          return;
        }
        if (!mounted) return;
        final isModelOutput = event.kind == WorkTaskEventKind.modelOutput;
        final isModelProgress = _isModelProgressEvent(event);
        final liveDraft = _safePanelText(
          _publicDraftFromEvent(event),
        ).trim();
        setState(() {
          _seenSequences.add(event.sequence);
          if (isModelOutput) {
            _livePublicDraft = liveDraft.isEmpty ? null : liveDraft;
            _livePublicEvent = liveDraft.isEmpty ? null : event;
            _modelOutputPending = false;
            _modelOutputPendingText = 'AI 正在整理公开进度…';
          } else if (isModelProgress) {
            // The transport event is only a liveness signal. It must not
            // become a character-count-only card in the public timeline.
            // A public_update event, when available, is rendered separately.
            if (liveDraft.isNotEmpty) {
              _livePublicDraft = liveDraft;
              // Newer runners also attach the safe draft to the liveness
              // event. Keep that value as the historical card if the model
              // output event is unavailable or arrives later than it.
              _livePublicEvent = WorkTaskEvent(
                taskId: event.taskId,
                sequence: event.sequence,
                timestamp: event.timestamp,
                kind: WorkTaskEventKind.modelOutput,
                title: 'AI 正在输出公开进度',
                detail: liveDraft,
                safeMetadata: <String, Object?>{
                  'stream': 'public_update',
                  'publicDraft': liveDraft,
                },
              );
              _modelOutputPendingText = 'AI 正在整理公开进度…';
            } else if (_livePublicDraft == null) {
              _modelOutputPending = true;
              _modelOutputPendingSince = event.timestamp;
              _modelOutputPendingText = _pendingTextFromEvent(event);
            }
          } else {
            if (_eventRepeatsLiveDraft(event)) {
              // Terminal/action events often repeat the latest public update
              // as their title. Keep one copy instead of showing the live
              // card, its historical card, and the terminal summary together.
              _livePublicEvent = null;
            } else {
              _commitLivePublicEvent();
            }
            _livePublicDraft = null;
            _modelOutputPending = false;
            _modelOutputPendingText = 'AI 正在整理公开进度…';
            _events.add(event);
            _events.sort(
              (left, right) => left.sequence.compareTo(right.sequence),
            );
          }
        });
        // 新动态落到列表尾部后贴底跟随，保证用户看到的始终是最新一条。
        _scrollToLatest();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onLatestEvent(event);
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted) return;
        setState(() {
          _streamError = sanitizeWorkTaskError(error);
        });
      },
    );
  }

  void _retry() {
    unawaited(_subscription?.cancel());
    if (!mounted) return;
    setState(() {
      _events.clear();
      _seenSequences.clear();
      _streamError = null;
      _livePublicDraft = null;
      _livePublicEvent = null;
      _modelOutputPending = false;
      _modelOutputPendingText = 'AI 正在整理公开进度…';
      _followLatest = true;
      _earlierExpanded = false;
    });
    _listen();
  }

  bool _isModelProgressEvent(WorkTaskEvent event) {
    return event.kind == WorkTaskEventKind.toolOutput &&
        event.safeMetadata['stream'] == 'model';
  }

  String _pendingTextFromEvent(WorkTaskEvent event) {
    final value = event.safeMetadata['pendingText'];
    if (value is String && value.trim().isNotEmpty) {
      return _safePanelText(value);
    }
    return 'AI 正在整理公开进度…';
  }

  bool _eventRepeatsLiveDraft(WorkTaskEvent event) {
    final draft = _livePublicDraft?.trim();
    if (draft == null || draft.isEmpty) return false;
    final title = event.title.trim();
    final detail = event.detail.trim();
    return title == draft || detail == draft;
  }

  void _commitLivePublicEvent() {
    final event = _livePublicEvent;
    if (event == null ||
        _events.any((candidate) => candidate.sequence == event.sequence)) {
      _livePublicEvent = null;
      return;
    }
    _events.add(event);
    _events.sort(
      (left, right) => left.sequence.compareTo(right.sequence),
    );
    _livePublicEvent = null;
  }

  /// 时间线顶部的临时卡片（流式输出 / 等待提示 / 流错误）。
  int get _transientItemCount {
    var count = 0;
    if (_streamError != null) count++;
    if (_livePublicDraft != null) count++;
    if (_modelOutputPending) count++;
    return count;
  }

  /// 当前运行段之前还压着多少条历史事件。
  ///
  /// 只在展开态折叠：折叠态本来就只画最后几条，按当前段取就够。
  int get _earlierEventCount =>
      widget.expanded ? WorkTaskRunBoundary.currentRunStartIndex(_events) : 0;

  bool get _hasEarlierEvents => _earlierEventCount > 0;

  bool get _showEarlierEvents => _hasEarlierEvents && _earlierExpanded;

  /// 当前这次请求产生的事件；更早的属于被并入同一条记录的旧请求。
  List<WorkTaskEvent> get _currentRunEvents =>
      _events.sublist(_earlierEventCount);

  List<WorkTaskEvent> get _visibleEvents =>
      _showEarlierEvents ? _events : _currentRunEvents;

  int get _timelineItemCount =>
      _transientItemCount + (_hasEarlierEvents ? 1 : 0) + _visibleEvents.length;

  /// 折叠态只展示"临时卡片 + 最近的历史事件"，且总数不超过
  /// `widget.collapsedItemLimit`；展开态返回全部条目。
  List<int> get _visibleItemIndices {
    final total = _timelineItemCount;
    if (widget.expanded || total <= widget.collapsedItemLimit) {
      return List<int>.generate(total, (index) => index);
    }
    final transient = _transientItemCount;
    final eventCount = _visibleEvents.length;
    final visibleEvents =
        (widget.collapsedItemLimit - transient).clamp(0, eventCount).toInt();
    final firstEventIndex = transient + eventCount - visibleEvents;
    return <int>[
      for (var index = 0; index < transient; index++) index,
      for (var index = firstEventIndex; index < total; index++) index,
    ];
  }

  void _toggleEarlierEvents() {
    setState(() => _earlierExpanded = !_earlierExpanded);
    // 展开会把内容插在当前视口上方，滚动位置是按像素记的，不校正就会把用户甩到
    // 别处。把分界行重新对到屏幕上，读到的还是刚才那一段。必须在布局之后执行，
    // 这一帧的新位置还没算出来（与 `_scrollToLatest` 同理）。回调里不改状态，
    // 因此不会构成 CLAUDE.md 禁止的 postFrame → setState 循环。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anchor = _earlierToggleKey.currentContext;
      if (anchor == null) return;
      unawaited(Scrollable.ensureVisible(anchor, duration: Duration.zero));
    });
  }

  Widget _buildTimelineItem(BuildContext context, int index) {
    // 折叠态每条动态只占一行（超长省略），展开态才完整显示标题与详情。
    final singleLine = !widget.expanded;
    var remaining = index;
    final error = _streamError;
    if (error != null) {
      if (remaining == 0) {
        return _TimelineItemPadding(
          child: _EventStreamError(
            error: error,
            onRetry: _retry,
            singleLine: singleLine,
          ),
        );
      }
      remaining--;
    }
    final liveDraft = _livePublicDraft;
    if (liveDraft != null) {
      if (remaining == 0) {
        return _TimelineItemPadding(
          child: _LivePublicOutput(text: liveDraft, singleLine: singleLine),
        );
      }
      remaining--;
    }
    if (_modelOutputPending) {
      if (remaining == 0) {
        return _TimelineItemPadding(
          child: _PendingPublicOutput(
            text: _modelOutputPendingText,
            singleLine: singleLine,
            // 等待时长必须可见：上游停滞时面板会连续几分钟只有一行静态占位，
            // 用户分不清"在等"和"卡死"（2026-09-30 现场）。
            waitLabel:
                _pendingWaitLabel(_modelOutputPendingSince, widget.clock()),
          ),
        );
      }
      remaining--;
    }
    // 展开态先画被折叠的旧请求事件，再是分界行，最后才是当前这次运行。
    final earlierCount = _showEarlierEvents ? _earlierEventCount : 0;
    if (remaining < earlierCount) {
      return _TimelineItemPadding(
        child: _EventCard(event: _events[remaining], singleLine: singleLine),
      );
    }
    remaining -= earlierCount;
    if (_hasEarlierEvents) {
      if (remaining == 0) {
        return _TimelineItemPadding(
          child: _TimelineEarlierEventsToggle(
            key: _earlierToggleKey,
            earlierCount: _earlierEventCount,
            expanded: _showEarlierEvents,
            onToggle: _toggleEarlierEvents,
          ),
        );
      }
      remaining--;
    }
    final event = _currentRunEvents[remaining];
    return _TimelineItemPadding(
      child: _EventCard(event: event, singleLine: singleLine),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 每次重建都补一次"贴底"：首次打开面板、切换任务、流式卡片变高这些时机
    // 不会有新事件经过监听回调，只有在这里调度才能保证视口一定落在最新一条。
    // `_followLatest` 为 false（用户正在翻阅历史）时该方法内部直接返回。
    _scrollToLatest();
    final error = _streamError;
    final liveDraft = _livePublicDraft;
    if (_events.isEmpty &&
        liveDraft == null &&
        !_modelOutputPending &&
        error == null) {
      return Align(
        key: const Key('work-task-event-timeline'),
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.hourglass_empty_rounded,
              size: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            const Text(
              '等待公开执行动态…',
              style: TextStyle(fontSize: 12.5),
            ),
          ],
        ),
      );
    }
    final indices = _visibleItemIndices;
    return Padding(
      // Keep the event scrollbar in its own hit-test lane. The outer details
      // scrollbar lives at the panel edge; this inset prevents the two thumbs
      // from covering one another while preserving wheel and drag scrolling.
      padding: const EdgeInsets.only(right: 12),
      child: _ConditionalScrollbar(
        enabled: widget.expanded,
        scrollbarKey: const Key('work-task-event-scrollbar'),
        controller: _eventScrollController,
        child: ListView.builder(
          key: const Key('work-task-event-timeline'),
          controller: _eventScrollController,
          primary: false,
          // 折叠态外层不给固定高度：让列表按内容撑开（后续条目都被
          // `_visibleItemIndices` 砍掉了，所以最多两行），这样面板高度是
          // 内容驱动的，不会因为固定配额把详情区挤到需要滚动。
          // 展开态才由外层给固定高度并允许内部滚动。
          shrinkWrap: !widget.expanded,
          physics:
              widget.expanded ? null : const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: indices.length,
          itemBuilder: (BuildContext context, int index) =>
              _buildTimelineItem(context, indices[index]),
        ),
      ),
    );
  }
}

class _TimelineItemPadding extends StatelessWidget {
  final Widget child;

  const _TimelineItemPadding({required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: child,
    );
  }
}

/// 时间线上"更早的运行段"开关。
///
/// 同一条记录里可能并入了好几轮请求，更早的事件默认收起。入口放在两段之间，让
/// "下面这些才是当前这次请求的进度"一眼可见；点开后才把旧历史铺出来。
class _TimelineEarlierEventsToggle extends StatelessWidget {
  /// 被收起来的事件条数。
  final int earlierCount;
  final bool expanded;
  final VoidCallback onToggle;

  const _TimelineEarlierEventsToggle({
    super.key,
    required this.earlierCount,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TextButton(
      key: const Key('work-task-timeline-earlier-toggle'),
      onPressed: onToggle,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: colors.onSurfaceVariant,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            expanded ? Icons.expand_less_rounded : Icons.history_rounded,
            size: 15,
          ),
          const SizedBox(width: 4),
          Text(
            expanded ? '收起之前的 $earlierCount 条动态' : '之前的 $earlierCount 条动态',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 标题左侧的品牌标记：渐变圆角块，替代原来的单色星星图标。
///
/// 尺寸刻意控制在 30x30 并排在一行里，不改变标题行的高度（行高仍由右侧
/// IconButton 的 48px 决定）。
class _PanelBrandMark extends StatelessWidget {
  const _PanelBrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(9),
      ),
      child: const Icon(
        Icons.auto_awesome_rounded,
        size: 17,
        color: Colors.white,
      ),
    );
  }
}

/// 上半区收起态单张卡片的固定高度。
///
/// 收起时只渲染标题行，把这行钉在 30 高里（行内容垂直居中），比展开态紧凑
/// 得多；三张卡加上间距就是收起态上半区的全部可见内容。
const double _collapsedSummaryRowHeight = 30.0;

/// 面板里的信息分组卡片：统一"图标 + 小标题 + 内容"的结构，替代原来一长串
/// 无分组的裸文本，让用户先看到分区再读细节。
class _PanelCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget? trailing;
  final Widget child;

  /// 收起态：只留标题行，内容不挂载，整张卡固定 [_collapsedSummaryRowHeight] 高。
  ///
  /// 上半区的三张卡（任务需求 / 运行状态 / 执行细节）都由顶部那个开关统一
  /// 控制，收起时它们仍然各占一行，用来提示"这里有这几块信息"。
  final bool collapsed;

  const _PanelCard({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
    this.collapsed = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      // 外层是竖直 SingleChildScrollView，子级拿到的是松宽度约束，
      // 不撑满宽度卡片会缩到内容宽度。
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Padding(
          // 收起态没有内容，横向留白即可，纵向高度由外层固定值决定。
          padding: collapsed
              ? const EdgeInsets.symmetric(horizontal: 12)
              : const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: SizedBox(
            height: collapsed ? _collapsedSummaryRowHeight : null,
            child: Column(
              mainAxisAlignment: collapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(icon, size: 14, color: colors.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (trailing != null) trailing!,
                  ],
                ),
                if (!collapsed) ...<Widget>[
                  const SizedBox(height: 8),
                  child,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 分组标题行右侧的「详情 / 收起」开关。
///
/// 上半区整体（任务需求 / 运行状态 / 执行细节）与执行动态共用同一个样式，
/// 保证两个入口看起来是同一套交互。
class _PanelToggleButton extends StatelessWidget {
  final Key toggleKey;
  final bool expanded;
  final VoidCallback onPressed;

  const _PanelToggleButton({
    required this.toggleKey,
    required this.expanded,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: toggleKey,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        iconSize: 15,
        foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      icon: Icon(
        expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
      ),
      label: Text(
        expanded ? '收起' : '详情',
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 按需在子树外面套一层 `Scrollbar`。
///
/// 折叠（正常）状态下内容本来就放得下，此时挂 `thumbVisibility: true` 的
/// `Scrollbar` 会画出一条占满轨道的滑块，看起来像"永远没滚到底"。所以折叠态
/// 直接不渲染 `Scrollbar`，也就不会出现滚动条；展开态才挂上真正可拖的滑块。
class _ConditionalScrollbar extends StatelessWidget {
  final bool enabled;
  final Key scrollbarKey;
  final ScrollController controller;
  final Widget child;

  const _ConditionalScrollbar({
    required this.enabled,
    required this.scrollbarKey,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Scrollbar(
      key: scrollbarKey,
      controller: controller,
      thumbVisibility: true,
      interactive: true,
      child: child,
    );
  }
}

/// 任务状态胶囊：状态色 + 圆点 + 短标签，让"跑到哪一步"一眼可见。
class _StatusBadge extends StatelessWidget {
  final AgentTaskStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final tone = _statusTone(context, status);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: tone.foreground,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _statusBadgeLabel(status),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: tone.foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusTone {
  const _StatusTone({required this.foreground, required this.background});

  final Color foreground;
  final Color background;
}

_StatusTone _statusTone(BuildContext context, AgentTaskStatus status) {
  final colors = Theme.of(context).colorScheme;
  final semantic = AppSemanticColors.of(context);
  Color tinted(Color base) => base.withValues(alpha: 0.14);
  return switch (status) {
    AgentTaskStatus.completed => _StatusTone(
        foreground: semantic.onSuccessContainer,
        background: semantic.successContainer,
      ),
    AgentTaskStatus.partiallyCompleted => _StatusTone(
        foreground: semantic.success,
        background: semantic.successContainer,
      ),
    AgentTaskStatus.failed => _StatusTone(
        foreground: colors.onErrorContainer,
        background: colors.errorContainer,
      ),
    AgentTaskStatus.waitingForApproval => _StatusTone(
        foreground: colors.tertiary,
        background: tinted(colors.tertiary),
      ),
    AgentTaskStatus.paused || AgentTaskStatus.interrupted => _StatusTone(
        foreground: colors.secondary,
        background: tinted(colors.secondary),
      ),
    AgentTaskStatus.cancelled => _StatusTone(
        foreground: colors.onSurfaceVariant,
        background: colors.surfaceContainerHighest,
      ),
    AgentTaskStatus.queued ||
    AgentTaskStatus.planning ||
    AgentTaskStatus.runningTool =>
      _StatusTone(
        foreground: colors.primary,
        background: tinted(colors.primary),
      ),
  };
}

String _statusBadgeLabel(AgentTaskStatus status) {
  return switch (status) {
    AgentTaskStatus.queued => '排队中',
    AgentTaskStatus.planning => '规划中',
    AgentTaskStatus.waitingForApproval => '等待审批',
    AgentTaskStatus.runningTool => '执行中',
    AgentTaskStatus.completed => '已完成',
    AgentTaskStatus.failed => '执行失败',
    AgentTaskStatus.cancelled => '已停止',
    AgentTaskStatus.partiallyCompleted => '部分完成',
    AgentTaskStatus.paused => '已暂停',
    AgentTaskStatus.interrupted => '已中断',
  };
}

/// 追问澄清的候选按钮：点一下等于把该候选的完整路径回给任务。
///
/// 单独的 widget 而不是内联 `Wrap`，是因为"同名候选要显示完整路径"这条判据
/// 需要看到整个候选列表，内联在 `build` 里会把它拆成两处。
class _CandidateButtons extends StatelessWidget {
  final List<WorkFollowUpOption> options;
  final bool enabled;
  final Future<void> Function(String reply) onSubmit;

  const _CandidateButtons({
    required this.options,
    required this.enabled,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: <Widget>[
        for (final option in options)
          OutlinedButton(
            key: Key('work-task-reply-option-${option.index}'),
            onPressed: enabled ? () => unawaited(onSubmit(option.path)) : null,
            child: Text(_labelFor(option)),
          ),
      ],
    );
  }

  /// 提交的永远是完整路径（同名候选只有路径能区分），但按钮文案默认只用短名。
  /// 短名撞车时退回完整路径 —— 两个长得一模一样的按钮等于没有给出选择，而这
  /// 正是这次澄清要解决的问题。
  String _labelFor(WorkFollowUpOption option) {
    final sameName = options
        .where((other) => other.displayName == option.displayName)
        .length;
    return sameName > 1 ? option.path : option.displayName;
  }
}
