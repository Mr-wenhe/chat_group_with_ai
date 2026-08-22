import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:chat_group/core/storage/credential_repository.dart';
import '../models/search_provider_config.dart';

/// The search-specific credential prefix. It must never overlap the
/// `credential.api-config.` namespace used by chat model credentials.
const String searchCredentialKeyPrefix = 'credential.web-search.';

typedef SearchCredentialFailure = CredentialFailure;
typedef SearchCredentialReadResult = CredentialReadResult;
typedef SearchCredentialWriteResult = CredentialWriteResult;

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

  String credentialIdFor(String configId) =>
      '$searchCredentialKeyPrefix${configId.trim()}';

  Future<SearchCredentialWriteResult> save(
    String configId,
    String secret,
  ) async {
    if (!_secureStorageAvailable) {
      return const CredentialWriteResult.failed(CredentialFailure.unavailable);
    }
    if (configId.trim().isEmpty || secret.isEmpty) {
      return const CredentialWriteResult.failed(CredentialFailure.systemError);
    }
    final key = credentialIdFor(configId);
    try {
      await _store.write(key, secret);
      final stored = await _store.read(key);
      if (stored != secret) {
        return const CredentialWriteResult.failed(
          CredentialFailure.systemError,
        );
      }
      return const CredentialWriteResult.success();
    } on PlatformException catch (error) {
      return CredentialWriteResult.failed(_mapPlatformFailure(error));
    } catch (_) {
      return const CredentialWriteResult.failed(CredentialFailure.systemError);
    }
  }

  Future<SearchCredentialReadResult> read(String configId) async {
    if (!_secureStorageAvailable) {
      return const CredentialReadResult.failed(CredentialFailure.unavailable);
    }
    if (configId.trim().isEmpty) return const CredentialReadResult.notFound();
    try {
      final value = await _store.read(credentialIdFor(configId));
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
    if (!_secureStorageAvailable) {
      return const CredentialWriteResult.failed(CredentialFailure.unavailable);
    }
    if (configId.trim().isEmpty) return const CredentialWriteResult.success();
    try {
      await _store.delete(credentialIdFor(configId));
      return const CredentialWriteResult.success();
    } on PlatformException catch (error) {
      return CredentialWriteResult.failed(_mapPlatformFailure(error));
    } catch (_) {
      return const CredentialWriteResult.failed(CredentialFailure.systemError);
    }
  }

  Future<bool> exists(String configId) async =>
      (await read(configId)).isAvailable;

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
