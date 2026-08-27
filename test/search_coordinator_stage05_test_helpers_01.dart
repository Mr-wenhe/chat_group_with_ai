part of 'search_coordinator_stage05_test.dart';

typedef SearchSnapshot = WebSearchSnapshot;

WebSearchSnapshot _domainSnapshot() => WebSearchSnapshot(
      requestId: 'request-1',
      rootRequestId: 'turn-1',
      originalTextHash: 'a' * 64,
      executedQueries: const ['query'],
      searchedAt: DateTime.utc(2026, 8, 23),
      provider: 'brave',
      results: [
        WebSearchResult(
          sourceId: 'S1',
          title: 'Result',
          snippet: 'Snippet',
          url: Uri.parse('https://example.com'),
          provider: 'brave',
        ),
      ],
    );
