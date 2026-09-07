import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/search_credential_resolver.dart';
import '../data/search_settings_store.dart';
import '../models/search_failure.dart';
import '../models/search_failure_factory.dart';
import '../models/search_models.dart';
import '../models/search_provider_config.dart';
import '../providers/brave_search_provider.dart';
import '../providers/duckduckgo_instant_answer_provider.dart';
import '../providers/gateway_search_provider.dart';
import '../providers/keyless_html_search_provider.dart';
import '../providers/native_web_search_adapter.dart';
import '../providers/search_provider.dart';
import '../providers/tavily_search_provider.dart';
import '../providers/visible_browser_search_provider.dart';
import 'search_provider_route.dart';
import '../security/search_endpoint_validator.dart';

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

  List<SearchProviderRoute> buildRoutes({
    NativeWebSearchBinding? nativeSearch,
    VisibleBrowserSearchHandler? visibleBrowserSearch,
  }) {
    // No Web build is a supported search target. Browser XHR may buffer an
    // entire response before app-level limits run, and it cannot provide the
    // native DNS pinning/credential boundary used by this feature.
    if (kIsWeb) return const [];
    final routes = <SearchProviderRoute>[];
    for (final config in store.configs.where(_isRuntimeEligible)) {
      final provider = _createProvider(config);
      routes.add(
        SearchProviderRoute.fromConfig(
          config: config,
          provider: CredentialResolvingSearchProvider(
            config: config,
            resolver: credentialResolver,
            delegate: provider,
            store: store,
          ),
          priority: routes.length,
        ),
      );
    }
    // Keep the keyless providers available after configured routes. The chain
    // itself limits Instant Answer to stable general-knowledge requests, so it
    // can never masquerade as a source for current news, prices, weather, or
    // policy; HTML remains the broader public-page fallback.
    if (!routes.any(
      (route) => route.kind == SearchProviderKind.duckDuckGoInstantAnswer,
    )) {
      routes.add(
        SearchProviderRoute(
          id: 'builtin-duckduckgo-fallback',
          provider: DuckDuckGoInstantAnswerProvider(isRelease: store.isRelease),
          isFallback: true,
          priority: routes.length,
          displayName: 'DuckDuckGo Instant Answer',
        ),
      );
    }
    if (!routes.any((route) => route.kind == SearchProviderKind.keylessHtml)) {
      routes.add(
        SearchProviderRoute(
          id: 'builtin-keyless-html',
          provider: KeylessHtmlSearchProvider(isRelease: store.isRelease),
          isFallback: true,
          priority: routes.length,
          displayName: 'DuckDuckGo HTML（无 Key）',
        ),
      );
    }
    if (visibleBrowserSearch != null &&
        !routes.any((route) => route.isVisibleBrowser)) {
      routes.add(
        SearchProviderRoute(
          id: 'builtin-visible-browser',
          provider: VisibleBrowserSearchProvider(visibleBrowserSearch),
          isFallback: true,
          isVisibleBrowser: true,
          priority: routes.length,
          displayName: '可见浏览器接管',
        ),
      );
    }
    // Add the native route after the independent fallback exists. This keeps
    // native Qwen search usable even when no separate Brave/Tavily/Gateway
    // route has been configured for the compatible fallback.
    _prependNativeRoute(routes, nativeSearch);
    return List.unmodifiable(routes);
  }

  /// Web has no supported search runtime because it cannot provide the native
  /// DNS pinning and secure credential storage used by this app.
  static bool isProviderAllowedForPlatform(
    SearchProviderKind provider, {
    required bool isWeb,
    required bool isRelease,
  }) =>
      !isWeb;

  bool _isRuntimeEligible(SearchProviderConfig config) {
    if (!config.enabled || config.requiresAttention) return false;
    if (!isProviderAllowedForPlatform(
      config.provider,
      isWeb: kIsWeb,
      isRelease: store.isRelease,
    )) {
      return false;
    }
    // Restored and hand-edited metadata cannot create a route without the
    // credential required by the provider. The same rule is applied while
    // loading and saving settings, so routing cannot bypass that boundary.
    if (searchProviderRequiresCredential(
          config.provider,
          isRelease: store.isRelease,
        ) &&
        (!config.hasCredential || config.credentialId.isEmpty)) {
      return false;
    }
    // Preserve the stronger requirement recorded by restored metadata too.
    // This covers older or hand-edited Gateway records whose provider policy
    // was stricter than the current platform default.
    if (config.credentialRequired &&
        (!config.hasCredential || config.credentialId.isEmpty)) {
      return false;
    }
    return true;
  }

  void _prependNativeRoute(
    List<SearchProviderRoute> routes,
    NativeWebSearchBinding? binding,
  ) {
    if (kIsWeb) return;
    if (binding == null || routes.isEmpty) return;
    final adapter = NativeWebSearchAdapterRegistry(
      isRelease: store.isRelease,
    ).resolve(
      provider: binding.provider,
      model: binding.model,
    );
    if (adapter == null) return;
    final fallback = routes.first;
    routes.insert(
      0,
      SearchProviderRoute(
        id: 'native:${binding.provider.name}:${binding.model}',
        provider: NativeWebSearchProvider(
          adapter: adapter,
          binding: binding,
          fallback: fallback.provider,
        ),
        isPrimary: true,
        isNative: true,
        priority: -1,
        displayName: adapter.providerId,
      ),
    );
  }

  SearchProvider _createProvider(SearchProviderConfig config) {
    try {
      // DuckDuckGo has no configurable endpoint. Do not turn an old blank or
      // hand-edited metadata field into a runtime outage for its built-in
      // adapter.
      if (!searchProviderUsesFixedEndpoint(config.provider)) {
        // Validate every persisted endpoint, including Gateway metadata that
        // is not yet backed by a local adapter. This keeps a legacy or
        // hand-edited configuration from bypassing the client-side boundary.
        SearchEndpointValidator.requireValid(
          config.baseUrl,
          isRelease: store.isRelease,
          allowLocalDevelopmentGateway:
              config.provider == SearchProviderKind.gateway &&
                  store.allowLocalDevelopmentGateway,
        );
      }
      return switch (config.provider) {
        SearchProviderKind.tavily => TavilySearchProvider(
            baseUrl: config.baseUrl,
            isRelease: store.isRelease,
            allowLocalDevelopmentGateway: false,
          ),
        SearchProviderKind.brave => BraveSearchProvider(
            baseUrl: config.baseUrl,
            isRelease: store.isRelease,
            allowLocalDevelopmentGateway: false,
          ),
        SearchProviderKind.duckDuckGoInstantAnswer =>
          DuckDuckGoInstantAnswerProvider(isRelease: store.isRelease),
        SearchProviderKind.keylessHtml =>
          KeylessHtmlSearchProvider(isRelease: store.isRelease),
        SearchProviderKind.gateway => GatewaySearchProvider(
            baseUrl: config.baseUrl,
            isRelease: store.isRelease,
            allowLocalDevelopmentGateway: store.allowLocalDevelopmentGateway,
          ),
      };
    } on Object {
      return _UnsupportedSearchProvider(
        config.provider,
        '搜索 Provider 配置无效',
      );
    }
  }
}

