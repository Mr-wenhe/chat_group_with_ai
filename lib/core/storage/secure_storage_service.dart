import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

import 'debug_credential_cache.dart';

class SecureStorageService {
  // macOS 走本地 Hive 库，下面这个实例在 macOS 上不会被调用（见 [_read] 等）。
  // 选项仍保留给其它平台与测试；Data Protection Keychain 在未启用 App Sandbox
  // 的签名下写入会报 -34018，故显式关掉。
  static const macOsOptions = MacOsOptions(useDataProtectionKeyChain: false);

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    mOptions: macOsOptions,
  );

  static const String _apiKeyPrefix = 'api_key_';
  static const String _apiConfigKeyPrefix = 'api_config_key_';

  /// Raw operations are only used by [CredentialRepository].
  ///
  /// Legacy api-config helpers remain during the key-prefix transition; do
  /// not use them from feature code.
  Future<void> writeRaw(String key, String value) => _write(key, value);

  Future<String?> readRaw(String key) => _read(key);

  Future<void> deleteRaw(String key) => _delete(key);

  Future<void> saveApiKey(String characterId, String apiKey) =>
      _write('$_apiKeyPrefix$characterId', apiKey);

  Future<String?> getApiKey(String characterId) =>
      _read('$_apiKeyPrefix$characterId');

  Future<void> deleteApiKey(String characterId) =>
      _delete('$_apiKeyPrefix$characterId');

  Future<bool> saveApiConfigKey(String configId, String apiKey) async {
    try {
      await _write('$_apiConfigKeyPrefix$configId', apiKey);
      return true;
    } on PlatformException {
      return false;
    }
  }

  Future<String?> getApiConfigKey(String configId) async {
    try {
      return await _read('$_apiConfigKeyPrefix$configId');
    } on PlatformException {
      return null;
    }
  }

  Future<void> deleteApiConfigKey(String configId) =>
      _delete('$_apiConfigKeyPrefix$configId');

  Future<void> saveDefaultProvider(String provider) =>
      _write('default_provider', provider);

  Future<String?> getDefaultProvider() => _read('default_provider');

  /// 企业微信自建应用配置（corpid / corpsecret / agentid），以 JSON 存于密钥库。
  static const String _wecomAppConfigKey = 'wecom_app_config';

  Future<void> saveWeComAppConfig(Map<String, String> config) =>
      _write(_wecomAppConfigKey, jsonEncode(config));

  Future<Map<String, String>?> getWeComAppConfig() async {
    try {
      final raw = await _read(_wecomAppConfigKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v.toString()));
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteWeComAppConfig() async {
    try {
      await _delete(_wecomAppConfigKey);
    } on PlatformException {
      // 企业微信配置沿用旧的 best-effort 清理语义。
    }
  }

  /// 凭据的三个落点，按平台与构建模式分流：
  ///
  ///   - **macOS**（[DebugCredentialCache.isPrimaryStore]）：一律读写本机 Hive 库，
  ///     **完全不碰钥匙串**。原因见该 getter 的注释——ad-hoc 签名下钥匙串要么每次
  ///     重建都弹密码框，要么根本写不进去，绕开它比继续给签名方式打补丁可靠。
  ///   - **其余平台非 Release**：先走 [DebugCredentialCache] 镜像，未命中才读一次
  ///     钥匙串并落盘，把弹窗收敛到每个键至多一次。
  ///   - **其余平台 Release / Web**：直接落平台安全存储，不经过镜像。
  ///
  /// 分支必须按平台走到底，不要为 macOS 再补一条「失败则回落钥匙串」：那条路径在
  /// 出问题的签名下自身就是不可用的，只会把失败原因藏起来。
  Future<String?> _read(String key) {
    if (DebugCredentialCache.isPrimaryStore) {
      return DebugCredentialCache.readLocal(key);
    }
    return DebugCredentialCache.enabled
        ? DebugCredentialCache.read(key, () => _storage.read(key: key))
        : _storage.read(key: key);
  }

  Future<void> _write(String key, String value) {
    if (DebugCredentialCache.isPrimaryStore) {
      return DebugCredentialCache.writeLocal(key, value);
    }
    return DebugCredentialCache.enabled
        ? DebugCredentialCache.write(
            key,
            value,
            () => _storage.write(key: key, value: value),
          )
        : _storage.write(key: key, value: value);
  }

  Future<void> _delete(String key) {
    if (DebugCredentialCache.isPrimaryStore) {
      return DebugCredentialCache.deleteLocal(key);
    }
    return DebugCredentialCache.enabled
        ? DebugCredentialCache.delete(key, () => _storage.delete(key: key))
        : _storage.delete(key: key);
  }
}
