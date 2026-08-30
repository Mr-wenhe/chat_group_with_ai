import 'dart:async';

import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:flutter_test/flutter_test.dart';

WorkResourceLockRequest _read(String path) =>
    WorkResourceLockRequest(path: path, mode: WorkResourceLockMode.read);

WorkResourceLockRequest _write(String path) =>
    WorkResourceLockRequest(path: path, mode: WorkResourceLockMode.write);

WorkResourceLockRequest _treeWrite(String path) => WorkResourceLockRequest(
      path: path,
      mode: WorkResourceLockMode.treeWrite,
    );

Future<void> _yield() => Future<void>.delayed(Duration.zero);

void main() {
  test('same-file writes are serialized', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final first = await manager.acquire('first', [_write('/workspace/a.txt')]);
    var secondAcquired = false;
    final secondFuture =
        manager.acquire('second', [_write('/workspace/a.txt')]).then((lease) {
      secondAcquired = true;
      return lease;
    });

    await _yield();
    expect(secondAcquired, isFalse);
    await first.release();
    final second = await secondFuture;
    expect(secondAcquired, isTrue);
    await second.release();
  });

  test('treeWrite conflicts with a child-file lock', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final directory =
        await manager.acquire('directory', [_treeWrite('/workspace/lib')]);
    final childFuture =
        manager.acquire('child', [_write('/workspace/lib/main.dart')]);

    await _yield();
    expect(manager.waitingOwnerIds, contains('child'));
    await directory.release();
    final child = await childFuture;
    await child.release();
  });

  test('read/read locks can run in parallel', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final first = await manager.acquire('first', [_read('/workspace/a.txt')]);
    final second = await manager.acquire('second', [_read('/workspace/a.txt')]);

    expect(manager.activeLeaseCount, 2);
    await first.release();
    await second.release();
  });

  test('read/write locks are serialized', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final reader = await manager.acquire('reader', [_read('/workspace/a.txt')]);
    final writerFuture =
        manager.acquire('writer', [_write('/workspace/a.txt')]);

    await _yield();
    expect(manager.waitingOwnerIds, contains('writer'));
    await reader.release();
    final writer = await writerFuture;
    await writer.release();
  });

  test('waiters are granted in FIFO order', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final first = await manager.acquire('first', [_write('/workspace/a.txt')]);
    final order = <String>[];
    final secondFuture =
        manager.acquire('second', [_write('/workspace/a.txt')]).then((lease) {
      order.add('second');
      return lease;
    });
    final thirdFuture =
        manager.acquire('third', [_write('/workspace/a.txt')]).then((lease) {
      order.add('third');
      return lease;
    });

    await _yield();
    await first.release();
    final second = await secondFuture;
    expect(order, ['second']);
    await second.release();
    final third = await thirdFuture;
    expect(order, ['second', 'third']);
    await third.release();
  });

  test('cancelling a waiter removes it from the queue', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final first = await manager.acquire('first', [_write('/workspace/a.txt')]);
    final cancellation = Completer<void>();
    final waiting = manager.acquire(
      'cancelled',
      [_write('/workspace/a.txt')],
      cancellation: cancellation.future,
    );

    cancellation.complete();
    await expectLater(waiting, throwsA(isA<WorkResourceLockCancelled>()));
    expect(manager.waitingOwnerIds, isNot(contains('cancelled')));
    await first.release();
    expect(manager.activeLeaseCount, 0);
  });

  test('withLocks releases after the runner throws', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    await expectLater(
      manager.withLocks<void>(
        'failing',
        [_write('/workspace/a.txt')],
        () async => throw StateError('runner failed'),
      ),
      throwsStateError,
    );

    final next = await manager.acquire('next', [_write('/workspace/a.txt')]);
    await next.release();
    expect(manager.activeLeaseCount, 0);
  });

  test('a nested overlapping lease is reentrant past a conflicting waiter',
      () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final outer = await manager.acquire(
      'owner',
      [_treeWrite('/workspace')],
    );
    final other = manager.acquire(
      'other',
      [_write('/workspace/file.txt')],
    );

    // The outer lease blocks `other`. A nested mutation lock for the same
    // owner must still complete, rather than queue behind `other` forever.
    await manager.withLocks<void>(
      'owner',
      [_write('/workspace/file.txt')],
      () async {},
    );

    await outer.release();
    final otherLease = await other;
    await otherLease.release();
    expect(manager.activeLeaseCount, 0);
  });

  test('multiple locks are sorted before an atomic acquisition', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final ordered = await manager.acquire(
      'ordered',
      [_write('/workspace/b.txt'), _write('/workspace/a.txt')],
    );
    expect(
      ordered.requests.map((request) => request.path),
      ['/workspace/a.txt', '/workspace/b.txt'],
    );
    await ordered.release();

    final first = manager.withLocks<void>(
      'first',
      [_write('/workspace/b.txt'), _write('/workspace/a.txt')],
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      },
    );
    final second = manager.withLocks<void>(
      'second',
      [_write('/workspace/a.txt'), _write('/workspace/b.txt')],
      () async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      },
    );

    await expectLater(
      Future.wait<void>([first, second]),
      completes,
    );
    expect(manager.activeLeaseCount, 0);
  });

  test('a blocked multi-lock plan never partially reserves a resource',
      () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final holder = await manager.acquire('holder', [_write('/workspace/a')]);
    final plan = manager.acquire(
      'plan',
      [_write('/workspace/b'), _write('/workspace/a')],
    );
    final later = manager.acquire('later', [_write('/workspace/b')]);

    await _yield();
    expect(manager.activeLeaseCount, 1);
    expect(manager.waitingOwnerIds, ['plan', 'later']);
    await holder.release();
    final planned = await plan;
    expect(manager.activeLeaseCount, 1);
    await planned.release();
    final grantedLater = await later;
    await grantedLater.release();
  });

  test('Windows drive paths compare case-insensitively', () async {
    final manager = WorkResourceLockManager(isWindows: true);
    final first = await manager.acquire('first', [_write(r'C:\Work\A.txt')]);
    final secondFuture = manager.acquire('second', [_write('c:/work/a.txt')]);

    await _yield();
    expect(manager.waitingOwnerIds, contains('second'));
    await first.release();
    final second = await secondFuture;
    await second.release();
  });

  test('a fresh manager does not inherit stale in-memory locks', () async {
    final previousProcess = WorkResourceLockManager(isWindows: false);
    final stale =
        await previousProcess.acquire('old', [_write('/workspace/a.txt')]);
    final restartedProcess = WorkResourceLockManager(isWindows: false);

    final fresh =
        await restartedProcess.acquire('new', [_write('/workspace/a.txt')]);
    expect(restartedProcess.activeLeaseCount, 1);
    await fresh.release();
    await stale.release();
  });

  test('stress write intervals never overlap for one resource', () async {
    final manager = WorkResourceLockManager(isWindows: false);
    final intervals = <({DateTime start, DateTime end})>[];

    await Future.wait<void>(
      List<Future<void>>.generate(24, (index) {
        return manager.withLocks<void>(
          'stress-$index',
          [_write('/workspace/stress.txt')],
          () async {
            final start = DateTime.now();
            await Future<void>.delayed(const Duration(milliseconds: 1));
            final end = DateTime.now();
            intervals.add((start: start, end: end));
          },
        );
      }),
    );

    intervals.sort((left, right) => left.start.compareTo(right.start));
    for (var index = 1; index < intervals.length; index++) {
      expect(
        intervals[index - 1].end.isBefore(intervals[index].start) ||
            intervals[index - 1].end.isAtSameMomentAs(intervals[index].start),
        isTrue,
        reason: 'conflicting write intervals overlap at index $index',
      );
    }
  });
}
