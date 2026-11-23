import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/application/search_context_formatter.dart';
import 'package:chat_group/features/web_search/presentation/inline_search_reply.dart';

void main() {
  test('hidden Zhipu attribution preserves punctuation and paragraphs', () {
    const formatter = SearchContextFormatter();
    expect(
      formatter.sanitizeCitationsWithSourceIds(
        '官方发布 [S1] 。\n\n链接：https://example.com/release [S1] 。后续。。',
        ['S1'],
        hideCitations: true,
      ),
      '官方发布。\n\n链接：https://example.com/release。后续。',
    );
  });

  testWidgets(
      'autonomous sources retain stable IDs across order and mixed citations',
      (tester) async {
    Uri? opened;
    final snapshot = WebSearchSnapshot(
      searchedAt: DateTime.utc(2026),
      provider: 'autonomous-web',
      results: [
        for (final id in [7, 2, 1, 9, 10, 11])
          WebSearchResult(
              sourceId: 's$id',
              title: 'source-$id',
              snippet: 'Evidence',
              url: Uri.parse('https://example.com/$id'),
              provider: 'public-web'),
      ],
    );
    const formatter = SearchContextFormatter();
    expect(
        formatter.format(snapshot).sourceIds, ['W7', 'W2', 'W1', 'W9', 'W10']);
    expect(formatter.sanitizeCitations('事实 [W11]，伪造 [W99]。', snapshot),
        '事实 [W11]，伪造 。');
    expect(
        formatter.sourceIdsForSnapshot(snapshot.copyWith(
            failure: const SearchFailure(
                type: SearchFailureType.connectionTimeout,
                safeMessage: '来源查询失败',
                retryable: true))),
        isEmpty);
    expect(
        formatter.sanitizeCitationsWithSourceIds('智谱 [S1]，自动 [W7]，伪造 [W99]。',
            ['S1', ...formatter.sourceIdsForSnapshot(snapshot)],
            hideCitations: true),
        contains('自动 [W7]'));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: InlineSearchReply(
                    content: '',
                    snapshot: snapshot.toMap(),
                    style: const TextStyle(),
                    mentionNames: const [],
                    onOpenSource: (uri) => opened = uri)))));
    await tester.tap(find.text('已联网 · 6 个来源'));
    await tester.pump();
    expect(find.text('[W7] source-7'), findsOneWidget);
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -700));
    await tester.pump();
    expect(find.text('[W11] source-11'), findsOneWidget);
    expect(find.text('[S1] source-7'), findsNothing);
    await tester.tap(find.text('[W11] source-11'));
    expect(opened?.path, '/11');
  });

  testWidgets('invalid autonomous IDs cannot shift labels onto a different URL',
      (tester) async {
    final snapshot = WebSearchSnapshot(
      searchedAt: DateTime.utc(2026),
      provider: 'autonomous-web',
      results: [
        for (final id in ['invalid', 's7', 's7'])
          WebSearchResult(
              sourceId: id,
              title: id,
              snippet: 'Evidence',
              url: Uri.parse('https://example.com/$id'),
              provider: 'public-web'),
      ],
    );
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: InlineSearchReply(
                content: '',
                snapshot: snapshot.toMap(),
                style: const TextStyle(),
                mentionNames: const []))));
    await tester.tap(find.text('已联网 · 1 个来源'));
    await tester.pump();
    expect(find.text('[W7] s7'), findsOneWidget);
    expect(find.textContaining('invalid'), findsNothing);
  });
  testWidgets('mixed sources keep separate provider provenance',
      (tester) async {
    WebSearchSnapshot snapshot(String provider, String title) =>
        WebSearchSnapshot(
            searchedAt: DateTime.utc(2026),
            provider: provider,
            results: [
              WebSearchResult(
                  sourceId: 's1',
                  title: title,
                  snippet: 'Evidence',
                  url: Uri.parse('https://example.com/$title'),
                  provider: provider)
            ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: InlineSearchReply(
      content: '',
      style: const TextStyle(),
      mentionNames: const [],
      snapshot: {
        ...snapshot('zhipu-native', 'original').toMap(),
        'networkSources': snapshot('autonomous-web', 'additional').toMap()
      },
    ))));
    await tester.tap(find.text('已联网 · 2 个来源'));
    await tester.pump();
    expect(find.textContaining('Provider'), findsNothing);
    expect(find.text('[S1] original'), findsOneWidget);
    expect(find.text('[W1] additional'), findsOneWidget);
    expect(find.textContaining('original'), findsWidgets);
    expect(find.textContaining('additional'), findsWidgets);
  });
}
