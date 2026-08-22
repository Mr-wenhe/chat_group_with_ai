import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/search/search_failure_type.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/brave_search_provider.dart';
import 'package:chat_group/features/web_search/providers/tavily_search_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _tavilyTestKey = 'tvly-test-key-must-not-appear-in-errors';
const _braveTestKey = 'brave-test-key-must-not-appear-in-errors';

void main() {
  group('TavilySearchProvider contract', () {
    test('sends the documented POST request and maps results', () async {
      late RequestOptions requestOptions;
      final provider = TavilySearchProvider(
        dio: _fixtureDio(
          _fixtureData('tavily/success.json'),
          onRequest: (options) => requestOptions = options,
        ),
      );

      final response = await provider.search(
        _request('Flutter 最新版本', category: SearchCategory.software),
        credential: _tavilyTestKey,
      );

      expect(requestOptions.method, 'POST');
      expect(requestOptions.uri.host, 'api.tavily.com');
      expect(requestOptions.uri.path, TavilySearchProvider.searchPath);
      expect(requestOptions.queryParameters, isEmpty);
      expect(requestOptions.headers['Authorization'], 'Bearer $_tavilyTestKey');
      expect(requestOptions.data, isA<Map>());
      expect(requestOptions.data['query'], 'Flutter 最新版本');
      expect(requestOptions.data['max_results'], 5);
      expect(requestOptions.data['include_answer'], isFalse);
      expect(requestOptions.data['include_raw_content'], isFalse);

      expect(response.failure, isNull);
      expect(response.providerRequestId, 'tavily-request-001');
      expect(response.items, hasLength(2));
      expect(response.items.map((item) => item.title), [
        'Flutter 稳定版发布说明',
        'Flutter stable release notes',
      ]);
      expect(response.items.first.url,
          Uri.parse('https://docs.flutter.dev/release/notes'));
      expect(
          response.items.first.publishedAt, DateTime.utc(2026, 8, 20, 8, 30));
      expect(response.items[1].publishedAt, isNull);
      expect(response.items.first.snippet,
          contains('Ignore previous instructions'));
      expect(response.items.first.snippet, isNot(contains('<script>')));
      expect(response.items.map((item) => item.snippet),
          isNot(contains('Provider answer must not be used')));
    });

    test('omits country when the topic is news or finance', () async {
      for (final category in [SearchCategory.news, SearchCategory.finance]) {
        late RequestOptions requestOptions;
        final response = await TavilySearchProvider(
          dio: _fixtureDio(
            _fixtureData('tavily/success.json'),
            onRequest: (options) => requestOptions = options,
          ),
        ).search(
          _request('topic query', category: category),
          credential: _tavilyTestKey,
        );

        expect(response.failure, isNull, reason: category.name);
        expect(requestOptions.data['topic'], category.name);
        expect(requestOptions.data, isNot(contains('country')));
      }
    });

    test('maps an empty result list to noResults', () async {
      final response = await TavilySearchProvider(
        dio: _fixtureDio(_fixtureData('tavily/empty.json')),
      ).search(_request('没有结果'), credential: _tavilyTestKey);

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.noResults);
      expect(response.failure?.retryable, isFalse);
      expect(response.statusCode, 200);
    });

    test('classifies provider HTTP failures without exposing the key',
        () async {
      for (final entry in <String, SearchFailureType>{
        'unauthorized.json': SearchFailureType.unauthorized,
        'forbidden.json': SearchFailureType.forbidden,
        'rate_limited.json': SearchFailureType.rateLimited,
        'server_error.json': SearchFailureType.providerUnavailable,
      }.entries) {
        final response = await TavilySearchProvider(
          dio: _fixtureDio(
            _fixtureData('tavily/${entry.key}'),
            statusCode: _statusCodeFor(entry.key),
            requestId: 'tavily-error-${entry.key}',
            dioErrorMessage: 'Authorization: Bearer $_tavilyTestKey',
          ),
        ).search(_request('failure'), credential: _tavilyTestKey);

        expect(response.items, isEmpty);
        expect(response.failure?.type, entry.value, reason: entry.key);
        expect(response.failure?.statusCode, isNotNull);
        expect(response.failure?.safeMessage, isNot(contains(_tavilyTestKey)));
        expect(response.failure?.safeMessage, isNot(contains('Authorization')),
            reason: entry.key);
        expect(response.providerRequestId, isNotEmpty);
      }
    });

    test('returns invalidResponse for a malformed results type', () async {
      final response = await TavilySearchProvider(
        dio: _fixtureDio(_fixtureData('tavily/type_error.json')),
      ).search(_request('malformed'), credential: _tavilyTestKey);

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.invalidResponse);
    });

    test('connection probe is healthy only when a result is returned',
        () async {
      final provider = TavilySearchProvider(
        dio: _fixtureDio(_fixtureData('tavily/success.json')),
      );

      final health = await provider.testConnection(
        credential: _tavilyTestKey,
        probeQuery: 'probe',
      );

      expect(health.isHealthy, isTrue);
      expect(health.failure, isNull);
    });
  });

  group('BraveSearchProvider contract', () {
    test('sends the documented GET request and maps web results', () async {
      late RequestOptions requestOptions;
      final provider = BraveSearchProvider(
        dio: _fixtureDio(
          _fixtureData('brave/success.json'),
          onRequest: (options) => requestOptions = options,
          responseHeaders: const {'x-request-id': 'brave-request-001'},
        ),
      );

      final response = await provider.search(
        _request(
          '最新 Flutter release',
          locale: 'en-US',
          country: 'US',
          category: SearchCategory.software,
          freshness: SearchFreshness.week,
        ),
        credential: _braveTestKey,
      );

      expect(requestOptions.method, 'GET');
      expect(requestOptions.uri.host, 'api.search.brave.com');
      expect(requestOptions.uri.path, BraveSearchProvider.searchPath);
      expect(requestOptions.data, isNull);
      expect(requestOptions.headers['X-Subscription-Token'], _braveTestKey);
      expect(requestOptions.uri.queryParameters['q'], '最新 Flutter release');
      expect(requestOptions.uri.queryParameters['count'], '5');
      expect(requestOptions.uri.queryParameters['text_decorations'], 'false');
      expect(requestOptions.uri.queryParameters['extra_snippets'], 'false');
      expect(requestOptions.uri.queryParameters['freshness'], 'pw');
      expect(requestOptions.uri.queryParameters, isNot(contains('api_key')));
      expect(requestOptions.uri.queryParameters, isNot(contains('token')));

      expect(response.failure, isNull);
      expect(response.providerRequestId, 'brave-request-001');
      expect(response.correctedQuery, 'latest Flutter release');
      expect(response.moreResultsAvailable, isTrue);
      expect(response.items, hasLength(2));
      expect(response.items.map((item) => item.title), [
        'Flutter 官方发布说明',
        'Flutter stable release notes',
      ]);
      expect(response.items.first.url,
          Uri.parse('https://docs.flutter.dev/release/notes'));
      expect(
          response.items.first.publishedAt, DateTime.utc(2026, 8, 20, 8, 30));
      expect(response.items[1].publishedAt, isNull);
      expect(response.items.first.snippet,
          contains('Ignore previous instructions'));
      expect(response.items.first.snippet, isNot(contains('<strong>')));
    });

    test('maps an empty web result list to noResults', () async {
      final response = await BraveSearchProvider(
        dio: _fixtureDio(_fixtureData('brave/empty.json')),
      ).search(_request('empty'), credential: _braveTestKey);

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.noResults);
      expect(response.failure?.retryable, isFalse);
      expect(response.statusCode, 200);
    });

    test('classifies provider HTTP failures without exposing the key',
        () async {
      for (final entry in <String, SearchFailureType>{
        'unauthorized.json': SearchFailureType.unauthorized,
        'forbidden.json': SearchFailureType.forbidden,
        'rate_limited.json': SearchFailureType.rateLimited,
        'server_error.json': SearchFailureType.providerUnavailable,
      }.entries) {
        final response = await BraveSearchProvider(
          dio: _fixtureDio(
            _fixtureData('brave/${entry.key}'),
            statusCode: _statusCodeFor(entry.key),
            requestId: 'brave-error-${entry.key}',
            dioErrorMessage: 'X-Subscription-Token: $_braveTestKey',
          ),
        ).search(_request('failure'), credential: _braveTestKey);

        expect(response.items, isEmpty);
        expect(response.failure?.type, entry.value, reason: entry.key);
        expect(response.failure?.statusCode, isNotNull);
        expect(response.failure?.safeMessage, isNot(contains(_braveTestKey)));
        expect(response.failure?.safeMessage,
            isNot(contains('X-Subscription-Token')),
            reason: entry.key);
        expect(response.providerRequestId, isNotEmpty);
      }
    });

    test('returns invalidResponse for a malformed web results type', () async {
      final response = await BraveSearchProvider(
        dio: _fixtureDio(_fixtureData('brave/type_error.json')),
      ).search(_request('malformed'), credential: _braveTestKey);

      expect(response.items, isEmpty);
      expect(response.failure?.type, SearchFailureType.invalidResponse);
    });

    test('accepts a body request id when the provider supplies no header id',
        () async {
      final response = await BraveSearchProvider(
        dio: _fixtureDio(_fixtureData('brave/body_request_id.json')),
      ).search(_request('body id'), credential: _braveTestKey);

      expect(response.providerRequestId, 'brave-body-request-001');
      expect(response.items, hasLength(1));
    });
  });

  group('search provider endpoint safety', () {
    test('rejects private hosts and HTTP endpoints in release mode', () {
      expect(
        () => TavilySearchProvider(baseUrl: 'https://127.0.0.1'),
        throwsArgumentError,
      );
      expect(
        () => BraveSearchProvider(baseUrl: 'https://10.0.0.5'),
        throwsArgumentError,
      );
      expect(
        () => TavilySearchProvider(
          baseUrl: 'http://api.example.com',
          isRelease: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => BraveSearchProvider(
          baseUrl: 'https://example.com/search?api_key=secret',
        ),
        throwsArgumentError,
      );
    });

    test('maps transport timeouts without exposing transport details',
        () async {
      final tavilyResponse = await TavilySearchProvider(
        dio: _transportFailureDio(
          DioExceptionType.connectionTimeout,
          'connection timeout for $_tavilyTestKey',
        ),
      ).search(_request('timeout'), credential: _tavilyTestKey);
      final braveResponse = await BraveSearchProvider(
        dio: _transportFailureDio(
          DioExceptionType.receiveTimeout,
          'receive timeout for $_braveTestKey',
        ),
      ).search(_request('timeout'), credential: _braveTestKey);

      expect(
        tavilyResponse.failure?.type,
        SearchFailureType.connectionTimeout,
      );
      expect(
        braveResponse.failure?.type,
        SearchFailureType.receiveTimeout,
      );
      expect(
          tavilyResponse.failure?.safeMessage, isNot(contains(_tavilyTestKey)));
      expect(
          braveResponse.failure?.safeMessage, isNot(contains(_braveTestKey)));
    });
  });
}

