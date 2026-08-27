import 'package:chat_group/core/search/search_failure_type.dart';
import 'package:chat_group/features/web_search/application/search_provider_chain.dart';
import 'package:chat_group/features/web_search/application/search_provider_route.dart';
import 'package:chat_group/features/web_search/application/search_retry_policy.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/gateway_search_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Gateway provider uses the fixed search contract and maps results',
      () async {
    late RequestOptions captured;
    final provider = GatewaySearchProvider(
      baseUrl: 'https://search.example.com',
      dio: _gatewayDio(
        onRequest: (options) => captured = options,
        data: {
          'request_id': 'gateway-request-001',
          'provider_request_id': 'brave-upstream-001',
          'provider': 'brave',
          'searched_at': '2026-08-23T00:00:00Z',
          'from_cache': true,
          'degraded': true,
          'results': [
            {
              'title': 'Flutter release notes',
              'url': 'https://docs.flutter.dev/release/notes',
              'snippet': 'Official release notes',
              'published_at': '2026-08-22T00:00:00Z',
              'score': 0.9,
              'language': 'en',
            },
          ],
        },
      ),
    );

    final response = await provider.search(
      SearchRequest(
        requestId: 'gateway-request-001',
        rootRequestId: 'turn-001',
        turnId: 'turn-001',
        query: 'Flutter latest release',
        category: SearchCategory.software,
        freshness: SearchFreshness.month,
        locale: 'en-US',
        country: 'US',
      ),
      credential: 'gateway-client-token',
    );

    expect(captured.method, 'POST');
    expect(captured.uri.path, '/v1/search');
    expect(captured.headers['Authorization'], 'Bearer gateway-client-token');
    expect(captured.headers['X-Request-Id'], 'gateway-request-001');
    expect(captured.data['query'], 'Flutter latest release');
    expect(captured.data['safe_search'], isTrue);
    expect(captured.data['max_results'], 5);
    expect(captured.data['request_id'], 'gateway-request-001');
    expect(response.failure, isNull);
    expect(response.providerRequestId, 'brave-upstream-001');
    expect(response.sourceProvider, 'brave');
    expect(response.fromCache, isTrue);
    expect(response.degraded, isTrue);
    expect(response.items.single.url,
        Uri.parse('https://docs.flutter.dev/release/notes'));
  });

  test('Gateway normalizes a versioned base URL without duplicating v1',
      () async {
    late RequestOptions captured;
    final provider = GatewaySearchProvider(
      baseUrl: 'https://search.example.com/v1',
      dio: _gatewayDio(
        onRequest: (options) => captured = options,
        data: {
          'request_id': 'gateway-versioned-base',
          'provider': 'brave',
          'searched_at': '2026-08-23T00:00:00Z',
          'results': const [],
        },
      ),
    );

    await provider.search(
      SearchRequest(requestId: 'gateway-versioned-base', query: 'Flutter'),
      credential: 'gateway-client-token',
    );

    expect(captured.uri.path, '/v1/search');
  });

  test('Gateway metadata is preserved in the normalized snapshot', () async {
    final provider = GatewaySearchProvider(
      baseUrl: 'https://search.example.com',
      dio: _gatewayDio(
        data: {
          'request_id': 'gateway-snapshot-001',
          'provider': 'tavily',
          'searched_at': '2026-08-23T00:00:00Z',
          'from_cache': true,
          'degraded': true,
          'results': [
            {
              'title': 'Flutter release notes',
              'url': 'https://docs.flutter.dev/release/notes',
              'snippet': 'Official release notes',
            },
          ],
        },
      ),
    );
    final chain = SearchProviderChain(
      routes: [SearchProviderRoute(provider: provider)],
      retryPolicy: SearchRetryPolicy(sleep: (_) async {}),
    );

    final snapshot = await chain.execute(
      request: SearchRequest(
        requestId: 'gateway-snapshot-001',
        query: 'Flutter latest release',
      ),
      cancelToken: null,
      onStatus: null,
    );

    expect(snapshot.provider, 'tavily');
    expect(snapshot.fromCache, isTrue);
    expect(snapshot.degraded, isTrue);
  });

  test('Gateway provider supports tokenless development and safe failures',
      () async {
    late RequestOptions captured;
    final provider = GatewaySearchProvider(
      baseUrl: 'https://search.example.com',
      dio: _gatewayDio(
        onRequest: (options) => captured = options,
        statusCode: 429,
        data: {
          'request_id': 'gateway-request-002',
          'error': {
            'code': 'RATE_LIMITED',
            'message': 'must not reach the UI',
            'retryable': true,
          },
        },
      ),
    );

    final response = await provider.search(
      SearchRequest(query: 'Flutter latest release'),
      credential: null,
    );

    expect(captured.headers, isNot(contains('Authorization')));
    expect(response.failure?.type, SearchFailureType.rateLimited);
    expect(response.failure?.safeMessage, isNot(contains('must not reach')));
  });

  test('release Gateway rejects a missing token before network dispatch',
      () async {
    var dispatched = false;
    final provider = GatewaySearchProvider(
      baseUrl: 'https://search.example.com',
      isRelease: true,
      dio: _gatewayDio(
        onRequest: (_) => dispatched = true,
        data: {
          'request_id': 'should-not-dispatch',
          'results': const [],
        },
      ),
    );

    final response = await provider.search(
      SearchRequest(query: 'Flutter latest release'),
      credential: null,
    );

    expect(dispatched, isFalse);
    expect(response.failure?.type, SearchFailureType.invalidConfiguration);
  });

  group('Gateway error contract', () {
    for (final (:statusCode, :code, :type) in [
      (
        statusCode: 400,
        code: 'INVALID_REQUEST',
        type: SearchFailureType.invalidConfiguration,
      ),
      (
        statusCode: 413,
        code: 'REQUEST_TOO_LARGE',
        type: SearchFailureType.invalidConfiguration,
      ),
      (
        statusCode: 401,
        code: 'UNAUTHORIZED',
        type: SearchFailureType.unauthorized,
      ),
      (
        statusCode: 403,
        code: 'FORBIDDEN',
        type: SearchFailureType.forbidden,
      ),
      (
        statusCode: 404,
        code: 'NOT_FOUND',
        type: SearchFailureType.invalidConfiguration,
      ),
      (
        statusCode: 500,
        code: 'INTERNAL_ERROR',
        type: SearchFailureType.providerUnavailable,
      ),
      (
        statusCode: 429,
        code: 'RATE_LIMITED',
        type: SearchFailureType.rateLimited,
      ),
      (
        statusCode: 503,
        code: 'UPSTREAM_UNAVAILABLE',
        type: SearchFailureType.providerUnavailable,
      ),
      (
        statusCode: 408,
        code: 'REQUEST_TIMEOUT',
        type: SearchFailureType.connectionTimeout,
      ),
      (
        statusCode: 402,
        code: 'QUOTA_EXCEEDED',
        type: SearchFailureType.quotaExceeded,
      ),
      (
        statusCode: 502,
        code: 'UPSTREAM_DNS_TIMEOUT',
        type: SearchFailureType.connectionTimeout,
      ),
      (
        statusCode: 502,
        code: 'UPSTREAM_DNS_FAILED',
        type: SearchFailureType.dns,
      ),
      (
        statusCode: 504,
        code: 'UPSTREAM_TIMEOUT',
        type: SearchFailureType.receiveTimeout,
      ),
      (
        statusCode: 502,
        code: 'UPSTREAM_DNS_BLOCKED',
        type: SearchFailureType.invalidConfiguration,
      ),
      (
        statusCode: 502,
        code: 'UPSTREAM_INVALID_RESPONSE',
        type: SearchFailureType.invalidResponse,
      ),
      (
        statusCode: 502,
        code: 'UPSTREAM_RESPONSE_TOO_LARGE',
        type: SearchFailureType.invalidResponse,
      ),
      (
        statusCode: 502,
        code: 'UPSTREAM_UNAUTHORIZED',
        type: SearchFailureType.unauthorized,
      ),
      (
        statusCode: 502,
        code: 'UPSTREAM_FORBIDDEN',
        type: SearchFailureType.forbidden,
      ),
      (
        statusCode: 499,
        code: 'UPSTREAM_CANCELLED',
        type: SearchFailureType.cancelled,
      ),
    ]) {
      test('$statusCode/$code maps to $type', () async {
        final provider = GatewaySearchProvider(
          baseUrl: 'https://search.example.com',
          dio: _gatewayDio(
            statusCode: statusCode,
            data: {
              'request_id': 'gateway-error-$statusCode',
              'error': {
                'code': code,
                'message': 'untrusted',
                'retryable': true
              },
            },
          ),
        );

        final response = await provider.search(
          SearchRequest(
            requestId: 'gateway-error-$statusCode',
            query: 'Flutter latest release',
          ),
          credential: 'gateway-client-token',
        );

        expect(response.failure?.type, type);
        expect(response.failure?.statusCode, statusCode);
      });
    }
  });

  test('bare gateway 502 is classified as an invalid upstream response',
      () async {
    final provider = GatewaySearchProvider(
      baseUrl: 'https://search.example.com',
      dio: _gatewayDio(statusCode: 502, data: {'unexpected': 'body'}),
    );

    final response = await provider.search(
      SearchRequest(requestId: 'gateway-bare-502', query: 'Flutter release'),
      credential: null,
    );

    expect(response.failure?.type, SearchFailureType.invalidResponse);
    expect(response.failure?.statusCode, 502);
  });

  test('Gateway rejects a response correlated to a different request',
      () async {
    final provider = GatewaySearchProvider(
      baseUrl: 'https://search.example.com',
      dio: _gatewayDio(
        data: {
          'request_id': 'other-request',
          'results': const [],
        },
      ),
    );

    final response = await provider.search(
      SearchRequest(requestId: 'expected-request', query: 'Flutter release'),
      credential: null,
    );

    expect(response.failure?.type, SearchFailureType.invalidResponse);
  });

  test('Gateway rejects an incomplete successful contract response', () async {
    final provider = GatewaySearchProvider(
      baseUrl: 'https://search.example.com',
      dio: _gatewayDio(
        data: {
          'request_id': 'gateway-incomplete-001',
          'results': const [],
        },
      ),
    );

    final response = await provider.search(
      SearchRequest(
        requestId: 'gateway-incomplete-001',
        query: 'Flutter release',
      ),
      credential: 'gateway-client-token',
    );

    expect(response.failure?.type, SearchFailureType.invalidResponse);
  });
}

Dio _gatewayDio({
  required dynamic data,
  int statusCode = 200,
  void Function(RequestOptions options)? onRequest,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        onRequest?.call(options);
        handler.resolve(Response<dynamic>(
          requestOptions: options,
          statusCode: statusCode,
          data: data,
        ));
      },
    ),
  );
  return dio;
}
