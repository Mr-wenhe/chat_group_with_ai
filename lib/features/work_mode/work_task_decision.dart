import 'package:chat_group/core/models/agent_task.dart';

import 'work_discussion_state.dart';
import 'work_collaboration_state.dart';

/// Read-only projection of the authoritative v2 collaboration decision.
/// A dialog, panel and chat action all read this same checkpoint.
class WorkTaskDecision {
  final String taskId;
  final String id;
  final int revision;
  final String status;
  final String reason;
  final String evidence;
  final String impact;
  final String answer;
  final String missingCondition;
  final String kind;
  final String targetId;
  final String promptedReminder;
  final List<Map<String, String>> options;
  final bool remainderReady;

  const WorkTaskDecision({
    required this.taskId,
    required this.id,
    required this.revision,
    required this.status,
    required this.reason,
    required this.evidence,
    required this.impact,
    required this.answer,
    required this.missingCondition,
    required this.kind,
    required this.targetId,
    required this.promptedReminder,
    required this.options,
    required this.remainderReady,
  });

  bool get isOpen => status == 'pending' || status == 'deferred';
  String? get reminderKind => status == 'pending'
      ? 'initial'
      : status == 'deferred' && remainderReady
          ? 'remainderReady'
          : null;

  /// 弹窗关闭后仍要补记提醒的决策。
  ///
  /// 弹窗打开到关闭之间，用户可能已经作答或暂缓其中一条，那条决策的修订和提醒种类
  /// 都会随之变化；按弹窗前的快照去 `markDecisionPromptShown` 一定落空，而落空就
  /// 意味着刚弹出的提醒立刻再次满足条件、弹窗马上重开（用户点「此项先放着」后重开）。
  /// 因此这里取**关闭后的当前状态**：[shown] 只用来限定"这次弹窗真的展示过哪几条"，
  /// 修订与提醒种类都按当前值读。
  ///
  /// 只补记当前确实有待发提醒的决策：暂缓后还没到收尾时机的（`reminderKind` 为 null）
  /// 不会被记账，收尾提醒仍会在其它工作项结束时照常弹出。
  static List<WorkTaskDecision> remindersToClaim(
    Iterable<WorkTaskDecision> shown,
    AgentTask task,
  ) {
    final shownIds = <String>{for (final item in shown) item.id};
    return <WorkTaskDecision>[
      for (final item in forTask(task))
        if (item.isOpen &&
            shownIds.contains(item.id) &&
            item.reminderKind != null &&
            item.promptedReminder != item.reminderKind)
          item,
    ];
  }

  static List<WorkTaskDecision> forTask(AgentTask task) {
    if (!task.workModeTask || task.isTerminal) return const [];
    final decoded =
        WorkDiscussionState.decodeExecutionState(task.executionStateJson);
    final collaboration = decoded.state?.collaboration;
    if (!decoded.isValid ||
        collaboration == null ||
        collaboration.taskId != task.id ||
        collaboration.conversationId != task.groupId) {
      return const [];
    }
    final deferredTargets = collaboration.deferredWork;
    final completedIndependentWork = collaboration.workItems.any(
      (item) =>
          item['status'] == 'done' && !deferredTargets.contains(item['id']),
    );
    final remainderReady = task.status == AgentTaskStatus.paused &&
        collaboration.workItems.isNotEmpty &&
        (completedIndependentWork ||
            collaboration.workItems
                .every((i) => deferredTargets.contains(i['id']))) &&
        collaboration.workItems.every((item) =>
            item['status'] == 'done' ||
            deferredTargets.contains(item['id']) ||
            (item['dependencies'] as List).any(deferredTargets.contains));
    return [
      for (final item in collaboration.decisions)
        WorkTaskDecision(
          taskId: task.id,
          id: item['id'] as String,
          revision: item['revision'] as int,
          status: item['status'] as String,
          reason: item['reason'] as String,
          evidence: item['evidence']?.toString() ?? '',
          impact: item['impact'] as String,
          answer: item['answer'] as String,
          missingCondition: item['missingCondition']?.toString() ?? '',
          kind: item['kind']?.toString() ?? 'question',
          targetId: item['targetId']?.toString() ?? '',
          promptedReminder: item['promptedReminder']?.toString() ?? '',
          options: [
            for (final option
                in item['options'] is List ? item['options'] as List : const [])
              {
                'id': option['id'] as String,
                'label': option['label'] as String,
                'impact': option['impact'] as String,
              }
          ],
          remainderReady: remainderReady,
        ),
    ];
  }
}
