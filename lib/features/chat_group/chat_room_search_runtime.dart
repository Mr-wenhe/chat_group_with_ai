import 'dart:convert';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/search_coordinator.dart';
import 'package:chat_group/features/web_search/application/search_runtime_provider_factory.dart';
import 'package:chat_group/features/web_search/application/search_turn_context.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/models/search_failure_factory.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/models/search_runtime_settings.dart';
import 'package:chat_group/features/web_search/providers/native_web_search_adapter.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/features/work_mode/visible_browser_service.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

typedef ChatRoomApiConfigResolver = ApiConfig? Function(AICharacter character);

/// Owns provider routing and turn-cache lifecycle for one chat room.
///
/// The page can be rebuilt or resumed without recreating this state unless the
/// persisted provider/runtime fingerprint changes. Keeping this boundary out
/// of the widget also prevents an in-flight turn from observing a half-rebuilt
/// search runtime.
class ChatRoomSearchRuntimeController {
  final String conversationId;
  final AiGovernanceStore governanceStore;
  final AiRequestGateway aiGateway;
  final ApiCredentialResolver credentialResolver;
  final Iterable<AICharacter> Function() allCharacters;
  final ChatRoomApiConfigResolver resolveApiConfig;
  final VisibleBrowserService? visibleBrowserService;

  late SearchCoordinator coordinator;
  late SearchTurnContextController turnController;
  late SearchRuntimeSettings runtimeSettings;

  String _runtimeFingerprint = '';
  bool _disposed = false;

  ChatRoomSearchRuntimeController({
    required this.conversationId,
    required this.governanceStore,
    required this.aiGateway,
    required this.credentialResolver,
    required this.allCharacters,
    required this.resolveApiConfig,
    this.visibleBrowserService,
  });

  String get runtimeFingerprint => _runtimeFingerprint;

  void initialize() {
    _rebuild(SearchProviderConfigStore(db: governanceStore.db));
  }

  /// Rebuilds after room members are loaded so optional planner/native routes
  /// can resolve exactly one eligible API configuration.
  void refreshAfterMembersLoaded() {
    if (_disposed) return;
    _rebuild(SearchProviderConfigStore(db: governanceStore.db));
  }

  /// Refreshes only when persisted search settings changed and the page is
  /// idle. A busy turn keeps its original coordinator and snapshot intact.
  void reloadIfChanged({required bool isBusy}) {
    if (_disposed || isBusy) return;
    final settings = SearchProviderConfigStore(db: governanceStore.db);
    final fingerprint = _searchRuntimeSignature(settings);
    if (fingerprint == _runtimeFingerprint) return;
    _rebuild(settings, fingerprint: fingerprint);
  }

  void dispose() {
    _disposed = true;
    turnController.clear();
  }

  void _rebuild(
    SearchProviderConfigStore settings, {
    String? fingerprint,
  }) {
    runtimeSettings = settings.runtimeSettings;
    coordinator = _createSearchCoordinator(settings);
    turnController = SearchTurnContextController(coordinator: coordinator);
    _runtimeFingerprint = fingerprint ?? _searchRuntimeSignature(settings);
  }

  SearchCoordinator _createSearchCoordinator(
    SearchProviderConfigStore settings,
  ) {
    return SearchCoordinator(
      store: governanceStore,
      routes: SearchRuntimeProviderFactory(store: settings).buildRoutes(
        nativeSearch: _nativeSearchBinding(),
        visibleBrowserSearch:
            visibleBrowserService == null ? null : _searchWithVisibleBrowser,
      ),
      queryPlanner: _searchQueryPlanner(),
    );
  }

