import 'package:chat_group/features/ai_governance/search_audit_entry.dart';
import 'package:chat_group/features/web_search/application/search_context_formatter.dart';
import 'package:chat_group/features/web_search/models/search_runtime_settings.dart';
import 'package:chat_group/features/web_search/presentation/web_search_audit_card.dart';
import 'package:chat_group/features/web_search/presentation/web_search_runtime_settings_card.dart';
import 'package:chat_group/features/web_search/presentation/web_search_sources_dialog.dart';
import 'package:chat_group/services/web_search_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'sources dialog maps formatted source IDs and hides unknown citations',
      (tester) async {
    Uri? openedUri;
    final snapshot = WebSearchSnapshot(
      query: 'Flutter release',
      executedQueries: const ['Flutter release'],
      searchedAt: DateTime.utc(2026, 8, 23),
      provider: 'Brave',
      results: const [
        WebSearchResult(
          sourceId: 'provider-source-id',
          title: 'Flutter release notes',
          snippet: 'The release details.',
          url: 'https://example.com/flutter',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SourcesDialog(
            snapshot: snapshot,
            onOpenSource: (uri) => openedUri = uri,
          ),
        ),
      ),
    );

    expect(find.text('[S1] Flutter release notes'), findsOneWidget);
    expect(find.textContaining('example.com'), findsOneWidget);
    expect(find.textContaining('未提供发布日期'), findsOneWidget);
    expect(find.text('Provider：Brave'), findsOneWidget);
    await tester.tap(find.byTooltip('在外部浏览器打开'));
    expect(openedUri?.host, 'example.com');

    final sanitized = const SearchContextFormatter().sanitizeLegacyCitations(
      '依据 [S1]，但不能使用 [S9] 或 [Sunknown]。',
      snapshot,
    );
    expect(sanitized, '依据 [S1]，但不能使用  或 。');
    expect(
      const SearchContextFormatter().sanitizeLegacyCitations(
        '小写 [s1]、空标记 [S]、非法 [S unknown]。',
        snapshot,
      ),
      '小写 [S1]、空标记 、非法 。',
    );
    expect(find.textContaining('[S9]'), findsNothing);
    expect(
      const SearchContextFormatter().sanitizeCitationsWithSourceIds(
        '没有快照时也不能认领 [S1]。',
        const <String>[],
      ),
      '没有快照时也不能认领 。',
    );
  });

  testWidgets('sources dialog keeps safe failure details visible',
      (tester) async {
    final snapshot = WebSearchSnapshot(
      query: 'current news',
      searchedAt: DateTime.utc(2026, 8, 23),
      provider: 'Brave',
      results: const [],
      failureType: SearchFailureType.connectionTimeout,
      safeMessage: '搜索服务连接超时',
      statusCode: 504,
      latencyMs: 1800,
      retryCount: 2,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SourcesDialog(snapshot: snapshot)),
      ),
    );

    expect(find.text('失败类型：connectionTimeout'), findsOneWidget);
    expect(find.text('HTTP 状态码：504'), findsOneWidget);
    expect(find.text('请求耗时：1800ms · 重试 2 次'), findsOneWidget);
  });

  testWidgets('persisted audit failure opens a readable detail dialog',
      (tester) async {
    final entry = SearchAuditEntry(
      conversationId: 'group-1',
      query: 'current news',
      searchedAt: DateTime.utc(2026, 8, 23),
      status: 'failed',
      provider: 'Brave',
      failureType: 'connectionTimeout',
      statusCode: 504,
      latencyMs: 1800,
      retryCount: 2,
      sources: const [],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WebSearchAuditCard(entries: [entry])),
      ),
    );

    await tester.tap(find.text('current news'));
    await tester.pumpAndSettle();
    expect(find.text('联网搜索详情'), findsOneWidget);
    expect(find.text('失败类型：connectionTimeout'), findsOneWidget);
    expect(find.text('HTTP 状态码：504'), findsOneWidget);
  });

  testWidgets(
      'runtime settings card saves provider-independent defaults and clears cache',
      (tester) async {
    SearchRuntimeSettings? saved;
    var clearCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WebSearchRuntimeSettingsCard(
            initialSettings: const SearchRuntimeSettings(maxResults: 10),
            onSave: (settings) async => saved = settings,
            onClearCache: () async => clearCount++,
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('search-runtime-locale')),
      'en-US',
    );
    await tester.enterText(
      find.byKey(const ValueKey('search-runtime-country')),
      'US',
    );
    await tester.tap(find.text('保存搜索参数'));
    await tester.pump();

    expect(saved?.locale, 'en-US');
    expect(saved?.country, 'US');
    expect(saved?.maxResults, 10);

    await tester.tap(find.text('清除搜索缓存'));
    await tester.pump();
    expect(clearCount, 1);
  });

  test('failure details survive the persisted audit representation', () {
    final entry = SearchAuditEntry(
      requestId: 'request-1',
      conversationId: 'dm:character-1',
      query: 'current news',
      searchedAt: DateTime.utc(2026, 8, 23),
      status: 'failed',
      provider: 'Brave',
      failureType: 'connectionTimeout',
      statusCode: 504,
      latencyMs: 1800,
      retryCount: 2,
      sources: const [],
    );

    final restored = SearchAuditEntry.fromMap(entry.toMap());
    expect(restored.failureType, 'connectionTimeout');
    expect(restored.statusCode, 504);
    expect(restored.latencyMs, 1800);
    expect(restored.retryCount, 2);
  });
}
