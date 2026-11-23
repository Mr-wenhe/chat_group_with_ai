import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:chat_group/features/web_search/application/search_flow_logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/search_failure.dart';
import '../models/search_models.dart';
import '../security/search_endpoint_dns_guard.dart';
import '../security/search_endpoint_validator.dart';
import '../security/search_secret_scanner.dart';
import 'search_provider.dart';
import 'search_provider_http_support.dart';

/// A model-provider-specific search protocol.
///
/// Native adapters may return only independently verifiable web sources. A
/// generated model answer is intentionally outside this contract, so it can
/// never be shown as if it were a search result.
abstract class NativeWebSearchAdapter {
  String get providerId;

  bool supports({
    required ApiProvider provider,
    required String model,
  });

  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  });
}

/// Explicit opt-in binding for a model-native search credential. The caller
/// owns selecting the model configuration; the search subsystem never guesses
/// which AI key a user intended to spend.
class NativeWebSearchBinding {
  final ApiProvider provider;
  final String model;
  final Future<String?> Function() resolveCredential;

  const NativeWebSearchBinding({
    required this.provider,
    required this.model,
    required this.resolveCredential,
  });
}

/// Bridges the dedicated native search credential into the provider chain.
class NativeWebSearchProvider implements SearchProvider {
  final NativeWebSearchAdapter adapter;
  final NativeWebSearchBinding binding;

  const NativeWebSearchProvider({
    required this.adapter,
    required this.binding,
  });

  @override
  SearchProviderKind get kind => SearchProviderKind.nativeModel;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    if (kIsWeb) return webSearchUnsupportedResponse();
    final nativeCredential = await binding.resolveCredential();
    return adapter.search(
      request,
      credential: nativeCredential,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      // Probe with the dedicated search credential used by production.
      final nativeCredential = await binding.resolveCredential();
      final request = SearchRequest(
        requestId: 'native-health',
        rootRequestId: 'native-health',
        turnId: 'native-health',
        query: sanitizeSearchText(
          probeQuery,
          maxLength: searchQueryMaxLength,
          fallback: 'Flutter official documentation',
          redactSecrets: true,
          redactOpaqueTokens: true,
        ),
        maxResults: 1,
      );
      final response = await adapter.search(
        request,
        credential: nativeCredential,
      );
      final failure = response.failure ??
          (response.items.isEmpty
              ? buildSearchFailure(type: SearchFailureType.noResults)
              : null);
      return SearchHealthResult(
        isHealthy: failure == null,
        latencyMs: stopwatch.elapsedMilliseconds,
        failure: failure,
        providerRequestId: response.providerRequestId,
      );
    } on Object {
      return SearchHealthResult(
        isHealthy: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        failure: buildSearchFailure(type: SearchFailureType.unknown),
      );
    }
  }
}

/// Explicit native protocol allow-list. Unknown and custom OpenAI-compatible
/// models never receive a provider-specific search parameter.
class NativeWebSearchAdapterRegistry {
  final ModelCapabilityRegistry capabilities;
  final bool isRelease;
  final Dio Function()? _dioFactory;

  NativeWebSearchAdapterRegistry({
    ModelCapabilityRegistry? capabilities,
    Dio Function()? dioFactory,
    bool? isRelease,
  })  : capabilities = capabilities ?? ModelCapabilityRegistry(),
        isRelease = isRelease ?? kReleaseMode,
        _dioFactory = dioFactory;

  NativeWebSearchAdapter? resolve({
    required ApiProvider provider,
    required String model,
  }) {
    final capability = capabilities.resolve(provider: provider, modelId: model);
    if (!capability.supportsNativeWebSearch) return null;
    return switch (provider) {
      ApiProvider.zhipu => ZhipuWebSearchAdapter(
          model: model,
          dio: _dioFactory?.call(),
          isRelease: isRelease,
        ),
      _ => null,
    };
  }
}

/// Zhipu's model-owned Web Search API. The caller supplies the dedicated
/// Zhipu search credential; the adapter never reads a character API config.
/// It returns structured sources, so no independent search key or DuckDuckGo
/// request is involved.
class ZhipuWebSearchAdapter extends NativeWebSearchAdapter {
  static final Uri endpoint = Uri.parse(
    'https://open.bigmodel.cn/api/paas/v4/web_search',
  );

