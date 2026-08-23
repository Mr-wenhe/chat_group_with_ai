import 'package:dio/dio.dart';

import '../data/search_credential_resolver.dart';
import '../data/search_settings_store.dart';
import '../models/search_failure.dart';
import '../models/search_models.dart';
import '../models/search_provider_config.dart';
import '../providers/brave_search_provider.dart';
import '../providers/duckduckgo_instant_answer_provider.dart';
import '../providers/search_provider.dart';
import '../providers/tavily_search_provider.dart';
import 'search_provider_route.dart';

/// Builds the runtime Provider chain from the settings metadata.
///
/// The route deliberately keeps its credential null. The wrapper resolves the
/// key immediately before every request, preserving the secure-storage rule
/// and allowing a user to rotate a key without recreating the chat page.
class SearchRuntimeProviderFactory {
  final SearchProviderConfigStore store;
  final SearchCredentialResolver credentialResolver;

  SearchRuntimeProviderFactory({
    required this.store,
    SearchCredentialResolver? credentialResolver,
  }) : credentialResolver = credentialResolver ??
            SearchCredentialResolver(
              credentials: store.credentials,
              isRelease: store.isRelease,
            );

  List<SearchProviderRoute> buildRoutes() {
    final routes = <SearchProviderRoute>[];
    for (final config in store.configs.where((item) => item.enabled)) {
      final provider = _createProvider(config);
      routes.add(
        SearchProviderRoute.fromConfig(
          config: config,
          provider: _CredentialResolvingProvider(
            config: config,
            resolver: credentialResolver,
            delegate: provider,
          ),
          priority: routes.length,
        ),
      );
    }
    // Keep the keyless encyclopedia fallback available after any configured
    // route. When there are no configured routes, the coordinator deliberately
    // keeps its legacy service path so the existing degraded metadata remains
    // unchanged; once a user configures a Provider, this route prevents a
    // transient outage from becoming an avoidable hard failure for stable
    // general-knowledge queries.
    if (routes.isNotEmpty &&
        !routes.any(
          (route) =>
              route.kind == SearchProviderKind.duckDuckGoInstantAnswer,
        )) {
      routes.add(
        SearchProviderRoute(
          id: 'builtin-duckduckgo-fallback',
          provider: DuckDuckGoInstantAnswerProvider(),
          isFallback: true,
          priority: routes.length,
          displayName: 'DuckDuckGo Instant Answer',
        ),
      );
    }
    return List.unmodifiable(routes);
  }

  SearchProvider _createProvider(SearchProviderConfig config) {
    try {
      return switch (config.provider) {
        SearchProviderKind.tavily => TavilySearchProvider(
            baseUrl: config.baseUrl,
            isRelease: store.isRelease,
            allowLocalDevelopmentGateway: store.allowLocalDevelopmentGateway,
          ),
        SearchProviderKind.brave => BraveSearchProvider(
            baseUrl: config.baseUrl,
            isRelease: store.isRelease,
            allowLocalDevelopmentGateway: store.allowLocalDevelopmentGateway,
          ),
        SearchProviderKind.duckDuckGoInstantAnswer =>
          DuckDuckGoInstantAnswerProvider(),
        SearchProviderKind.gateway => const _UnsupportedSearchProvider(
            SearchProviderKind.gateway,
            'Backend Gateway 尚未接入运行时搜索适配器',
          ),
      };
    } on Object catch (error) {
      return _UnsupportedSearchProvider(
        config.provider,
        '搜索 Provider 配置无效：$error',
      );
    }
  }
}

class _CredentialResolvingProvider implements SearchProvider {
  final SearchProviderConfig config;
  final SearchCredentialResolver resolver;
  final SearchProvider delegate;

  const _CredentialResolvingProvider({
    required this.config,
    required this.resolver,
    required this.delegate,
  });

  @override
  SearchProviderKind get kind => delegate.kind;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    final resolved = await resolver.resolve(config);
    return delegate.search(
      request,
      credential: resolved,
      cancelToken: cancelToken,
    );
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    final resolved = await resolver.resolve(config);
    return delegate.testConnection(
      credential: resolved,
      probeQuery: probeQuery,
    );
  }
}

class _UnsupportedSearchProvider implements SearchProvider {
  final SearchProviderKind _kind;
  final String _message;

  const _UnsupportedSearchProvider(this._kind, this._message);

  @override
  SearchProviderKind get kind => _kind;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    return SearchProviderResponse(
      items: const [],
      failure: SearchFailure(
        type: SearchFailureType.invalidConfiguration,
        safeMessage: _message,
        retryable: false,
      ),
    );
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    return SearchHealthResult(
      isHealthy: false,
      failure: SearchFailure(
        type: SearchFailureType.invalidConfiguration,
        safeMessage: _message,
        retryable: false,
      ),
    );
  }
}
