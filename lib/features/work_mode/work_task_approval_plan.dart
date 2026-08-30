import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';

import 'work_change_plan.dart';

/// Reads the display-safe approval plan persisted by the production runner.
///
/// The pending tool checkpoint deliberately omits file contents and reduces
/// paths to names. The separate plan keeps exact authorized paths available to
/// the approval UI without exposing the mutation payload.
WorkChangePlan? approvalPlanForTask(AgentTask task) {
  final raw = task.executionStateJson.trim();
  if (raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final planJson = decoded['approvalPlan'];
    if (planJson is Map) {
      final plan = WorkChangePlan.fromJson(Map<String, dynamic>.from(planJson));
      return plan.taskId == task.id ? plan : null;
    }
    return _legacyPlanFromCheckpoint(task, decoded);
  } on Object {
    // A malformed checkpoint must not create an approval UI that claims a
    // path is covered. The runner will re-plan and ask again.
    return null;
  }
}

WorkChangePlan? _legacyPlanFromCheckpoint(
  AgentTask task,
  Map<dynamic, dynamic> checkpoint,
) {
  final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
  if (pending == null ||
      (pending.tool != AgentToolName.workspacePatch &&
          pending.tool != AgentToolName.workspaceRename &&
          pending.tool != AgentToolName.workspaceDelete)) {
    return null;
  }
  final rawScope = checkpoint['approvalScope'];
  if (rawScope is! Map) return null;
  final scope = WorkApprovalScope.fromJson(
    Map<String, dynamic>.from(rawScope),
  );
  if (scope.taskId != task.id) return null;
  final exactPaths = scope.entries
      .where((entry) => entry.kind == WorkApprovalScopePathKind.file)
      .map((entry) => entry.path)
      .toList(growable: false);
  final directories = scope.entries
      .where((entry) => entry.kind == WorkApprovalScopePathKind.directory)
      .map((entry) => entry.path)
      .toList(growable: false);
  if (exactPaths.isEmpty) return null;
  final action = scope.entries.expand((entry) => entry.actions).firstWhere(
        (item) => item != WorkChangeActionType.command,
        orElse: () => WorkChangeActionType.modify,
      );
  final contentLength = _safeContentLength(pending);
  return WorkChangePlan(
    taskId: task.id,
    actionType: action,
    exactPaths: exactPaths,
    knownAffectedDirectories: directories,
    estimatedBytes: contentLength,
    snapshotAvailable: true,
    reversible: true,
    riskReason: '工作模式需要在已授权目录内执行文件变更。',
  );
}

int _safeContentLength(ToolRequest request) {
  final raw = request.args['contentLength'];
  if (raw is int && raw >= 0) return raw;
  return 0;
}
