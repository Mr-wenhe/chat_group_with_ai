import 'dart:io';

import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/web_search/application/search_coordinator.dart';
import 'package:chat_group/features/web_search/application/search_provider_chain.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/keyless_html_search_provider.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/memory_governance_store.dart';

void main() {
  group('KeylessHtmlSearchProvider', () {
    test('maps a public HTML fixture and sends a keyless request', () async {
      late RequestOptions requestOptions;
      final provider = KeylessHtmlSearchProvider(
        dio: _fixtureDio(
          _fixture('success.html'),
          onRequest: (options) => requestOptions = options,
        ),
        isRelease: false,
      );

      final response = await provider.search(
        _request('Flutter release notes'),
        credential: 'must-be-ignored',
      );

      expect(requestOptions.method, 'GET');
      expect(requestOptions.uri.host, 'html.duckduckgo.com');
      expect(requestOptions.uri.path, KeylessHtmlSearchProvider.searchPath);
      expect(requestOptions.uri.queryParameters['q'], 'Flutter release notes');
      expect(requestOptions.headers['User-Agent'],
          KeylessHtmlSearchProvider.userAgent);
      expect(requestOptions.headers, isNot(contains('Authorization')));
      expect(requestOptions.responseType, ResponseType.plain);
      expect(requestOptions.followRedirects, isFalse);
      expect(requestOptions.maxRedirects, 0);

      expect(response.failure, isNull);
      expect(response.items, hasLength(2));
      expect(response.items.first.title, 'Flutter & Dart release notes');
      expect(response.items.first.snippet, 'Stable & secure release notes.');
      expect(response.items.first.url,
          Uri.parse('https://docs.flutter.dev/release/notes'));
      expect(response.items[1].url, Uri.parse('https://dart.dev/overview'));
    });

    test('maps an empty page to noResults', () async {
      final response = await _provider('empty.html').search(
        _request('no results'),
        credential: null,
      );

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.noResults);
      expect(response.failure?.retryable, isFalse);
    });

    test('tolerates a small result markup change and decodes entities',
        () async {
      final response = await _provider('structure_changed.html').search(
        _request('changed markup'),
        credential: null,
      );

      expect(response.failure, isNull);
      expect(response.items, hasLength(1));
      expect(response.items.single.title, 'Changed & entity title');
      expect(response.items.single.snippet, 'A small "markup" change.');
      expect(
          response.items.single.url, Uri.parse('https://example.com/changed'));
    });

    test('resolves root-relative DuckDuckGo wrapper links safely', () async {
      final response = await KeylessHtmlSearchProvider(
        dio: _fixtureDio('''
          <html><body><div class="result">
            <h2><a class="result__a"
              href="/l/?uddg=https%3A%2F%2Fexample.com%2Frelative">Relative</a></h2>
            <div class="result__snippet">Relative result.</div>
          </div></body></html>
        '''),
        isRelease: false,
      ).search(_request('relative'), credential: null);

      expect(response.failure, isNull);
      expect(
        response.items.single.url,
        Uri.parse('https://example.com/relative'),
      );
    });

    test('drops unsafe result URLs while keeping public results', () async {
      final response = await _provider('malicious.html').search(
        _request('unsafe links'),
        credential: null,
      );

      expect(response.failure, isNull);
      expect(response.items, hasLength(1));
      expect(response.items.single.url, Uri.parse('https://example.com/good'));
    });

    test('classifies 429 without exposing response content', () async {
      final response = await KeylessHtmlSearchProvider(
        dio: _fixtureDio(
          _fixture('empty.html'),
          statusCode: 429,
          responseHeaders: const {'retry-after': '30'},
        ),
        isRelease: false,
      ).search(_request('rate limited'), credential: null);

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.rateLimited);
      expect(response.failure?.statusCode, 429);
      expect(response.failure?.retryable, isTrue);
      expect(response.failure?.safeMessage, isNot(contains('retry-after')));
    });

    test('recognizes a CAPTCHA page and does not try to bypass it', () async {
      final response = await _provider('challenge.html').search(
        _request('challenge'),
        credential: null,
      );

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.invalidResponse);
      expect(response.failure?.retryable, isFalse);
      expect(response.terminal, isFalse);
    });

    test('recognizes login or paywall pages for later user handoff', () async {
      final response = await _provider('paywall.html').search(
        _request('paywall'),
        credential: null,
      );

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.invalidResponse);
      expect(response.failure?.retryable, isFalse);
      expect(response.terminal, isFalse);
    });

    test('maps transport timeout to the shared failure contract', () async {
      final response = await KeylessHtmlSearchProvider(
        dio: _failureDio(DioExceptionType.receiveTimeout),
        isRelease: false,
      ).search(_request('timeout'), credential: null);

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.receiveTimeout);
      expect(response.failure?.retryable, isTrue);
    });

    test('maps connection timeout to the shared failure contract', () async {
      final response = await KeylessHtmlSearchProvider(
        dio: _failureDio(DioExceptionType.connectionTimeout),
        isRelease: false,
      ).search(_request('connection timeout'), credential: null);

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.connectionTimeout);
      expect(response.failure?.retryable, isTrue);
    });

    test('does not follow redirects', () async {
      late RequestOptions requestOptions;
      final response = await KeylessHtmlSearchProvider(
        dio: _fixtureDio(
          _fixture('success.html'),
          statusCode: 302,
          onRequest: (options) => requestOptions = options,
          responseHeaders: const {'location': 'https://example.com/next'},
        ),
        isRelease: false,
      ).search(_request('redirect'), credential: null);

      expect(requestOptions.followRedirects, isFalse);
      expect(requestOptions.maxRedirects, 0);
      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.invalidResponse);
    });

    test('rejects a response over the byte budget before parsing DOM',
        () async {
      final oversized = '<html><body>${List.filled(
        KeylessHtmlSearchProvider.maxResponseBytes,
        'x',
      ).join()}</body></html>';
      final response = await KeylessHtmlSearchProvider(
        dio: _fixtureDio(oversized),
        isRelease: false,
      ).search(_request('oversized'), credential: null);

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.invalidResponse);
    });

    test('connection probe is healthy only when a result is returned',
        () async {
      final health = await _provider('success.html').testConnection(
        credential: null,
        probeQuery: 'probe',
      );

      expect(health.isHealthy, isTrue);
      expect(health.failure, isNull);
    });
  });

  group('keyless HTML routing', () {
    test('default evidence prompt withholds links unless requested', () {
      expect(SearchPrompts.promptD, contains('默认回答只给结论'));
      expect(SearchPrompts.promptD, contains('明确索要链接或来源'));
    });

    test('orders configured, Instant Answer, then HTML fallback', () async {
      final calls = <SearchProviderKind>[];
      final chain = SearchProviderChain(
        routes: [
          SearchProviderRoute(
            provider: _RecordingProvider(
              kind: SearchProviderKind.keylessHtml,
              calls: calls,
              response: _successResponse('https://example.com/html'),
            ),
            isFallback: true,
            priority: 0,
          ),
          SearchProviderRoute(
            provider: _RecordingProvider(
              kind: SearchProviderKind.duckDuckGoInstantAnswer,
              calls: calls,
              response: _noResultsResponse(),
            ),
            isFallback: true,
            priority: 0,
          ),
          SearchProviderRoute(
            provider: _RecordingProvider(
              kind: SearchProviderKind.brave,
              calls: calls,
              response: _noResultsResponse(),
            ),
            priority: 99,
          ),
        ],
        retryPolicy: const SearchRetryPolicy(
          maxRetries: 0,
          sleep: _noSleep,
        ),
      );

      final snapshot = await chain.execute(
        request: _request('ordered fallback'),
        cancelToken: null,
        onStatus: null,
      );

      expect(calls, [
        SearchProviderKind.brave,
        SearchProviderKind.duckDuckGoInstantAnswer,
        SearchProviderKind.keylessHtml,
      ]);
      expect(snapshot.provider, 'keylessHtml');
      expect(snapshot.results, hasLength(1));
    });

    test('continues from an empty Instant Answer route to HTML', () async {
      final instant = _EmptyInstantAnswerProvider();
      final html = _provider('success.html');
      final chain = SearchProviderChain(
        routes: [
          SearchProviderRoute(provider: instant, isFallback: true),
          SearchProviderRoute(
            provider: html,
            isFallback: true,
            id: 'builtin-keyless-html',
          ),
        ],
        retryPolicy: const SearchRetryPolicy(
          maxRetries: 0,
          sleep: _noSleep,
        ),
      );

      final snapshot = await chain.execute(
        request: _request('chain fallback'),
        cancelToken: null,
        onStatus: null,
      );

      expect(instant.calls, 1);
      expect(snapshot.provider, 'keylessHtml');
      expect(snapshot.results, hasLength(2));
    });

    test('escalates an empty HTML result to the visible browser route',
        () async {
      final htmlCalls = <SearchProviderKind>[];
      final browserCalls = <SearchProviderKind>[];
      final browserResponse = SearchProviderResponse(
        items: [
          SearchProviderItem(
            title: '公开网页',
            snippet: '用户确认后的公开内容',
            url: Uri.parse('https://example.com/browser'),
          ),
        ],
        sourceProvider: 'visibleBrowser',
      );
      final chain = SearchProviderChain(
        routes: [
          SearchProviderRoute(
            provider: _RecordingProvider(
              kind: SearchProviderKind.keylessHtml,
              calls: htmlCalls,
              response: _noResultsResponse(),
            ),
            isFallback: true,
            id: 'builtin-keyless-html',
          ),
          SearchProviderRoute(
            provider: _RecordingProvider(
              kind: SearchProviderKind.keylessHtml,
              calls: browserCalls,
              response: browserResponse,
            ),
            isFallback: true,
            isVisibleBrowser: true,
            id: 'builtin-visible-browser',
          ),
        ],
        retryPolicy: const SearchRetryPolicy(
          maxRetries: 0,
          sleep: _noSleep,
        ),
      );

      final snapshot = await chain.execute(
        request: _request('browser fallback'),
        cancelToken: null,
        onStatus: null,
      );

      expect(htmlCalls, hasLength(1));
      expect(browserCalls, hasLength(1));
      expect(snapshot.provider, 'visibleBrowser');
      expect(snapshot.results, hasLength(1));
    });

    test('coordinator records HTML sources in the security audit', () async {
      final instant = _EmptyInstantAnswerProvider();
      final store = MemoryGovernanceStore(
        globalSearchPolicy: WebSearchPolicy.auto,
      );
      final coordinator = SearchCoordinator(
        store: store,
        routes: [
          SearchProviderRoute(provider: instant, isFallback: true),
          SearchProviderRoute(
            provider: _provider('success.html'),
            isFallback: true,
            id: 'builtin-keyless-html',
          ),
        ],
      );

      final snapshot = await coordinator.search(
        request: _request('audit source'),
        conversationId: 'conversation-html',
      );

      expect(snapshot?.provider, 'keylessHtml');
      expect(store.searchAudits.single.provider, 'keylessHtml');
      expect(store.searchAudits.single.sources,
          contains('https://docs.flutter.dev/release/notes'));
    });
  });
}

