import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';

/// Serializes writes for one stable directional relationship.
///
/// Automatic observations and manual audit actions must share this queue so a
/// stale manual snapshot cannot overwrite an in-flight automatic event.
class RelationshipDirectionLock {
  static final Map<String, Future<void>> _tails = {};

  static Future<T> run<T>({
    required DatabaseService db,
    required String relationshipId,
    required Future<T> Function() action,
  }) async {
    final key = '${identityHashCode(db)}:$relationshipId';
    final previous = _tails[key];
    final gate = Completer<void>();
    _tails[key] = gate.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      if (!gate.isCompleted) gate.complete();
      if (identical(_tails[key], gate.future)) _tails.remove(key);
    }
  }
}
