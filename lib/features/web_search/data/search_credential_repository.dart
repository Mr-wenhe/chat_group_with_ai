import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:chat_group/core/storage/credential_repository.dart';
import '../models/search_provider_config.dart';
import '../security/search_credential_validator.dart';

/// The search-specific credential prefix. It must never overlap the
/// `credential.api-config.` namespace used by chat model credentials.
const String searchCredentialKeyPrefix = 'credential.web-search.';

typedef SearchCredentialFailure = CredentialFailure;
typedef SearchCredentialReadResult = CredentialReadResult;

/// Result of changing a search credential.
///
/// Development Hive fallback is permitted only when secure storage did not
/// complete a write. A completed write followed by a failed verification is an
/// integrity failure, not a reason to duplicate the secret in Hive.
class SearchCredentialWriteResult {
  final CredentialFailure? failure;
  final bool canUseDevelopmentFallback;

  /// True when a candidate write could not be verified or removed. Callers
  /// must retain a durable repair intent instead of treating the key as absent.
  final bool requiresRecovery;

  const SearchCredentialWriteResult.success()
      : failure = null,
        canUseDevelopmentFallback = false,
        requiresRecovery = false;

  const SearchCredentialWriteResult.failed(
    this.failure, {
    this.canUseDevelopmentFallback = false,
    this.requiresRecovery = false,
  });

  bool get isSuccess => failure == null;
}

/// Secure-storage boundary for search provider keys.
class SearchCredentialRepository {
  static const String developmentHiveCredentialId =
      searchDevelopmentFallbackCredentialId;

  final CredentialStore _store;
  final bool _secureStorageAvailable;

  SearchCredentialRepository({
    CredentialStore? store,
    bool? secureStorageAvailable,
  })  : _store = store ?? SecureStorageCredentialStore(),
        _secureStorageAvailable = secureStorageAvailable ?? !kIsWeb;

  bool get secureStorageAvailable => _secureStorageAvailable;

  /// Returns the canonical key only for a bounded provider configuration ID.
  ///
  /// An empty result is safer than constructing an unbounded secure-storage
  /// key when a caller passes malformed or imported metadata.
  String credentialIdFor(String configId) {
    if (!_isValidConfigId(configId)) return '';
    return '$searchCredentialKeyPrefix$configId';
  }

  /// Returns whether an explicitly requested repair may remove this binding.
  /// Only keys in the search namespace are eligible; a malformed or
  /// cross-domain identifier must never let search settings delete another
  /// feature's credential.
  bool canDeleteBinding(String credentialId) {
    if (credentialId.length > SearchProviderConfig.maxCredentialIdLength ||
        !credentialId.startsWith(searchCredentialKeyPrefix)) {
      return false;
    }
    final configId = credentialId.substring(searchCredentialKeyPrefix.length);
    return SearchProviderConfig.canonicalizeId(configId) == configId;
  }

  Future<SearchCredentialWriteResult> save(
    String configId,
    String secret,
  ) async {
    final normalizedConfigId = configId;
    if (!_isValidConfigId(normalizedConfigId) ||
        secret.isEmpty ||
        SearchCredentialValidator.validate(secret) != null) {
      return const SearchCredentialWriteResult.failed(
        CredentialFailure.systemError,
      );
    }
    if (!_secureStorageAvailable) {
      return const SearchCredentialWriteResult.failed(
        CredentialFailure.unavailable,
        canUseDevelopmentFallback: true,
      );
    }
    final key = credentialIdFor(normalizedConfigId);
    var writeCompleted = false;
    try {
      await _store.write(key, secret);
      writeCompleted = true;
      final stored = await _store.read(key);
      if (stored != secret) {
        return _failedSaveAfterWrite(
          key,
          CredentialFailure.systemError,
          canUseDevelopmentFallback: false,
        );
      }
      return const SearchCredentialWriteResult.success();
    } on PlatformException catch (error) {
      return _failedSaveAfterWrite(
        key,
        _mapPlatformFailure(error),
        canUseDevelopmentFallback: !writeCompleted,
      );
    } catch (_) {
      return _failedSaveAfterWrite(
        key,
        CredentialFailure.systemError,
        canUseDevelopmentFallback: !writeCompleted,
      );
    }
  }

  /// A secure-store write can succeed before its verification read fails.
  /// Always remove that candidate value before reporting failure, so callers
  /// never leave an untracked credential behind. If deletion also fails, Hive
  /// fallback is forbidden because the secure-store state is unknown.
  Future<SearchCredentialWriteResult> _failedSaveAfterWrite(
    String key,
    CredentialFailure failure, {
    required bool canUseDevelopmentFallback,
  }) async {
    try {
      await _store.delete(key);
      return SearchCredentialWriteResult.failed(
        failure,
        canUseDevelopmentFallback: canUseDevelopmentFallback,
      );
    } on Object {
      return const SearchCredentialWriteResult.failed(
        CredentialFailure.systemError,
        requiresRecovery: true,
      );
    }
  }