  final String model;
  final Dio _dio;
  final ModelCapabilityRegistry _capabilities;
  final bool _isRelease;

  ZhipuWebSearchAdapter({
    required this.model,
    Dio? dio,
    ModelCapabilityRegistry? capabilities,
    bool? isRelease,
  })  : _dio = configureSearchProviderDio(dio ??
            Dio(
              BaseOptions(
                connectTimeout: searchProviderConnectTimeout,
                sendTimeout: searchProviderConnectTimeout,
                receiveTimeout: searchProviderReceiveTimeout,
                followRedirects: false,
                maxRedirects: 0,
              ),
            )),
        _capabilities = capabilities ?? ModelCapabilityRegistry(),
        _isRelease = isRelease ?? kReleaseMode;

  @override
  String get providerId => 'zhipu-native';

  @override
  bool supports({required ApiProvider provider, required String model}) {
    final canonicalModel = _canonicalZhipuModel(model);
    return provider == ApiProvider.zhipu &&
        canonicalModel == _canonicalZhipuModel(this.model) &&
        _capabilities
            .resolve(provider: provider, modelId: canonicalModel)
            .supportsNativeWebSearch;
  }

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    if (kIsWeb) return webSearchUnsupportedResponse();
    if (!supports(provider: ApiProvider.zhipu, model: model)) {
      SearchFlowLogger.event(
        'native_request_blocked',
        query: request.query,
        fields: {
          'provider': providerId,
          'model': model,
          'reason': 'unsupported'
        },
      );
      return _failure(SearchFailureType.invalidConfiguration);
    }
    final token = _credential(credential);
    if (token == null || request.query.trim().isEmpty) {
      SearchFlowLogger.event(
        'native_request_blocked',
        query: request.query,
        fields: {
          'provider': providerId,
          'model': model,
          'reason': token == null ? 'credential_unavailable' : 'empty_query',
        },
      );
      return _failure(SearchFailureType.invalidConfiguration);
    }
    try {
      SearchFlowLogger.event(
        'native_http_start',
        query: request.query,
        fields: {
          'provider': providerId,
          'model': model,
          'endpoint': endpoint.toString(),
          'requestId': request.requestId,
          'freshness': request.freshness.name,
          'maxResults': request.maxResults,
        },
      );
      await prepareSearchEndpointConnection(_dio, endpoint,
          isRelease: _isRelease);
      final response = await _dio.postUri<dynamic>(
        endpoint,
        data: {
          'search_engine': 'search_pro',
          'search_query': request.query,
          'search_intent': false,
          'count': request.maxResults,
          'search_recency_filter': _recency(request.freshness),
          'content_size': 'high',
          'request_id': request.requestId,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          responseType: ResponseType.json,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
      final parsed = _parseResponse(response);
      SearchFlowLogger.event(
        'native_http_complete',
        query: request.query,
        fields: {
          'provider': providerId,
          'model': model,
          'statusCode': response.statusCode,
          'providerRequestId': parsed.providerRequestId,
          'resultCount': parsed.items.length,
          'failureType': parsed.failure?.type.name,
        },
      );
      return parsed;
    } on DioException catch (error) {
      SearchFlowLogger.event(
        'native_http_error',
        query: request.query,
        fields: {
          'provider': providerId,
          'model': model,
          'statusCode': error.response?.statusCode,
          'failureType': searchFailureTypeFromDioException(error).name,
        },
      );
      return _failure(
        searchFailureTypeFromDioException(error),
        statusCode: error.response?.statusCode,
        providerRequestId: _requestId(error.response?.data),
      );
    } on SearchEndpointDnsException catch (error) {
      SearchFlowLogger.event(
        'native_http_error',
        query: request.query,
        fields: {
          'provider': providerId,
          'model': model,
          'reason': error.toString()
        },
      );
      return _failure(searchFailureTypeFromEndpointDnsException(error));
    } on Object {
      SearchFlowLogger.event(
        'native_http_error',
        query: request.query,
        fields: {'provider': providerId, 'model': model, 'reason': 'unknown'},
      );
      return _failure(SearchFailureType.unknown);
    }
  }

  SearchProviderResponse _parseResponse(Response<dynamic> response) {
    final body = _map(response.data);
    final status = response.statusCode;
    final requestId = _requestId(body);
    if (status == null || status < 200 || status >= 300) {
      return _failure(
        status == null
            ? SearchFailureType.invalidResponse
            : searchFailureTypeFromStatusCode(status),
        statusCode: status,
        providerRequestId: requestId,
      );
    }
    final raw = body?['search_result'];
    if (raw is! List) {
      SearchFlowLogger.event(
        'native_response_shape',
        fields: {
          'provider': providerId,
          'statusCode': status,
          'bodyKeys': body?.keys.toList(growable: false),
          'searchResultType': raw?.runtimeType.toString(),
          'rawResultCount': 0,
          'acceptedUrlCount': 0,
        },
      );
      return _failure(SearchFailureType.invalidResponse,
          statusCode: status, providerRequestId: requestId);
    }
    final items = <SearchProviderItem>[];
    final urls = <String>{};
    var candidateCount = 0;
    var rejectedUrlCount = 0;
    for (final value in raw) {
      if (items.length >= searchProviderMaxResults || value is! Map) break;
      candidateCount++;
      final url = _url(value['link']);
      final title = _text(value['title'], fallback: '智谱搜索来源');
      final content = _text(value['content']);
      if (url == null) {
        rejectedUrlCount++;
        SearchFlowLogger.event(
          'native_url_rejected',
          fields: _urlDiagnostics(value['link']),
        );
      }
      // Zhipu may return useful `search_result` text with an empty `link`.
      // search_answer.py keeps these entries as “链接: 无”, so retain them
      // for answer grounding while keeping them non-clickable in the UI.
      if (url == null && content.isEmpty) continue;
      if (url != null && !urls.add(url.toString())) continue;
      items.add(SearchProviderItem(
        title: title,
        snippet: content,
        url: url,
        publishedAt: _publishedAt(value['publish_date']),
      ));
    }
    SearchFlowLogger.event(
      'native_response_shape',
      fields: {
        'provider': providerId,
        'statusCode': status,
        'bodyKeys': body?.keys.toList(growable: false),
        'rawResultCount': raw.length,
        'candidateCount': candidateCount,
        'rejectedUrlCount': rejectedUrlCount,
        'acceptedUrlCount': urls.length,
        'acceptedResultCount': items.length,
      },
    );
    _logSearchResults(raw);
    if (items.isEmpty) {
      return _failure(SearchFailureType.noResults,
          statusCode: status, providerRequestId: requestId);
    }
    return SearchProviderResponse(
      items: items,
      providerRequestId: requestId,
      sourceProvider: providerId,
      statusCode: status,
    );
  }

  SearchProviderResponse _failure(
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

  static Map<String, dynamic>? _map(dynamic value) {
    if (value is! Map) return null;
    return value.map<String, dynamic>(
      (key, item) => MapEntry(key.toString(), item),
    );
  }

  static String? _requestId(dynamic value) =>
      safeProviderRequestId(_map(value)?['request_id'] ?? _map(value)?['id']);

  static String? _credential(String? value) {
    final token = value?.trim();
    if (token == null ||
        token.isEmpty ||
        token.contains('\r') ||
        token.contains('\n')) {
      return null;
    }
    return token;
  }

  static Uri? _url(dynamic value) {
    if (value is! String) return null;
    final candidate = _extractUrl(value);
    return tryValidateSearchUrl(Uri.tryParse(candidate));
  }

  static Map<String, Object?> _urlDiagnostics(dynamic value) {
    if (value is! String) return {'reason': 'not_string'};
    final candidate = _extractUrl(value);
    final parsed = Uri.tryParse(candidate);
    if (parsed == null) return {'reason': 'malformed'};
    final scheme = parsed.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return {'reason': 'unsupported_scheme', 'scheme': scheme};
    }
    if (scheme != 'https') {
      return {'reason': 'https_required', 'scheme': scheme};
    }
    if (parsed.host.trim().isEmpty) return {'reason': 'missing_host'};
    if (parsed.userInfo.isNotEmpty) return {'reason': 'userinfo_not_allowed'};
    if (SearchEndpointValidator.isPrivateOrLocalHost(parsed.host)) {
      return {'reason': 'private_or_local_host'};
    }
    const scanner = SearchSecretScanner();
    if (scanner.containsSensitiveData(
          parsed.host,
          includeOpaqueTokens: true,
        ) ||
        scanner.containsSensitiveData(
          parsed.path,
          includeOpaqueTokens: true,
        ) ||
        scanner.containsSensitiveData(
          parsed.fragment,
          includeOpaqueTokens: true,
        )) {
      return {'reason': 'sensitive_url_component'};
    }
    for (final parameter in parsed.queryParameters.entries) {
      if (scanner.isSensitiveParameter(parameter.key) ||
          scanner.containsSensitiveData(
            parameter.value,
            includeOpaqueTokens: true,
          )) {
        return {'reason': 'sensitive_query_parameter'};
      }
    }
    if (parsed.toString().length > searchUrlMaxLength) {
      return {'reason': 'url_too_long'};
    }
    return {
      'reason': 'validation_mismatch',
      'scheme': scheme,
      'hostLength': parsed.host.length,
      'pathLength': parsed.path.length,
      'queryParameterCount': parsed.queryParameters.length,
    };
  }

  /// Accept the plain URL returned by the API and the occasional markdown or
  /// punctuation wrapper without weakening the HTTPS/private-host checks.
  static String _extractUrl(String value) {
    final trimmed = value.trim();
    final match = RegExp(
      r'https?://[^\s<>\[\]{}"“”‘’]+',
      caseSensitive: false,
    ).firstMatch(trimmed);
    return (match?.group(0) ?? trimmed).replaceFirst(
      RegExp(r'[),.;:!?]+$'),
      '',
    );
  }

  static DateTime? _publishedAt(dynamic value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim())?.toUtc();
  }

