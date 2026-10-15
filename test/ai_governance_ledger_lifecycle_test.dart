import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  group('AI usage ledger lifecycle', () {
    late Directory hiveDirectory;
    late DatabaseService db;

    setUp(() async {
      hiveDirectory = await openLifecycleHive();
      db = DatabaseService();
    });

    tearDown(() => closeLifecycleHive(hiveDirectory, db));

    testWidgets('请求 ID 幂等写入，独立重试仍计入且任务归属可读', (tester) async {
      await tester.runAsync(() async {
        final firstStore = AiGovernanceStore.forDatabase(db);
        final first = _entry(requestId: 'root', inputTokens: 10);
        await firstStore.addLedgerEntry(first);
        await firstStore.addLedgerEntry(first);
        expect(firstStore.ledgerEntries, hasLength(1));
        expect(db.getTokenUsage()['requestCount'], 1);

        final retry = _entry(
          requestId: 'root:1',
          inputTokens: 12,
          status: 'failed',
        );
        await firstStore.addLedgerEntry(retry);

        // Rebuild the index from the persisted append-only box, as after a restart.
        final restoredDatabase = DatabaseService();
        final restoredStore = AiGovernanceStore.forDatabase(restoredDatabase);
        await restoredStore.addLedgerEntry(first);
        expect(restoredStore.ledgerEntries, hasLength(2));
        expect(db.getTokenUsage()['requestCount'], 2);
        expect(
          restoredStore.ledgerEntries.map((entry) => entry.requestId),
          ['root', 'root:1'],
        );
        expect(
          restoredStore.ledgerEntries.every((entry) =>
              entry.taskId == 'task-ledger' && entry.runBoundary == 31),
          isTrue,
        );
        restoredDatabase.dispose();
      });
    });

    testWidgets('诊断记录保留失败原因并可复制', (tester) async {
      await tester.runAsync(() async {
        final store = AiGovernanceStore.forDatabase(db);
        await store.addDiagnostic(AiRequestDiagnostic(
          requestId: 'r1',
          rootRequestId: 'r1',
          timestamp: DateTime.utc(2026, 10, 15, 12, 9),
          purpose: AiRequestPurpose.connectionTest,
          provider: 'custom',
          model: 'deepseek-flash',
          latencyMs: 206,
          retryCount: 0,
          inputTokens: null,
          cachedInputTokens: null,
          outputTokens: null,
          estimatedCostMicros: null,
          currency: null,
          status: 'failed',
          failureType: 'provider_error',
          failureDetail: 'DioException/unknown | FormatException: 响应不是 JSON',
        ));

        // 重新读一遍：断言的是持久化往返（toMap/fromMap）之后仍在。
        final restored = AiGovernanceStore.forDatabase(db).diagnostics.last;
        expect(
          restored.failureDetail,
          'DioException/unknown | FormatException: 响应不是 JSON',
        );
        expect(
          restored.toSafeText(),
          contains('failureDetail=DioException/unknown'),
        );
      });
    });
  });
}

UsageLedgerEntry _entry({
  required String requestId,
  required int inputTokens,
  String status = 'success',
}) =>
    UsageLedgerEntry(
      requestId: requestId,
      rootRequestId: 'root',
      timestamp: DateTime.utc(2026, 10, 14),
      provider: 'deepseek',
      model: 'deepseek-chat',
      characterId: 'member',
      conversationId: 'group',
      taskId: 'task-ledger',
      runBoundary: 31,
      purpose: AiRequestPurpose.agent,
      originPurpose: AiRequestPurpose.agent,
      inputTokens: inputTokens,
      cachedInputTokens: 0,
      outputTokens: 2,
      estimatedCostMicros: 1,
      currency: 'USD',
      priceVersion: 'test',
      exactUsage: true,
      status: status,
    );
