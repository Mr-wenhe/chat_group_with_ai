import 'package:dio/dio.dart';

import '../models/search_failure.dart';
import '../models/search_failure_factory.dart';
import '../models/search_models.dart';
import 'search_provider.dart';

/// Opens a visible browser only after the bounded providers have failed.
///
/// The callback is supplied by the application layer so this provider stays
/// independent of Flutter windows and remains straightforward to test.
typedef VisibleBrowserSearchHandler = Future<SearchProviderResponse> Function(
  SearchRequest request, {
  CancelToken? cancelToken,
});

class VisibleBrowserSearchProvider implements SearchProvider {
  final VisibleBrowserSearchHandler handler;

  const VisibleBrowserSearchProvider(this.handler);

  /// Keep the existing enum stable for persisted settings and exhaustive
  /// provider switches. The route flag identifies this interactive adapter.
  @override
  SearchProviderKind get kind => SearchProviderKind.keylessHtml;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) {
      return SearchProviderResponse(
        items: const [],
        sourceProvider: 'visibleBrowser',
        failure: buildSearchFailure(type: SearchFailureType.cancelled),
      );
    }
    return handler(request, cancelToken: cancelToken);
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    return const SearchHealthResult(
      isHealthy: false,
      failure: SearchFailure(
        type: SearchFailureType.invalidConfiguration,
        safeMessage: '可见浏览器需要在真实搜索失败后由任务触发。',
        retryable: false,
      ),
    );
  }
}
