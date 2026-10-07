import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_follow_up_policy.dart';

import 'work_task_decision.dart';

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
  static const String optionsKey = 'clarificationOptions';
  static const String answerRejectedKey = 'clarificationAnswerRejected';

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
      isPending(task) ||
      isFollowUpPending(task) ||
      WorkTaskDecision.forTask(task).any((decision) => decision.isOpen);

  static String question(AgentTask task) {
    final raw = _decode(task.executionStateJson)[questionKey];
    return raw is String && raw.trim().isNotEmpty
        ? raw.trim()
        : task.lastError.trim();
  }

  /// 可回答问题的展示文案（模型问题与追问澄清共用同一读取路径）。
  static String answerableQuestion(AgentTask task) {
    final decision =
        WorkTaskDecision.forTask(task).where((item) => item.isOpen).firstOrNull;
    return decision?.reason ?? question(task);
  }

  /// 追问澄清的候选目标，供面板渲染点击按钮。
  ///
  /// 与 [question] 同源：问题清单里的第几条就是这里的第几个选项，所以两者必须
  /// 一起落盘、一起清除。模型提问没有结构化候选，这里恒为空。
  static List<WorkFollowUpOption> options(AgentTask task) =>
      WorkFollowUpOption.listFromJson(
        _decode(task.executionStateJson)[optionsKey],
      );

  /// 上一次答复没能被采纳（读不出目标，问题原样再问一遍）。
  ///
  /// 没有这个标记，用户看到的就是同一句话重复出现，分不清系统是没收到答复，
  /// 还是收到了但看不懂。缺省为 false：旧检查点写下时还没有这个字段，
  /// 按"还没答过"读比按"答错了"读更保守 —— 后者会凭空指责用户。
  static bool answerRejected(AgentTask task) =>
      _decode(task.executionStateJson)[answerRejectedKey] == true;

  static void markPending(AgentTask task, String question) {
    final metadata = _decode(task.executionStateJson)
      ..[requiredKey] = true
      ..[questionKey] = question.trim();
    task.executionStateJson = jsonEncode(metadata);
  }

  /// Drops the question because it has been answered through another route.
  ///
  /// Without this the marker outlives the answer, and the next time the task
  /// pauses for an unrelated reason the panel offers a reply box for a question
  /// that no longer exists — the same "answerable according to one rule, not
  /// according to another" dead end this class exists to prevent.
  static void clear(AgentTask task) {
    final metadata = _decode(task.executionStateJson)
      ..remove(requiredKey)
      ..remove(questionKey)
      // 选项是问题的一部分，跟着问题一起走：留下的按钮属于一个已经不存在的
      // 提问，点下去只会提交一个没人认领的路径。
      ..remove(optionsKey)
      // "上次答复没看懂"同理：问题都解开了，这句指责必须一起消失。
      ..remove(answerRejectedKey);
    // Only this class's own keys are touched; a checkpoint that carried nothing
    // else legitimately becomes empty.
    task.executionStateJson = metadata.isEmpty ? '' : jsonEncode(metadata);
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