  NativeWebSearchBinding? _nativeSearchBinding() {
    if (!runtimeSettings.nativeSearchEnabled) return null;
    final candidates = <String, ApiConfig>{};
    for (final character in allCharacters()) {
      final config = resolveApiConfig(character);
      if (config == null ||
          config.provider != ApiProvider.qwen.name ||
          (!config.hasCredential && !config.hasApiKey)) {
        continue;
      }
      candidates[config.id] = config;
    }
    if (candidates.length != 1) return null;
    final config = candidates.values.single;
    return NativeWebSearchBinding(
      provider: ApiProvider.qwen,
      model: config.modelName,
      resolveCredential: () => credentialResolver.resolve(config),
    );
  }

  SearchQueryPlanner? _searchQueryPlanner() {
    if (!runtimeSettings.queryPlanningEnabled) return null;
    final candidates = <String, ApiConfig>{};
    for (final character in allCharacters()) {
      final config = resolveApiConfig(character);
      if (config != null) candidates[config.id] = config;
    }
    if (candidates.length != 1) return null;
    final config = candidates.values.single;
    final provider = ApiProvider.values.firstWhere(
      (value) => value.name == config.provider,
      orElse: () => ApiProvider.custom,
    );
    return SearchQueryPlanner(
      gateway: aiGateway,
      config: SearchPlannerConfig(
        provider: provider,
        model: config.modelName,
        customBaseUrl: config.customBaseUrl,
        conversationId: conversationId,
        resolveApiKey: () => credentialResolver.resolve(config),
      ),
    );
  }

  String _searchRuntimeSignature(SearchProviderConfigStore settings) {
    final configs = settings.configs
        .map(
          (config) => {
            'id': config.id,
            'name': config.name,
            'provider': config.provider.name,
            'baseUrl': config.baseUrl,
            'enabled': config.enabled,
            'isDefault': config.isDefault,
            'credentialId': config.credentialId,
            'hasCredential': config.hasCredential,
            'credentialRequired': config.credentialRequired,
            // This is a non-secret metadata revision. It changes on every
            // formal key rotation, including the macOS Debug Hive fallback.
            'credentialRevision': config.credentialRevision,
            'requiresAttention': config.requiresAttention,
          },
        )
        .toList(growable: false);
    configs.sort((left, right) =>
        (left['id'] as String).compareTo(right['id'] as String));

    final characterBindings = allCharacters()
        .map(
          (character) => {
            'characterId': character.id,
            'apiConfigId': character.apiConfigId,
            'legacyProvider': character.apiProvider,
            'legacyModel': character.modelName,
            'legacyCustomBaseUrl': character.customBaseUrl,
            'isActive': character.isActive,
            'apiConfig': _apiConfigSignature(resolveApiConfig(character)),
          },
        )
        .toList(growable: false);
    characterBindings.sort((left, right) => (left['characterId'] as String)
        .compareTo(right['characterId'] as String));

    return jsonEncode({
      'configs': configs,
      'characters': characterBindings,
      'runtime': settings.runtimeSettings.toMap(),
    });
  }

