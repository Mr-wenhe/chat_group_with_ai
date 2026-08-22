import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/search_coordinator.dart';
import 'package:chat_group/features/web_search/application/search_snapshot_builder.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/duckduckgo_instant_answer_provider.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/services/web_search_service.dart' as legacy;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_governance_store.dart';

void main() {
  group('DuckDuckGoInstantAnswerProvider JSON branches', () {
    test('parses Abstract fields', () async {
      final response = await _searchFixture('abstract.json');

      expect(response.failure, isNull);
      expect(response.items, hasLength(1));
      expect(response.items.single.title, 'Dart');
      expect(response.items.single.snippet, contains('client-optimized'));
      expect(response.items.single.url, Uri.parse('https://dart.dev/'));
    });

    test('parses Answer fields without copying the query into its source URL',
        () async {
      final response = await _searchFixture('answer.json');

      expect(response.failure, isNull);
      expect(response.items, hasLength(1));
      expect(response.items.single.title, 'calc');
      expect(response.items.single.snippet, '42');
      expect(response.items.single.url.scheme, 'https');
      expect(response.items.single.url.queryParameters['ia'], 'answer');
      expect(response.items.single.url.queryParameters['q'], isNull);
    });

    test('parses Definition fields', () async {
      final response = await _searchFixture('definition.json');

      expect(response.items, hasLength(1));
      expect(response.items.single.title, 'Example Dictionary');
      expect(response.items.single.snippet, contains('concise explanation'));
      expect(response.items.single.url.host, 'example.com');
    });

    test('parses Results fields and strips result markup', () async {
      final response = await _searchFixture('results.json');

      expect(response.items, hasLength(2));
      expect(response.items[0].title, 'Flutter');
      expect(response.items[0].snippet, 'Build beautiful, multiplatform apps.');
      expect(response.items[1].title, 'Fallback title');
      expect(response.items[1].snippet, 'A result represented by HTML.');
    });

    test('parses flat and nested RelatedTopics', () async {
      final response = await _searchFixture('related_topics.json');

      expect(response.items, hasLength(2));
      expect(response.items.map((item) => item.title), ['Dart', 'Flutter']);
      expect(response.items.map((item) => item.url.host), [
        'dart.dev',
        'flutter.dev',
      ]);
    });

    test('maps just_another_test with no content to noResults', () async {
      final response = await _searchFixture('no_results.json');

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.noResults);
      expect(response.failure?.retryable, isFalse);
      expect(response.failure?.type, isNot(SearchFailureType.invalidResponse));
    });

    test('does not report an empty probe as a healthy connection', () async {
      final provider = DuckDuckGoInstantAnswerProvider(
        dio: _fixtureDio(_fixtureData('no_results.json')),
      );

      final health = await provider.testConnection(
        credential: null,
        probeQuery: 'probe',
      );

      expect(health.isHealthy, isFalse);
      expect(health.failure?.type, SearchFailureType.noResults);
    });

    test('reports a probe with a valid result as healthy', () async {
      final provider = DuckDuckGoInstantAnswerProvider(
        dio: _fixtureDio(_fixtureData('abstract.json')),
      );

      final health = await provider.testConnection(
        credential: null,
        probeQuery: 'probe',
      );

      expect(health.isHealthy, isTrue);
      expect(health.failure, isNull);
    });
  });

  group('DuckDuckGoInstantAnswerProvider malformed and duplicate data', () {
    test('ignores abnormal fields and invalid URLs without throwing', () async {
      final response = await _searchFixture('invalid_fields.json');

      expect(response.failure, isNull);
      expect(response.items, hasLength(1));
      expect(response.items.single.title, 'Valid result');
      expect(response.items.single.url, Uri.parse('https://example.com/valid'));
    });

    test('deduplicates URL variants before returning provider items', () async {
      final response = await _searchFixture('duplicate_results.json');

      expect(response.items, hasLength(2));
      expect(response.items.map((item) => item.url.host), [
        'example.com',
        'example.com',
      ]);
      expect(response.items[1].url.path, '/different');
    });

    test('returns invalidResponse for malformed JSON', () async {
      final response = await _searchWithData('not-json');

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.invalidResponse);
    });

    test('returns invalidResponse for a non-object JSON payload', () async {
      final response = await _searchWithData(const []);

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.invalidResponse);
    });
  });

  group('web search domain models', () {
    test('requires absolute HTTP or HTTPS URLs and derives displayHost', () {
      final result = WebSearchResult(
        sourceId: 'S1',
        title: ' title ',
        snippet: ' snippet ',
        url: Uri.parse('https://Example.com/path'),
        displayHost: 'spoofed.example',
        publishedAt: DateTime.utc(2026, 8, 22),
        providerScore: 0.91,
        provider: 'duckDuckGoInstantAnswer',
      );

      expect(result.displayHost, 'example.com');
      expect(result.title, 'title');
      expect(result.snippet, 'snippet');
      expect(result.publishedAt, DateTime.utc(2026, 8, 22));
      expect(result.providerScore, 0.91);
      expect(
        () => WebSearchResult(
          sourceId: 'S2',
          title: 'bad',
          snippet: 'bad',
          url: Uri.parse('ftp://example.com/file'),
          provider: 'test',
        ),
        throwsArgumentError,
      );
    });

    test('bounds text and rejects invalid scores', () {
      final result = WebSearchResult(
        sourceId: 'S1',
        title: 'a' * 400,
        snippet: 'b' * 900,
        url: Uri.parse('https://example.com'),
        providerScore: double.nan,
        provider: 'test',
      );

      expect(result.title, hasLength(300));
      expect(result.snippet, hasLength(800));
      expect(result.providerScore, isNull);
    });

    test('normalizes provider items before final snapshot construction', () {
      final item = SearchProviderItem(
        title: '${'a' * 400}\n',
        snippet: '${'b' * 900}\t',
        url: Uri.parse('https://example.com'),
      );

      expect(item.title, hasLength(searchTitleMaxLength));
      expect(item.snippet, hasLength(searchSnippetMaxLength));
      expect(item.title, isNot(contains('\n')));
      expect(item.snippet, isNot(contains('\t')));
    });

    test('normalizes request query and preserves an explicit original hash',
        () {
      final request = SearchRequest(
        query: '  current\nversion  ',
        originalTextHash: 'A' * 64,
        maxResults: searchMaxResultsLimit,
      );

      expect(request.query, 'current version');
      expect(request.originalTextHash, 'a' * 64);
      expect(
        () => SearchRequest(query: 'query', maxResults: 0),
        throwsArgumentError,
      );
      expect(
        () => SearchRequest(
          query: 'query',
          maxResults: searchMaxResultsLimit + 1,
        ),
        throwsArgumentError,
      );
    });

    test('assigns stable source IDs after deduplication', () {
      final request = SearchRequest(
        requestId: 'req-1',
        rootRequestId: 'root-1',
        turnId: 'turn-1',
        query: 'duplicate sources',
        originalTextHash: 'B' * 64,
        maxResults: 5,
      );
      final response = SearchProviderResponse(
        items: [
          SearchProviderItem(
            title: 'first',
            snippet: 'first',
            url: Uri.parse('https://example.com/source#one'),
          ),
          SearchProviderItem(
            title: 'duplicate',
            snippet: 'duplicate',
            url: Uri.parse('https://EXAMPLE.com/source'),
          ),
          SearchProviderItem(
            title: 'second',
            snippet: 'second',
            url: Uri.parse('https://example.com/second'),
          ),
        ],
        statusCode: 207,
      );

      final snapshot = const SearchSnapshotBuilder().build(
        request: request,
        provider: 'test',
        response: response,
        searchedAt: DateTime.utc(2026, 8, 22),
        latencyMs: 12,
      );

      expect(snapshot.results, hasLength(2));
      expect(snapshot.results.map((result) => result.sourceId), ['S1', 'S2']);
      expect(snapshot.results.map((result) => result.displayHost), [
        'example.com',
        'example.com',
      ]);
      expect(snapshot.originalTextHash, 'b' * 64);
      expect(snapshot.statusCode, 207);
    });
  });

  group('WebSearchService compatibility facade', () {
    test('keeps the legacy String URL snapshot contract', () async {
      final snapshot = await legacy.WebSearchService(
        dio: _fixtureDio(_fixtureData('abstract.json')),
      ).search('current Dart');

      expect(snapshot, isA<legacy.WebSearchSnapshot>());
      expect(snapshot.provider, legacy.WebSearchService.providerName);
      expect(snapshot.results.single.url, 'https://dart.dev/');
      expect(snapshot.results.single.title, 'Dart');
      expect(snapshot.requestId, isNotEmpty);
      expect(snapshot.hasResults, isTrue);
      expect(snapshot.statusCode, 200);
    });

    test('keeps noResults terminal status compatible with SearchCoordinator',
        () async {
      final store = MemoryGovernanceStore(
        globalSearchPolicy: WebSearchPolicy.auto,
      );
      final states = <SearchRunStatus>[];
      final coordinator = SearchCoordinator(
        store: store,
        service: legacy.WebSearchService(
          dio: _fixtureDio(_fixtureData('no_results.json')),
        ),
      );

      final snapshot = await coordinator.searchIfAllowed(
        text: 'search no results',
        conversationId: 'group-1',
        requestConsent: (_) async => true,
        onStatus: (state) => states.add(state.status),
      );

      expect(snapshot?.failureType, SearchFailureType.noResults);
      expect(snapshot?.hasFailure, isFalse);
      expect(snapshot?.statusCode, 200);
      expect(states.last, SearchRunStatus.noResults);
    });

    test('does not persist the user query inside a fallback source URL',
        () async {
      final store = MemoryGovernanceStore(
        globalSearchPolicy: WebSearchPolicy.auto,
      );
      final coordinator = SearchCoordinator(
        store: store,
        service: legacy.WebSearchService(
          dio: _fixtureDio(_fixtureData('answer.json')),
        ),
      );

      await coordinator.searchIfAllowed(
        text: 'search private patient Alice 12345',
        conversationId: 'group-1',
        requestConsent: (_) async => true,
      );

      expect(store.searchAudits.single.sources, [
        'https://duckduckgo.com/?ia=answer',
      ]);
      expect(
        store.searchAudits.single.sources.single,
        isNot(contains('private patient Alice 12345')),
      );
    });
  });
}

Future<SearchProviderResponse> _searchFixture(String fileName) {
  return _searchWithData(_fixtureData(fileName));
}

dynamic _fixtureData(String fileName) => jsonDecode(
      File('test/fixtures/web_search/$fileName').readAsStringSync(),
    );

Future<SearchProviderResponse> _searchWithData(dynamic data) {
  final provider = DuckDuckGoInstantAnswerProvider(dio: _fixtureDio(data));
  return provider.search(
    SearchRequest(
      requestId: 'req-test',
      rootRequestId: 'root-test',
      turnId: 'turn-test',
      query: 'fixture query',
      maxResults: 10,
    ),
    credential: null,
  );
}

Dio _fixtureDio(dynamic data) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: data is String ? data : jsonEncode(data),
          ),
        );
      },
    ),
  );
  return dio;
}
