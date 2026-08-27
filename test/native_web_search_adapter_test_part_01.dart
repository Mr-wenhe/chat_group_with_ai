part of 'native_web_search_adapter_test.dart';

void _registerNativeWebSearchAdapterTestPart1() {
  test('native capability registry is explicit and custom is conservative', () {
    final registry = NativeWebSearchAdapterRegistry();
    final capabilities = ModelCapabilityRegistry();

    expect(
      capabilities
          .resolve(provider: ApiProvider.qwen, modelId: 'qwen-plus')
          .supportsNativeWebSearch,
      isTrue,
    );
    expect(
      registry.resolve(provider: ApiProvider.qwen, model: 'qwen-plus'),
      isA<QwenDashScopeWebSearchAdapter>(),
    );
    expect(
      capabilities
          .resolve(provider: ApiProvider.qwen, modelId: 'qwen-unknown')
          .supportsNativeWebSearch,
      isFalse,
    );
    expect(
      registry.resolve(provider: ApiProvider.qwen, model: 'qwen-unknown'),
      isNull,
    );
    expect(
      capabilities
          .resolve(provider: ApiProvider.custom, modelId: 'any-openai-model')
          .supportsNativeWebSearch,
      isFalse,
    );
    expect(
      registry.resolve(provider: ApiProvider.custom, model: 'any-openai-model'),
      isNull,
    );
  });

  test('Qwen native adapter requests documented source output only', () async {
    late RequestOptions captured;
    final adapter = QwenDashScopeWebSearchAdapter(
      model: 'qwen-plus',
      dio: _dio((options) {
        captured = options;
        return {
          'request_id': 'dashscope-001',
          'output': {
            // This model prose is intentionally ignored by the adapter.
            'choices': [
              {
                'message': {'content': 'This is not source evidence.'}
              },
            ],
            'search_info': {
              'search_results': [
                {
                  'title': 'Flutter release notes',
                  'url': 'https://docs.flutter.dev/release/notes',
                },
              ],
            },
          },
        };
      }),
    );

    final response = await adapter.search(
      SearchRequest(
        query: 'Flutter latest release',
        freshness: SearchFreshness.week,
      ),
      credential: 'dashscope-key',
    );

    expect(captured.uri, QwenDashScopeWebSearchAdapter.endpoint);
    expect(captured.data['parameters']['enable_search'], isTrue);
    expect(
        captured.data['parameters']['search_options']['enable_source'], isTrue);
    expect(
        captured.data['parameters']['search_options']['forced_search'], isTrue);
    expect(captured.data['parameters']['search_options']['freshness'], 7);
    expect(response.failure, isNull);
    expect(response.sourceProvider, 'qwen-native');
    expect(response.items.single.title, 'Flutter release notes');
    expect(response.items.single.snippet, isEmpty);
  });

  test('missing verifiable Qwen sources triggers independent fallback',
      () async {
    final adapter = QwenDashScopeWebSearchAdapter(
      model: 'qwen-plus',
      dio: _dio((_) => {
            'request_id': 'dashscope-empty',
            'output': {
              'choices': [
                {
                  'message': {'content': 'Generated answer without sources'}
                },
              ],
              'search_info': {'search_results': []},
            },
          }),
    );
    final fallback = _FallbackProvider();

    final response = await adapter.searchOrFallback(
      SearchRequest(query: 'Flutter release'),
      credential: 'dashscope-key',
      fallback: fallback,
      fallbackCredential: 'brave-key',
    );

    expect(fallback.calls, 1);
    expect(response.items.single.url, Uri.parse('https://example.com/source'));
  });

  test('sensitive native request never starts an independent fallback',
      () async {
    final adapter = QwenDashScopeWebSearchAdapter(
      model: 'qwen-plus',
      dio: _dio((_) => {
            'request_id': 'dashscope-empty-sensitive',
            'output': {
              'search_info': {'search_results': []},
            },
          }),
    );
    final fallback = _FallbackProvider();

    final response = await adapter.searchOrFallback(
      SearchRequest(query: 'redacted account details', isSensitive: true),
      credential: 'dashscope-key',
      fallback: fallback,
      fallbackCredential: 'brave-key',
    );

    expect(fallback.calls, 0);
    expect(response.items, isEmpty);
  });

  test('Qwen day freshness uses the smallest documented seven-day window',
      () async {
    late RequestOptions captured;
    final adapter = QwenDashScopeWebSearchAdapter(
      model: 'qwen-plus',
      dio: _dio((options) {
        captured = options;
        return {
          'request_id': 'dashscope-day',
          'output': {
            'search_info': {'search_results': []},
          },
        };
      }),
    );

    await adapter.search(
      SearchRequest(query: 'today news', freshness: SearchFreshness.day),
      credential: 'dashscope-key',
    );

    expect(captured.data['parameters']['search_options']['freshness'], 7);
  });

  test('Qwen source parsing stops at the configured result limit', () async {
    final adapter = QwenDashScopeWebSearchAdapter(
      model: 'qwen-plus',
      dio: _dio((_) => {
            'output': {
              'search_info': {
                'search_results': List.generate(
                  searchMaxResultsLimit + 5,
                  (index) => {
                    'title': 'Source $index',
                    'url': 'https://example.com/$index',
                  },
                ),
              },
            },
          }),
    );

    final response = await adapter.search(
      SearchRequest(query: 'bounded native sources'),
      credential: 'dashscope-key',
    );

    expect(response.items, hasLength(searchMaxResultsLimit));
  });

  test('Qwen source parsing bounds malformed source candidates', () async {
    final adapter = QwenDashScopeWebSearchAdapter(
      model: 'qwen-plus',
      dio: _dio((_) => {
            'output': {
              'search_info': {
                'search_results': [
                  ...List.filled(searchProviderMaxResultCandidates, {}),
                  {
                    'title': 'Should not be scanned',
                    'url': 'https://example.com/after-limit',
                  },
                ],
              },
            },
          }),
    );

    final response = await adapter.search(
      SearchRequest(query: 'malformed sources'),
      credential: 'dashscope-key',
    );

    expect(response.failure?.type, SearchFailureType.noResults);
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

  test('cancelling native search never starts the independent fallback',
      () async {
    final fallback = _FallbackProvider();

    final response = await _CancelledNativeAdapter().searchOrFallback(
      SearchRequest(query: 'Flutter release'),
      credential: 'dashscope-key',
      fallback: fallback,
      fallbackCredential: 'brave-key',
    );

    expect(response.failure?.type, SearchFailureType.cancelled);
    expect(fallback.calls, 0);
  });

  test('unsupported native protocol failure remains visible', () async {
    final fallback = _FallbackProvider();

    final response = await _InvalidNativeAdapter().searchOrFallback(
      SearchRequest(query: 'Flutter release'),
      credential: 'dashscope-key',
      fallback: fallback,
      fallbackCredential: 'brave-key',
    );

    expect(response.failure?.type, SearchFailureType.invalidConfiguration);
    expect(fallback.calls, 0);
  });

  test('native route leaves independent fallback ownership to the chain',
      () async {
    final fallback = _FallbackProvider();
    final provider = NativeWebSearchProvider(
      adapter: _InvalidNativeAdapter(),
      binding: NativeWebSearchBinding(
        provider: ApiProvider.qwen,
        model: 'qwen-plus',
        resolveCredential: () async => 'dashscope-key',
      ),
      fallback: fallback,
    );

    final response = await provider.search(
      SearchRequest(query: 'Flutter release'),
      credential: 'brave-key',
    );

    expect(response.failure?.type, SearchFailureType.invalidConfiguration);
    expect(fallback.calls, 0);
  });

  test('native route health probe exercises native search, not fallback',
      () async {
    final fallback = _FallbackProvider();
    final native = _SuccessfulNativeAdapter();
    final provider = NativeWebSearchProvider(
      adapter: native,
      binding: NativeWebSearchBinding(
        provider: ApiProvider.qwen,
        model: 'qwen-plus',
        resolveCredential: () async => 'dashscope-key',
      ),
      fallback: fallback,
    );

    final health = await provider.testConnection(
      credential: 'brave-key',
      probeQuery: 'Flutter official documentation',
    );

    expect(health.isHealthy, isTrue);
    expect(native.calls, 1);
    expect(fallback.calls, 0);
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
      fallback: fallback,
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
            fallback: fallback,
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

  test('adapter support is bound to its configured model', () {
    final adapter = QwenDashScopeWebSearchAdapter(model: 'qwen-plus');

    expect(
      adapter.supports(provider: ApiProvider.qwen, model: 'qwen-turbo'),
      isFalse,
    );
  });
}
