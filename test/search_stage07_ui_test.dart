import 'package:chat_group/features/ai_governance/search_audit_entry.dart';
import 'package:chat_group/features/web_search/application/search_context_formatter.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/models/search_runtime_settings.dart';
import 'package:chat_group/features/web_search/presentation/web_search_audit_card.dart';
import 'package:chat_group/features/web_search/presentation/web_search_runtime_settings_card.dart';
import 'package:chat_group/features/web_search/presentation/inline_search_reply.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'inline sources retain citation mapping without a technical dialog',
      (tester) async {
    Uri? openedUri;
    final snapshot = WebSearchSnapshot(
      executedQueries: const ['Flutter release'],
      searchedAt: DateTime.utc(2026, 8, 23),
      provider: 'Brave',
      results: [
        WebSearchResult(
          sourceId: 'provider-source-id',
          title: 'Flutter release notes',
          snippet: 'The release details.',
          url: Uri.parse('https://example.com/flutter'),
          provider: 'Brave',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InlineSearchReply(
            content: '**Flutter release notes**',
            style: const TextStyle(),
            mentionNames: const [],
            snapshot: snapshot.toMap(),
            onOpenSource: (uri) => openedUri = uri,
          ),
        ),
      ),
    );

    expect(find.text('[S1] Flutter release notes'), findsNothing);
    await tester.tap(find.text('已联网 · 1 个来源'));
    await tester.pump();
    expect(find.text('[S1] Flutter release notes'), findsOneWidget);
    expect(find.textContaining('example.com'), findsOneWidget);
    expect(find.textContaining('未提供'), findsNothing);
    expect(find.textContaining('Provider'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('[S1] Flutter release notes'));
    expect(openedUri?.host, 'example.com');

    final sanitized = const SearchContextFormatter().sanitizeCitations(
      '依据 [S1]，但不能使用 [S9] 或 [Sunknown]。',
      snapshot,
    );
    expect(sanitized, '依据 [S1]，但不能使用  或 [Sunknown]。');
    expect(
      const SearchContextFormatter().sanitizeCitations(
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

  testWidgets('failed networking shows a readable status without a success badge',
      (tester) async {
    final snapshot = WebSearchSnapshot(
      searchedAt: DateTime.utc(2026, 8, 23),
      provider: 'Brave',
      results: const [],
      failure: const SearchFailure(
        type: SearchFailureType.connectionTimeout,
        safeMessage: '搜索服务连接超时',
        statusCode: 504,
        retryable: true,
      ),
      statusCode: 504,
      latencyMs: 1800,
      retryCount: 2,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
            body: InlineSearchReply(
                content: '搜索服务连接超时',
                snapshot: snapshot.toMap(),
                style: const TextStyle(),
                mentionNames: const [])),
      ),
    );

    expect(find.text('未取得联网来源'), findsOneWidget);
    expect(find.text('搜索服务连接超时'), findsOneWidget);
    expect(find.textContaining('已联网'), findsNothing);
    expect(find.textContaining('connectionTimeout'), findsNothing);
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

  test('native search and query planning require explicit persisted opt-in',
      () {
    const defaults = SearchRuntimeSettings();
    expect(defaults.toMap()['nativeSearchEnabled'], isFalse);
    expect(defaults.toMap()['queryPlanningEnabled'], isFalse);

    final enabled = SearchRuntimeSettings.fromMap({
      'nativeSearchEnabled': true,
      'queryPlanningEnabled': true,
    });
    expect(enabled.toMap()['nativeSearchEnabled'], isTrue);
    expect(enabled.toMap()['queryPlanningEnabled'], isTrue);
  });

  testWidgets('runtime settings exposes explicit native and Planner switches',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WebSearchRuntimeSettingsCard(
            initialSettings: const SearchRuntimeSettings(),
            onSave: (_) async {},
            onClearCache: () async {},
          ),
        ),
      ),
    );

    expect(find.text('使用模型原生联网搜索'), findsOneWidget);
    expect(find.text('使用 AI 改写搜索词'), findsOneWidget);
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
