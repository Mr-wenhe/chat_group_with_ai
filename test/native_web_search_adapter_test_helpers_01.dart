part of 'native_web_search_adapter_test.dart';

Dio _dio(Map<String, dynamic> Function(RequestOptions) responseData) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: options,
          statusCode: 200,
          data: responseData(options),
        ),
      ),
    ),
  );
  return dio;
}

class _FallbackProvider implements SearchProvider {
  int calls = 0;

  @override
  SearchProviderKind get kind => SearchProviderKind.brave;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    calls++;
    expect(credential, 'brave-key');
    return SearchProviderResponse(
      items: [
        SearchProviderItem(
          title: 'Independent source',
          snippet: 'Fallback result',
          url: Uri.parse('https://example.com/source'),
        ),
      ],
    );
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) =>
      throw UnimplementedError();
}

class _SuccessfulNativeAdapter extends NativeWebSearchAdapter {
  int calls = 0;

  @override
  String get providerId => 'successful-native';

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    calls++;
    return SearchProviderResponse(
      items: [
        SearchProviderItem(
          title: 'Latest release',
          snippet: 'A current source',
          url: Uri.parse('https://example.com/latest'),
        ),
      ],
    );
  }

  @override
  bool supports({required ApiProvider provider, required String model}) => true;
}

class _DuckFallbackProvider implements SearchProvider {
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
    return SearchProviderResponse(items: const []);
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async =>
      const SearchHealthResult(isHealthy: true);
}

class _CancelledNativeAdapter extends NativeWebSearchAdapter {
  @override
  String get providerId => 'cancelled-native';

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async =>
      SearchProviderResponse(
        items: const [],
        failure: const SearchFailure(
          type: SearchFailureType.cancelled,
          safeMessage: 'cancelled',
          retryable: false,
        ),
      );

  @override
  bool supports({required ApiProvider provider, required String model}) => true;
}

class _InvalidNativeAdapter extends _CancelledNativeAdapter {
  @override
  String get providerId => 'invalid-native';

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async =>
      SearchProviderResponse(
        items: const [],
        failure: const SearchFailure(
          type: SearchFailureType.invalidConfiguration,
          safeMessage: 'unsupported search parameter',
          retryable: false,
        ),
      );
}
