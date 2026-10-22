import 'dart:convert';

import 'work_collaboration_state.dart';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';

/// User decisions belong to the frozen bytes and current requirement/team only.
class WorkTaskCompletionChoice {
  static const key = 'candidateCompletionChoice';
  static const pauseKey = 'userSupplementPause';

  static Map<String, dynamic> root(AgentTask task) {
    if (task.executionStateJson.trim().isEmpty) return {};
    try {
      return Map<String, dynamic>.from(
          jsonDecode(task.executionStateJson) as Map);
    } on Object {
      return {};
    }
  }

  static String? identity(AgentTask task) {
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)
            ?.collaboration;
    final candidate = state?.currentIteration;
    if (state == null ||
        candidate == null ||
        candidate['requestRevision'] != state.requestRevision ||
        candidate['teamRevision'] != state.teamRevision) {
      return null;
    }
    return jsonEncode([
      task.id,
      state.requestRevision,
      state.teamRevision,
      candidate['id'],
      candidate['artifactDigest']
    ]);
  }

  static String? choice(AgentTask task) {
    final value = root(task)[key];
    return value is Map &&
            value['identity'] == identity(task) &&
            value['choice'] is String
        ? value['choice'] as String
        : null;
  }

  static bool pending(AgentTask task) {
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)
            ?.collaboration;
    return !task.isTerminal &&
        state?.taskId == task.id &&
        state?.conversationId == task.groupId &&
        state?.productionReady == true &&
        !root(task).containsKey('uncertainAction') &&
        root(task)['startupRecoveryPending'] != true &&
        state?.projectScopeId != 'portable-unbound' &&
        state?.phase == 'verifying' &&
        identity(task) != null &&
        choice(task) != 'test';
  }

  static bool paused(AgentTask task) => root(task)[pauseKey] == true;

  static void setChoice(AgentTask task, String choice) {
    final id = identity(task);
    if (id == null || !{'test', 'deliver'}.contains(choice)) {
      throw StateError('候选确认已失效，请查看最新成果。');
    }
    task.executionStateJson = jsonEncode(root(task)
      ..[key] = {
        'identity': id,
        'choice': choice,
      });
  }

  static void setPaused(AgentTask task, bool value) {
    final data = root(task);
    if (!value && !data.containsKey(pauseKey)) return;
    if (value) {
      data[pauseKey] = true;
    } else {
      data.remove(pauseKey);
    }
    task.executionStateJson = jsonEncode(data);
  }
}
