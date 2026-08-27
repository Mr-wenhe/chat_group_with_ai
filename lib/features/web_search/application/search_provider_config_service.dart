import 'package:chat_group/core/storage/credential_repository.dart';
import '../data/search_credential_repository.dart';
import '../data/search_settings_store.dart';
import '../models/search_provider_config.dart';
import '../models/search_models.dart';
import '../providers/search_provider.dart';
import '../providers/search_provider_http_support.dart';
import '../security/search_endpoint_validator.dart';
import '../security/search_credential_validator.dart';
import '../security/search_secret_scanner.dart';

const String searchHealthProbeQuery = 'Flutter official documentation';

typedef SearchProviderFactory = SearchProvider Function(
  SearchProviderConfig config,
);

class SearchConnectionTestResult {
  final bool isHealthy;
  final SearchHealthResult? health;
  final CredentialFailure? credentialFailure;
  final String? errorMessage;

  const SearchConnectionTestResult.success(this.health)
      : isHealthy = true,
        credentialFailure = null,
        errorMessage = null;

  const SearchConnectionTestResult.failure({
    this.credentialFailure,
    this.errorMessage,
    this.health,
  }) : isHealthy = false;
}

/// Coordinates the form's test/save actions while keeping the connection
/// test path read-only with respect to credential persistence.
class SearchProviderConfigService {
  final SearchProviderConfigStore store;
  final SearchCredentialResolver credentialResolver;
  final SearchProviderFactory providerFactory;

  const SearchProviderConfigService({
    required this.store,
    required this.credentialResolver,
    required this.providerFactory,
  });

  Future<SearchConnectionTestResult> testConnection({
    required SearchProviderConfig config,
    required String enteredCredential,
    String probeQuery = searchHealthProbeQuery,
  }) async {
    if (store.isWebUnsupported) {
      return const SearchConnectionTestResult.failure(
        credentialFailure: CredentialFailure.unavailable,
        errorMessage: 'Web 端不支持联网搜索',
      );
    }
    final endpoint =
        config.provider == SearchProviderKind.duckDuckGoInstantAnswer
            ? null
            : SearchEndpointValidator.validate(
                config.baseUrl,
                isRelease: store.isRelease,
                allowLocalDevelopmentGateway:
                    config.provider == SearchProviderKind.gateway &&
                        store.allowLocalDevelopmentGateway,
              );
    if (endpoint != null && !endpoint.isValid) {
      return SearchConnectionTestResult.failure(errorMessage: endpoint.message);
    }

    final credentialError =
        SearchCredentialValidator.validate(enteredCredential);
    if (credentialError != null) {
      return SearchConnectionTestResult.failure(errorMessage: credentialError);
    }
    final entered = enteredCredential.trim();
    final safeProbe = const SearchSecretScanner().redact(probeQuery).trim();
    String? credential;
    if (entered.isNotEmpty) {
      credential = entered;
    } else if (config.hasCredential) {
      final resolved = await credentialResolver.resolveResult(config);
      if (!resolved.isAvailable) {
        return SearchConnectionTestResult.failure(
          credentialFailure: resolved.failure ?? CredentialFailure.unavailable,
          errorMessage: '搜索凭据不可用',
        );
      }
      credential = resolved.value;
    } else if (searchProviderRequiresCredential(
      config.provider,
      isRelease: store.isRelease,
    )) {
      return const SearchConnectionTestResult.failure(
        credentialFailure: CredentialFailure.unavailable,
        errorMessage: '搜索凭据不可用',
      );
    }

    try {
      final validatedConfig = config.copyWith(
        baseUrl: endpoint?.uri?.toString() ?? config.baseUrl,
      );
      final health = _sanitizeHealth(
        await providerFactory(validatedConfig).testConnection(
          credential: credential,
          probeQuery: safeProbe.isEmpty ? searchHealthProbeQuery : safeProbe,
        ),
      );
      // A connection test is intentionally read-only. Health metadata is
      // returned to the form caller and becomes durable only through save();
      // otherwise a probe would silently mutate runtime routing state.
      return health.isHealthy
          ? SearchConnectionTestResult.success(health)
          : SearchConnectionTestResult.failure(
              health: health,
              errorMessage: '搜索 Provider 连接测试失败',
            );
    } on UnsupportedError {
      return const SearchConnectionTestResult.failure(
        errorMessage: '搜索 Provider 连接测试不支持',
      );
    } on Object {
      return const SearchConnectionTestResult.failure(
        errorMessage: '搜索 Provider 连接测试失败',
      );
    }
  }

  Future<SearchProviderConfigSaveResult> save(
    SearchProviderConfig config, {
    required String enteredCredential,
  }) =>
      store.save(config, enteredCredential: enteredCredential);

  SearchHealthResult _sanitizeHealth(SearchHealthResult result) {
    final failure = result.failure;
    final safeFailure = failure == null
        ? null
        : buildSearchFailure(
            type: failure.type,
            statusCode: failure.statusCode,
            providerRequestId: safeProviderRequestId(failure.providerRequestId),
          );
    return SearchHealthResult(
      requestId: normalizeSearchCorrelationId(result.requestId),
      isHealthy: result.isHealthy,
      latencyMs: result.latencyMs < 0 ? 0 : result.latencyMs,
      failure: safeFailure,
      providerRequestId: safeProviderRequestId(result.providerRequestId),
    );
  }
}
