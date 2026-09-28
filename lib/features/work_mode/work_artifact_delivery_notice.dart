/// The artifact-delivery notice carried in an execution checkpoint.
///
/// A task can finish its work while the chat attachment fails: the deliverable
/// is saved and validated, only the message failed to carry it. That state is
/// described by three keys in `AgentTask.executionStateJson`, and both the
/// runner and the coordinator have to agree on what they mean, so the contract
/// lives here rather than inside either of them.
library;

import 'dart:convert';

/// Whether a task is holding a saved deliverable that still has to be re-sent
/// as a chat attachment.
///
/// The marker is what lets an already finished task re-enter the runner for a
/// delivery-only pass, so it is always read back from the persisted checkpoint
/// rather than from in-memory run state.
bool workArtifactDeliveryRetryPending(String executionStateJson) {
  if (executionStateJson.trim().isEmpty) return false;
  try {
    final decoded = jsonDecode(executionStateJson);
    if (decoded is! Map) return false;
    if (decoded['artifactDeliveryNoticePublished'] != true) return false;
    if (decoded['artifactDeliveryRetryOnly'] != true) return false;
    final messageId = decoded['artifactDeliveryMessageId'];
    return messageId is String && messageId.trim().isNotEmpty;
  } on Object {
    return false;
  }
}

/// Removes a pending artifact-delivery notice from an execution checkpoint.
///
/// A stage that hands the task to the next role must not leave its own resend
/// marker behind: the next role's run would otherwise enter the delivery-only
/// branch and re-send the previous stage's message instead of executing its own
/// stage. Returns the input unchanged when it cannot be read as a map, so a
/// damaged checkpoint is never reduced to an empty, runnable-looking state.
String workWithoutArtifactDeliveryNotice(String executionStateJson) {
  if (executionStateJson.trim().isEmpty) return executionStateJson;
  try {
    final decoded = jsonDecode(executionStateJson);
    if (decoded is! Map) return executionStateJson;
    final metadata = Map<String, dynamic>.from(decoded)
      ..remove('artifactDeliveryNoticePublished')
      ..remove('artifactDeliveryMessageId')
      ..remove('artifactDeliveryRetryOnly');
    return metadata.isEmpty ? '' : jsonEncode(metadata);
  } on Object {
    return executionStateJson;
  }
}
