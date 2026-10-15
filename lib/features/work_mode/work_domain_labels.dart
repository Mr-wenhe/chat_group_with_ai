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
  static EntityIdResolver forConversation(
    DatabaseService database,
    String conversationId,
  ) {
    WorkDomainLabels? cached;
    var loaded = false;
    return (id) {
      if (!loaded) {
        loaded = true;
        for (final task in database.agentTaskBox.values) {
          if (task.groupId != conversationId) continue;
          final decoded =
              WorkDiscussionState.decodeExecutionState(task.executionStateJson);
          final collaboration = decoded.state?.collaboration;
          if (collaboration != null) {
            cached = WorkDomainLabels(collaboration);
            break;
          }
        }
      }
      return cached?.resolver(id);
    };
  }
}
