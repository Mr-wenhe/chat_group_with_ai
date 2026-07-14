import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

class SecureStorageService {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  static const String _apiKeyPrefix = 'api_key_';
  static const String _apiConfigKeyPrefix = 'api_config_key_';

  /// Raw operations are intentionally package-private to the storage layer.
  /// NOTE: [CredentialRepository] 是计划中的统一 LLM API key 边界，目前尚未被
  /// 业务代码接线（见其类上 TODO），实际读写仍由本类承接。迁移完成前请勿删除
  /// 本类的 apiConfig / wecom 方法。
  Future<void> writeRaw(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<String?> readRaw(String key) => _storage.read(key: key);

  Future<void> deleteRaw(String key) => _storage.delete(key: key);

  Future<void> saveApiKey(String characterId, String apiKey) async {
    await _storage.write(key: '$_apiKeyPrefix$characterId', value: apiKey);
  }

  Future<String?> getApiKey(String characterId) async {
    return await _storage.read(key: '$_apiKeyPrefix$characterId');
  }

  Future<void> deleteApiKey(String characterId) async {
    await _storage.delete(key: '$_apiKeyPrefix$characterId');
  }

  Future<bool> saveApiConfigKey(String configId, String apiKey) async {
    try {
      await _storage.write(key: '$_apiConfigKeyPrefix$configId', value: apiKey);
      return true;
    } on PlatformException {
      return false;
    }
  }

  Future<String?> getApiConfigKey(String configId) async {
    try {
      return await _storage.read(key: '$_apiConfigKeyPrefix$configId');
    } on PlatformException {
      return null;
    }
  }

  Future<void> deleteApiConfigKey(String configId) async {
    try {
      await _storage.delete(key: '$_apiConfigKeyPrefix$configId');
    } on PlatformException {
      // Some macOS debug builds do not have Keychain entitlements. Deleting the
      // Hive row still removes the config from the app in that environment.
    }
  }

  Future<void> saveDefaultProvider(String provider) async {
    await _storage.write(key: 'default_provider', value: provider);
  }

  Future<String?> getDefaultProvider() async {
    return await _storage.read(key: 'default_provider');
  }

  /// 企业微信自建应用配置（corpid / corpsecret / agentid），以 JSON 存于密钥库。
  static const String _wecomAppConfigKey = 'wecom_app_config';

  Future<void> saveWeComAppConfig(Map<String, String> config) async {
    await _storage.write(key: _wecomAppConfigKey, value: jsonEncode(config));
  }

  Future<Map<String, String>?> getWeComAppConfig() async {
    try {
      final raw = await _storage.read(key: _wecomAppConfigKey);
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
      await _storage.delete(key: _wecomAppConfigKey);
    } on PlatformException {
      // 同 deleteApiConfigKey：macOS debug 无 Keychain 权限时静默忽略。
    }
  }
}
