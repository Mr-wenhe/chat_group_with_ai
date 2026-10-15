part of 'work_collaboration_state.dart';

class WorkCollaborationUpdate {
  final String taskId;
  final String conversationId;
  final int expectedRevision;
  final String eventId;
  final String sourceRole;
  final String sourceId;
  final WorkCollaborationState next;

  const WorkCollaborationUpdate(
      {required this.taskId,
      required this.conversationId,
      required this.expectedRevision,
      required this.eventId,
      required this.sourceRole,
      required this.sourceId,
      required this.next});
}
