part of 'search_settings_store.dart';

extension SearchProviderConfigStoreCredentialLifecycle
    on SearchProviderConfigStore {
  /// Whether an existing binding is unknown but still safely repairable
  /// inside the search credential namespace.
  bool canRepairUnknownCredentialBinding(String id) {
    final existing = findById(id);
    return existing != null &&
        _hasUnknownCredentialBinding(existing) &&
        credentials.canDeleteBinding(existing.credentialId);
  }

  bool hasUnknownCredentialBinding(String id) {
    final existing = findById(id);
    return existing != null && _hasUnknownCredentialBinding(existing);
  }

  /// Explicit recovery for a legacy search binding that cannot be mapped to
  /// the canonical credential ID. The old secret is deleted first, then the
  /// metadata is marked for a fresh binding; this prevents a failed metadata
  /// write from leaving an untracked secret behind. Cross-domain IDs are
  /// rejected because search must not delete another feature's credential.
  Future<SearchProviderConfigSaveResult> repairUnknownCredentialBinding(
    String id,
  ) =>
      _runSerialized(() => _repairUnknownCredentialBinding(id));

  Future<SearchProviderConfigSaveResult> _repairUnknownCredentialBinding(
    String id,
  ) async {
    final existing = findById(id);
    if (existing == null || !_hasUnknownCredentialBinding(existing)) {
      return const SearchProviderConfigSaveResult.failure(
        credentialFailure: CredentialFailure.systemError,
        errorMessage: '当前配置没有可修复的未知凭据绑定',
      );
    }
    if (!credentials.canDeleteBinding(existing.credentialId)) {
      return const SearchProviderConfigSaveResult.failure(
        credentialFailure: CredentialFailure.systemError,
        errorMessage: '未知凭据不属于搜索安全存储命名空间，无法自动修复',
      );
    }
    final snapshot = _captureSettings();
    try {
      // Persist the repair intent before deleting the explicitly identified
      // legacy key. If metadata cannot be rewritten afterward, the next
      // lifecycle pass can still retry the safe deletion.
      await _markCredentialRepair(
        configId: existing.id,
        credentialId: existing.credentialId,
        operation: 'repair_binding',
      );
    } on Object {
      return const SearchProviderConfigSaveResult.failure(
        credentialFailure: CredentialFailure.systemError,
        errorMessage: '旧搜索凭据修复状态无法持久化',
      );
    }
    final deleted = await credentials.deleteBinding(existing.credentialId);
    if (!deleted.isSuccess) {
      return SearchProviderConfigSaveResult.failure(
        credentialFailure: deleted.failure,
        errorMessage: '旧搜索凭据清理失败，配置未修复',
      );
    }
    final repaired = existing.copyWith(
      credentialId: '',
      hasCredential: false,
      credentialRequired: true,
      requiresAttention: true,
    );
    try {
      await _putConfig(repaired, includeDevelopmentFallback: false);
      try {
        await _clearCredentialRepair(existing.id);
      } on Object {
        return const SearchProviderConfigSaveResult.failure(
          credentialFailure: CredentialFailure.systemError,
          errorMessage: '搜索凭据修复完成，但修复状态仍待清理',
        );
      }
      return SearchProviderConfigSaveResult.success(repaired);
    } on Object {
      final restored = await _restoreSettings(snapshot);
      return SearchProviderConfigSaveResult.failure(
        credentialFailure: CredentialFailure.systemError,
        errorMessage: restored
            ? '旧搜索凭据已清理，但配置元数据保存失败，请重新绑定 Key'
            : '旧搜索凭据已清理，且配置元数据回滚失败；请先重试修复再重新绑定 Key',
      );
    }
  }

  /// Deletes provider metadata only after all bound credentials have been
  /// removed. A failed binding therefore remains available for retry.
  Future<void> clearConfigurationIfEmpty() =>
      _runSerialized(_clearConfigurationIfEmpty);

  Future<void> _clearConfigurationIfEmpty() async {
    if (configs.isNotEmpty) return;
    final repairState = _readCredentialRepairState();
    if (repairState.malformed || repairState.repairs.isNotEmpty) {
      throw StateError('search credential repair is still pending');
    }
    final raw = box.get(SearchProviderConfigStore.configsKey);
    if (raw != null && (raw is! List || raw.isNotEmpty)) {
      // A malformed legacy record may still carry a credential binding that
      // cannot be addressed safely. Retain it and surface an incomplete
      // lifecycle operation instead of deleting metadata silently.
      throw StateError('search configuration cannot be safely cleared');
    }
    await box.delete(SearchProviderConfigStore.configsKey);
    await box.delete(SearchProviderConfigStore.defaultProviderKey);
  }

  /// Retries durable deletion intents, including intents whose provider
  /// metadata is already gone. Returning the completed IDs lets lifecycle and
  /// settings callers report remaining work without exposing credential data.
  Future<List<String>> retryPendingCredentialRepairs() =>
      _runSerialized(_retryPendingCredentialRepairs);

  Future<List<String>> _retryPendingCredentialRepairs() async {
    if (hasMalformedCredentialRepairState) return const [];
    final repaired = <String>[];
    for (final id in pendingCredentialRepairIds) {
      final repair = _pendingCredentialRepair(id);
      if (repair == null) continue;
      final existing = findById(id);
      final operation = repair['operation']?.toString();
      SearchProviderConfigDeleteResult result;
      if (operation == 'credential_rotation') {
        result = await _retryCredentialRotation(id, repair);
      } else if (operation == 'credential_recovery') {
        result = await _finishCredentialRecovery(id, repair);
      } else if (operation == 'credential_cleanup') {
        final currentHasBinding =
            existing != null && _hasSecureCredentialBinding(existing);
        result = currentHasBinding
            ? await _clearPendingCredentialRepair(id)
            : await _finishPendingCredentialRepair(id, repair);
      } else {
        final bindingRepairCompleted = existing != null &&
            existing.credentialId.isEmpty &&
            !existing.hasCredential &&
            existing.credentialRequired;
        result = operation == 'repair_binding'
            ? await _retryBindingRepair(id, repair)
            : bindingRepairCompleted
                ? await _clearPendingCredentialRepair(id)
                : existing == null
                    ? await _finishPendingCredentialRepair(id, repair)
                    : await _delete(id);
      }
      if (result.isSuccess) repaired.add(id);
    }
    return repaired;
  }

  Future<SearchProviderConfigDeleteResult> _retryCredentialRotation(
    String configId,
    Map<String, dynamic> repair,
  ) async {
    final credentialId = repair['credentialId']?.toString() ?? '';
    if (!credentials.canDeleteBinding(credentialId)) {
      return const SearchProviderConfigDeleteResult.failure(
        CredentialFailure.systemError,
      );
    }
    final existing = findById(configId);
    // A metadata write can fail after the old credential was restored. In
    // that state the canonical binding is still owned by the current config;
    // the rotation marker is only stale bookkeeping and must be cleared, not
    // treated as permission to delete the last usable key.
    if (existing != null &&
        _hasSecureCredentialBinding(existing) &&
        existing.credentialId == credentialId) {
      return _clearPendingCredentialRepair(configId);
    }
    if (existing != null && _hasSecureCredentialBinding(existing)) {
      // The original metadata may still own this canonical key. Without a
      // durable recovery phase, deleting it could destroy the last usable
      // credential; retain the marker until an explicit repair can establish
      // which value is safe to remove.
      return const SearchProviderConfigDeleteResult.failure(
        CredentialFailure.systemError,
      );
    }
    final deleted = await credentials.deleteBinding(credentialId);
    if (!deleted.isSuccess) {
      return SearchProviderConfigDeleteResult.failure(deleted.failure);
    }
    return _clearPendingCredentialRepair(configId);
  }

  Future<SearchProviderConfigDeleteResult> _retryBindingRepair(
    String configId,
    Map<String, dynamic> repair,
  ) async {
    final credentialId = repair['credentialId']?.toString() ?? '';
    if (!credentials.canDeleteBinding(credentialId)) {
      return const SearchProviderConfigDeleteResult.failure(
        CredentialFailure.systemError,
      );
    }
    final existing = findById(configId);
    if (existing == null) {
      return _finishPendingCredentialRepair(configId, repair);
    }
    final deleted = await credentials.deleteBinding(credentialId);
    if (!deleted.isSuccess) {
      return SearchProviderConfigDeleteResult.failure(deleted.failure);
    }
    final bindingMatches = existing.credentialId == credentialId ||
        (existing.credentialId.isEmpty && existing.hasCredential);
    if (bindingMatches) {
      final repaired = existing.copyWith(
        credentialId: '',
        hasCredential: false,
        credentialRequired: true,
        requiresAttention: true,
      );
      try {
        await _putConfig(repaired, includeDevelopmentFallback: false);
      } on Object {
        return const SearchProviderConfigDeleteResult.failure(
          CredentialFailure.systemError,
        );
      }
    }
    return _clearPendingCredentialRepair(configId);
  }

  Future<SearchProviderConfigDeleteResult> _clearPendingCredentialRepair(
    String configId,
  ) async {
    try {
      await _clearCredentialRepair(configId);
    } on Object {
      return const SearchProviderConfigDeleteResult.failure(
        CredentialFailure.systemError,
      );
    }
    return const SearchProviderConfigDeleteResult.success();
  }

  Future<SearchProviderConfigDeleteResult> _finishCredentialRecovery(
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
    final existing = findById(configId);
    if (existing != null &&
        (existing.credentialId == credentialId || existing.hasCredential)) {
      try {
        await _putConfig(
          existing.copyWith(
            credentialId: '',
            hasCredential: false,
            credentialRequired: true,
            requiresAttention: true,
            clearDevelopmentLegacyApiKey: true,
          ),
          includeDevelopmentFallback: false,
        );
      } on Object {
        return const SearchProviderConfigDeleteResult.failure(
          CredentialFailure.systemError,
        );
      }
    }
    return _clearPendingCredentialRepair(configId);
  }

  /// Clears the persisted cache namespace. In-memory turn caches are owned by
  /// active chat coordinators and are cleared when their page is recreated;
  /// this operation also gives future persistent cache implementations one
  /// stable, backwards-compatible key to invalidate.
  Future<void> clearSearchCache() => _runSerialized(
        () => box.delete(SearchProviderConfigStore.resultCacheKey),
      );
}
