part of 'search_settings_store.dart';

// Dart2JS represents integers with JavaScript numbers. Keep revision values
// inside the exact integer range so the fingerprint remains stable on Web.
const int _maxExactJavaScriptInteger = 9007199254740991;

extension SearchProviderConfigStoreTransactions on SearchProviderConfigStore {
  Future<SearchProviderConfigSaveResult> save(
    SearchProviderConfig draft, {
    String enteredCredential = '',
  }) =>
      _runSerialized(() => _save(draft, enteredCredential: enteredCredential));

  Future<SearchProviderConfigSaveResult> _save(
    SearchProviderConfig draft, {
    required String enteredCredential,
  }) async {
    if (isWebUnsupported) {
      return const SearchProviderConfigSaveResult.failure(
        credentialFailure: CredentialFailure.unavailable,
        errorMessage: 'Web 端不支持保存搜索 Provider 配置',
      );
    }
    final canonicalId = SearchProviderConfig.canonicalizeId(draft.id);
    if (canonicalId == null) {
      return const SearchProviderConfigSaveResult.failure(
        errorMessage: 'Provider ID 必须是不带首尾空格或控制字符的有效 ID',
      );
    }
    if (_hasAmbiguousProviderIds()) {
      return const SearchProviderConfigSaveResult.failure(
        errorMessage: '已有搜索 Provider ID 存在空格、控制字符或重复规范化结果',
      );
    }
    draft = draft.copyWith(id: canonicalId);
    final validationError = _validateDraft(draft, enteredCredential);
    if (validationError != null) {
      return SearchProviderConfigSaveResult.failure(
        errorMessage: validationError,
      );
    }
    SearchEndpointValidationResult? endpoint;
    if (draft.provider != SearchProviderKind.duckDuckGoInstantAnswer) {
      endpoint = SearchEndpointValidator.validate(
        draft.baseUrl,
        isRelease: isRelease,
        allowLocalDevelopmentGateway:
            draft.provider == SearchProviderKind.gateway &&
                allowLocalDevelopmentGateway,
      );
      if (!endpoint.isValid) {
        return SearchProviderConfigSaveResult.failure(
          errorMessage: endpoint.message,
        );
      }
    }

    final existing = findById(draft.id);
    final metadataSnapshot = _captureSettings();
    // An unknown binding means the old secret cannot be addressed safely.
    // Refuse every edit, including a replacement key, until the user repairs
    // the binding explicitly; otherwise the old secret would remain orphaned
    // in secure storage beside the newly written canonical credential.
    if (existing != null && _hasUnknownCredentialBinding(existing)) {
      return const SearchProviderConfigSaveResult.failure(
        credentialFailure: CredentialFailure.systemError,
        errorMessage: '现有搜索凭据绑定无法安全迁移',
      );
    }
    // Capture before a credential operation. Secure-store callbacks can fail
    // or invalidate the metadata backend; rollback must not need to read it
    // again after that point.
    final entered = enteredCredential.trim();
    final requiresCredential = searchProviderRequiresCredential(
      draft.provider,
      isRelease: isRelease,
    );
    final preservesCredential =
        existing != null && _hasUsableCredential(existing);
    if (requiresCredential && entered.isEmpty) {
      final sameProviderCredential = existing != null &&
          existing.provider == draft.provider &&
          _hasUsableCredential(existing);
      if (!sameProviderCredential) {
        return const SearchProviderConfigSaveResult.failure(
          credentialFailure: CredentialFailure.unavailable,
          errorMessage: '该搜索 Provider 必须配置访问令牌',
        );
      }
    }
    if (isRelease &&
        draft.provider == SearchProviderKind.gateway &&
        entered.isEmpty &&
        !preservesCredential) {
      return const SearchProviderConfigSaveResult.failure(
        credentialFailure: CredentialFailure.unavailable,
        errorMessage: '生产环境 Gateway 必须配置访问令牌',
      );
    }
    CredentialReadResult? previousCredential;
    if (entered.isNotEmpty &&
        existing != null &&
        existing.hasCredential &&
        existing.credentialId == credentials.credentialIdFor(existing.id)) {
      previousCredential = await credentials.read(existing.id);
      if (!previousCredential.isAvailable &&
          previousCredential.failure != null) {
        return SearchProviderConfigSaveResult.failure(
          credentialFailure: previousCredential.failure,
          errorMessage: '现有搜索凭据不可读取，未覆盖配置',
        );
      }
    }
    var next = draft.copyWith(
      baseUrl: endpoint?.uri?.toString() ?? draft.baseUrl,
      credentialRequired: requiresCredential,
      requiresAttention: entered.isNotEmpty
          ? false
          : existing?.requiresAttention ?? draft.requiresAttention,
    );
    var usedFallback = false;
    var credentialIntentWritten = false;
    var credentialCleanupIntentWritten = false;
    final removesPreviousSecureCredential = entered.isEmpty &&
        existing != null &&
        existing.provider != draft.provider &&
        _hasSecureCredentialBinding(existing);
    if (removesPreviousSecureCredential) {
      try {
        await _markCredentialRepair(
          configId: existing.id,
          credentialId: existing.credentialId,
          operation: 'credential_cleanup',
          phase: 'planned',
        );
        credentialCleanupIntentWritten = true;
      } on Object {
        return const SearchProviderConfigSaveResult.failure(
          credentialFailure: CredentialFailure.systemError,
          errorMessage: '原搜索凭据清理意图无法持久化',
        );
      }
    }
    if (entered.isNotEmpty) {
      try {
        await _markCredentialRepair(
          configId: draft.id,
          credentialId: credentials.credentialIdFor(draft.id),
          operation: 'credential_rotation',
          phase: 'planned',
        );
        credentialIntentWritten = true;
      } on Object {
        return const SearchProviderConfigSaveResult.failure(
          credentialFailure: CredentialFailure.systemError,
          errorMessage: '搜索凭据变更意图无法持久化',
        );
      }
      final result = await credentials.save(draft.id, entered);
      if (result.isSuccess) {
        next = next.copyWith(
          credentialId: credentials.credentialIdFor(draft.id),
          hasCredential: true,
          credentialRevision: _nextCredentialRevision(existing),
          clearDevelopmentLegacyApiKey: true,
        );
      } else {
        final restored = await _restorePreviousCredentialAfterFailedSave(
          draft.id,
          previousCredential,
        );
        if (!restored ||
            (result.requiresRecovery && previousCredential == null)) {
          final recoveryMarked = await _markCredentialRecovery(draft.id);
          return SearchProviderConfigSaveResult.failure(
            credentialFailure: CredentialFailure.systemError,
            errorMessage: recoveryMarked
                ? '搜索凭据写入失败且无法恢复原凭据'
                : '搜索凭据写入失败，恢复状态无法持久化；原变更意图将保留待重试',
          );
        }
        try {
          await _clearCredentialRepair(draft.id);
        } on Object {
          return const SearchProviderConfigSaveResult.failure(
            credentialFailure: CredentialFailure.systemError,
            errorMessage: '搜索凭据未变更，但修复状态仍待清理',
          );
        }
        if (_canUseDevelopmentFallback(result, existing)) {
          next = next.copyWith(
            credentialId:
                SearchCredentialRepository.developmentHiveCredentialId,
            hasCredential: true,
            credentialRequired: true,
            credentialRevision: _nextCredentialRevision(existing),
            developmentLegacyApiKey: entered,
          );
          usedFallback = true;
        } else {
          return SearchProviderConfigSaveResult.failure(
            credentialFailure: result.failure,
          );
        }
      }
    } else if (existing != null && existing.provider == draft.provider) {
      // Empty input means preserve the existing binding; it never triggers a
      // write and does not silently erase a credential.
      next = next.copyWith(
        credentialId: existing.credentialId,
        hasCredential: existing.hasCredential,
        credentialRequired: existing.credentialRequired,
        credentialRevision: existing.credentialRevision,
        developmentLegacyApiKey: existing.developmentLegacyApiKey,
      );
    } else {
      next = next.copyWith(
        credentialId: '',
        hasCredential: false,
        credentialRequired: false,
        clearDevelopmentLegacyApiKey: true,
      );
    }

    try {
      await _putConfig(next, includeDevelopmentFallback: usedFallback);
      if (removesPreviousSecureCredential) {
        await _markCredentialRepair(
          configId: existing.id,
          credentialId: existing.credentialId,
          operation: 'credential_cleanup',
          phase: 'cleanup',
        );
        final deleted = await credentials.delete(existing.id);
        if (!deleted.isSuccess) {
          final restored = await _restoreSettings(metadataSnapshot);
          if (restored) {
            // The old metadata still owns the credential. If marker cleanup
            // fails, leave a planned intent so a retry only clears the marker
            // and never deletes the still-owned old key.
            try {
              await _markCredentialRepair(
                configId: existing.id,
                credentialId: existing.credentialId,
                operation: 'credential_cleanup',
                phase: 'planned',
              );
              await _clearCredentialRepair(existing.id);
            } on Object {
              // The planned marker remains durable for the next retry.
            }
          }
          return SearchProviderConfigSaveResult.failure(
            credentialFailure: deleted.failure,
            errorMessage: '原搜索凭据删除失败，配置已保留待重试',
          );
        }
      }
      if (credentialIntentWritten || credentialCleanupIntentWritten) {
        try {
          await _clearCredentialRepair(draft.id);
        } on Object {
          return const SearchProviderConfigSaveResult.failure(
            credentialFailure: CredentialFailure.systemError,
            errorMessage: '搜索凭据已变更，但修复状态仍待清理',
          );
        }
      }
      return SearchProviderConfigSaveResult.success(
        next,
        usedDevelopmentFallback: usedFallback,
      );
    } on Object {
      // Metadata and secure storage are separate systems. If metadata fails
      // after a credential rotation, restore the old value rather than
      // deleting the only known credential. No secret enters diagnostics.
      var recoveryMarkerWritten = true;
      if (!usedFallback && entered.isNotEmpty) {
        if (previousCredential?.isAvailable == true) {
          final restored = await credentials.save(
            draft.id,
            previousCredential!.value!,
          );
          if (!restored.isSuccess) {
            recoveryMarkerWritten = await _markCredentialRecovery(draft.id);
          }
        } else {
          final deleted = await credentials.delete(draft.id);
          if (!deleted.isSuccess) {
            recoveryMarkerWritten = await _markCredentialRecovery(draft.id);
          }
        }
      }
      return SearchProviderConfigSaveResult.failure(
        credentialFailure: CredentialFailure.systemError,
        errorMessage: recoveryMarkerWritten
            ? '搜索配置保存失败'
            : '搜索配置保存失败，恢复状态无法持久化；原变更意图将保留待重试',
      );
    }
  }

