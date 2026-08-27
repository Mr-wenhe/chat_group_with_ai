import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';

import '../models/search_failure.dart';
import '../models/search_models.dart';
import '../security/search_secret_scanner.dart';
import '../security/search_endpoint_dns_guard.dart';
import 'search_provider.dart';
import 'search_provider_http_support.dart';

/// Adapter for the company's fixed-upstream Search Gateway.
///
/// The endpoint receives a query only; it does not accept a client-selected
/// upstream URL. Provider keys remain on the server, while [credential] is an
/// optional Gateway application/user bearer token.
class GatewaySearchProvider implements SearchProvider {
  static const String searchPath = '/v1/search';
  static const String healthProbeQuery = 'Flutter official documentation';

  GatewaySearchProvider({
    Dio? dio,
    required String baseUrl,
    bool? isRelease,
    bool allowLocalDevelopmentGateway = false,
  })  : _dio = configureSearchProviderDio(dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: searchProviderConnectTimeout,
                sendTimeout: searchProviderConnectTimeout,
                receiveTimeout: searchProviderReceiveTimeout,
                followRedirects: false,
                maxRedirects: 0,
              ),
            )),
        _endpoint = resolveSearchProviderEndpoint(
          baseUrl,
          searchPath,
          isRelease: isRelease,
          allowLocalDevelopmentGateway: allowLocalDevelopmentGateway,
        ),
        _isRelease = isRelease ?? kReleaseMode;

  final Dio _dio;
  final Uri _endpoint;
  final bool _isRelease;

  @override
  SearchProviderKind get kind => SearchProviderKind.gateway;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    if (kIsWeb) return webSearchUnsupportedResponse();
    // Coordinators allocate this before dispatch, but direct adapter callers
    // (including health tooling) still need one correlation ID for the header,
    // payload, and Gateway response contract.
    final correlatedRequest = request.requestId.isEmpty
        ? request.copyWith(requestId: const Uuid().v4())
        : request;
    if (correlatedRequest.query.trim().isEmpty) {
      return _failureResponse(SearchFailureType.noResults);
    }
    final token = _validGatewayToken(credential);
    if (credential?.trim().isNotEmpty == true && token == null) {
      return _failureResponse(SearchFailureType.invalidConfiguration);
    }
    if (_isRelease && token == null) {
      return _failureResponse(SearchFailureType.invalidConfiguration);
    }
    try {
      await prepareSearchEndpointConnection(
        _dio,
        _endpoint,
        isRelease: _isRelease,
      );
      final response = await _dio.postUri<dynamic>(
        _endpoint,
        data: _requestBody(correlatedRequest),
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'X-Request-Id': correlatedRequest.requestId,
            if (token != null) 'Authorization': 'Bearer $token',
          },
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
      return _parseResponse(correlatedRequest, response);
    } on DioException catch (error) {
      return _dioFailure(error);
    } on SearchEndpointDnsException catch (error) {
      return _failureResponse(
        searchFailureTypeFromEndpointDnsException(error),
      );
    } on ArgumentError {
      return _failureResponse(SearchFailureType.invalidConfiguration);
    } catch (_) {
      return _failureResponse(SearchFailureType.unknown);
    }
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    final stopwatch = Stopwatch()..start();
    final requestId = const Uuid().v4();
    final response = await search(
      SearchRequest(
        requestId: requestId,
        rootRequestId: requestId,
        turnId: requestId,
        query: _safeProbeQuery(probeQuery),
        maxResults: searchProviderProbeMaxResults,
      ),
      credential: credential,
    );
    return SearchHealthResult(
      requestId: requestId,
      isHealthy: response.failure == null && response.items.isNotEmpty,
      latencyMs: stopwatch.elapsedMilliseconds,
      failure: response.failure,
      providerRequestId: response.providerRequestId,
    );
  }

  Map<String, dynamic> _requestBody(SearchRequest request) => {
        'request_id': request.requestId,
        'query': request.query,
        'category': request.category.name,
        'freshness': request.freshness.name,
        'locale': request.locale,
        if (request.country != null) 'country': request.country,
        'max_results': boundedSearchProviderMaxResults(request.maxResults),
        'safe_search': true,
        'force_refresh': request.forceRefresh,
      };

  SearchProviderResponse _parseResponse(
    SearchRequest request,
    Response<dynamic> response,
  ) {
    final body = decodeSearchProviderMap(response.data);
    final providerId = providerRequestId(response: response, body: body);
    final statusCode = response.statusCode;
    if (statusCode == null || statusCode < 200 || statusCode >= 300) {
      return _failureResponse(
        _gatewayFailureType(statusCode, body),
        statusCode: statusCode,
        providerRequestId: providerId,
      );
    }
    if (body == null ||
        !_hasSuccessContractMetadata(body) ||
        body['results'] is! List) {
      return _failureResponse(
        SearchFailureType.invalidResponse,
        statusCode: statusCode,
        providerRequestId: providerId,
      );
    }
    // `/v1/search` is a correlated contract: accepting a successful response
    // for another request would put the wrong evidence into this user turn.
    if (providerString(body['request_id']) != request.requestId) {
      return _failureResponse(
        SearchFailureType.invalidResponse,
        statusCode: statusCode,
        providerRequestId: providerId,
      );
    }
    final items = _itemsFrom(body['results'] as List, request.maxResults);
    if (items.isEmpty) {
      return _failureResponse(
        SearchFailureType.noResults,
        statusCode: statusCode,
        providerRequestId: providerId,
      );
    }
    return SearchProviderResponse(
      items: items,
      providerRequestId: providerId,
      sourceProvider: _gatewayProviderName(body['provider']),
      statusCode: statusCode,
      fromCache: body['from_cache'] == true,
      degraded: body['degraded'] == true,
      moreResultsAvailable: items.length < (body['results'] as List).length,
    );
  }

  List<SearchProviderItem> _itemsFrom(List raw, int maxResults) {
    final items = <SearchProviderItem>[];
    final seenUrls = <String>{};
    for (var index = 0;
        index < raw.length && index < searchProviderMaxResultCandidates;
        index++) {
      final value = raw[index];
      if (items.length >= boundedSearchProviderMaxResults(maxResults)) break;
      if (value is! Map) continue;
      final url = providerUrl(value['url']);
      if (url == null || !seenUrls.add(canonicalProviderUrl(url))) continue;
      items.add(SearchProviderItem(
        title: cleanProviderTitle(value['title']),
        snippet: cleanProviderText(value['snippet']),
        url: url,
        publishedAt: providerPublishedAt(value['published_at']),
        providerScore: providerScore(value['score']),
        language: providerString(value['language']),
      ));
    }
    return items;
  }

  SearchProviderResponse _dioFailure(DioException error) {
    final body = decodeSearchProviderMap(error.response?.data);
    return _failureResponse(
      _gatewayFailureType(error.response?.statusCode, body),
      statusCode: error.response?.statusCode,
      providerRequestId: providerRequestId(
        response: error.response,
        body: body,
      ),
    );
  }

  SearchProviderResponse _failureResponse(
    SearchFailureType type, {
    int? statusCode,
    String? providerRequestId,
  }) =>
      SearchProviderResponse(
        items: const [],
        statusCode: statusCode,
        providerRequestId: providerRequestId,
        failure: buildSearchFailure(
          type: type,
          statusCode: statusCode,
          providerRequestId: providerRequestId,
        ),
      );

  SearchFailureType _gatewayFailureType(
    int? statusCode,
    Map<String, dynamic>? body,
  ) {
    final code = providerString(
            body?['error'] is Map ? (body!['error'] as Map)['code'] : null)
        ?.toUpperCase();
    if (code == 'RATE_LIMITED' || code == 'UPSTREAM_RATE_LIMITED') {
      return SearchFailureType.rateLimited;
    }
    if (code == 'UNAUTHORIZED') return SearchFailureType.unauthorized;
    if (code == 'FORBIDDEN') return SearchFailureType.forbidden;
    if (code == 'INVALID_REQUEST' || code == 'REQUEST_TOO_LARGE') {
      return SearchFailureType.invalidConfiguration;
    }
    if (code == 'REQUEST_TIMEOUT' || code == 'UPSTREAM_DNS_TIMEOUT') {
      return SearchFailureType.connectionTimeout;
    }
    if (code == 'QUOTA_EXCEEDED') return SearchFailureType.quotaExceeded;
    if (code == 'NOT_FOUND') return SearchFailureType.invalidConfiguration;
    if (code == 'UPSTREAM_TIMEOUT') return SearchFailureType.receiveTimeout;
    if (code == 'UPSTREAM_DNS_FAILED') return SearchFailureType.dns;
    if (code == 'UPSTREAM_DNS_BLOCKED') {
      return SearchFailureType.invalidConfiguration;
    }
    if (code == 'UPSTREAM_INVALID_RESPONSE' ||
        code == 'UPSTREAM_RESPONSE_TOO_LARGE') {
      return SearchFailureType.invalidResponse;
    }
    if (code == 'UPSTREAM_UNAUTHORIZED') {
      return SearchFailureType.unauthorized;
    }
    if (code == 'UPSTREAM_FORBIDDEN') return SearchFailureType.forbidden;
    if (code == 'UPSTREAM_CANCELLED') return SearchFailureType.cancelled;
    if (code == 'UPSTREAM_UNAVAILABLE' || code == 'INTERNAL_ERROR') {
      return SearchFailureType.providerUnavailable;
    }
    // A bare 502 from the gateway is an invalid upstream response. Treating
    // it as providerUnavailable hides the actionable contract failure and
    // makes retry classification differ from the explicit upstream codes.
    if (statusCode == 502) return SearchFailureType.invalidResponse;
    return statusCode == null
        ? SearchFailureType.connection
        : searchFailureTypeFromStatusCode(statusCode);
  }

  String? _gatewayProviderName(dynamic value) {
    final provider = providerString(value);
    if (provider == null) return null;
    return sanitizeSearchText(
      provider,
      maxLength: searchProviderNameMaxLength,
      fallback: 'gateway',
      redactSecrets: true,
      redactOpaqueTokens: true,
    );
  }

  bool _hasSuccessContractMetadata(Map<String, dynamic> body) {
    final provider = providerString(body['provider']);
    final searchedAt = providerString(body['searched_at']);
    return provider != null &&
        provider.trim().isNotEmpty &&
        searchedAt != null &&
        DateTime.tryParse(searchedAt) != null &&
        body['from_cache'] is bool &&
        body['degraded'] is bool;
  }

  String _safeProbeQuery(String value) {
    final safe = const SearchSecretScanner().redact(value).trim();
    return safe.isEmpty ? healthProbeQuery : safe;
  }

  String? _validGatewayToken(String? credential) {
    final value = credential?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.contains('\r') || value.contains('\n')) return null;
    return value;
  }
}
