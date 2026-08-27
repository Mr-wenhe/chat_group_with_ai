part of 'search_settings_store.dart';

extension SearchProviderConfigStoreTransactionHelpers
    on SearchProviderConfigStore {
  bool _canUseDevelopmentFallback(
    SearchCredentialWriteResult result,
    SearchProviderConfig? existing,
  ) =>
      !isRelease &&
      _allowDevelopmentFallback &&
      result.failure != null &&
      result.canUseDevelopmentFallback &&
      // A failed rotation must retain the existing secure value rather than
      // silently creating an untracked copy next to a Hive fallback.
      (existing == null ||
          existing.credentialId ==
              SearchCredentialRepository.developmentHiveCredentialId);

  bool _hasSecureCredentialBinding(SearchProviderConfig config) =>
      (config.hasCredential || config.credentialId.isNotEmpty) &&
      config.credentialId !=
          SearchCredentialRepository.developmentHiveCredentialId;

  bool _hasUsableCredential(SearchProviderConfig config) =>
      config.hasCredential && config.credentialId.isNotEmpty;

  String _nextCredentialRevision(SearchProviderConfig? existing) {
    final previous = int.tryParse(existing?.credentialRevision ?? '');
    if (previous != null && previous < _maxExactJavaScriptInteger) {
      return '${previous + 1}';
    }
    return DateTime.now().toUtc().microsecondsSinceEpoch.toString();
  }

  Future<bool> _markCredentialRecovery(String configId) async {
    try {
      await _markCredentialRepair(
        configId: configId,
        credentialId: credentials.credentialIdFor(configId),
        operation: 'credential_recovery',
        phase: 'cleanup',
      );
      return true;
    } on Object {
      // The caller reports this separately. The original rotation marker is
      // intentionally retained and retry logic treats it conservatively.
      return false;
    }
  }

  String? _validateDraft(
    SearchProviderConfig draft,
    String enteredCredential,
  ) {
    final credentialError =
        SearchCredentialValidator.validate(enteredCredential);
    if (credentialError != null) return credentialError;
    if (SearchProviderConfig.canonicalizeId(draft.id) == null) {
      return 'Provider ID 无效或过长';
    }
    if (draft.name.trim().isEmpty ||
        draft.name.trim().length > SearchProviderConfig.maxNameLength) {
      return 'Provider 名称无效或过长';
    }
    if (draft.baseUrl.length > SearchProviderConfig.maxBaseUrlLength) {
      return 'Base URL 过长';
    }
    if (draft.credentialId.length >
        SearchProviderConfig.maxCredentialIdLength) {
      return '凭据绑定 ID 过长';
    }
    final legacyCredentialError = draft.developmentLegacyApiKey == null
        ? null
        : SearchCredentialValidator.validate(draft.developmentLegacyApiKey!);
    if (legacyCredentialError != null) {
      return legacyCredentialError;
    }
    if (draft.invalidCredentialBinding) {
      return '现有搜索凭据绑定需要人工修复';
    }
    return null;
  }

  Future<bool> _restorePreviousCredentialAfterFailedSave(
    String configId,
    CredentialReadResult? previous,
  ) async {
    if (previous?.isAvailable != true) return true;
    final restored = await credentials.save(configId, previous!.value!);
    if (restored.isSuccess) return true;
    // The failed save has already removed its candidate value. Attempt a
    // final cleanup so metadata cannot point at an unknown secret state.
    await credentials.delete(configId);
    return false;
  }

  Future<SearchProviderConfigDeleteResult> _finishPendingCredentialRepair(
    String configId,
    Map<String, dynamic> repair,
  ) async {
    final credentialId = repair['credentialId']?.toString() ?? '';
    if (!credentials.canDeleteBinding(credentialId)) {
      return const SearchProviderConfigDeleteResult.failure(
        CredentialFailure.systemError,
      );
    }
    final deleted = await credentials.deleteBinding(credentialId);
    if (!deleted.isSuccess) {
      return SearchProviderConfigDeleteResult.failure(deleted.failure);
    }
    try {
      await _clearCredentialRepair(configId);
    } on Object {
      return const SearchProviderConfigDeleteResult.failure(
        CredentialFailure.systemError,
      );
    }
    return const SearchProviderConfigDeleteResult.success();
  }
}
