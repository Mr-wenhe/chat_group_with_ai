part of 'work_task_panel.dart';

const _discussionContinuationReply =
    '请继续基于现有任务上下文完成两轮可验证讨论：测试给出验收标准，开发给出改造边界，设计给出交互方案，产品经理整合结论；信息充分后再更新到100%，不要虚报进度。';

class _TaskReplyBox extends StatelessWidget {
  final AgentTask task;
  final String? discussionQuestion;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool actionInFlight;
  final String? actionError;
  final Future<void> Function(String reply) onSubmit;

  const _TaskReplyBox({
    required this.task,
    this.discussionQuestion,
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
    final question = discussionQuestion ?? WorkTaskClarification.question(task);
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
              isDiscussionQuestion ? '请回答群讨论的问题' : '请回答模型的问题',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Text(_safePanelText(question)),
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
                if (isDiscussionQuestion)
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
  final VoidCallback onClose;

  /// 进入历史任务视图；为空时不显示历史入口。
  final VoidCallback? onOpenHistory;

  /// 历史视图里的返回按钮：详情 → 列表，列表 → 任务面板。
  final VoidCallback? onBackFromHistory;
  final bool inHistory;

  const _PanelHeader({
    required this.onCollapse,
    required this.onClose,
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
          const Icon(Icons.auto_awesome_rounded),
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
        IconButton(
          key: const Key('work-task-close'),
          tooltip: '隐藏执行面板（任务继续运行）',
          onPressed: onClose,
          icon: const Icon(Icons.close_rounded),
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
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: tasks
          .map(
            // 只有终态任务允许关掉标签：执行中 / 等待审批的任务一旦隐藏，
            // 用户就看不到它卡在哪里，因此不提供关闭入口。
            (task) => InputChip(
              key: Key('work-task-tab-${task.id}'),
              label: Text(workTaskTabLabel(task)),
              selected: task.id == selectedTaskId,
              onSelected: (_) => onSelectTask(task.id),
              onDeleted: onHideTask == null || !task.isTerminal
                  ? null
                  : () => onHideTask!(task.id),
              deleteIcon: const Icon(Icons.close_rounded, size: 16),
              deleteButtonTooltipMessage: '关掉这个标签（记录保留在历史任务中）',
            ),
          )
          .toList(growable: false),
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
    if (inline) return Text('$title：$text');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 2),
        Text(text),
      ],
    );
  }
}

class _TaskEventTimeline extends StatefulWidget {
  final String taskId;
  final WorkTaskEventStream eventStreamFor;
  final ValueChanged<WorkTaskEvent> onLatestEvent;

  const _TaskEventTimeline({
    super.key,
    required this.taskId,
    required this.eventStreamFor,
    required this.onLatestEvent,
  });

  @override
  State<_TaskEventTimeline> createState() => _TaskEventTimelineState();
}

class _TaskEventTimelineState extends State<_TaskEventTimeline> {
  final List<WorkTaskEvent> _events = <WorkTaskEvent>[];
  final Set<int> _seenSequences = <int>{};
  final ScrollController _eventScrollController = ScrollController();
  StreamSubscription<WorkTaskEvent>? _subscription;
  String? _streamError;
  String? _livePublicDraft;
  WorkTaskEvent? _livePublicEvent;
  bool _modelOutputPending = false;
  String _modelOutputPendingText = 'AI 正在整理公开进度…';

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(covariant _TaskEventTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskId == widget.taskId) return;
    _events.clear();
    _seenSequences.clear();
    _streamError = null;
    _livePublicDraft = null;
    _livePublicEvent = null;
    _modelOutputPending = false;
    _modelOutputPendingText = 'AI 正在整理公开进度…';
    unawaited(_subscription?.cancel());
    _listen();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _eventScrollController.dispose();
    super.dispose();
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

  int get _timelineItemCount {
    var count = _events.length;
    if (_streamError != null) count++;
    if (_livePublicDraft != null) count++;
    if (_modelOutputPending) count++;
    return count;
  }

  Widget _buildTimelineItem(BuildContext context, int index) {
    var remaining = index;
    final error = _streamError;
    if (error != null) {
      if (remaining == 0) {
        return _TimelineItemPadding(
          child: _EventStreamError(error: error, onRetry: _retry),
        );
      }
      remaining--;
    }
    final liveDraft = _livePublicDraft;
    if (liveDraft != null) {
      if (remaining == 0) {
        return _TimelineItemPadding(child: _LivePublicOutput(text: liveDraft));
      }
      remaining--;
    }
    if (_modelOutputPending) {
      if (remaining == 0) {
        return _TimelineItemPadding(
          child: _PendingPublicOutput(text: _modelOutputPendingText),
        );
      }
      remaining--;
    }
    final event = _events[remaining];
    return _TimelineItemPadding(child: _EventCard(event: event));
  }

  @override
  Widget build(BuildContext context) {
    final error = _streamError;
    final liveDraft = _livePublicDraft;
    if (_events.isEmpty &&
        liveDraft == null &&
        !_modelOutputPending &&
        error == null) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text('等待公开执行动态…'),
      );
    }
    return Padding(
      // Keep the event scrollbar in its own hit-test lane. The outer details
      // scrollbar lives at the panel edge; this inset prevents the two thumbs
      // from covering one another while preserving wheel and drag scrolling.
      padding: const EdgeInsets.only(right: 12),
      child: Scrollbar(
        key: const Key('work-task-event-scrollbar'),
        controller: _eventScrollController,
        thumbVisibility: true,
        interactive: true,
        child: ListView.builder(
          key: const Key('work-task-event-timeline'),
          controller: _eventScrollController,
          primary: false,
          padding: EdgeInsets.zero,
          itemCount: _timelineItemCount,
          itemBuilder: _buildTimelineItem,
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
