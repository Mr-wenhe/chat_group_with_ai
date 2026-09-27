part of 'work_task_panel.dart';

/// 任务标签栏里显示的名字：取用户指令首行并截断。
///
/// 标签栏是用户唯一能一眼分辨"哪一个任务"的地方，因此这里必须复用历史列表
/// 的标题规则。「任务 1」这类序号既不说明在做什么，也会随列表变化改号。
String workTaskTabLabel(AgentTask task, {int maxLength = 12}) =>
    workTaskHistoryTitle(task, maxLength: maxLength);

/// 历史任务列表里显示的标题：取用户指令首行并截断。
///
/// 历史列表按需求只展示「时间 + 标题」，因此这里不拼接状态、角色等信息，
/// 避免把任务执行细节提前泄露到列表层级。
String workTaskHistoryTitle(AgentTask task, {int maxLength = 28}) {
  final firstLine = task.userRequest
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  final safe = _safePanelText(firstLine);
  if (safe.isEmpty) return '未命名任务';
  return safe.length <= maxLength ? safe : '${safe.substring(0, maxLength)}…';
}

/// 历史任务列表里显示的时间，精确到分钟。
String workTaskHistoryTime(DateTime time) {
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${pad(time.month)}-${pad(time.day)} '
      '${pad(time.hour)}:${pad(time.minute)}';
}

/// 历史任务列表里显示的次行：创建时间，必要时附上"已从标签栏隐藏"。
String workTaskHistorySubtitle(
  AgentTask task, {
  bool hiddenFromTabStrip = false,
}) {
  final time = workTaskHistoryTime(task.createdAt);
  return hiddenFromTabStrip ? '$time · 已从标签栏隐藏' : time;
}

/// 历史任务列表：每行只显示创建时间和标题，点击后由外层切到任务详情。
class _TaskHistoryList extends StatefulWidget {
  final List<AgentTask> tasks;
  final ValueChanged<String> onSelectTask;
  final Set<String> hiddenTaskIds;

  const _TaskHistoryList({
    required this.tasks,
    required this.onSelectTask,
    this.hiddenTaskIds = const <String>{},
  });

  @override
  State<_TaskHistoryList> createState() => _TaskHistoryListState();
}

class _TaskHistoryListState extends State<_TaskHistoryList> {
  final ScrollController _historyScrollController = ScrollController();

  @override
  void dispose() {
    _historyScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tasks.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text('当前会话还没有历史任务。'),
      );
    }
    return Scrollbar(
      key: const Key('work-task-history-scrollbar'),
      controller: _historyScrollController,
      thumbVisibility: true,
      child: ListView.builder(
        key: const Key('work-task-history-list'),
        controller: _historyScrollController,
        primary: false,
        padding: EdgeInsets.zero,
        itemCount: widget.tasks.length,
        itemBuilder: (context, index) {
          final task = widget.tasks[index];
          return ListTile(
            key: Key('work-task-history-item-${task.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(workTaskHistoryTitle(task)),
            subtitle: Text(workTaskHistorySubtitle(
              task,
              hiddenFromTabStrip: widget.hiddenTaskIds.contains(task.id),
            )),
            onTap: () => widget.onSelectTask(task.id),
          );
        },
      ),
    );
  }
}