KeylessHtmlSearchProvider _provider(String fixture) =>
    KeylessHtmlSearchProvider(
      dio: _fixtureDio(_fixture(fixture)),
      isRelease: false,
    );

SearchRequest _request(String query) => SearchRequest(
      requestId: 'html-request',
      rootRequestId: 'html-root',
      turnId: 'html-turn',
      query: query,
    );

String _fixture(String name) => File(
      'test/fixtures/web_search/providers/duckduckgo_html/$name',
    ).readAsStringSync();

Dio _fixtureDio(
  String body, {
  int statusCode = 200,
  void Function(RequestOptions options)? onRequest,
  Map<String, String> responseHeaders = const {},
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        onRequest?.call(options);
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: statusCode,
            data: body,
            headers: Headers.fromMap({
              for (final entry in responseHeaders.entries)
                entry.key: [entry.value],
            }),
          ),
        );
      },
    ),
  );
  return dio;
}

Dio _failureDio(DioExceptionType type) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.reject(
          DioException(
            requestOptions: options,
            type: type,
          ),
        );
      },
    ),
  );
  return dio;
}

Future<void> _noSleep(Duration _) async {}

SearchProviderResponse _noResultsResponse() => SearchProviderResponse(
      items: [],
      failure: const SearchFailure(
        type: SearchFailureType.noResults,
        safeMessage: 'no results',
        retryable: false,
      ),
    );

SearchProviderResponse _successResponse(String url) => SearchProviderResponse(
      items: [
        SearchProviderItem(
          title: 'HTML result',
          snippet: 'Public result',
          url: Uri.parse(url),
        ),
      ],
    );

class _RecordingProvider implements SearchProvider {
  @override
  final SearchProviderKind kind;
  final List<SearchProviderKind> calls;
  final SearchProviderResponse response;

  const _RecordingProvider({
    required this.kind,
    required this.calls,
    required this.response,
  });

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    calls.add(kind);
    return response;
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async =>
      const SearchHealthResult(isHealthy: false);
}

class _EmptyInstantAnswerProvider implements SearchProvider {
  int calls = 0;

  @override
  SearchProviderKind get kind => SearchProviderKind.duckDuckGoInstantAnswer;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    calls++;
    return SearchProviderResponse(
      items: [],
      failure: const SearchFailure(
        type: SearchFailureType.noResults,
        safeMessage: 'no results',
        retryable: false,
      ),
    );
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async =>
      const SearchHealthResult(isHealthy: false);
}