  Future<SearchProviderConfigDeleteResult> delete(String id) =>
      _runSerialized(() => _delete(id));

  Future<SearchProviderConfigDeleteResult> _delete(String id) async {
    final existing = findById(id);
    if (existing == null) {
      final pending = _pendingCredentialRepair(id);
      if (pending == null) {
        return const SearchProviderConfigDeleteResult.success();
      }
      return _finishPendingCredentialRepair(id, pending);
    }
    if (_hasUnknownCredentialBinding(existing)) {
      return const SearchProviderConfigDeleteResult.failure(
        CredentialFailure.systemError,
      );
    }
    final secureCredentialBound =
        (existing.hasCredential || existing.credentialId.isNotEmpty) &&
            existing.credentialId !=
                SearchCredentialRepository.developmentHiveCredentialId;
    final snapshot = _captureSettings();
    if (secureCredentialBound) {
      try {
        await _markCredentialRepair(
          configId: existing.id,
          credentialId: existing.credentialId,
        );
      } on Object {
        return const SearchProviderConfigDeleteResult.failure(
          CredentialFailure.systemError,
        );
      }
    }
    try {
      final remaining = configs.where((item) => item.id != id).toList();
      await _writeConfigs(remaining);
      if (box.get(SearchProviderConfigStore.defaultProviderKey)?.toString() ==
          id) {
        await box.delete(SearchProviderConfigStore.defaultProviderKey);
      }
    } on Object {
      final restored = await _restoreSettings(snapshot);
      if (restored) {
        try {
          await _clearCredentialRepair(id);
        } on Object {
          // Keep the marker when its cleanup cannot be persisted.
        }
      }
      return const SearchProviderConfigDeleteResult.failure(
        CredentialFailure.systemError,
      );
    }

    if (secureCredentialBound) {
      final result = await credentials.delete(id);
      if (!result.isSuccess) {
        final restored = await _restoreSettings(snapshot);
        if (restored) {
          try {
            await _clearCredentialRepair(id);
          } on Object {
            // Keep the marker when its cleanup cannot be persisted.
          }
        }
        return SearchProviderConfigDeleteResult.failure(result.failure);
      }
    }
    try {
      await _clearCredentialRepair(id);
    } on Object {
      // The metadata and secure credential are already in their target state;
      // retaining the durable marker makes the cleanup retryable.
      return const SearchProviderConfigDeleteResult.failure(
        CredentialFailure.systemError,
      );
    }
    return const SearchProviderConfigDeleteResult.success();
  }

  Future<void> _putConfig(
    SearchProviderConfig config, {
    required bool includeDevelopmentFallback,
  }) async {
    final snapshot = _captureSettings();
    try {
      final next = configs
          .where((item) => item.id != config.id)
          .map((item) =>
              config.isDefault ? item.copyWith(isDefault: false) : item)
          .toList();
      next.add(config);
      await _writeConfigs(
        next,
        includeDevelopmentFallbackFor:
            includeDevelopmentFallback ? config.id : null,
      );
      if (config.isDefault) {
        await box.put(SearchProviderConfigStore.defaultProviderKey, config.id);
      } else if (box
              .get(SearchProviderConfigStore.defaultProviderKey)
              ?.toString() ==
          config.id) {
        await box.delete(SearchProviderConfigStore.defaultProviderKey);
      }
    } on Object {
      final restored = await _restoreSettings(snapshot);
      if (!restored) {
        throw StateError('search metadata rollback failed');
      }
      rethrow;
    }
  }
}
