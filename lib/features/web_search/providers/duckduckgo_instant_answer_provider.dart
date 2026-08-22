import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';

import '../models/search_failure.dart';
import '../models/search_models.dart';
import 'duckduckgo_instant_answer_parser.dart';
import 'search_provider.dart';

/// Free, keyless DuckDuckGo Instant Answer fallback.
///
/// This adapter intentionally exposes only normalized answer/topic items. It
/// is not a full web-search provider and is marked degraded by the facade.
class DuckDuckGoInstantAnswerProvider implements SearchProvider {
  DuckDuckGoInstantAnswerProvider({Dio? dio, Uuid? uuid})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 12),
              ),
            ),
        _uuid = uuid ?? const Uuid();

  static const endpoint = 'https://api.duckduckgo.com/';
  static const _defaultProbeQuery = 'DuckDuckGo';

  final Dio _dio;
  final Uuid _uuid;

  @override
  SearchProviderKind get kind => SearchProviderKind.duckDuckGoInstantAnswer;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    // DuckDuckGo does not use a credential; keeping the interface parameter
    // makes this adapter interchangeable with keyed providers in Stage 04.
    try {
      final query = request.query.trim();
      if (query.isEmpty) {
        return _noResults();
      }

      final response = await _dio.get<dynamic>(
        endpoint,
        queryParameters: {
          'q': query,
          'format': 'json',
          'no_html': '1',
          'skip_disambig': '1',
          'no_redirect': '1',
        },
        cancelToken: cancelToken,
      );
      final data = _decodeMap(response.data);
      if (data == null) {
        return _failureResponse(
          type: SearchFailureType.invalidResponse,
          statusCode: response.statusCode,
          providerRequestId: _providerRequestId(response),
        );
      }
      return _parseResponse(
        request: request,
        data: data,
        statusCode: response.statusCode,
        providerRequestId: _providerRequestId(response),
      );
    } on DioException catch (error) {
      final type = searchFailureTypeFromDioException(error);
      return _failureResponse(
        type: type,
        statusCode: error.response?.statusCode,
        providerRequestId: _providerRequestId(error.response),
      );
    } on FormatException {
      return _failureResponse(
        type: SearchFailureType.invalidResponse,
      );
    } catch (_) {
      return _failureResponse(
        type: SearchFailureType.unknown,
      );
    }
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    final stopwatch = Stopwatch()..start();
    final requestId = _uuid.v4();
    final response = await search(
      SearchRequest(
        requestId: requestId,
        rootRequestId: requestId,
        turnId: requestId,
        query: probeQuery.trim().isEmpty ? _defaultProbeQuery : probeQuery,
        maxResults: 1,
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

  SearchProviderResponse _parseResponse({
    required SearchRequest request,
    required Map<String, dynamic> data,
    required int? statusCode,
    required String? providerRequestId,
  }) {
    final parsed = DuckDuckGoInstantAnswerParser(
      maxResults: request.maxResults,
    ).parse(data);
    if (parsed.items.isEmpty) {
      return SearchProviderResponse(
        items: const [],
        providerRequestId: providerRequestId,
        moreResultsAvailable: parsed.moreResultsAvailable,
        statusCode: statusCode,
        failure: _noResultsFailure(),
      );
    }
    return SearchProviderResponse(
      items: parsed.items,
      providerRequestId: providerRequestId,
      moreResultsAvailable: parsed.moreResultsAvailable,
      statusCode: statusCode,
    );
  }

  SearchProviderResponse _noResults() => SearchProviderResponse(
        items: const [],
        failure: _noResultsFailure(),
      );

  SearchFailure _noResultsFailure() => const SearchFailure(
        type: SearchFailureType.noResults,
        safeMessage: '搜索服务没有返回可用结果',
        retryable: false,
      );

  SearchProviderResponse _failureResponse({
    required SearchFailureType type,
    int? statusCode,
    String? providerRequestId,
  }) {
    return SearchProviderResponse(
      items: const [],
      statusCode: statusCode,
      providerRequestId: providerRequestId,
      failure: SearchFailure(
        type: type,
        safeMessage: safeMessageForSearchFailure(type),
        statusCode: statusCode,
        retryable: _isRetryable(type),
        providerRequestId: providerRequestId,
      ),
    );
  }

  Map<String, dynamic>? _decodeMap(dynamic raw) {
    if (raw is String) {
      final decoded = jsonDecode(raw);
      raw = decoded;
    }
    if (raw is! Map) return null;
    return raw.map<String, dynamic>(
      (key, value) => MapEntry(key.toString(), value),
    );
  }

  String? _providerRequestId(Response<dynamic>? response) =>
      response?.headers.value('x-request-id') ??
      response?.headers.value('request-id');

  bool _isRetryable(SearchFailureType type) => switch (type) {
        SearchFailureType.offline ||
        SearchFailureType.connection ||
        SearchFailureType.dns ||
        SearchFailureType.connectionTimeout ||
        SearchFailureType.receiveTimeout ||
        SearchFailureType.providerUnavailable ||
        SearchFailureType.rateLimited =>
          true,
        _ => false,
      };
}
