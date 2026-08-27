import 'dart:async';

import 'package:hive/hive.dart';

/// Serializes destructive and configuration mutations that share one Hive
/// app-settings box.
///
/// The zone token makes nested calls re-entrant. Data-lifecycle operations
/// can therefore call search-store methods while holding the same gate
/// without deadlocking, while separate store instances still queue behind
/// one another.
class DatabaseMutationGate {
  static final Expando<DatabaseMutationGate> _byBox =
      Expando<DatabaseMutationGate>('DatabaseMutationGate.byBox');
  static final Object _zoneKey = Object();

  Future<void>? _tail;
  int _epoch = 0;

  DatabaseMutationGate._();

  factory DatabaseMutationGate.forBox(Box<dynamic> box) =>
      _byBox[box] ??= DatabaseMutationGate._();

  /// Changes whenever a lifecycle operation starts. Long-running migrations
  /// capture the old value and skip stale writes after this changes.
  int get epoch => _epoch;

  bool isCurrent(int capturedEpoch) => _epoch == capturedEpoch;

  /// Invalidates snapshots immediately, even when another mutation currently
  /// owns the gate. The in-flight operation is allowed to finish, while every
  /// later migration write observes the new epoch and fails closed.
  void invalidate() => _epoch++;

  /// Runs [operation] after all earlier mutations have completed.
  Future<T> run<T>(
    Future<T> Function() operation, {
    bool invalidateEpoch = false,
  }) {
    if (Zone.current[_zoneKey] == this) {
      if (invalidateEpoch) _epoch++;
      return operation();
    }
    final previous = _tail;
    final next = _execute(previous, operation, invalidateEpoch);
    _tail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  Future<T> _execute<T>(
    Future<void>? previous,
    Future<T> Function() operation,
    bool invalidateEpoch,
  ) async {
    if (previous != null) await previous;
    if (invalidateEpoch) _epoch++;
    return runZoned(
      operation,
      zoneValues: {_zoneKey: this},
    );
  }
}

/// Raised when a migration reaches a write after its snapshot was superseded
/// by a lifecycle mutation or an explicit cancellation.
class StaleMigrationWrite implements Exception {
  const StaleMigrationWrite();
}
