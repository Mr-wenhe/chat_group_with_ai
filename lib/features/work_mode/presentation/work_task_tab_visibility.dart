import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';

/// 任务面板"该显示哪些任务"的判据。
///
/// 宿主 `WorkTaskOverlayHost` 还要管覆盖层、审批弹窗和浏览器面板，已经很大；
/// 而这一组规则可以脱离 widget 独立推理、独立测试，所以单独放这里。全部方法只
/// 读入参，不持有状态：调用方每次传入当前的隐藏标记与所在会话。
class WorkTaskTabVisibility {
  const WorkTaskTabVisibility._();

  /// 标签栏最多同时显示几条任务，其余折叠成下方的计数行。
  static const int maxTabs = 4;

  /// 占用执行槽的状态。这类任务即使属于别的会话也必须留在标签栏上：
  /// 切走页面任务照跑是工作模式的核心承诺，用户在哪儿都得看得见。
  static bool occupiesExecutionSlot(AgentTaskStatus status) =>
      status == AgentTaskStatus.planning ||
      status == AgentTaskStatus.waitingForApproval ||
      status == AgentTaskStatus.runningTool;

  /// 标签栏要展示的任务，执行中的优先。
  ///
  /// 标签栏回答的是"我现在该盯哪几条任务"：当前会话的任务，加上别的会话里正在
  /// 执行的任务。别的会话的终态、排队、暂停任务属于历史——它们曾经占满标签栏，
  /// 让用户在当前会话里找不到自己刚提交的那一条。
  ///
  /// [activeConversationId] 为空表示不在任何会话里（角色列表、设置页等）：那时
  /// 没有可归属的会话，收敛范围只会让面板在这些页面上凭空消失，因此保留旧行为
  /// ——按更新时间取最新几条，两个执行槽都占满时只展示执行中的任务。
  static List<AgentTask> visibleTasks(
    List<AgentTask> allTasks, {
    required Set<String> hiddenTaskIds,
    required String? activeConversationId,
    String? preferredTaskId,
  }) {
    // 被用户关掉标签的任务不参与挑选，但仍在 allTasks 里，供历史任务回查。
    final sorted = allTasks
        .where((task) => !hiddenTaskIds.contains(task.id))
        .toList()
      ..sort(
        (left, right) => (right.updatedAt ?? right.createdAt)
            .compareTo(left.updatedAt ?? left.createdAt),
      );
    if (activeConversationId == null) {
      final active = sorted
          .where((task) => occupiesExecutionSlot(task.status))
          .toList(growable: false);
      final rest = sorted
          .where((task) => !occupiesExecutionSlot(task.status))
          .toList(growable: false);
      // 反正是协调器的并发槽数：本地再写一个 2 会在槽位调整后静默分叉。
      const executionSlotCount = WorkTaskCoordinator.maximumConcurrentTasks;
      final visible = active.length >= executionSlotCount
          ? active.take(executionSlotCount).toList(growable: false)
          : <AgentTask>[...active, ...rest]
              .take(maxTabs)
              .toList(growable: false);
      return _withPreferred(visible, sorted, preferredTaskId);
    }
    final inConversation = sorted
        .where((task) => task.groupId == activeConversationId)
        .toList(growable: false);
    final activeElsewhere = sorted
        .where((task) =>
            task.groupId != activeConversationId &&
            occupiesExecutionSlot(task.status))
        .toList(growable: false);
    // 会话内仍按"执行中的优先"排序：一条更新的排队任务不允许把正在跑的任务挤出
    // 标签栏。
    final visible = <AgentTask>[
      ...inConversation.where((task) => occupiesExecutionSlot(task.status)),
      ...activeElsewhere,
      ...inConversation.where((task) => !occupiesExecutionSlot(task.status)),
    ].take(maxTabs).toList(growable: false);
    return _withPreferred(visible, sorted, preferredTaskId);
  }

  /// 标签栏折叠起来的、当前会话尚未结束的任务数。
  ///
  /// 只数当前会话：这里曾经用整个 App 的任务流减去展示的标签，于是别的会话里
  /// 早已结束的历史任务也被算成"还有 18 个任务在队列中"，队列长度看着像积压。
  /// 用户自己关掉的标签不算——那是他主动收起来的，不该再回来提示。
  static int foldedUnfinishedCount(
    List<AgentTask> allTasks,
    List<AgentTask> visible, {
    required Set<String> hiddenTaskIds,
    required String? activeConversationId,
  }) {
    if (activeConversationId == null) return 0;
    final visibleIds = visible.map((task) => task.id).toSet();
    return allTasks
        .where((task) =>
            task.groupId == activeConversationId &&
            !task.isTerminal &&
            !hiddenTaskIds.contains(task.id) &&
            !visibleIds.contains(task.id))
        .length;
  }

  /// 面板是否还有理由出现。
  ///
  /// 标签栏为空不等于没有可看的东西：当前会话的任务记录（哪怕都已结束）也要让
  /// 面板留着——「历史任务」入口在面板里，一旦整体消失，那些记录就再也找不回来。
  static bool hasContent(
    List<AgentTask> allTasks,
    List<AgentTask> visible, {
    required Set<String> hiddenTaskIds,
    required String? activeConversationId,
  }) {
    if (visible.isNotEmpty) return true;
    if (allTasks.any((task) => hiddenTaskIds.contains(task.id))) return true;
    if (activeConversationId == null) return false;
    return allTasks.any((task) => task.groupId == activeConversationId);
  }

  /// 用户点名要看的那条任务始终可见。
  ///
  /// 从聊天卡片打开任务比"关掉标签"更新，所以这里是"追加"而不是"替换"：
  /// 分页只是展示问题，任何情况下都不能改变消息指向的任务 id。
  static List<AgentTask> _withPreferred(
    List<AgentTask> visible,
    List<AgentTask> sorted,
    String? preferredTaskId,
  ) {
    if (preferredTaskId == null ||
        visible.any((task) => task.id == preferredTaskId)) {
      return visible;
    }
    final preferred =
        sorted.where((task) => task.id == preferredTaskId).firstOrNull;
    return preferred == null ? visible : <AgentTask>[...visible, preferred];
  }
}
