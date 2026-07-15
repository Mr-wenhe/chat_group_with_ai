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
///
/// 过渡策略（migration）：本类采用「新前缀 +
/// 旧前缀双写 / 新前缀优先 + 旧前缀回退」策略：
///   - 写入：同时写新前缀 `credential.api-config.{id}` 与旧前缀
///     `api_config_key_{id}`（经 [SecureStorageService]），保证过渡期两套读取
///     逻辑都能命中。
///   - 读取：先读新前缀，缺失再回退旧 `api_config_key_{id}`。
///
/// 移除条件：待 [SecureStorageService] 的全部调用方迁移到本类、且线上存量用户
/// 均已至少成功走一次双写（旧 key 已补齐）后，方可删除旧路径读写逻辑与本类
/// 对 [SecureStorageService] 的依赖。完成迁移前请勿删除旧路径。
class CredentialRepository {
  static const _keyPrefix = 'credential.api-config.';
  static final _cache = <String, String>{};

  final CredentialStore _store;
  final SecureStorageService _legacyStorage;
  final bool _secureStorageAvailable;

  CredentialRepository({
    CredentialStore? store,
    SecureStorageService? legacyStorage,
    bool? secureStorageAvailable,
  })  : _store = store ?? SecureStorageCredentialStore(),
        _legacyStorage = legacyStorage ?? SecureStorageService(),
        _secureStorageAvailable = secureStorageAvailable ?? !kIsWeb;

  String credentialIdFor(String configId) => '$_keyPrefix$configId';

  /// 当前平台是否存在可用的安全存储。Web 等无 Keychain/Keystore 环境为 false，
  /// 调用方据此决定是否回退到 Hive 明文 legacyApiKey。
  bool get secureStorageAvailable => _secureStorageAvailable;

  static String? cached(String configId) => _cache[configId];

  static void clearCache() => _cache.clear();

  Future<CredentialWriteResult> save(String configId, String secret) async {
    if (!_secureStorageAvailable) {
      return const CredentialWriteResult.failed(CredentialFailure.unavailable);
    }
    if (configId.trim().isEmpty || secret.isEmpty) {
      return const CredentialWriteResult.failed(CredentialFailure.systemError);
    }
    try {
      // 过渡期双写：新前缀为主，旧 api_config_key_ 前缀为 best-effort 兼容副本。
      // 旧前缀写入失败不阻断主流程（旧副本缺失不影响新前缀读取）。
      await _store.write(credentialIdFor(configId), secret);
      try {
        await _legacyStorage.saveApiConfigKey(configId, secret);
      } on Object {
        // 旧前缀仅用于过渡兼容；主凭据已写入新存储，不记录异常细节。
      }
      // Verify before a caller is allowed to remove any legacy copy.
      final stored = await _store.read(credentialIdFor(configId));
      if (stored != secret) {
        return const CredentialWriteResult.failed(
            CredentialFailure.systemError);
      }
      _cache[configId] = secret;
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
    final cached = _cache[configId];
    if (cached != null && cached.isNotEmpty) {
      return CredentialReadResult.found(cached);
    }
    try {
      // 先读新前缀。
      final newValue = await _store.read(credentialIdFor(configId));
      if (newValue != null && newValue.isNotEmpty) {
        _cache[configId] = newValue;
        return CredentialReadResult.found(newValue);
      }
      // 新前缀缺失，回退读旧 api_config_key_ 前缀（兼容历史用户已存密钥）。
      // 旧存储不可用（如测试 / 无 Keychain 环境）时按「未命中」处理，不翻转为失败。
      String? legacyValue;
      try {
        legacyValue = await _legacyStorage.getApiConfigKey(configId);
      } on Object {
        // 回退存储不可用时按未命中处理，避免泄露平台异常细节。
      }
      if (legacyValue != null && legacyValue.isNotEmpty) {
        _cache[configId] = legacyValue;
        return CredentialReadResult.found(legacyValue);
      }
      return const CredentialReadResult.notFound();
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
      // 同时删除新、旧两套 key；旧 key 删除失败为 best-effort，不阻断主流程。
      await _store.delete(credentialIdFor(configId));
      _cache.remove(configId);
      try {
        await _legacyStorage.deleteApiConfigKey(configId);
      } on Object {
        // 旧前缀删除是过渡期 best-effort，不记录异常细节。
      }
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
