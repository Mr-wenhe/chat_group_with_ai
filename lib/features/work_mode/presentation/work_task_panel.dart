import 'dart:async';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:flutter/material.dart';

typedef WorkTaskEventStream = Stream<WorkTaskEvent> Function(String taskId);

/// Displays public task state without owning task execution or navigation.
///
/// Keeping this widget callback-driven makes hiding/collapsing a UI concern;
/// only the app-scoped coordinator can stop a task.
class WorkTaskPanel extends StatefulWidget {
  final List<AgentTask> tasks;
  final String? selectedTaskId;
  final WorkTaskEventStream eventStreamFor;
  final ValueChanged<String> onSelectTask;
  final ValueChanged<String> onStop;
  final ValueChanged<String> onContinue;
  final ValueChanged<String> onOpenConversation;
  final VoidCallback onCollapse;
  final VoidCallback onClose;
  final DateTime Function() clock;

  const WorkTaskPanel({
    super.key,
    required this.tasks,
    required this.eventStreamFor,
    required this.onSelectTask,
    required this.onStop,
    required this.onContinue,
    required this.onOpenConversation,
    required this.onCollapse,
    required this.onClose,
    this.selectedTaskId,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  @override
  State<WorkTaskPanel> createState() => _WorkTaskPanelState();
}

class _WorkTaskPanelState extends State<WorkTaskPanel> {
  final Map<String, WorkTaskEvent> _latestEvents = <String, WorkTaskEvent>{};
  final Map<String, WorkTaskEvent> _latestActionEvents =
      <String, WorkTaskEvent>{};
  final Map<String, WorkTaskEvent> _latestToolEvents =
      <String, WorkTaskEvent>{};
  Timer? _durationTicker;

  @override
  void initState() {
    super.initState();
    _durationTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _durationTicker?.cancel();
    super.dispose();
  }

  AgentTask? get _selectedTask {
    final selectedTaskId = widget.selectedTaskId;
    if (selectedTaskId != null) {
      for (final task in widget.tasks) {
        if (task.id == selectedTaskId) return task;
      }
    }
    return widget.tasks.isEmpty ? null : widget.tasks.first;
  }

  @override
  Widget build(BuildContext context) {
    final task = _selectedTask;
    if (task == null) return const SizedBox.shrink();
    final latestEvent = _latestEvents[task.id];
    final latestAction = _latestActionEvents[task.id] ?? latestEvent;
    final continueReason = _continueUnavailableReason(task);
    final stopReason = task.isTerminal ? '任务已结束，无法停止。' : null;
    final toolName =
        _toolName(latestEvent) ?? _toolName(_latestToolEvents[task.id]);
    final approvalText =
        task.status == AgentTaskStatus.waitingForApproval ? '等待你批准当前操作。' : null;

    return Material(
      key: const Key('work-task-panel'),
      elevation: 12,
      borderRadius: BorderRadius.circular(20),
      color: Theme.of(context).colorScheme.surface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _PanelHeader(
                onCollapse: widget.onCollapse,
                onClose: widget.onClose,
              ),
              const SizedBox(height: 10),
              _TaskTabs(
                tasks: widget.tasks,
                selectedTaskId: task.id,
                onSelectTask: widget.onSelectTask,
              ),
              const SizedBox(height: 14),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        task.userRequest,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text('执行角色：${task.characterId}'),
                      const SizedBox(height: 4),
                      Text('步骤 ${task.currentStep} / ${task.actionLimit}'),
                      const SizedBox(height: 4),
                      Text(_durationLabel(task, widget.clock())),
                      const SizedBox(height: 12),
                      _PublicDetail(
                        title: '计划摘要',
                        text:
                            task.plan.trim().isEmpty ? '尚未生成公开计划。' : task.plan,
                      ),
                      const SizedBox(height: 8),
                      _PublicDetail(
                        title: '当前动作',
                        text: latestAction == null
                            ? _statusLabel(task.status)
                            : latestAction.title,
                        inline: true,
                      ),
                      if (toolName != null) ...<Widget>[
                        const SizedBox(height: 8),
                        _PublicDetail(
                          title: '工具',
                          text: toolName,
                          inline: true,
                        ),
                      ],
                      if (approvalText != null) ...<Widget>[
                        const SizedBox(height: 8),
                        _PublicDetail(
                          title: '审批',
                          text: approvalText,
                          inline: true,
                        ),
                      ],
                      if (task.resultSummary.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        _PublicDetail(title: '结论', text: task.resultSummary),
                      ],
                      const SizedBox(height: 14),
                      Text('执行动态',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      SizedBox(
                        height: 180,
                        child: _TaskEventTimeline(
                          key: ValueKey<String>(task.id),
                          taskId: task.id,
                          eventStreamFor: widget.eventStreamFor,
                          onLatestEvent: _rememberLatestEvent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OutlinedButton.icon(
                    key: const Key('work-task-open-conversation'),
                    onPressed: () => widget.onOpenConversation(task.groupId),
                    icon: const Icon(Icons.forum_outlined),
                    label: const Text('回到对话'),
                  ),
                  Tooltip(
                    message: stopReason ?? '停止当前任务。',
                    child: OutlinedButton.icon(
                      key: const Key('work-task-stop'),
                      onPressed: stopReason == null
                          ? () => widget.onStop(task.id)
                          : null,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('停止'),
                    ),
                  ),
                  Tooltip(
                    message: continueReason ?? '继续当前任务。',
                    child: FilledButton.icon(
                      key: const Key('work-task-continue'),
                      onPressed: continueReason == null
                          ? () => widget.onContinue(task.id)
                          : null,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('继续'),
                    ),
                  ),
                  Tooltip(
                    message: '撤销将在任务快照完成后可用。',
                    child: OutlinedButton.icon(
                      key: const Key('work-task-undo'),
                      onPressed: null,
                      icon: const Icon(Icons.undo_rounded),
                      label: const Text('撤销'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _rememberLatestEvent(WorkTaskEvent event) {
    final current = _latestEvents[event.taskId];
    if (current != null && current.sequence >= event.sequence) return;
    if (!mounted) return;
    setState(() {
      _latestEvents[event.taskId] = event;
      if (_isActionEvent(event)) {
        _latestActionEvents[event.taskId] = event;
      }
      if (_toolName(event) != null) {
        _latestToolEvents[event.taskId] = event;
      }
    });
  }

  bool _isActionEvent(WorkTaskEvent event) {
    return event.kind == WorkTaskEventKind.planning ||
        event.kind == WorkTaskEventKind.stepStarted ||
        event.kind == WorkTaskEventKind.approvalRequired ||
        event.kind == WorkTaskEventKind.paused;
  }

  String? _continueUnavailableReason(AgentTask task) {
    if (task.softLimitReached) return null;
    if (task.status == AgentTaskStatus.interrupted ||
        task.status == AgentTaskStatus.paused) {
      return null;
    }
    if (task.status == AgentTaskStatus.waitingForApproval) {
      return '请先批准当前操作。';
    }
    if (task.isTerminal) return '任务已结束，无需继续。';
    return '任务正在执行，无需继续。';
  }

  String? _toolName(WorkTaskEvent? event) {
    if (event == null) return null;
    final tool = event.safeMetadata['tool'];
    return tool is String && tool.trim().isNotEmpty ? tool : null;
  }
}

class _PanelHeader extends StatelessWidget {
  final VoidCallback onCollapse;
  final VoidCallback onClose;

  const _PanelHeader({required this.onCollapse, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Icon(Icons.auto_awesome_rounded),
        const SizedBox(width: 8),
        Expanded(
          child: Text('工作任务', style: Theme.of(context).textTheme.titleLarge),
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

  const _TaskTabs({
    required this.tasks,
    required this.selectedTaskId,
    required this.onSelectTask,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: tasks
          .map(
            (task) => ChoiceChip(
              key: Key('work-task-tab-${task.id}'),
              label: Text('任务 ${tasks.indexOf(task) + 1}'),
              selected: task.id == selectedTaskId,
              onSelected: (_) => onSelectTask(task.id),
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
  StreamSubscription<WorkTaskEvent>? _subscription;

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
    _subscription?.cancel();
    _listen();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _listen() {
    _subscription = widget.eventStreamFor(widget.taskId).listen(
      (event) {
        if (event.taskId != widget.taskId ||
            _events.any((item) => item.sequence == event.sequence)) {
          return;
        }
        if (!mounted) return;
        setState(() {
          _events.add(event);
          _events
              .sort((left, right) => left.sequence.compareTo(right.sequence));
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onLatestEvent(event);
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_events.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text('等待公开执行动态…'),
      );
    }
    return SingleChildScrollView(
      key: const Key('work-task-event-timeline'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _events
            .expand<Widget>((event) => <Widget>[
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(event.title),
                          if (event.detail.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 2),
                            Text(event.detail),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                ])
            .toList(growable: false),
      ),
    );
  }
}

String _durationLabel(AgentTask task, DateTime now) {
  final startedAt = task.startedAt ?? task.createdAt;
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