  /// Converts the visible-browser handoff into the same normalized search
  /// response used by the bounded providers. The browser remains open and
  /// waits for the user when a login/CAPTCHA/paywall is detected; clicking
  /// Continue resolves this Future and resumes the original search turn.
  Future<SearchProviderResponse> _searchWithVisibleBrowser(
    SearchRequest request, {
    CancelToken? cancelToken,
  }) async {
    final service = visibleBrowserService;
    if (service == null) {
      return SearchProviderResponse(
        items: const [],
        sourceProvider: 'visibleBrowser',
        failure: buildSearchFailure(
          type: SearchFailureType.invalidConfiguration,
        ),
      );
    }
    final taskId = _browserTaskId(request);
    final url = Uri.https(
      'html.duckduckgo.com',
      '/html/',
      <String, String>{'q': request.query},
    ).toString();
    try {
      final opened = await service.open(taskId: taskId, url: url);
      final session = await service.waitForReadablePage(
        opened.id,
        cancelToken: cancelToken,
      );
      if (session == null) {
        return SearchProviderResponse(
          items: const [],
          sourceProvider: 'visibleBrowser',
          failure: buildSearchFailure(type: SearchFailureType.cancelled),
        );
      }
      if (session.status == VisibleBrowserStatus.failed) {
        return SearchProviderResponse(
          items: const [],
          sourceProvider: 'visibleBrowser',
          failure: buildSearchFailure(
            type: SearchFailureType.providerUnavailable,
          ),
        );
      }
      final pageUri = tryValidateSearchUrl(
        Uri.tryParse(session.url),
        allowInsecureHttp: true,
      );
      if (pageUri == null || session.pageText.trim().isEmpty) {
        return SearchProviderResponse(
          items: const [],
          sourceProvider: 'visibleBrowser',
          failure: buildSearchFailure(type: SearchFailureType.noResults),
        );
      }
      final title = sanitizeSearchText(
        session.title,
        maxLength: searchTitleMaxLength,
        fallback: '公开网页结果',
        redactSecrets: true,
        redactOpaqueTokens: true,
      );
      final snippet = sanitizeSearchText(
        session.pageText,
        maxLength: searchSnippetMaxLength,
        redactSecrets: true,
        redactOpaqueTokens: true,
      );
      if (snippet.isEmpty) {
        return SearchProviderResponse(
          items: const [],
          sourceProvider: 'visibleBrowser',
          failure: buildSearchFailure(type: SearchFailureType.noResults),
        );
      }
      return SearchProviderResponse(
        items: <SearchProviderItem>[
          SearchProviderItem(
            title: title,
            snippet: snippet,
            url: pageUri,
            allowInsecureHttp: true,
          ),
        ],
        sourceProvider: 'visibleBrowser',
        moreResultsAvailable: true,
        degraded: true,
      );
    } on DioException catch (error) {
      if (cancelToken?.isCancelled == true ||
          error.type == DioExceptionType.cancel) {
        return SearchProviderResponse(
          items: const [],
          sourceProvider: 'visibleBrowser',
          failure: buildSearchFailure(type: SearchFailureType.cancelled),
        );
      }
      return SearchProviderResponse(
        items: const [],
        sourceProvider: 'visibleBrowser',
        failure:
            buildSearchFailure(type: SearchFailureType.providerUnavailable),
      );
    } on Object {
      return SearchProviderResponse(
        items: const [],
        sourceProvider: 'visibleBrowser',
        failure:
            buildSearchFailure(type: SearchFailureType.providerUnavailable),
      );
    }
  }

  String _browserTaskId(SearchRequest request) {
    for (final value in <String>[
      request.requestId,
      request.sourceMessageId,
      request.turnId,
      request.rootRequestId,
      'browser-search',
    ]) {
      final raw = value.trim();
      if (raw.isEmpty) continue;
      var normalized = raw.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]'),
        '_',
      );
      normalized = normalized.replaceFirst(RegExp(r'^_+'), '');
      if (normalized.isEmpty) continue;
      if (!RegExp(r'^[A-Za-z0-9]').hasMatch(normalized)) {
        normalized = 'browser_$normalized';
      }
      if (normalized.length <= 128 && normalized == raw) return normalized;
      // Replacing punctuation alone makes `a:b` and `a/b` share one browser
      // task and can merge their audit events. Keep a short readable prefix,
      // then add a non-reversible digest whenever normalization changed it.
      final digest = sha256.convert(utf8.encode(raw)).toString();
      final suffix = '-${digest.substring(0, 16)}';
      final prefixLength = (128 - suffix.length).clamp(1, 128).toInt();
      normalized = normalized.substring(0, prefixLength);
      return '$normalized$suffix';
    }
    return 'browser-search';
  }

  Map<String, Object?>? _apiConfigSignature(ApiConfig? config) {
    if (config == null) return null;
    return {
      'id': config.id,
      'provider': config.provider,
      'model': config.modelName,
      'customBaseUrl': config.customBaseUrl,
      'credentialId': config.credentialId,
      'hasCredential': config.hasCredential,
    };
  }
}
