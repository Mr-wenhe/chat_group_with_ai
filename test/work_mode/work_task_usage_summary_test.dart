import 'package:chat_group/core/streaming/reported_token_usage.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/work_mode/work_task_usage_summary.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_usage_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

UsageLedgerEntry entry(String id, ReportedTokenUsage? usage,
        {String task = 'task'}) =>
    UsageLedgerEntry(
      requestId: id,
      rootRequestId: id,
      timestamp: DateTime.utc(2026),
      provider: 'custom',
      model: 'model',
      characterId: 'actor',
      conversationId: 'room',
      taskId: task,
      purpose: AiRequestPurpose.agent,
      originPurpose: AiRequestPurpose.agent,
      inputTokens: 9999,
      outputTokens: 9999,
      cachedInputTokens: 9999,
      estimatedCostMicros: null,
      currency: null,
      priceVersion: null,
      exactUsage: usage?.complete == true,
      reportedUsage: usage,
    );

void main() {
  test('only raw values count, weighted hit rate and coverage stay separate',
      () {
    final entries = [
      entry(
          'one',
          const ReportedTokenUsage(
              inputTokens: 100, outputTokens: 20, cachedTokens: 50)),
      entry(
          'two',
          const ReportedTokenUsage(
              inputTokens: 900,
              outputTokens: 100,
              cachedTokens: 0,
              cacheWriteTokens: 0)),
      entry(
          'one',
          const ReportedTokenUsage(
              inputTokens: 100, outputTokens: 20, cachedTokens: 50)),
      entry('partial', const ReportedTokenUsage(inputTokens: 10)),
      entry('estimated', const ReportedTokenUsage()),
      entry('legacy', null),
      entry(
          'invalid', const ReportedTokenUsage(inputTokens: 5, cachedTokens: 9)),
      entry('other', const ReportedTokenUsage(inputTokens: 100000),
          task: 'another'),
    ];
    final s = WorkTaskUsageSummary.forTask('task', entries, []);
    expect(s.input.tokens, 1010);
    expect(s.output.tokens, 120);
    expect(s.requests, 6);
    expect(s.cacheHitRate, '5.0%');
    expect(s.cacheRateRequests, 2);
    expect(s.cacheWrite.label, '0');
    expect(s.completeRequests, 2);
    expect(s.unknownRequests, 2);
    expect(s.legacyRequests, 1);
    expect(s.invalidRequests, 1);
  });

  test('unknown differs from reported zero and invalid negative data', () {
    final unknown = WorkTaskUsageSummary.forTask(
        'task', [entry('a', const ReportedTokenUsage())], []);
    expect(unknown.input.label, '未知');
    expect(unknown.cached.label, '未知');
    expect(unknown.cacheHitRate, '—');
    expect(const ReportedTokenUsage(inputTokens: -1).valid, isFalse);
    final zero = WorkTaskUsageSummary.forTask('task', [
      entry(
          'a',
          const ReportedTokenUsage(
              inputTokens: 0, outputTokens: 0, cachedTokens: 0))
    ], []);
    expect(zero.input.label, '0');
    expect(zero.cacheHitRate, '—');
  });

  testWidgets('summary remains visible at narrow width with unknown fields',
      (tester) async {
    final summary = WorkTaskUsageSummary.forTask('task', [
      entry('a', const ReportedTokenUsage(inputTokens: 100, outputTokens: 20))
    ], []);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 280, child: WorkTaskUsageCard(summary: summary)))));
    expect(find.text('输入 100 Token'), findsOneWidget);
    expect(find.text('缓存 未知 Token'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single cache label shows hits without adding cache writes',
      (tester) async {
    final summary = WorkTaskUsageSummary.forTask('task', [
      entry(
          'a',
          const ReportedTokenUsage(
              inputTokens: 100,
              outputTokens: 20,
              cachedTokens: 30,
              cacheWriteTokens: 40))
    ], []);
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: WorkTaskUsageCard(summary: summary))));
    expect(find.text('输入 100 Token'), findsOneWidget);
    expect(find.text('输出 20 Token'), findsOneWidget);
    expect(find.text('缓存 30 Token'), findsOneWidget);
    expect(find.textContaining('缓存读取'), findsNothing);
    expect(find.textContaining('缓存写入'), findsNothing);
    expect(find.text('命中率 30.0%（1/1 次）'), findsOneWidget);
  });
}
