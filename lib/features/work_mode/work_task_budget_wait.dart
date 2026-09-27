/// Durable bookkeeping for time a work task spends waiting on the user.
///
/// [AgentTask.startedAt] is deliberately fixed for the whole task: the comment
/// on `AgentTask.attemptStartedAt` records that a revision must never be able to
/// extend the shared budget. Waiting for an approval decision is not agent work
/// though, so the wait is accumulated separately in the execution checkpoint
/// instead of moving that origin. A task approved after a long pause therefore
/// resumes with the budget it had left, rather than reporting that the wall
/// clock already expired.
///
/// The accumulated total is stamped with the budget origin it was measured
/// against. A replan or a manual continue moves [AgentTask.startedAt] and opens
/// a fresh window; that window must not inherit the previous one's discount, or
/// the task would be handed that much extra time.
abstract final class WorkTaskBudgetWait {
  /// Epoch milliseconds of the wait that is still open, if any.
  static const String startedAtKey = 'budgetWaitStartedAtMs';

  /// Epoch milliseconds already excluded from the task's wall-clock budget.
  static const String totalKey = 'budgetWaitTotalMs';

  /// Epoch milliseconds of the budget origin [totalKey] was measured against.
  static const String originKey = 'budgetWaitOriginMs';

  /// Opens a wait window. Reopening without settling keeps the earliest start
  /// so an interleaved checkpoint cannot silently discard elapsed wait time.
  static Map<String, dynamic> begin(
    Map<String, dynamic> execution,
    DateTime now,
  ) {
    if (startedAtOf(execution) != null) return execution;
    return <String, dynamic>{
      ...execution,
      startedAtKey: now.millisecondsSinceEpoch,
    };
  }

  /// Folds a finished wait into the excluded total and clears the marker.
  ///
  /// [budgetStartedAt] is the budget origin the wait is folded into, which is
  /// [AgentTask.startedAt] as the loop sees it. A total measured against
  /// another origin is dropped, and a wait never discounts more than the age of
  /// that origin: a replan can land in the middle of an open wait window, and
  /// the part of the wait that predates it belongs to the window it replaced.
  ///
  /// Idempotent with respect to [begin]: settling twice only folds the same
  /// window once, because the second call finds no open marker.
  static Map<String, dynamic> settle(
    Map<String, dynamic> execution,
    DateTime now, {
    required DateTime budgetStartedAt,
  }) {
    final startedAt = startedAtOf(execution);
    if (startedAt == null) return execution;
    final origin = budgetStartedAt.millisecondsSinceEpoch;
    final next = Map<String, dynamic>.from(execution)..remove(startedAtKey);
    final carried = _milliseconds(next[originKey]) == origin
        ? _storedTotal(next)
        : Duration.zero;
    final waited = _earlierOf(
      now.difference(startedAt),
      now.difference(budgetStartedAt),
    );
    final total = carried + (waited > Duration.zero ? waited : Duration.zero);
    if (total > Duration.zero) {
      next[totalKey] = total.inMilliseconds;
      next[originKey] = origin;
    } else {
      next
        ..remove(totalKey)
        ..remove(originKey);
    }
    return next;
  }

  static DateTime? startedAtOf(Map<String, dynamic> execution) {
    final milliseconds = _milliseconds(execution[startedAtKey]);
    return milliseconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }

  /// Wait time already excluded from the budget that began at
  /// [budgetStartedAt]. A total measured against an earlier budget window is
  /// ignored rather than carried over.
  static Duration totalFor(
    Map<String, dynamic> execution,
    DateTime budgetStartedAt,
  ) {
    if (_milliseconds(execution[originKey]) !=
        budgetStartedAt.millisecondsSinceEpoch) {
      return Duration.zero;
    }
    return _storedTotal(execution);
  }

  static Duration _storedTotal(Map<String, dynamic> execution) {
    final milliseconds = _milliseconds(execution[totalKey]) ?? 0;
    return milliseconds <= 0
        ? Duration.zero
        : Duration(milliseconds: milliseconds);
  }

  static Duration _earlierOf(Duration value, Duration ceiling) =>
      value < ceiling ? value : ceiling;

  static int? _milliseconds(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return raw is String ? int.tryParse(raw.trim()) : null;
  }
}
