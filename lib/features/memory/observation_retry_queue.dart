import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';

enum RetryTaskOutcome {
  completed,
  retry,
  keep,
  drop,
}

typedef RetryTaskProcessor = Future<RetryTaskOutcome> Function({
  required Map<String, dynamic> item,
  required Map<String, AICharacter> charactersById,
});

/// 持久化永久记忆提炼任务，并串行化所有队列读改写。
class ObservationRetryQueue {
  static final Map<int, Future<void>> _locks = {};

  final DatabaseService db;

  const ObservationRetryQueue(this.db);

  Future<void> enqueue({
    required String messageId,
    required String observerId,
    required String conversationId,
    required String conversationNameSnapshot,
    bool forceMemory = false,
  }) async {
    await _withLock(() async {
      final key = _retryKey(messageId, observerId);
      if (db.appSettingsBox.get(key) != null) return;

      final queue = load();
      queue.add({
        'id': DateTime.now().microsecondsSinceEpoch.toString(),
        'messageId': messageId,
        'conversationId': conversationId,
        'conversationNameSnapshot': conversationNameSnapshot,
        'observerId': observerId,
        'forceMemory': forceMemory,
        'queuedAt': DateTime.now().toIso8601String(),
        'attemptCount': 0,
      });
      await db.appSettingsBox.put(_queueKey, queue);
      await db.appSettingsBox.put(key, true);
    });
  }

  List<dynamic> load() {
    final raw = db.appSettingsBox.get(_queueKey);
    if (raw is List) return raw.cast<dynamic>().toList();
    return <dynamic>[];
  }

  Future<int> process({
    int maxBatch = 5,
    List<AICharacter>? allCharacters,
    required RetryTaskProcessor processItem,
  }) async {
    final queue = load();
    if (queue.isEmpty || maxBatch <= 0) return 0;

    final charactersById = allCharacters != null
        ? {for (final character in allCharacters) character.id: character}
        : {
            for (final character in db.aiCharacterBox.values)
              character.id: character
          };
    final remaining = <dynamic>[];
    final removedKeys = <String>{};
    final processingKeys = queue.map(_retryKeyForItem).toSet();
    var attempts = 0;
    var completed = 0;

    for (final rawItem in queue) {
      if (attempts >= maxBatch) {
        remaining.add(rawItem);
        continue;
      }
      attempts++;

      final item = Map<String, dynamic>.from(rawItem as Map);
      final key = _retryKeyForItem(item);
      final attemptCount = (item['attemptCount'] ?? 0) as int;
      if (attemptCount >= 3) {
        removedKeys.add(key);
        continue;
      }

      RetryTaskOutcome outcome;
      try {
        outcome = await processItem(
          item: item,
          charactersById: charactersById,
        );
      } on Object {
        outcome = RetryTaskOutcome.retry;
      }

      switch (outcome) {
        case RetryTaskOutcome.completed:
          removedKeys.add(key);
          completed++;
        case RetryTaskOutcome.retry:
          remaining.add(_incrementAttempt(item));
        case RetryTaskOutcome.keep:
          remaining.add(item);
        case RetryTaskOutcome.drop:
          removedKeys.add(key);
      }
    }

    await _withLock(() async {
      final concurrentItems = load().where(
        (item) => !processingKeys.contains(_retryKeyForItem(item)),
      );
      await db.appSettingsBox.put(
        _queueKey,
        [...remaining, ...concurrentItems],
      );
      for (final key in removedKeys) {
        await db.appSettingsBox.delete(key);
      }
    });
    return completed;
  }

  static const _queueKey = 'memory_retry_queue_v1';

  String _retryKeyForItem(dynamic item) =>
      _retryKey(item['messageId'] ?? '', item['observerId'] ?? '');

  String _retryKey(String messageId, String observerId) =>
      'retry:$messageId:$observerId';

  Map<String, dynamic> _incrementAttempt(Map<String, dynamic> item) =>
      Map<String, dynamic>.from(item)
        ..['attemptCount'] = ((item['attemptCount'] ?? 0) as int) + 1;

  Future<void> _withLock(Future<void> Function() action) async {
    final lockKey = identityHashCode(db);
    final previous = _locks[lockKey];
    final gate = Completer<void>();
    _locks[lockKey] = gate.future;
    try {
      if (previous != null) await previous;
      await action();
    } finally {
      gate.complete();
      if (identical(_locks[lockKey], gate.future)) _locks.remove(lockKey);
    }
  }
}
