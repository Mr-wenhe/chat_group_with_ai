import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';

/// Identifies a work task that is paused because the model needs a textual
/// answer from the user before it can safely continue.
class WorkTaskClarification {
  const WorkTaskClarification._();

  static const String requiredKey = 'clarificationRequired';
  static const String questionKey = 'clarificationQuestion';

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

  static String question(AgentTask task) {
    final raw = _decode(task.executionStateJson)[questionKey];
    return raw is String && raw.trim().isNotEmpty
        ? raw.trim()
        : task.lastError.trim();
  }

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
