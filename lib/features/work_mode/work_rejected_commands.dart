import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'work_task_execution_policy.dart';
import 'work_discussion_state.dart';

/// Reopen persisted denials or resubmit a current contract check for approval.
List<String> reviewableCommandCheckpointsFor(AgentTask task) {
  if (!WorkTaskExecutionPolicy.isValidatedV2GroupTask(task) ||
      !(task.isUserStopped ||
          task.status == AgentTaskStatus.paused ||
          task.status == AgentTaskStatus.failed ||
          task.status == AgentTaskStatus.interrupted)) {
    return const [];
  }
  try {
    final root = jsonDecode(task.executionStateJson);
    if (root is! Map || root['rejectedOperationFingerprints'] is! List) {
      return const [];
    }
    final denied = root['rejectedOperationFingerprints'] as List;
    final checks =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)
            ?.collaboration
            ?.artifactContract['verificationCommands'];
    final baselines = <Map>[];
    if (checks is List) {
      for (final value in checks.whereType<String>()) {
        try {
          final command = jsonDecode(value);
          if (command is Map) baselines.add(command);
        } on Object {
          /* Invalid contract commands never become approval choices. */
        }
      }
    }
    final matches = <String>[];
    for (final raw in task.completedOperations.reversed) {
      final checkpoint = safeToolRequestCheckpointJson(raw);
      if (checkpoint.isEmpty || matches.contains(checkpoint)) continue;
      final operation = jsonDecode(checkpoint) as Map;
      final args = operation['args'];
      if (operation['tool'] == 'command.run' &&
          args is Map &&
          args['executable'] is String &&
          args['arguments'] is List &&
          (denied.contains(
                  sha256.convert(utf8.encode(checkpoint)).toString()) ||
              baselines.any((command) =>
                  command['executable'] == args['executable'] &&
                  jsonEncode(command['arguments']) ==
                      jsonEncode(args['arguments'])))) {
        matches.add(checkpoint);
      }
    }
    return matches;
  } on Object {
    return const [];
  }
}

/// This is a request to use the normal approval pipeline, never execution consent.
Map<String, dynamic>? commandReapprovalContextFor(AgentTask task) {
  if (!WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) return null;
  try {
    final root = jsonDecode(task.executionStateJson) as Map;
    final pending = root['commandReapprovalRequest'];
    if (pending is! Map ||
        jsonEncode(pending['binding']) !=
            jsonEncode(root['workItemExecution'])) {
      return null;
    }
    final checkpoint =
        safeToolRequestCheckpointJson(jsonEncode(pending['operation']));
    if (checkpoint.isEmpty) return null;
    final operation = jsonDecode(checkpoint) as Map;
    if (operation['tool'] != 'command.run') return null;
    return {
      'operation': operation,
      'instruction':
          '用户已明确请求重新提交这条命令审批。请直接提交此command.run请求，不要再重复读取已有文件；这不是执行许可，仍须通过正常工具、目录和审批校验。不得替换为其他命令或副作用。'
    };
  } on Object {
    return null;
  }
}
