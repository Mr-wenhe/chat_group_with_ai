import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'secure_storage_service.dart';

/// The reason a credential cannot be read or changed.
///
/// Callers must handle this result explicitly. In particular, they must not
/// fall back to a legacy Hive field, which could revive a deleted credential.
enum CredentialFailure {
  unavailable,
  permissionDenied,
  systemError,
}

/// A typed result for credential reads.
class CredentialReadResult {
  final String? value;
  final CredentialFailure? failure;

  const CredentialReadResult._({this.value, this.failure});

  const CredentialReadResult.found(String value) : this._(value: value);

  const CredentialReadResult.notFound() : this._();

  const CredentialReadResult.failed(CredentialFailure failure)
      : this._(failure: failure);

  bool get isAvailable => value != null && value!.isNotEmpty;
  bool get isMissing => value == null && failure == null;
}

/// A typed result for credential mutations.
class CredentialWriteResult {
  final CredentialFailure? failure;

  const CredentialWriteResult._({this.failure});

  const CredentialWriteResult.success() : this._();

  const CredentialWriteResult.failed(CredentialFailure failure)
      : this._(failure: failure);

  bool get isSuccess => failure == null;
}

/// Minimal secure key-value boundary used by [CredentialRepository].
///
/// It is deliberately small so migration and failure paths can be tested
/// without a platform Keychain/Keystore implementation.
abstract interface class CredentialStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

class SecureStorageCredentialStore implements CredentialStore {
  final SecureStorageService _storage;

  SecureStorageCredentialStore([SecureStorageService? storage])
      : _storage = storage ?? SecureStorageService();

  @override
  Future<void> delete(String key) => _storage.deleteRaw(key);

  @override
  Future<String?> read(String key) => _storage.readRaw(key);

  @override
  Future<void> write(String key, String value) => _storage.writeRaw(key, value);
}

/// The only persistence boundary for LLM API keys.
///
/// Native builds use platform secure storage. Web deliberately returns an
/// explicit unavailable result: browser storage is not represented as a
/// Keychain-equivalent and must never become a silent fallback.
/// TODO(migration): 本类目前是「计划中的统一 LLM API key 边界」，尚未被
/// `ApiConfig` / `AICharacter` / `WeComPushService` 任一调用方接线——
/// 实际读写仍由 [SecureStorageService] 承接。
///
/// 关键约束：本类写入 key 前缀为 `credential.api-config.`，与
/// [SecureStorageService] 现有 `api_config_key_` **不同**。若直接把
/// `ApiConfig` 改为走本类，旧用户已存的密钥将因 key 不匹配而读不到（破坏性
/// 迁移）。接线时须先做「先读新 key、缺失再回退旧 `api_config_key_`」的兼容
/// 读取，并在写入稳定后再清理旧路径。完成迁移前请勿删除
/// [SecureStorageService] 的对应方法。
class CredentialRepository {
  static const _keyPrefix = 'credential.api-config.';

  final CredentialStore _store;
  final bool _secureStorageAvailable;

  CredentialRepository({
    CredentialStore? store,
    bool? secureStorageAvailable,
  })  : _store = store ?? SecureStorageCredentialStore(),
        _secureStorageAvailable = secureStorageAvailable ?? !kIsWeb;

  String credentialIdFor(String configId) => '$_keyPrefix$configId';

  Future<CredentialWriteResult> save(String configId, String secret) async {
    if (!_secureStorageAvailable) {
      return const CredentialWriteResult.failed(CredentialFailure.unavailable);
    }
    if (configId.trim().isEmpty || secret.isEmpty) {
      return const CredentialWriteResult.failed(CredentialFailure.systemError);
    }
    try {
      await _store.write(credentialIdFor(configId), secret);
      // Verify before a caller is allowed to remove any legacy copy.
      final stored = await _store.read(credentialIdFor(configId));
      if (stored != secret) {
        return const CredentialWriteResult.failed(
            CredentialFailure.systemError);
      }
      return const CredentialWriteResult.success();
    } on PlatformException catch (error) {
      return CredentialWriteResult.failed(_mapPlatformFailure(error));
    } catch (_) {
      return const CredentialWriteResult.failed(CredentialFailure.systemError);
    }
  }

  Future<CredentialReadResult> read(String configId) async {
    if (!_secureStorageAvailable) {
      return const CredentialReadResult.failed(CredentialFailure.unavailable);
    }
    if (configId.trim().isEmpty) return const CredentialReadResult.notFound();
    try {
      final value = await _store.read(credentialIdFor(configId));
      return value == null || value.isEmpty
          ? const CredentialReadResult.notFound()
          : CredentialReadResult.found(value);
    } on PlatformException catch (error) {
      return CredentialReadResult.failed(_mapPlatformFailure(error));
    } catch (_) {
      return const CredentialReadResult.failed(CredentialFailure.systemError);
    }
  }

  Future<CredentialWriteResult> delete(String configId) async {
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
