import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/text/entity_labels.dart';

import 'work_collaboration_state.dart';
import 'work_discussion_state.dart';

/// 协作状态里的 id → 人话标签（迭代/问题/验收/工作项只有 work_mode 认识）。
///
/// 只用于显示：这些 id 在检查点与事件里必须继续原样保存。
class WorkDomainLabels {
  WorkDomainLabels(this.state);

  final WorkCollaborationState? state;

  EntityIdResolver get resolver => _resolve;

  String? _resolve(String id) {
    final current = state;
    if (current == null || id.trim().isEmpty) return null;
    return _indexed(current.iterations, id, '第 %s 轮候选') ??
        _indexed(current.issues, id, '问题 %s') ??
        _indexed(current.acceptances, id, '验收项 %s') ??
        _indexed(current.workItems, id, '工作项 %s');
  }

  static String? _indexed(
    List<Map<String, dynamic>> items,
    String id,
    String template,
  ) {
    for (var index = 0; index < items.length; index++) {
      if (items[index]['id'] == id) {
        return template.replaceFirst('%s', '${index + 1}');
      }
    }
    return null;
  }

  /// 气泡侧用：文案里出现 token 时才解析该会话的任务状态，避免每次渲染都解析 JSON。
  ///
  /// **按 id 归属解析，而不是只认某一条任务**：一个会话可以有多条 v2 任务（当前这条、
  /// 更早那条、刚被追问接手的），只取第一条会让当前任务的候选版本 id 解析不到、
  /// 退成「未知对象」。任务集合发生变化（新任务落库、旧任务被删）时重扫一次，
  /// 集合没变就只做零成本的命中判断——既不把「当前解析不到」永久钉死，也不在
  /// 每次渲染都解析一遍全部任务 JSON。
  static EntityIdResolver forConversation(
    DatabaseService database,
    String conversationId,
  ) {
    var resolvers = _collect(database, conversationId);
    var knownTaskCount = database.agentTaskBox.length;
    return (id) {
      final hit = _firstHit(resolvers, id);
      if (hit != null) return hit;
      if (database.agentTaskBox.length == knownTaskCount) return null;
      knownTaskCount = database.agentTaskBox.length;
      resolvers = _collect(database, conversationId);
      return _firstHit(resolvers, id);
    };
  }

  static String? _firstHit(List<EntityIdResolver> resolvers, String id) {
    for (final resolve in resolvers) {
      final label = resolve(id);
      if (label != null) return label;
    }
    return null;
  }

  static List<EntityIdResolver> _collect(
    DatabaseService database,
    String conversationId,
  ) {
    final collected = <EntityIdResolver>[];
    for (final task in database.agentTaskBox.values) {
      if (task.groupId != conversationId) continue;
      final decoded =
          WorkDiscussionState.decodeExecutionState(task.executionStateJson);
      final collaboration = decoded.state?.collaboration;
      if (collaboration != null) {
        collected.add(WorkDomainLabels(collaboration).resolver);
      }
    }
    return collected;
  }

  /// 把任务的协作状态解析器叠加到已有标签上（面板与决策弹窗共用一份判据）。
  static EntityLabels? labelsForTask(
    EntityLabels? base,
    String executionStateJson,
  ) {
    if (base == null) return null;
    final collaboration = WorkDiscussionState.decodeExecutionState(
      executionStateJson,
    ).state?.collaboration;
    if (collaboration == null) return base;
    return base.withResolver(WorkDomainLabels(collaboration).resolver);
  }
}
