import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'agent_decision.dart';
import 'work_discussion_state.dart';
import 'work_collaboration_state.dart';
import 'work_task_coordinator.dart';
import 'work_tool_registry.dart';

/// A scheduler-issued binding, never derived from a role's public text.
class WorkInvestigationBinding {
  final String taskId;
  final String memberId;
  final String issueId;
  final int requestRevision;
  final int teamRevision;
  const WorkInvestigationBinding(
      {required this.taskId,
      required this.memberId,
      required this.issueId,
      required this.requestRevision,
      required this.teamRevision});

  bool matches(AgentTask task) {
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)
            ?.collaboration;
    return state != null &&
        task.workModeTask &&
        !task.isTerminal &&
        !task.groupId.startsWith('dm:') &&
        state.conversationId == task.groupId &&
        state.taskId == taskId &&
        task.id == taskId &&
        state.requestRevision == requestRevision &&
        state.teamRevision == teamRevision &&
        state.pendingInputIds.isEmpty &&
        state.activeMembers.contains(memberId) &&
        state.issues.any(
            (issue) => issue['id'] == issueId && issue['status'] == 'open');
  }
}

/// Results are in-memory evidence. Only their provenance/ref enters the ledger.
class WorkInvestigationResult {
  final WorkToolResult result;
  final String evidenceRef;
  final bool stalled;
  const WorkInvestigationResult(
      {required this.result, this.evidenceRef = '', this.stalled = false});
}

typedef WorkDiscussionInvestigation = Future<WorkInvestigationResult> Function(
    AgentTask task,
    AICharacter character,
    AgentToolCall call,
    WorkInvestigationBinding binding,
    WorkTaskCancellation cancellation);