  Future<SearchCredentialReadResult> read(String configId) async {
    final normalizedConfigId = configId;
    if (normalizedConfigId.isEmpty) {
      return const CredentialReadResult.notFound();
    }
    if (!_isValidConfigId(normalizedConfigId)) {
      return const CredentialReadResult.failed(CredentialFailure.systemError);
    }
    if (!_secureStorageAvailable) {
      return const CredentialReadResult.failed(CredentialFailure.unavailable);
    }
    try {
      final value = await _store.read(credentialIdFor(normalizedConfigId));
      if (value == null || value.isEmpty) {
        return const CredentialReadResult.notFound();
      }
      return CredentialReadResult.found(value);
    } on PlatformException catch (error) {
      return CredentialReadResult.failed(_mapPlatformFailure(error));
    } catch (_) {
      return const CredentialReadResult.failed(CredentialFailure.systemError);
    }
  }

  Future<SearchCredentialWriteResult> delete(String configId) async {
    final normalizedConfigId = configId;
    if (normalizedConfigId.isEmpty) {
      return const SearchCredentialWriteResult.success();
    }
    if (!_isValidConfigId(normalizedConfigId)) {
      return const SearchCredentialWriteResult.failed(
        CredentialFailure.systemError,
      );
    }
    if (!_secureStorageAvailable) {
      return const SearchCredentialWriteResult.failed(
        CredentialFailure.unavailable,
      );
    }
    try {
      await _store.delete(credentialIdFor(normalizedConfigId));
      return const SearchCredentialWriteResult.success();
    } on PlatformException catch (error) {
      return SearchCredentialWriteResult.failed(_mapPlatformFailure(error));
    } catch (_) {
      return const SearchCredentialWriteResult.failed(
        CredentialFailure.systemError,
      );
    }
  }

  /// Deletes one explicitly confirmed, unknown search binding during repair.
  /// This is intentionally separate from [delete], which derives only the
  /// canonical key for a configuration ID.
  Future<SearchCredentialWriteResult> deleteBinding(String credentialId) async {
    if (!_secureStorageAvailable) {
      return const SearchCredentialWriteResult.failed(
        CredentialFailure.unavailable,
      );
    }
    if (!canDeleteBinding(credentialId)) {
      return const SearchCredentialWriteResult.failed(
        CredentialFailure.systemError,
      );
    }
    try {
      await _store.delete(credentialId);
      return const SearchCredentialWriteResult.success();
    } on PlatformException catch (error) {
      return SearchCredentialWriteResult.failed(_mapPlatformFailure(error));
    } catch (_) {
      return const SearchCredentialWriteResult.failed(
        CredentialFailure.systemError,
      );
    }
  }

  Future<bool> exists(String configId) async =>
      (await read(configId)).isAvailable;

  bool _isValidConfigId(String configId) =>
      SearchProviderConfig.canonicalizeId(configId) == configId;

  CredentialFailure _mapPlatformFailure(PlatformException error) {
    final code = error.code.toLowerCase();
    if (code.contains('auth') ||
        code.contains('permission') ||
        code.contains('denied') ||
        code.contains('locked')) {
      return CredentialFailure.permissionDenied;
    }
    if (code.contains('unavailable') || code.contains('not_implemented')) {
      return CredentialFailure.unavailable;
    }
    return CredentialFailure.systemError;
  }
}

/// Resolves a search credential immediately before a connection or provider
/// request. A development fallback is read only outside release builds.
class SearchCredentialResolver {
  final SearchCredentialRepository _credentials;
  final bool _isRelease;

  SearchCredentialResolver({
    SearchCredentialRepository? credentials,
    bool? isRelease,
  })  : _credentials = credentials ?? SearchCredentialRepository(),
        _isRelease = isRelease ?? kReleaseMode;

  Future<SearchCredentialReadResult> resolveResult(
    SearchProviderConfig config,
  ) async {
    if (!config.hasCredential) {
      return const CredentialReadResult.notFound();
    }
    if (config.credentialId == developmentHiveCredentialId) {
      // Do not even inspect the legacy field in release builds. This is the
      // hard boundary that prevents a Hive plaintext secret from reappearing.
      if (_isRelease) {
        return const CredentialReadResult.failed(
          CredentialFailure.unavailable,
        );
      }
      final fallback = config.developmentLegacyApiKey;
      return fallback == null || fallback.isEmpty
          ? const CredentialReadResult.notFound()
          : CredentialReadResult.found(fallback);
    }
    if (config.credentialId != _credentials.credentialIdFor(config.id)) {
      return const CredentialReadResult.failed(CredentialFailure.systemError);
    }
    return _credentials.read(config.id);
  }

  Future<String?> resolve(SearchProviderConfig config) async {
    final result = await resolveResult(config);
    return result.isAvailable ? result.value : null;
  }

  static const String developmentHiveCredentialId =
      SearchCredentialRepository.developmentHiveCredentialId;
}

/// Naming-compatible alias for callers that mirror the API credential
/// resolver's explicit secure implementation name.
typedef SecureSearchCredentialResolver = SearchCredentialResolver;
