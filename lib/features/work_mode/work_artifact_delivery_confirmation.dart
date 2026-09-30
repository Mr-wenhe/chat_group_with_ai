/// The user's answer to a delivery confirmation, carried in a checkpoint.
///
/// The completion guard refuses a deliverable it cannot recognise. When the run
/// really did write readable files, failing outright is the wrong answer: the
/// user asked for those files and can see them. Instead the task asks — this is
/// the state that records the question, and then the answer.
///
/// Three states share one key so a checkpoint can never hold two contradictory
/// answers:
///  * absent  — nothing was asked; the guard behaves exactly as before;
///  * pending — the question was asked and is waiting for the user;
///  * accepted— the user confirmed, and [WorkArtifactDeliveryGuard.validateTask]
///              delivers exactly these paths instead of re-judging the contract.
///
/// The accepted form is deliberately narrow: it names paths the run already
/// wrote and that were readable when they were offered. It never lets a
/// fabricated deliverable through — prose still cannot become an attachment —
/// and it is scoped to this task, so the next request is judged from scratch.
library;

import 'dart:convert';

const String _confirmationKey = 'artifactDeliveryConfirmation';
const String _stateKey = 'state';
const String _pathsKey = 'paths';

const String _pendingState = 'pending';
const String _acceptedState = 'accepted';

/// Whether the task is waiting for the user to confirm a delivery.
bool artifactDeliveryConfirmationPending(String executionStateJson) =>
    _confirmationOf(executionStateJson)?[_stateKey] == _pendingState;

/// The paths the user confirmed, or the ones being offered while pending.
///
/// Empty when nothing was asked. The guard reads this to decide whether the
/// user has already answered; the panel reads it to name the files in the
/// question and in the confirmation button.
List<String> artifactDeliveryConfirmationPaths(String executionStateJson) {
  final entries = _confirmationOf(executionStateJson)?[_pathsKey];
  if (entries is! List) return const <String>[];
  return entries
      .whereType<String>()
      .map((path) => path.trim())
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
}

/// The paths the user confirmed, or empty when the question is still open.
///
/// This is the accessor the completion guard uses: only an answered question
/// overrides the contract, never a question that is merely waiting.
List<String> acceptedArtifactDeliveryPaths(String executionStateJson) {
  final confirmation = _confirmationOf(executionStateJson);
  if (confirmation?[_stateKey] != _acceptedState) return const <String>[];
  return artifactDeliveryConfirmationPaths(executionStateJson);
}

/// Records the question and the files it is about.
///
/// An empty [paths] clears the key instead: a question about no files is not a
/// question, and leaving the previous answer behind would silently deliver a
/// deliverable the user never saw.
String withArtifactDeliveryConfirmationPending(
  String executionStateJson,
  Iterable<String> paths,
) =>
    _write(executionStateJson, _pendingState, paths);

/// Records the user's confirmation of the offered files.
String withArtifactDeliveryConfirmationAccepted(
  String executionStateJson,
  Iterable<String> paths,
) =>
    _write(executionStateJson, _acceptedState, paths);

/// Forgets the question and its answer.
String withoutArtifactDeliveryConfirmation(String executionStateJson) {
  final metadata = _metadataOf(executionStateJson);
  if (metadata == null || !metadata.containsKey(_confirmationKey)) {
    return executionStateJson;
  }
  metadata.remove(_confirmationKey);
  return metadata.isEmpty ? '' : jsonEncode(metadata);
}

String _write(
  String executionStateJson,
  String state,
  Iterable<String> paths,
) {
  final unique = <String>[];
  for (final path in paths) {
    final trimmed = path.trim();
    if (trimmed.isEmpty || unique.contains(trimmed)) continue;
    unique.add(trimmed);
  }
  if (unique.isEmpty) {
    return withoutArtifactDeliveryConfirmation(executionStateJson);
  }
  final metadata = _metadataOf(executionStateJson) ?? <String, dynamic>{};
  metadata[_confirmationKey] = <String, dynamic>{
    _stateKey: state,
    _pathsKey: unique,
  };
  return jsonEncode(metadata);
}

/// The whole checkpoint metadata map, or null when it is not a readable map.
Map<String, dynamic>? _metadataOf(String raw) {
  if (raw.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } on Object {
    return null;
  }
}

/// The confirmation entry, or null when the checkpoint has none.
Map<String, dynamic>? _confirmationOf(String raw) {
  final entry = _metadataOf(raw)?[_confirmationKey];
  return entry is Map ? Map<String, dynamic>.from(entry) : null;
}
