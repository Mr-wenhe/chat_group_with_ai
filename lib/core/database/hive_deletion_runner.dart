import 'dart:async';

import 'package:hive/hive.dart';

class HiveDeletionRunner {
  static const batchSize = 500;

  const HiveDeletionRunner();

  Future<List<dynamic>> matchingKeys<T>(
    Box<T> box,
    bool Function(T value) matches,
  ) async {
    final keys = <dynamic>[];
    var scanned = 0;
    for (final key in box.keys) {
      final value = box.get(key);
      if (value != null && matches(value)) keys.add(key);
      if (++scanned % batchSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return keys;
  }

  Future<void> deleteWhere<T>(
    String failure,
    Box<T> box,
    bool Function(T value) matches,
    List<String> incomplete,
  ) async {
    await deleteKeys(
      failure,
      box,
      await matchingKeys(box, matches),
      incomplete,
    );
  }

  Future<void> deleteKeys<T>(
    String failure,
    Box<T> box,
    List<dynamic> keys,
    List<String> incomplete,
  ) async {
    for (var start = 0; start < keys.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, keys.length);
      await attempt(
        failure,
        incomplete,
        () => box.deleteAll(keys.sublist(start, end)),
      );
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<bool> attempt(
    String failure,
    List<String> incomplete,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
      return true;
    } on Object {
      if (!incomplete.contains(failure)) incomplete.add(failure);
      return false;
    }
  }
}
