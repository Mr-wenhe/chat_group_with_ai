import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';

/// Runtime policy derived only from a valid, task-bound v2 group checkpoint.
///
/// Unknown, malformed, cross-task and DM checkpoints deliberately retain the
/// legacy cumulative limits. This keeps a stray JSON field from widening the
/// execution boundary.
class WorkTaskExecutionPolicy {
  const WorkTaskExecutionPolicy._();

  static bool isValidatedV2GroupTask(AgentTask task) {
    if (!task.workModeTask ||
        !WorkDiscussionState.requiresDiscussionForConversation(task.groupId) ||
        workExecutionCheckpointRequiresReview(task.executionStateJson)) {
      return false;
    }
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final state = decoded.state;
    final collaboration = state?.collaboration;
    return decoded.isValid &&
        state?.schemaVersion == WorkDiscussionState.currentSchemaVersion &&
        state?.conversationId == task.groupId &&
        collaboration?.taskId == task.id &&
        collaboration?.conversationId == task.groupId;
  }

  static bool enforcesCumulativeLimits(AgentTask task) =>
      !isValidatedV2GroupTask(task);

  static int? progressTotal(AgentTask task, int legacyTotal) =>
      enforcesCumulativeLimits(task) ? legacyTotal : null;
}

enum WorkProgressObservationKind { progress, noProgress, failure, waiting }

class WorkProgressObservation {
  final WorkProgressObservationKind kind;
  final String fingerprint;
  final String summary;
  final String missing;
  final String conditionFingerprint;

  const WorkProgressObservation({
    required this.kind,
    this.fingerprint = '',
    required this.summary,
    this.missing = '',
    this.conditionFingerprint = '',
  });
}

class WorkProgressGuardResult {
  final Map<String, dynamic> executionState;
  final bool madeProgress;
  final bool stalled;
  final String reason;

  const WorkProgressGuardResult({
    required this.executionState,
    required this.madeProgress,
    required this.stalled,
    required this.reason,
  });
}

/// Durable, evidence-based liveness guard for v2 work.
///
/// It stores only fingerprints and short public summaries. Model self-report,
/// wording changes and raw tool output are intentionally absent.
class WorkProgressGuard {
  const WorkProgressGuard._();

  static const String jsonKey = 'v2ProgressGuard';
  static const int repeatedFailureLimit = 3;
  static const int noProgressResultLimit = 8;
  // ponytail: 128 fingerprints fit the existing checkpoint list boundary; an
  // indexed evidence store is needed for tasks revisiting more than 128 results.
  static const int _historyLimit = 128;
  static const int _attemptLimit = 8;

  static WorkProgressGuardResult observe(
    Map<String, dynamic> executionState,
    WorkProgressObservation observation, {
    required DateTime now,
  }) {
    final root = Map<String, dynamic>.from(executionState);
    final guard = _guard(root[jsonKey]);
    final attempts = _strings(guard['attempts'], _attemptLimit);
    final progressFingerprints =
        _strings(guard['progressFingerprints'], _historyLimit);
    var noProgressCount = _count(guard['noProgressCount']);
    var repeatedFailureCount = _count(guard['repeatedFailureCount']);
    var lastFailureFingerprint = _text(guard['lastFailureFingerprint']);
    var failureConditionFingerprint =
        _text(guard['failureConditionFingerprint']);
    var madeProgress = false;

    if (observation.kind == WorkProgressObservationKind.waiting) {
      return WorkProgressGuardResult(
        executionState: root,
        madeProgress: false,
        stalled: guard['stalled'] == true,
        reason: _text(guard['reason']),
      );
    }

    final fingerprint = _text(observation.fingerprint, maximum: 128);
    final condition = _text(observation.conditionFingerprint, maximum: 128);
    final summary = _text(observation.summary, maximum: 240);
    final missing = _text(observation.missing, maximum: 240);

    if (observation.kind == WorkProgressObservationKind.progress &&
        fingerprint.isNotEmpty &&
        !progressFingerprints.contains(fingerprint)) {
      madeProgress = true;
      noProgressCount = 0;
      repeatedFailureCount = 0;
      lastFailureFingerprint = '';
      failureConditionFingerprint = '';
      progressFingerprints.add(fingerprint);
      while (progressFingerprints.length > _historyLimit) {
        progressFingerprints.removeAt(0);
      }
      guard
        ..['lastProgressAt'] = now.toUtc().millisecondsSinceEpoch
        ..['lastProgressSummary'] = summary
        ..['stalled'] = false
        ..remove('reason');
    } else {
      noProgressCount++;
    }

    if (observation.kind == WorkProgressObservationKind.failure) {
      final sameFailure = fingerprint.isNotEmpty &&
          fingerprint == lastFailureFingerprint &&
          condition == failureConditionFingerprint;
      repeatedFailureCount = sameFailure ? repeatedFailureCount + 1 : 1;
      lastFailureFingerprint = fingerprint;
      failureConditionFingerprint = condition;
    }

    if (summary.isNotEmpty) {
      attempts.add(summary);
      while (attempts.length > _attemptLimit) {
        attempts.removeAt(0);
      }
    }

    final repeatedFailure = repeatedFailureCount >= repeatedFailureLimit;
    final noProgress = noProgressCount >= noProgressResultLimit;
    final stalled = repeatedFailure || noProgress;
    final reason = repeatedFailure
        ? '同一失败在相同条件下连续出现 $repeatedFailureCount 次。'
        : noProgress
            ? '连续 $noProgressCount 个结果没有带来新的问题、证据、验收或文件内容变化。'
            : '';

    guard
      ..['noProgressCount'] = noProgressCount
      ..['repeatedFailureCount'] = repeatedFailureCount
      ..['lastFailureFingerprint'] = lastFailureFingerprint
      ..['failureConditionFingerprint'] = failureConditionFingerprint
      ..['progressFingerprints'] = progressFingerprints
      ..['attempts'] = attempts
      ..['missing'] = missing
      ..['stalled'] = stalled;
    if (reason.isEmpty) {
      guard.remove('reason');
    } else {
      guard['reason'] = reason;
    }
    root[jsonKey] = guard;
    return WorkProgressGuardResult(
      executionState: root,
      madeProgress: madeProgress,
      stalled: stalled,
      reason: reason,
    );
  }

  static Map<String, dynamic> snapshot(AgentTask task) {
    if (task.executionStateJson.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(task.executionStateJson);
      if (decoded is! Map) return const {};
      return Map<String, dynamic>.unmodifiable(
        _guard(decoded[jsonKey]),
      );
    } on Object {
      return const {};
    }
  }

  static Map<String, dynamic> _guard(Object? raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

  static int _count(Object? value) =>
      value is num ? value.clamp(0, 1000000).toInt() : 0;

  static List<String> _strings(Object? value, int limit) => value is List
      ? value
          .whereType<String>()
          .map((item) => _text(item, maximum: 240))
          .where((item) => item.isNotEmpty)
          .take(limit)
          .toList(growable: true)
      : <String>[];

  static String _text(Object? value, {int maximum = 512}) {
    if (value is! String) return '';
    final clean = value
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return clean.length <= maximum ? clean : clean.substring(0, maximum);
  }
}
