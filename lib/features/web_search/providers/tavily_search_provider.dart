import 'package:dio/dio.dart';

import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';

import '../models/search_failure.dart';
import '../models/search_models.dart';
import 'search_provider.dart';
import 'search_provider_http_support.dart';

/// Tavily's search-only adapter. It deliberately ignores answer/raw-content
/// fields so the application remains the only component generating answers.
class TavilySearchProvider implements SearchProvider {
  static const String defaultBaseUrl = 'https://api.tavily.com';
  static const String searchPath = '/search';
  static const Duration connectTimeout = searchProviderConnectTimeout;
  static const Duration receiveTimeout = searchProviderReceiveTimeout;
  static const int defaultMaxResults = searchProviderDefaultMaxResults;
  static const String defaultCountry = 'CN';

  TavilySearchProvider({
    Dio? dio,
    String baseUrl = defaultBaseUrl,
    bool? isRelease,
    bool allowLocalDevelopmentGateway = false,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: connectTimeout,
                sendTimeout: connectTimeout,
                receiveTimeout: receiveTimeout,
              ),
            ),
        _endpoint = resolveSearchProviderEndpoint(
          baseUrl,
          searchPath,
          isRelease: isRelease,
          allowLocalDevelopmentGateway: allowLocalDevelopmentGateway,
        );

  final Dio _dio;
  final Uri _endpoint;

  @override
  SearchProviderKind get kind => SearchProviderKind.tavily;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    final query = request.query.trim();
    if (query.isEmpty) return _noResults();

    final apiKey = _validCredential(credential);
    if (apiKey == null) return _invalidConfiguration();

    try {
      final response = await _dio.postUri<dynamic>(
        _endpoint,
        data: _requestBody(request),
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
      return _parseResponse(request, response);
    } on DioException catch (error) {
      return _dioFailure(error);
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
    final response = await search(
      SearchRequest(
        query: probeQuery.trim().isEmpty ? 'Tavily' : probeQuery,
        maxResults: searchProviderProbeMaxResults,
      ),
      credential: credential,
    );
    return SearchHealthResult(
      isHealthy: response.failure == null && response.items.isNotEmpty,
      latencyMs: stopwatch.elapsedMilliseconds,
      failure: response.failure,
      providerRequestId: response.providerRequestId,
    );
  }

  Map<String, dynamic> _requestBody(SearchRequest request) {
    final topic = _topic(request.category);
    final body = <String, dynamic>{
      'query': request.query,
      'search_depth': 'basic',
      'max_results': boundedSearchProviderMaxResults(request.maxResults),
      'topic': topic,
      'include_answer': false,
      'include_raw_content': false,
      'include_images': false,
      'include_image_descriptions': false,
      'include_favicon': false,
      'auto_parameters': false,
      'exact_match': false,
      'include_usage': false,
    };
    final timeRange = _timeRange(request.freshness);
    if (timeRange != null) body['time_range'] = timeRange;
    // Tavily only accepts country targeting for general searches. News and
    // finance requests must omit it or the provider can reject the request.
    if (topic == 'general') {
      final country = _country(request.country);
      if (country != null) body['country'] = country;
    }
    return body;
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
    if (body == null || body['results'] is! List) {
      return _failureResponse(
        SearchFailureType.invalidResponse,
        statusCode: statusCode,
        providerRequestId: requestId,
      );
    }

    final items = _itemsFrom(
      body['results'] as List,
      boundedSearchProviderMaxResults(request.maxResults),
    );
    final correctedQuery = _correctedQuery(request, body);
    if (items.isEmpty) {
      return SearchProviderResponse(
        items: const [],
        providerRequestId: requestId,
        correctedQuery: correctedQuery,
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
      correctedQuery: correctedQuery,
      moreResultsAvailable: items.length < (body['results'] as List).length,
      statusCode: statusCode,
    );
  }

  List<SearchProviderItem> _itemsFrom(List rawResults, int maxResults) {
    final items = <SearchProviderItem>[];
    final seenUrls = <String>{};
    for (final rawResult in rawResults) {
      if (items.length >= maxResults) break;
      if (rawResult is! Map) continue;
      final url = providerUrl(rawResult['url']);
      if (url == null || !seenUrls.add(canonicalProviderUrl(url))) continue;
      items.add(
        SearchProviderItem(
          title: cleanProviderTitle(rawResult['title']),
          snippet: cleanProviderText(rawResult['content']),
          url: url,
          publishedAt: providerPublishedAt(
            rawResult['published_date'] ??
                rawResult['published_at'] ??
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

  String _topic(SearchCategory category) => switch (category) {
        SearchCategory.news => 'news',
        SearchCategory.finance => 'finance',
        _ => 'general',
      };

  String? _timeRange(SearchFreshness freshness) => switch (freshness) {
        SearchFreshness.day => 'day',
        SearchFreshness.week => 'week',
        SearchFreshness.month => 'month',
        SearchFreshness.year => 'year',
        SearchFreshness.any => null,
      };

  String? _country(String? country) {
    final normalized = country?.trim().toUpperCase() ?? defaultCountry;
    return switch (normalized) {
      'CN' => 'china',
      'US' => 'united states',
      'GB' => 'united kingdom',
      'JP' => 'japan',
      'KR' => 'south korea',
      _ => null,
    };
  }

  String? _correctedQuery(SearchRequest request, Map<String, dynamic> body) {
    final returnedQuery = providerString(body['query']);
    return returnedQuery != null && returnedQuery != request.query
        ? returnedQuery
        : null;
  }
}
