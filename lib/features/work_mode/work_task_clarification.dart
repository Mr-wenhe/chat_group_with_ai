import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_follow_up_policy.dart';

/// Identifies a work task that is paused because the model needs a textual
/// answer from the user before it can safely continue.
///
/// 这里同时承载**两类**需要用户回答的问题：模型在运行中提出的问题，以及协调器
/// 在跟进请求里无法确定修订目标时提出的问题。两者都是"任务在等用户输入"，
/// 可回答性只能由同一处判定：一旦判据分散，就会出现一个判据说"要先回答"、
/// 另一个判据说"不需要回答"的死角——面板不给回复框、"继续"又被拒绝，
/// 任务既答不了也退不出。
class WorkTaskClarification {
  const WorkTaskClarification._();

  static const String requiredKey = 'clarificationRequired';
  static const String questionKey = 'clarificationQuestion';

  /// 协调器写入的跟进分类字段与"澄清"取值（见 [WorkFollowUpKind]）。
  static const String followUpKindKey = 'followUpKind';
  static final String followUpClarificationKind =
      WorkFollowUpKind.clarification.name;

  static bool isPending(AgentTask task) {
    if (task.status != AgentTaskStatus.paused &&
        task.status != AgentTaskStatus.interrupted) {
      return false;
    }
    final metadata = _decode(task.executionStateJson);
    if (metadata[requiredKey] == true) return true;

    // Older checkpoints did not persist the clarification marker. A paused
    // user-action question with no tool checkpoint is safe to treat as a text
    // clarification when its public message is visibly phrased as a question.
    final question = task.lastError.trim();
    return task.resumeRequired &&
        task.pendingToolRequestJson.trim().isEmpty &&
        (question.endsWith('？') || question.endsWith('?'));
  }

  /// 跟进澄清：请求要改既有产物，但无法唯一确定改哪一个，于是暂停问用户。
  ///
  /// 只认暂停态：答复入口（`enqueueFollowUp`）同样只接受暂停态，把别的状态也算
  /// 进来会让面板给出一个按下去就报错的入口。
  static bool isFollowUpPending(AgentTask task) {
    if (task.status != AgentTaskStatus.paused) return false;
    final metadata = _decode(task.executionStateJson);
    return metadata[followUpKindKey] == followUpClarificationKind &&
        metadata[questionKey] is String;
  }

  /// 面板与聊天是否需要为此任务提供回答入口。
  static bool isAnswerable(AgentTask task) =>
      isPending(task) || isFollowUpPending(task);

  static String question(AgentTask task) {
    final raw = _decode(task.executionStateJson)[questionKey];
    return raw is String && raw.trim().isNotEmpty
        ? raw.trim()
        : task.lastError.trim();
  }

  /// 可回答问题的展示文案（模型问题与追问澄清共用同一读取路径）。
  static String answerableQuestion(AgentTask task) => question(task);

  static void markPending(AgentTask task, String question) {
    final metadata = _decode(task.executionStateJson)
      ..[requiredKey] = true
      ..[questionKey] = question.trim();
    task.executionStateJson = jsonEncode(metadata);
  }

  static Map<String, dynamic> _decode(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? Map<String, dynamic>.from(decoded)
          : decoded is Map
              ? Map<String, dynamic>.from(decoded)
              : <String, dynamic>{};
    } on Object {
      return <String, dynamic>{};
    }
  }
}
