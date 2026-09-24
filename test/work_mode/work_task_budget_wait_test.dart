import 'dart:convert';

import 'package:chat_group/features/work_mode/work_task_budget_wait.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkTaskBudgetWait', () {
    final window = DateTime.utc(2026, 9, 20, 10);

    test('begins a wait window and folds it into the excluded total', () {
      var execution = WorkTaskBudgetWait.begin(<String, dynamic>{}, window);

      expect(WorkTaskBudgetWait.startedAtOf(execution), window);
      expect(WorkTaskBudgetWait.totalFor(execution, window), Duration.zero);

      execution = WorkTaskBudgetWait.settle(
        execution,
        window.add(const Duration(minutes: 45)),
        budgetStartedAt: window,
      );

      expect(WorkTaskBudgetWait.startedAtOf(execution), isNull);
      expect(
        WorkTaskBudgetWait.totalFor(execution, window),
        const Duration(minutes: 45),
      );
    });

    test('keeps the earliest start when begin repeats without settling', () {
      final execution = WorkTaskBudgetWait.begin(
        WorkTaskBudgetWait.begin(<String, dynamic>{}, window),
        window.add(const Duration(minutes: 5)),
      );

      expect(WorkTaskBudgetWait.startedAtOf(execution), window);
    });

    test('settling without an open window changes nothing', () {
      final settled = <String, dynamic>{'other': 'kept'};

      final result = WorkTaskBudgetWait.settle(
        settled,
        window.add(const Duration(minutes: 3)),
        budgetStartedAt: window,
      );

      expect(result, settled);
      expect(WorkTaskBudgetWait.totalFor(result, window), Duration.zero);
    });

    test('settling twice only folds the window once', () {
      var execution = WorkTaskBudgetWait.begin(<String, dynamic>{}, window);
      execution = WorkTaskBudgetWait.settle(
        execution,
        window.add(const Duration(minutes: 10)),
        budgetStartedAt: window,
      );
      execution = WorkTaskBudgetWait.settle(
        execution,
        window.add(const Duration(minutes: 40)),
        budgetStartedAt: window,
      );

      expect(
        WorkTaskBudgetWait.totalFor(execution, window),
        const Duration(minutes: 10),
      );
    });

    test('accumulates across successive waits', () {
      var execution = WorkTaskBudgetWait.begin(<String, dynamic>{}, window);
      execution = WorkTaskBudgetWait.settle(
        execution,
        window.add(const Duration(minutes: 10)),
        budgetStartedAt: window,
      );
      execution = WorkTaskBudgetWait.begin(
        execution,
        window.add(const Duration(minutes: 20)),
      );
      execution = WorkTaskBudgetWait.settle(
        execution,
        window.add(const Duration(minutes: 25)),
        budgetStartedAt: window,
      );

      expect(
        WorkTaskBudgetWait.totalFor(execution, window),
        const Duration(minutes: 15),
      );
    });

    test('a new budget window does not inherit the previous discount', () {
      var execution = WorkTaskBudgetWait.begin(<String, dynamic>{}, window);
      execution = WorkTaskBudgetWait.settle(
        execution,
        window.add(const Duration(minutes: 30)),
        budgetStartedAt: window,
      );
      expect(
        WorkTaskBudgetWait.totalFor(execution, window),
        const Duration(minutes: 30),
      );

      // A replan or a manual continue moves the origin: the task gets a fresh
      // window and must not be handed the old wait as extra time.
      final replanned = window.add(const Duration(hours: 2));
      expect(WorkTaskBudgetWait.totalFor(execution, replanned), Duration.zero);

      execution = WorkTaskBudgetWait.begin(execution, replanned);
      execution = WorkTaskBudgetWait.settle(
        execution,
        replanned.add(const Duration(minutes: 5)),
        budgetStartedAt: replanned,
      );
      expect(
        WorkTaskBudgetWait.totalFor(execution, replanned),
        const Duration(minutes: 5),
      );
    });

    test('a wait that spans a new budget window only discounts its own window',
        () {
      // The wait opened an hour before the replan that started this window.
      final execution = WorkTaskBudgetWait.begin(
        <String, dynamic>{},
        window.subtract(const Duration(hours: 1)),
      );

      final settled = WorkTaskBudgetWait.settle(
        execution,
        window.add(const Duration(minutes: 10)),
        budgetStartedAt: window,
      );

      expect(
        WorkTaskBudgetWait.totalFor(settled, window),
        const Duration(minutes: 10),
      );
    });

    test('survives a JSON round trip and ignores unparsable values', () {
      final encoded = jsonEncode(
        WorkTaskBudgetWait.begin(<String, dynamic>{}, window),
      );
      final decoded = Map<String, dynamic>.from(
          jsonDecode(encoded) as Map<String, dynamic>);

      expect(WorkTaskBudgetWait.startedAtOf(decoded), window);
      expect(
        WorkTaskBudgetWait.startedAtOf(<String, dynamic>{
          WorkTaskBudgetWait.startedAtKey: 'not-a-number',
        }),
        isNull,
      );
      expect(
        WorkTaskBudgetWait.totalFor(<String, dynamic>{
          WorkTaskBudgetWait.totalKey: -5,
          WorkTaskBudgetWait.originKey: window.millisecondsSinceEpoch,
        }, window),
        Duration.zero,
      );
      expect(
        WorkTaskBudgetWait.totalFor(<String, dynamic>{
          WorkTaskBudgetWait.totalKey: '90000',
          WorkTaskBudgetWait.originKey: window.millisecondsSinceEpoch,
        }, window),
        const Duration(milliseconds: 90000),
      );
    });
  });
}