class CredentialResolvingSearchProvider implements SearchProvider {
  final SearchProviderConfig config;
  final SearchCredentialResolver resolver;
  final SearchProvider delegate;
  final SearchProviderConfigStore store;

  const CredentialResolvingSearchProvider({
    required this.config,
    required this.resolver,
    required this.delegate,
    required this.store,
  });

  @override
  SearchProviderKind get kind => delegate.kind;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    final current = store.findById(config.id);
    if (current == null || !current.enabled || current.requiresAttention) {
      return _invalidConfigurationResponse();
    }
    final resolvedResult = await resolver.resolveResult(current);
    if (!resolvedResult.isAvailable && current.credentialRequired) {
      await store.setRequiresAttention(config.id, true);
      return _invalidConfigurationResponse();
    }
    final resolved = resolvedResult.isAvailable ? resolvedResult.value : null;
    final response = await delegate.search(
      request,
      credential: resolved,
      cancelToken: cancelToken,
    );
    final failureType = response.failure?.type;
    if (failureType == SearchFailureType.unauthorized ||
        failureType == SearchFailureType.forbidden) {
      await store.setRequiresAttention(config.id, true);
    }
    return response;
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async {
    final current = store.findById(config.id);
    if (current == null || !current.enabled || current.requiresAttention) {
      return SearchHealthResult(
        isHealthy: false,
        failure: _invalidConfigurationFailure(),
      );
    }
    final entered = credential?.trim() ?? '';
    final String? resolved;
    if (entered.isNotEmpty) {
      // A form probe may supply a new key that has not been saved yet. It must
      // take precedence over secure-storage lookup for this single request.
      resolved = entered;
    } else {
      final resolvedResult = await resolver.resolveResult(current);
      if (!resolvedResult.isAvailable && current.credentialRequired) {
        // Health checks are probes, not save operations. Keep the durable
        // routing metadata unchanged; a failed probe is returned to the
        // caller and only an explicit save may update requiresAttention.
        return const SearchHealthResult(
          isHealthy: false,
          failure: SearchFailure(
            type: SearchFailureType.invalidConfiguration,
            safeMessage: '搜索凭据不可用',
            retryable: false,
          ),
        );
      }
      resolved = resolvedResult.isAvailable ? resolvedResult.value : null;
    }
    return delegate.testConnection(
      credential: resolved,
      probeQuery: probeQuery,
    );
  }

  SearchProviderResponse _invalidConfigurationResponse() =>
      SearchProviderResponse(
        items: const [],
        terminal: true,
        failure: _invalidConfigurationFailure(),
      );

  SearchFailure _invalidConfigurationFailure() => buildSearchFailure(
        type: SearchFailureType.invalidConfiguration,
      );
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
