import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

import 'debug_credential_cache.dart';

class SecureStorageService {
  // Runner 的 macOS Debug/Release 均未启用 App Sandbox；插件默认的 Data
  // Protection Keychain 需要相应 entitlement，在此签名下写入会报 -34018。
  // 普通 macOS Keychain 仍是系统安全存储，不回退到 Hive 明文。
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

  /// 非 Release 下先走 [DebugCredentialCache]：ad-hoc 签名的 debug 构建每次重建
  /// 都会让钥匙串把新二进制当成陌生程序并弹密码框，缓存把这次弹窗收敛到每个键
  /// 至多一次。Release 与 Web 直接落到平台安全存储，不经过缓存。
  Future<String?> _read(String key) => DebugCredentialCache.enabled
      ? DebugCredentialCache.read(key, () => _storage.read(key: key))
      : _storage.read(key: key);

  Future<void> _write(String key, String value) => DebugCredentialCache.enabled
      ? DebugCredentialCache.write(
          key,
          value,
          () => _storage.write(key: key, value: value),
        )
      : _storage.write(key: key, value: value);

  Future<void> _delete(String key) => DebugCredentialCache.enabled
      ? DebugCredentialCache.delete(key, () => _storage.delete(key: key))
      : _storage.delete(key: key);
}
