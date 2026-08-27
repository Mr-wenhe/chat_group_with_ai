import 'dart:async';

import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/web_search/application/search_coordinator.dart';
import 'package:chat_group/features/web_search/application/search_provider_chain.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_governance_store.dart';

part 'search_coordinator_stage05_test_helpers_01.dart';
part 'search_coordinator_stage05_test_part_01.dart';
part 'search_coordinator_stage05_test_part_02.dart';

class _FakeClock {
  DateTime value = DateTime.utc(2026, 8, 23, 12);

  DateTime call() => value;

  void advance(Duration duration) => value = value.add(duration);
}

class _ScriptedProvider implements SearchProvider {
  _ScriptedProvider(this._kind, this._script);

  final SearchProviderKind _kind;
  final List<Object> _script;
  final List<SearchRequest> requests = [];
  int searchCount = 0;
  CancelToken? receivedCancelToken;

  @override
  SearchProviderKind get kind => _kind;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    searchCount++;
    requests.add(request);
    receivedCancelToken = cancelToken;
    if (cancelToken?.isCancelled == true) {
      return _failure(SearchFailureType.cancelled);
    }
    final next = _script.isEmpty ? _success() : _script.removeAt(0);
    if (next is Future<SearchProviderResponse>) return next;
    if (next is SearchProviderResponse) return next;
    throw next;
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    return const SearchHealthResult(isHealthy: true);
  }

  static SearchProviderResponse _success() => SearchProviderResponse(
        items: [
          SearchProviderItem(
            title: 'Result',
            snippet: 'A result',
            url: Uri.parse('https://example.com/result'),
          ),
        ],
      );

  static SearchProviderResponse _failure(
    SearchFailureType type, {
    int? statusCode,
  }) {
    return SearchProviderResponse(
      items: const [],
      statusCode: statusCode,
      failure: SearchFailure(
        type: type,
        safeMessage: 'safe failure',
        statusCode: statusCode,
        retryable: false,
      ),
    );
  }
}

class _CancellationAwareProvider implements SearchProvider {
  bool cancellationObserved = false;
  int searchCount = 0;

  @override
  SearchProviderKind get kind => SearchProviderKind.brave;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) {
    searchCount++;
    final token = cancelToken;
    if (token == null) return Completer<SearchProviderResponse>().future;
    return token.whenCancel.then<SearchProviderResponse>((_) {
      cancellationObserved = true;
      return _failure(SearchFailureType.cancelled);
    });
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async =>
      const SearchHealthResult(isHealthy: true);
}

SearchProviderResponse _success({String path = 'result'}) =>
    SearchProviderResponse(
      items: [
        SearchProviderItem(
          title: 'Result',
          snippet: 'A result',
          url: Uri.parse('https://example.com/$path'),
        ),
      ],
    );

SearchProviderResponse _failure(
  SearchFailureType type, {
  int? statusCode,
}) =>
    SearchProviderResponse(
      items: const [],
      statusCode: statusCode,
      failure: SearchFailure(
        type: type,
        safeMessage: 'safe failure',
        statusCode: statusCode,
        retryable: false,
      ),
    );

SearchRequest _request({
  String sourceMessageId = 'message-1',
  String turnId = 'turn-1',
  SearchCategory category = SearchCategory.general,
  SearchFreshness freshness = SearchFreshness.any,
  String locale = 'zh-CN',
  String? country,
  int maxResults = 5,
  bool safeSearch = true,
  bool forceRefresh = false,
  bool isSensitive = false,
}) {
  return SearchRequest(
    requestId: '$turnId-$sourceMessageId',
    rootRequestId: turnId,
    sourceMessageId: sourceMessageId,
    turnId: turnId,
    query: 'same query',
    category: category,
    freshness: freshness,
    locale: locale,
    country: country,
    maxResults: maxResults,
    safeSearch: safeSearch,
    forceRefresh: forceRefresh,
    isSensitive: isSensitive,
  );
}

void main() {
  _registerSearchCoordinatorStage05TestPart1();
  _registerSearchCoordinatorStage05TestPart2();
}
