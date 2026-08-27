import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_mutation_gate.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  group('search audit lifecycle', () {
    late Directory hiveDirectory;
    late DatabaseService db;

    setUp(() async {
      hiveDirectory = await openLifecycleHive();
      db = DatabaseService();
    });

    tearDown(() => closeLifecycleHive(hiveDirectory));

    test('retains only fresh, bounded entries and preserves request linkage',
        () async {
      final store = AiGovernanceStore.forDatabase(db);
      final now = DateTime.now().toUtc();
      final oldEntry = SearchAuditEntry(
        requestId: 'old-request',
        rootRequestId: 'old-root',
        conversationId: 'group-stage08',
        query: 'old',
        searchedAt: now.subtract(const Duration(days: 31)),
        status: 'completed',
        sources: const [],
      );
      final freshEntry = SearchAuditEntry(
        requestId: 'fresh-request',
        rootRequestId: 'fresh-root',
        conversationId: 'group-stage08',
        query: 'fresh',
        searchedAt: now.subtract(const Duration(days: 1)),
        status: 'completed',
        sources: const [],
      );
      await db.appSettingsBox.put(
        AiGovernanceStore.searchAuditKey,
        [oldEntry.toMap(), freshEntry.toMap()],
      );

      expect(store.searchAudits, hasLength(1));
      expect(store.searchAudits.single.requestId, 'fresh-request');
      expect(store.searchAudits.single.rootRequestId, 'fresh-root');

      for (var index = 0; index < 105; index++) {
        await store.addSearchAudit(
          SearchAuditEntry(
            requestId: 'request-$index',
            rootRequestId: 'root-stage08',
            conversationId: 'group-stage08',
            query: 'query-$index',
            searchedAt: DateTime.now().toUtc(),
            status: 'completed',
            sources: const [],
          ),
        );
      }

      expect(store.searchAudits, hasLength(100));
      expect(store.searchAudits.first.requestId, 'request-5');
      expect(store.searchAudits.last.requestId, 'request-104');
      final raw = db.appSettingsBox.get(AiGovernanceStore.searchAuditKey);
      expect(raw, isA<List>());
      expect(raw, hasLength(100));
      expect(raw.toString(), isNot(contains('old-request')));
    });

    test('scans all records but retains only the newest audit candidates',
        () async {
      final store = AiGovernanceStore.forDatabase(db);
      final now = DateTime.now().toUtc();
      final stalePrefix = List<Map<String, dynamic>>.generate(
        2000,
        (index) => {
          'requestId': 'stale-$index',
          'searchedAt':
              now.subtract(const Duration(days: 31)).toIso8601String(),
          'sources': const <String>[],
        },
      );
      final recentSuffix = List<Map<String, dynamic>>.generate(
        100,
        (index) => SearchAuditEntry(
          requestId: 'recent-$index',
          conversationId: 'group-stage08',
          query: 'query-$index',
          searchedAt: now,
          status: 'completed',
          sources: const [],
        ).toMap(),
      );
      await db.appSettingsBox.put(
        AiGovernanceStore.searchAuditKey,
        [...stalePrefix, ...recentSuffix],
      );

      final audits = store.searchAudits;

      expect(audits, hasLength(100));
      expect(audits.first.requestId, 'recent-0');
      expect(audits.last.requestId, 'recent-99');
    });

    test('retains fresh audits by searchedAt rather than Hive list order',
        () async {
      final store = AiGovernanceStore.forDatabase(db);
      final now = DateTime.now().toUtc();
      final newest = SearchAuditEntry(
        requestId: 'newest',
        conversationId: 'group-stage08',
        query: 'newest',
        searchedAt: now,
        status: 'completed',
        sources: const [],
      );
      final olderFresh = SearchAuditEntry(
        requestId: 'older-fresh',
        conversationId: 'group-stage08',
        query: 'older',
        searchedAt: now.subtract(const Duration(hours: 1)),
        status: 'completed',
        sources: const [],
      );
      final stale = List<Map<String, dynamic>>.generate(
        500,
        (index) => {
          'requestId': 'stale-reordered-$index',
          'searchedAt':
              now.subtract(const Duration(days: 31)).toIso8601String(),
          'sources': const <String>[],
        },
      );
      await db.appSettingsBox.put(
        AiGovernanceStore.searchAuditKey,
        [newest.toMap(), ...stale, olderFresh.toMap()],
      );

      expect(
        store.searchAudits.map((entry) => entry.requestId),
        ['older-fresh', 'newest'],
      );
    });

    test('scans fresh records restored before the bounded legacy prefix',
        () async {
      final store = AiGovernanceStore.forDatabase(db);
      final now = DateTime.now().toUtc();
      final restoredAtFront = SearchAuditEntry(
        requestId: 'restored-at-front',
        conversationId: 'group-stage08',
        query: 'restored',
        searchedAt: now,
        status: 'completed',
        sources: const [],
      );
      final staleSuffix = List<Map<String, dynamic>>.generate(
        1500,
        (index) => {
          'requestId': 'stale-suffix-$index',
          'searchedAt':
              now.subtract(const Duration(days: 31)).toIso8601String(),
          'sources': const <String>[],
        },
      );
      await db.appSettingsBox.put(
        AiGovernanceStore.searchAuditKey,
        [restoredAtFront.toMap(), ...staleSuffix],
      );

      expect(
        store.searchAudits.map((entry) => entry.requestId),
        ['restored-at-front'],
      );
    });

    test('caps oversized raw audit scans without rewriting the raw list',
        () async {
      final store = AiGovernanceStore.forDatabase(db);
      final now = DateTime.now().toUtc();
      final oversizedStale = List<Map<String, dynamic>>.generate(
        10001,
        (index) => {
          'requestId': 'oversized-stale-$index',
          'searchedAt':
              now.subtract(const Duration(days: 31)).toIso8601String(),
          'sources': const <String>[],
        },
      );
      final recent = SearchAuditEntry(
        requestId: 'oversized-recent',
        conversationId: 'group-stage08',
        query: 'recent',
        searchedAt: now,
        status: 'completed',
        sources: const [],
      ).toMap();
      await db.appSettingsBox.put(
        AiGovernanceStore.searchAuditKey,
        [...oversizedStale, recent],
      );

      expect(store.searchAudits.map((entry) => entry.requestId),
          ['oversized-recent']);
      expect(
        (db.appSettingsBox.get(AiGovernanceStore.searchAuditKey) as List),
        hasLength(10002),
      );
    });

    test('does not rewrite an audit entry with oversized unknown payload',
        () async {
      final store = AiGovernanceStore.forDatabase(db);
      final raw = {
        'requestId': 'unknown-payload',
        'searchedAt': DateTime.now().toUtc().toIso8601String(),
        'sources': const <String>[],
        'unknownPayload': 'x' * 1000000,
      };
      await db.appSettingsBox.put(AiGovernanceStore.searchAuditKey, [raw]);

      expect(store.searchAudits.single.requestId, 'unknown-payload');
      await Future<void>.delayed(Duration.zero);

      final persisted =
          (db.appSettingsBox.get(AiGovernanceStore.searchAuditKey) as List)
              .single as Map;
      expect(persisted['unknownPayload'], raw['unknownPayload']);
    });

    test('future audit timestamps are clamped to the retention clock',
        () async {
      final store = AiGovernanceStore.forDatabase(db);
      final beforeRead = DateTime.now().toUtc();
      await db.appSettingsBox.put(
        AiGovernanceStore.searchAuditKey,
        [
          {
            'requestId': 'future-restored',
            'conversationId': 'group-stage08',
            'query': 'future',
            'searchedAt': DateTime.utc(2099, 1, 1).toIso8601String(),
            'status': 'completed',
            'sources': const <String>[],
          },
        ],
      );

      final entry = store.searchAudits.single;

      expect(entry.requestId, 'future-restored');
      expect(
        entry.searchedAt.isBefore(
          beforeRead.add(const Duration(minutes: 1)),
        ),
        isTrue,
      );
    });

    test('policy writes wait behind the shared lifecycle mutation gate',
        () async {
      final store = AiGovernanceStore.forDatabase(db);
      final gate = DatabaseMutationGate.forBox(db.appSettingsBox);
      final entered = Completer<void>();
      final release = Completer<void>();
      final hold = gate.run(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      final save = store.saveGlobalSearchPolicy(WebSearchPolicy.ask);
      await Future<void>.delayed(Duration.zero);
      expect(
        db.appSettingsBox.get(AiGovernanceStore.globalSearchPolicyKey),
        isNull,
      );

      release.complete();
      await Future.wait<void>([hold, save]);
      expect(store.globalSearchPolicy, WebSearchPolicy.ask);
    });

    test('audit pruning waits behind the shared lifecycle mutation gate',
        () async {
      final store = AiGovernanceStore.forDatabase(db);
      final now = DateTime.now().toUtc();
      final oldEntry = SearchAuditEntry(
        requestId: 'queued-old',
        conversationId: 'queued',
        query: 'old',
        searchedAt: now.subtract(const Duration(days: 31)),
        status: 'completed',
        sources: const [],
      );
      final freshEntry = SearchAuditEntry(
        requestId: 'queued-fresh',
        conversationId: 'queued',
        query: 'fresh',
        searchedAt: now,
        status: 'completed',
        sources: const [],
      );
      final raw = [oldEntry.toMap(), freshEntry.toMap()];
      await db.appSettingsBox.put(AiGovernanceStore.searchAuditKey, raw);

      final gate = DatabaseMutationGate.forBox(db.appSettingsBox);
      final entered = Completer<void>();
      final release = Completer<void>();
      final hold = gate.run(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      expect(store.searchAudits, hasLength(1));
      await Future<void>.delayed(Duration.zero);
      expect(
        db.appSettingsBox.get(AiGovernanceStore.searchAuditKey),
        raw,
      );

      release.complete();
      await hold;
      await Future<void>.delayed(Duration.zero);
      expect(
        db.appSettingsBox.get(AiGovernanceStore.searchAuditKey),
        hasLength(1),
      );
    });

    test('concurrent audit append operations preserve every entry', () async {
      final store = AiGovernanceStore.forDatabase(db);
      final entries = [
        for (var index = 0; index < 24; index++)
          SearchAuditEntry(
            requestId: 'concurrent-$index',
            conversationId: 'concurrent',
            query: 'query-$index',
            searchedAt:
                DateTime.now().toUtc().add(Duration(microseconds: index)),
            status: 'completed',
            sources: const [],
          ),
      ];

      await Future.wait<void>(
        entries.map((entry) => store.addSearchAudit(entry)),
      );

      expect(store.searchAudits, hasLength(entries.length));
      expect(
        store.searchAudits.map((entry) => entry.requestId).toSet(),
        entries.map((entry) => entry.requestId).toSet(),
      );
    });

    test('delayed audit prune cannot resurrect data cleared by lifecycle',
        () async {
      final store = AiGovernanceStore.forDatabase(db);
      final now = DateTime.now().toUtc();
      await db.appSettingsBox.put(
        AiGovernanceStore.searchAuditKey,
        [
          SearchAuditEntry(
            requestId: 'lifecycle-old',
            conversationId: 'lifecycle',
            query: 'old',
            searchedAt: now.subtract(const Duration(days: 31)),
            status: 'completed',
            sources: const [],
          ).toMap(),
          SearchAuditEntry(
            requestId: 'lifecycle-fresh',
            conversationId: 'lifecycle',
            query: 'fresh',
            searchedAt: now,
            status: 'completed',
            sources: const [],
          ).toMap(),
        ],
      );

      final gate = DatabaseMutationGate.forBox(db.appSettingsBox);
      final entered = Completer<void>();
      final release = Completer<void>();
      final hold = gate.run(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      final clear = DataLifecycleService(
        db: db,
        clearExternalSettings: () async {},
      ).clear(DataClearScope.chatContent);
      expect(store.searchAudits, hasLength(1));
      await Future<void>.delayed(Duration.zero);
      expect(
        db.appSettingsBox.get(AiGovernanceStore.searchAuditKey),
        isNotNull,
      );

      release.complete();
      await Future.wait<void>([hold, clear]);
      await Future<void>.delayed(Duration.zero);
      expect(
        db.appSettingsBox.get(AiGovernanceStore.searchAuditKey),
        isNull,
      );
    });
  });
}
