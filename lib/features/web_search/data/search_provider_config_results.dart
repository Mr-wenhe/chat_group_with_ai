import 'package:chat_group/core/storage/credential_repository.dart';

import '../models/search_provider_config.dart';

class SearchProviderConfigSaveResult {
  final SearchProviderConfig? config;
  final CredentialFailure? credentialFailure;
  final String? errorMessage;
  final bool usedDevelopmentFallback;

  const SearchProviderConfigSaveResult.success(
    this.config, {
    this.usedDevelopmentFallback = false,
  })  : credentialFailure = null,
        errorMessage = null;

  const SearchProviderConfigSaveResult.failure({
    this.credentialFailure,
    this.errorMessage,
  })  : config = null,
        usedDevelopmentFallback = false;

  bool get isSuccess => config != null && credentialFailure == null;
}

class SearchProviderConfigDeleteResult {
  final CredentialFailure? failure;

  const SearchProviderConfigDeleteResult.success() : failure = null;
  const SearchProviderConfigDeleteResult.failure(this.failure);

  bool get isSuccess => failure == null;
}