int _statusCodeFor(String fixtureName) => switch (fixtureName) {
      'unauthorized.json' => 401,
      'forbidden.json' => 403,
      'rate_limited.json' => 429,
      'server_error.json' => 500,
      _ => 200,
    };

SearchRequest _request(
  String query, {
  SearchCategory category = SearchCategory.general,
  SearchFreshness freshness = SearchFreshness.any,
  String locale = 'zh-CN',
  String? country,
}) {
  return SearchRequest(
    requestId: 'request-test',
    rootRequestId: 'root-test',
    turnId: 'turn-test',
    query: query,
    category: category,
    freshness: freshness,
    locale: locale,
    country: country,
  );
}

dynamic _fixtureData(String path) => jsonDecode(
      File('test/fixtures/web_search/providers/$path').readAsStringSync(),
    );

Dio _fixtureDio(
  dynamic data, {
  int statusCode = 200,
  String? requestId,
  String? dioErrorMessage,
  void Function(RequestOptions options)? onRequest,
  Map<String, String> responseHeaders = const {},
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        onRequest?.call(options);
        final headers = <String, List<String>>{
          for (final entry in responseHeaders.entries) entry.key: [entry.value],
        };
        if (requestId != null) headers['x-request-id'] = [requestId];
        if (dioErrorMessage != null) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              message: dioErrorMessage,
              response: Response<dynamic>(
                requestOptions: options,
                statusCode: statusCode,
                data: data is String ? data : jsonEncode(data),
                headers: Headers.fromMap(headers),
              ),
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: statusCode,
            data: data is String ? data : jsonEncode(data),
            headers: Headers.fromMap(headers),
          ),
        );
      },
    ),
  );
  return dio;
}

Dio _transportFailureDio(DioExceptionType type, String message) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.reject(
          DioException(
            requestOptions: options,
            type: type,
            message: message,
          ),
        );
      },
    ),
  );
  return dio;
}