  static String _text(dynamic value, {String fallback = ''}) =>
      sanitizeSearchText(
        value is String ? value : '',
        maxLength: searchSnippetMaxLength,
        fallback: fallback,
        redactSecrets: true,
        redactOpaqueTokens: true,
      );

  /// Debug-only result output for inspecting the Zhipu search-answer flow.
  /// Credentials and rejected raw URLs are never included.
  void _logSearchResults(List<dynamic> rawResults) {
    final results = <Map<String, Object?>>[];
    for (var index = 0;
        index < rawResults.length && index < searchProviderMaxResults;
        index++) {
      final value = rawResults[index];
      if (value is! Map) {
        results.add({
          'index': index + 1,
          'accepted': false,
          'reason': 'result_not_object',
        });
        continue;
      }
      final url = _url(value['link']);
      results.add({
        'index': index + 1,
        'title': _text(value['title'], fallback: '无'),
        'media': _text(value['media'], fallback: '未知'),
        'publishDate': _text(value['publish_date'], fallback: '未知'),
        'link': url?.toString(),
        'content': _text(value['content']),
        'accepted': url != null,
        if (url == null) 'urlRejection': _urlDiagnostics(value['link']),
      });
    }
    SearchFlowLogger.event(
      'native_search_results',
      fields: {
        'provider': providerId,
        'resultCount': rawResults.length,
        'printedCount': results.length,
        'results': results,
      },
    );
  }

  static String _recency(SearchFreshness freshness) => switch (freshness) {
        SearchFreshness.any => 'noLimit',
        SearchFreshness.day => 'oneDay',
        SearchFreshness.week => 'oneWeek',
        SearchFreshness.month => 'oneMonth',
        SearchFreshness.year => 'oneYear',
      };

  static String _canonicalZhipuModel(String value) {
    final normalized = value.trim().toLowerCase().replaceAll('_', '-');
    return normalized == 'glm4.7' ? 'glm-4.7' : normalized;
  }
}
