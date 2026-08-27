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

/// Brave Web Search adapter. Only the web result block is mapped; answer,
/// rich-result, and other provider-specific blocks stay outside the contract.
class BraveSearchProvider implements SearchProvider {
  static const String defaultBaseUrl = 'https://api.search.brave.com';
  static const String searchPath = '/res/v1/web/search';
  static const Duration connectTimeout = searchProviderConnectTimeout;
  static const Duration receiveTimeout = searchProviderReceiveTimeout;
  static const int defaultMaxResults = searchProviderDefaultMaxResults;
  static const String defaultCountry = 'CN';
  static const String healthProbeQuery = 'Flutter official documentation';

  BraveSearchProvider({
    Dio? dio,
    String baseUrl = defaultBaseUrl,
    bool? isRelease,
    bool allowLocalDevelopmentGateway = false,
  })  : _dio = configureSearchProviderDio(dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: connectTimeout,
                sendTimeout: connectTimeout,
                receiveTimeout: receiveTimeout,
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
  SearchProviderKind get kind => SearchProviderKind.brave;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    if (kIsWeb) return webSearchUnsupportedResponse();
    final query = request.query.trim();
    if (query.isEmpty) return _noResults();

    final apiKey = _validCredential(credential);
    if (apiKey == null) return _invalidConfiguration();

    try {
      await prepareSearchEndpointConnection(
        _dio,
        _endpoint,
        isRelease: _isRelease,
      );
      final response = await _dio.getUri<dynamic>(
        _endpoint.replace(queryParameters: _queryParameters(request)),
        options: Options(
          headers: {
            'Accept': 'application/json',
            'X-Subscription-Token': apiKey,
          },
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
      return _parseResponse(request, response);
    } on DioException catch (error) {
      return _dioFailure(error);
    } on SearchEndpointDnsException catch (error) {
      return _failureResponse(
        searchFailureTypeFromEndpointDnsException(error),
      );
    } on ArgumentError {
      return _invalidConfiguration();
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

  String _safeProbeQuery(String value) {
    final safe = const SearchSecretScanner().redact(value).trim();
    return safe.isEmpty ? healthProbeQuery : safe;
  }

  Map<String, dynamic> _queryParameters(SearchRequest request) {
    final parameters = <String, dynamic>{
      'q': request.query,
      'count': boundedSearchProviderMaxResults(request.maxResults).toString(),
      'country': _country(request.country),
      'search_lang': _searchLanguage(request.locale),
      'ui_lang': request.locale,
      'safesearch': request.safeSearch ? 'moderate' : 'off',
      'text_decorations': 'false',
      'extra_snippets': 'false',
      'result_filter': 'web',
    };
    final freshness = _freshness(request.freshness);
    if (freshness != null) parameters['freshness'] = freshness;
    return parameters;
  }

  SearchProviderResponse _parseResponse(
    SearchRequest request,
    Response<dynamic> response,
  ) {
    final body = decodeSearchProviderMap(response.data);
    final requestId = providerRequestId(response: response, body: body);
    final statusCode = response.statusCode;
    if (!_isSuccess(statusCode)) {
      return _failureResponse(
        _httpFailureType(statusCode),
        statusCode: statusCode,
        providerRequestId: requestId,
      );
    }
    final web = body?['web'];
    if (body == null || web is! Map || web['results'] is! List) {
      return _failureResponse(
        SearchFailureType.invalidResponse,
        statusCode: statusCode,
        providerRequestId: requestId,
      );
    }

    final queryMetadata = body['query'];
    final items = _itemsFrom(
      web['results'] as List,
      boundedSearchProviderMaxResults(request.maxResults),
    );
    if (items.isEmpty) {
      return SearchProviderResponse(
        items: const [],
        providerRequestId: requestId,
        correctedQuery: _correctedQuery(request, queryMetadata),
        moreResultsAvailable: _moreResultsAvailable(queryMetadata),
        statusCode: statusCode,
        failure: buildSearchFailure(
          type: SearchFailureType.noResults,
          statusCode: statusCode,
          providerRequestId: requestId,
        ),
      );
    }
    return SearchProviderResponse(
      items: items,
      providerRequestId: requestId,
      correctedQuery: _correctedQuery(request, queryMetadata),
      moreResultsAvailable: _moreResultsAvailable(queryMetadata) ||
          items.length < (web['results'] as List).length,
      statusCode: statusCode,
    );
  }

  List<SearchProviderItem> _itemsFrom(List rawResults, int maxResults) {
    final items = <SearchProviderItem>[];
    final seenUrls = <String>{};
    for (var index = 0;
        index < rawResults.length && index < searchProviderMaxResultCandidates;
        index++) {
      final rawResult = rawResults[index];
      if (items.length >= maxResults) break;
      if (rawResult is! Map) continue;
      final url = providerUrl(rawResult['url']);
      if (url == null || !seenUrls.add(canonicalProviderUrl(url))) continue;
      items.add(
        SearchProviderItem(
          title: cleanProviderTitle(rawResult['title']),
          snippet: cleanProviderText(rawResult['description']),
          url: url,
          publishedAt: providerPublishedAt(
            rawResult['page_age'] ??
                rawResult['published_date'] ??
                rawResult['publishedAt'],
          ),
          providerScore: providerScore(rawResult['score']),
          language: providerString(rawResult['language']),
        ),
      );
    }
    return items;
  }

  SearchProviderResponse _dioFailure(DioException error) {
    final body = decodeSearchProviderMap(error.response?.data);
    final statusCode = error.response?.statusCode;
    final requestId = providerRequestId(
      response: error.response,
      body: body,
    );
    final type = statusCode == null
        ? searchFailureTypeFromDioException(error)
        : _httpFailureType(statusCode);
    return _failureResponse(
      type,
      statusCode: statusCode,
      providerRequestId: requestId,
    );
  }

  SearchProviderResponse _failureResponse(
    SearchFailureType type, {
    int? statusCode,
    String? providerRequestId,
  }) {
    return SearchProviderResponse(
      items: const [],
      statusCode: statusCode,
      providerRequestId: providerRequestId,
      failure: buildSearchFailure(
        type: type,
        statusCode: statusCode,
        providerRequestId: providerRequestId,
      ),
    );
  }

  SearchProviderResponse _noResults() => _failureResponse(
        SearchFailureType.noResults,
      );

  SearchProviderResponse _invalidConfiguration() => _failureResponse(
        SearchFailureType.invalidConfiguration,
      );

  SearchFailureType _httpFailureType(int? statusCode) => statusCode == null
      ? SearchFailureType.invalidResponse
      : searchFailureTypeFromStatusCode(statusCode);

  String? _validCredential(String? credential) {
    final value = credential?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.contains('\r') || value.contains('\n')) return null;
    return value;
  }

  bool _isSuccess(int? statusCode) =>
      statusCode != null && statusCode >= 200 && statusCode < 300;

  String _country(String? country) =>
      (country?.trim().isNotEmpty == true ? country!.trim() : defaultCountry)
          .toUpperCase();

  String _searchLanguage(String locale) {
    final normalized = locale.trim().toLowerCase();
    return switch (normalized) {
      'zh-cn' || 'zh-hans' => 'zh-hans',
      'zh-tw' || 'zh-hant' => 'zh-hant',
      _ => normalized.split('-').first,
    };
  }

  String? _freshness(SearchFreshness freshness) => switch (freshness) {
        SearchFreshness.day => 'pd',
        SearchFreshness.week => 'pw',
        SearchFreshness.month => 'pm',
        SearchFreshness.year => 'py',
        SearchFreshness.any => null,
      };

  String? _correctedQuery(SearchRequest request, dynamic metadata) {
    if (metadata is! Map) return null;
    final altered = providerString(metadata['altered']);
    final cleaned = providerString(metadata['cleaned']);
    final corrected = altered ?? cleaned;
    return corrected != null && corrected != request.query ? corrected : null;
  }

  bool _moreResultsAvailable(dynamic metadata) =>
      metadata is Map && metadata['more_results_available'] == true;
}
