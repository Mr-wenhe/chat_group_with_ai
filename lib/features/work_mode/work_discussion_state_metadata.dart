part of 'work_discussion_state.dart';

/// The durable phases used by the group discussion gate.
abstract final class WorkDiscussionPhase {
  static const String awaitingDiscussion = 'awaitingDiscussion';
  static const String awaitingExecutor = 'awaitingExecutor';
  static const String ready = 'ready';
  static const String blocked = 'blocked';

  static const Set<String> values = <String>{
    awaitingDiscussion,
    awaitingExecutor,
    ready,
    blocked,
  };
}

/// One bounded record of a role's participation in the discussion.
class WorkDiscussionParticipant {
  final String characterId;
  final String status;
  final int contributionCount;
  final String lastContribution;

  const WorkDiscussionParticipant({
    required this.characterId,
    this.status = 'invited',
    this.contributionCount = 0,
    this.lastContribution = '',
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'characterId': characterId,
        'status': status,
        'contributionCount': contributionCount,
        'lastContribution': lastContribution,
      };

  static WorkDiscussionParticipant? tryParse(Object? value) {
    try {
      if (value is! Map || value.keys.any((key) => key is! String)) {
        return null;
      }
      final raw = <String, dynamic>{
        for (final entry in value.entries) entry.key as String: entry.value,
      };
      final characterId = _strictText(
        raw['characterId'],
        maximum: 128,
        required: true,
      );
      if (characterId == null) return null;
      final status = raw['status'] == null
          ? 'invited'
          : _strictText(raw['status'], maximum: 64);
      if (status == null) return null;
      final count = _wholeInt(raw['contributionCount'], maximum: 100000);
      if (count == null) return null;
      return WorkDiscussionParticipant(
        characterId: characterId,
        status: status.isEmpty ? 'invited' : status,
        contributionCount: count,
        lastContribution: raw['lastContribution'] == null
            ? ''
            : _strictText(raw['lastContribution'], maximum: 512)!,
      );
    } on Object {
      return null;
    }
  }

  WorkDiscussionParticipant bounded() => WorkDiscussionParticipant(
        characterId: _cleanId(characterId),
        status: _cleanText(status, maximum: 64),
        contributionCount: contributionCount.clamp(0, 100000).toInt(),
        lastContribution: _cleanText(lastContribution, maximum: 512),
      );

  WorkDiscussionParticipant compactForContext({int textLimit = 128}) =>
      WorkDiscussionParticipant(
        characterId: _cleanText(characterId, maximum: 128),
        status: _cleanText(status, maximum: 32),
        contributionCount: contributionCount.clamp(0, 100000).toInt(),
        lastContribution: _cleanText(
          lastContribution,
          maximum: textLimit.clamp(32, 128).toInt(),
        ),
      );
}

class WorkDiscussionDecodeResult {
  final WorkDiscussionState? state;
  final bool present;
  final String? error;

  const WorkDiscussionDecodeResult.absent()
      : state = null,
        present = false,
        error = null;

  const WorkDiscussionDecodeResult.present(this.state)
      : present = true,
        error = null;

  const WorkDiscussionDecodeResult.invalid(this.error)
      : state = null,
        present = true;

  bool get isValid => present && state != null;
}

/// Returns whether an execution checkpoint must be reviewed before a runner
/// can use it. Missing `schemaVersion` is the legacy V1 shape; an explicit
/// unknown version (or the local review marker) is fail-closed until the user
/// resumes the task and the current code rewrites the safe allow-list.
bool workExecutionCheckpointRequiresReview(String raw) {
  if (raw.trim().isEmpty) return false;
  try {
    final decoded = jsonDecode(raw);
    // A non-empty scalar/list is not a legacy checkpoint shape. Treat it like
    // an unknown version so a damaged record cannot be interpreted as an empty
    // runnable state after restart.
    if (decoded is! Map) return true;
    if (decoded['checkpointSchemaUnsupported'] == true) return true;
    final version = decoded['schemaVersion'];
    if (version == null) return false;
    return !(version is num &&
        version.isFinite &&
        version == version.toInt() &&
        version.toInt() == WorkContextExecutionSchema.currentVersion);
  } on Object {
    // A malformed non-empty checkpoint cannot be safely replayed. The caller
    // will replace it with the minimal review marker and wait for an explicit
    // user continuation.
    return true;
  }
}

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
/// stage. Returns the input unchanged when it cannot be read as a map.
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

/// Reduces an unsupported execution checkpoint to the small set of fields
/// that can still explain a recovery gate. Capability grants and opaque future
/// fields are deliberately dropped; the review marker keeps the task paused
/// until an explicit user continuation rewrites the checkpoint.
Map<String, dynamic> workExecutionCheckpointReviewMetadata(Object? value) {
  final decoded = value is Map
      ? <String, dynamic>{
          for (final entry in value.entries)
            if (entry.key is String) entry.key as String: entry.value,
        }
      : <String, dynamic>{};
  final safe = <String, dynamic>{
    'schemaVersion': WorkContextExecutionSchema.currentVersion,
    'checkpointSchemaUnsupported': true,
  };
  if (decoded.containsKey(WorkDiscussionState.jsonKey)) {
    final discussion = WorkDiscussionState.tryParse(
      decoded[WorkDiscussionState.jsonKey],
    );
    // Do not persist a null discussion marker. A null value is still a
    // present-but-invalid extension to the decoder, which would hide the
    // checkpoint review action and leave the user unable to reach the
    // explicit continuation that can migrate a legacy group task safely.
    if (discussion != null) {
      safe[WorkDiscussionState.jsonKey] = discussion.toJson();
    }
  }
  for (final key in const [
    'folderGrantPending',
    'folderRequiresWritable',
    'toolMissing',
    'visionModelRequired',
    'explicitCommandRequestRequired',
  ]) {
    final candidate = decoded[key];
    if (candidate is bool) safe[key] = candidate;
  }
  final folderPath = decoded['folderRequestPath'];
  if (folderPath is String && folderPath.trim().isNotEmpty) {
    safe['folderRequestPath'] = _cleanText(folderPath, maximum: 4096);
  }
  return safe;
}

/// The execution marker currently shares the V1 allow-list with the public
/// context snapshot. Keeping the value here avoids a second version constant
/// that could drift during a future checkpoint migration.
abstract final class WorkContextExecutionSchema {
  static const int currentVersion = 1;
}
