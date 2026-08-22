import 'package:chat_group/core/storage/credential_repository.dart';
import '../data/search_credential_repository.dart';
import '../data/search_settings_store.dart';
import '../models/search_provider_config.dart';
import '../models/search_models.dart';
import '../providers/search_provider.dart';
import '../security/search_endpoint_validator.dart';

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
    String probeQuery = 'test',
  }) async {
    final endpoint = SearchEndpointValidator.validate(
      config.baseUrl,
      isRelease: store.isRelease,
      allowLocalDevelopmentGateway: store.allowLocalDevelopmentGateway,
    );
    if (!endpoint.isValid) {
      return SearchConnectionTestResult.failure(
        errorMessage: endpoint.message,
      );
    }

    final entered = enteredCredential.trim();
    String? credential;
    if (entered.isNotEmpty) {
      credential = entered;
    } else if (config.provider == SearchProviderKind.tavily ||
        config.provider == SearchProviderKind.brave) {
      final resolved = await credentialResolver.resolveResult(config);
      if (!resolved.isAvailable) {
        return SearchConnectionTestResult.failure(
          credentialFailure: resolved.failure ?? CredentialFailure.unavailable,
          errorMessage: '搜索凭据不可用',
        );
      }
      credential = resolved.value;
    }

    try {
      final validatedConfig = config.copyWith(
        baseUrl: endpoint.uri!.toString(),
      );
      final health = await providerFactory(validatedConfig).testConnection(
        credential: credential,
        probeQuery: probeQuery,
      );
      return health.isHealthy
          ? SearchConnectionTestResult.success(health)
          : SearchConnectionTestResult.failure(
              health: health,
              errorMessage: '搜索 Provider 连接测试失败',
            );
    } on UnsupportedError catch (error) {
      return SearchConnectionTestResult.failure(
        errorMessage: error.message,
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
}
