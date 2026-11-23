part of 'native_web_search_adapter_test.dart';

void _registerNativeWebSearchAdapterTestPart1() {
  test('Zhipu native adapter uses the role model credential and sources',
      () async {
    late RequestOptions captured;
    final adapter = ZhipuWebSearchAdapter(
      model: 'glm-4-flash',
      dio: _dio((options) {
        captured = options;
        return {
          'id': 'glm-search-001',
          'search_result': [
            {
              'title': 'GLM source',
              'link': 'https://docs.bigmodel.cn/guide',
              'content': 'Structured source content',
            },
          ],
        };
      }),
    );
    final response = await adapter.search(
      SearchRequest(query: 'GLM latest release'),
      credential: 'role-zhipu-key',
    );
    expect(captured.uri, ZhipuWebSearchAdapter.endpoint);
    expect(captured.headers['Authorization'], 'Bearer role-zhipu-key');
    expect(captured.data['search_query'], 'GLM latest release');
    expect(response.sourceProvider, 'zhipu-native');
    expect(
        response.items.single.url.toString(), 'https://docs.bigmodel.cn/guide');
  });

  test('Zhipu keeps textual search results when the API omits link', () async {
    final adapter = ZhipuWebSearchAdapter(
      model: 'glm-4-flash',
      dio: _dio((_) => {
            'request_id': 'glm-search-no-link',
            'search_result': [
              {
                'title': '实时新闻结果',
                'link': '',
                'content': '智谱返回了可用于回答的新闻正文。',
                'publish_date': '2026-09-14',
              },
            ],
          }),
    );

    final response = await adapter.search(
      SearchRequest(query: '今天有什么新闻'),
      credential: 'role-zhipu-key',
    );

    expect(response.hasResults, isTrue);
    expect(response.failure, isNull);
    expect(response.items.single.hasSourceUrl, isFalse);
    expect(response.items.single.snippet, contains('新闻正文'));
    final snapshot = const SearchSnapshotBuilder().build(
      request: SearchRequest(query: '今天有什么新闻'),
      provider: 'zhipu-native',
      response: response,
      searchedAt: DateTime.utc(2026, 9, 14),
      latencyMs: 1,
    );
    expect(snapshot.hasResults, isTrue);
    expect(snapshot.results.single.hasSourceUrl, isFalse);
  });

  test('Qwen Max is not registered for the native source protocol', () {
    final capabilities = ModelCapabilityRegistry();
    expect(
      capabilities
          .resolve(provider: ApiProvider.qwen, modelId: 'qwen-max')
          .supportsNativeWebSearch,
      isFalse,
    );
    expect(
      NativeWebSearchAdapterRegistry()
          .resolve(provider: ApiProvider.qwen, model: 'qwen-max'),
      isNull,
    );
  });

  test('native cancellation remains terminal', () async {
    final response = await _CancelledNativeAdapter().search(
      SearchRequest(query: 'Flutter release'),
      credential: 'dashscope-key',
    );

    expect(response.failure?.type, SearchFailureType.cancelled);
  });

  test('unsupported native protocol failure remains visible', () async {
    final response = await _InvalidNativeAdapter().search(
      SearchRequest(query: 'Flutter release'),
      credential: 'dashscope-key',
    );

    expect(response.failure?.type, SearchFailureType.invalidConfiguration);
  });

  test('native route preserves its own failure', () async {
    final provider = NativeWebSearchProvider(
      adapter: _InvalidNativeAdapter(),
      binding: NativeWebSearchBinding(
        provider: ApiProvider.qwen,
        model: 'qwen-plus',
        resolveCredential: () async => 'dashscope-key',
      ),
    );

    final response = await provider.search(
      SearchRequest(query: 'Flutter release'),
      credential: 'brave-key',
    );

    expect(response.failure?.type, SearchFailureType.invalidConfiguration);
  });

  test('native route health probe exercises native search', () async {
    final native = _SuccessfulNativeAdapter();
    final provider = NativeWebSearchProvider(
      adapter: native,
      binding: NativeWebSearchBinding(
        provider: ApiProvider.qwen,
        model: 'qwen-plus',
        resolveCredential: () async => 'dashscope-key',
      ),
    );

    final health = await provider.testConnection(
      credential: 'brave-key',
      probeQuery: 'Flutter official documentation',
    );

    expect(health.isHealthy, isTrue);
    expect(native.calls, 1);
  });

  test('native failure reaches the independent fallback exactly once',
      () async {
    final fallback = _FallbackProvider();
    final native = NativeWebSearchProvider(
      adapter: _InvalidNativeAdapter(),
      binding: NativeWebSearchBinding(
        provider: ApiProvider.qwen,
        model: 'qwen-plus',
        resolveCredential: () async => 'dashscope-key',
      ),
    );
    final chain = SearchProviderChain(
      routes: [
        SearchProviderRoute(provider: native, isPrimary: true),
        SearchProviderRoute(
          provider: fallback,
          credential: 'brave-key',
          isFallback: true,
        ),
      ],
      retryPolicy: SearchRetryPolicy(maxRetries: 0, sleep: (_) async {}),
    );

    final response = await chain.execute(
      request: SearchRequest(query: 'Flutter release'),
      cancelToken: null,
      onStatus: null,
    );

    expect(fallback.calls, 1);
    expect(response.degraded, isTrue);
    expect(response.results, hasLength(1));
  });

  test('native route remains eligible for time-sensitive requests', () async {
    final native = _SuccessfulNativeAdapter();
    final fallback = _DuckFallbackProvider();
    final chain = SearchProviderChain(
      routes: [
        SearchProviderRoute(
          provider: NativeWebSearchProvider(
            adapter: native,
            binding: NativeWebSearchBinding(
              provider: ApiProvider.qwen,
              model: 'qwen-plus',
              resolveCredential: () async => 'dashscope-key',
            ),
          ),
          isPrimary: true,
          isNative: true,
        ),
        SearchProviderRoute(provider: fallback, isFallback: true),
      ],
      retryPolicy: SearchRetryPolicy(maxRetries: 0, sleep: (_) async {}),
    );

    final response = await chain.execute(
      request: SearchRequest(
        query: 'latest Flutter release',
        category: SearchCategory.software,
        freshness: SearchFreshness.week,
      ),
      cancelToken: null,
      onStatus: null,
    );

    expect(native.calls, 1);
    expect(fallback.calls, 0);
    expect(response.results, hasLength(1));
  });
}
